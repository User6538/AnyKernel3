/*
 * notif_keep_patch/binder_keep_notif.c — keep notification on force-stop (v3)
 *
 * 功能: 应用被强行停止 (force-stop) 后, 不移除该应用的通知。
 *       对全部应用生效。不影响其他操作 (用户手动清除/点击/清除全部等正常)。
 *
 * 拦截点: NMS -> SystemUI 的 INotificationListener.onNotificationRemoved
 *         (跨进程 binder 事务, 经过内核 binder 驱动)。
 *
 * 为什么拦截 onNotificationRemoved 而非 PACKAGE_RESTARTED 广播:
 *   NMS 通过进程内 BroadcastReceiver 接收 PACKAGE_RESTARTED, 同进程动态
 *   receiver 走 binder local fast path, 不经 binder 驱动, 内核层拦不到。
 *   但 NMS 移除通知后会跨进程调用 SystemUI 的 onNotificationRemoved,
 *   这一步经过 binder 驱动, 可精准拦截。
 *
 * 精准识别 force-stop (三层过滤):
 *   1. code == 3 (onNotificationRemoved 的 AIDL transaction code)
 *      → 99%+ binder 事务在此放行, 一次整数比较 ~1ns
 *   2. 读 Parcel 末尾 4 字节 reason 字段
 *      → reason == REASON_USER_STOPPED (6) 才是 force-stop 触发
 *      → 用户手动清除 (REASON_CANCEL=2)/点击 (REASON_CLICK=1)/
 *        清除全部 (REASON_CANCEL_ALL=3) 等正常操作 reason 不同, 放行
 *   3. 读 Parcel 头部确认 interface descriptor 是 INotificationListener
 *      → 防止其他接口的 code=3 + 末尾恰好为 6 的事务被误拦截
 *
 * 拦截方式: 将 t->code 改为 0 (无效 transaction code)。
 *   onNotificationRemoved 是 oneway 接口, SystemUI 的 onTransact 收到
 *   未知 code 走 default 分支返回 false, 事务被静默忽略, 通知不移除。
 *
 * 不影响:
 *   - 用户手动划掉通知 (REASON_CANCEL)
 *   - 用户点击通知 (REASON_CLICK)
 *   - 用户清除全部 (REASON_CANCEL_ALL)
 *   - 应用自己 cancel 通知 (REASON_APP_CANCEL / APP_CANCEL_ALL)
 *   - 通知超时移除 (REASON_TIMEOUT)
 *   - 通知显示 (onNotificationPosted, code=2, 不拦截)
 *   - PACKAGE_RESTARTED 广播 (AlarmManager/JobScheduler 正常处理)
 *   - 其他所有 binder 事务
 *
 * 前台通知技术约束 (重要):
 *   onNotificationRemoved 的 Parcel 参数是 IStatusBarNotificationHolder
 *   (一个 Binder 引用包装), 不含 Notification 对象本身。Notification
 *   数据需通过 holder.get() 二次 binder 调用获取, 不在本事务 buffer 里。
 *   因此无法在内核层区分前台/普通通知。
 *   实际影响: force-stop 后前台通知也保留。但 force-stop 时前台服务
 *   已停止, 通知保留只是显示 (不会恢复服务), 用户可手动划掉。
 *
 * 性能:
 *   - code != 3: ~1ns (99%+ 事务)
 *   - code == 3, reason != 6: copy_from_user 4 字节 ~1μs
 *   - reason == 6 (force-stop, 极低频): +256 字节 descriptor 搜索 ~3μs
 *   - 对 binder IPC 整体性能无可测量影响
 *
 * 不可检测性:
 *   - 无 sysctl / 无内核模块 / 无 debugfs / 无 tracepoint
 *   - 编译期生效, 运行时无任何可探测开关
 *   - 应用被 force-stop 后处于 stopped 状态, 收不到广播, 无法自测
 *
 * User6538/AnyKernel3 — keep notification on force-stop (v3)
 */

/* 前向声明 — 允许 binder_transaction() 在本函数定义之前调用
 * (函数顺序跨版本不确定, 前向声明保证编译通过) */
static bool nk_should_drop(binder_uintptr_t, binder_size_t, unsigned int);

/* INotificationListener.onNotificationRemoved 的 AIDL transaction code.
 * AIDL 方法按声明顺序从 FIRST_CALL_TRANSACTION(1) 编号:
 *   1: onListenerConnected
 *   2: onNotificationPosted
 *   3: onNotificationRemoved  ← 拦截目标
 *   4: onNotificationRankingUpdate
 *   5: onListenerHintsChanged
 *   6: onInterruptionFilterChanged
 * 跨 Android 12..16 稳定 (方法未重排, 新方法追加在末尾)。 */
#define NK_ON_REMOVED_CODE  3

/* 改为此 code 使 SystemUI onTransact 的 switch 走 default 分支,
 * 返回 false。onNotificationRemoved 是 oneway 接口, 调用方不检查
 * 返回值, 事务被 SystemUI 静默忽略, 通知不移除。 */
#define NK_DROP_CODE        0

/* NotificationListenerService.RemovalReason 常量值 (API 稳定, Android 10+):
 *   REASON_CLICK              = 1   用户点击通知
 *   REASON_CANCEL             = 2   用户划掉通知
 *   REASON_CANCEL_ALL         = 3   用户清除全部
 *   REASON_ERROR              = 4   通知渲染错误
 *   REASON_PACKAGE_CHANGED    = 5   包管理变更
 *   REASON_USER_STOPPED       = 6   用户上下文停止 (force-stop 触发)  ← 拦截
 *   REASON_PACKAGE_BANNED     = 7   用户禁用包通知
 *   REASON_APP_CANCEL         = 8   应用自己 cancel 单条
 *   REASON_APP_CANCEL_ALL     = 9   应用自己 cancel 全部
 *   REASON_LISTENER_CANCEL    = 10  listener 取消
 *   REASON_LISTENER_CANCEL_ALL= 11  listener 清除全部
 *   ...
 * 只拦截 REASON_USER_STOPPED (force-stop 场景), 其他全部放行。 */
#define NK_REASON_USER_STOPPED  6

/* INotificationListener 的 interface descriptor (UTF-16LE, 无 BOM).
 * Parcel.writeInterfaceToken() 在 buffer 头部写入此字符串。
 * "android.service.notification.INotificationListener" (47 字符 = 94 字节) */
static const u8 nk_desc_utf16[] = {
	'a',0,'n',0,'d',0,'r',0,'o',0,'i',0,'d',0,'.',0,
	's',0,'e',0,'r',0,'v',0,'i',0,'c',0,'e',0,'.',0,
	'n',0,'o',0,'t',0,'i',0,'f',0,'i',0,'c',0,'a',0,'t',0,
	'i',0,'o',0,'n',0,'.',0,'I',0,'N',0,'o',0,'t',0,'i',0,
	'f',0,'i',0,'c',0,'a',0,'t',0,'i',0,'o',0,'n',0,'L',0,
	'i',0,'s',0,'t',0,'e',0,'n',0,'e',0,'r',0
};

/* 内核没有 memmem, 自己实现一个简单的。 */
static const void *nk_memmem(const void *haystack, size_t hlen,
			     const void *needle, size_t nlen)
{
	const u8 *h = haystack;
	const u8 *n = needle;
	size_t i;

	if (nlen == 0 || hlen < nlen)
		return NULL;
	for (i = 0; i <= hlen - nlen; i++) {
		if (h[i] == n[0] && memcmp(h + i, n, nlen) == 0)
			return h + i;
	}
	return NULL;
}

/*
 * nk_should_drop - 检查 binder 事务是否是 force-stop 触发的
 *                 onNotificationRemoved, 是则应拦截
 * @user_buf: 调用方用户空间的事务数据指针 (tr->data.ptr.buffer)
 * @data_size: 数据大小 (tr->data_size)
 * @code: 事务 code (t->code, 来自 tr->code)
 *
 * 在 binder_transaction() 中、binder_proc_transaction() 调用前检查。
 * 此时 tr->data.ptr.buffer 指向调用方用户空间数据,
 * 可用 copy_from_user 安全读取。
 *
 * 返回 true = 应拦截 (调用方将 t->code 改为 NK_DROP_CODE, 通知保留)。
 * 返回 false = 放行 (正常操作, 通知正常移除)。
 *
 * onNotificationRemoved Parcel 布局 (Android 12+):
 *   [writeInterfaceToken(descriptor)]  ← 头部, 用于第 3 层 descriptor 校验
 *   [writeStrongBinder(holder)]        ← IBinder 引用, 不含 Notification 数据
 *   [writeParcelable(rankingUpdate)]
 *   [writeParcelable(stats)]
 *   [writeInt(reason)]                 ← 末尾 4 字节, 用于第 2 层 reason 判断
 */
static bool nk_should_drop(binder_uintptr_t user_buf,
			   binder_size_t data_size,
			   unsigned int code)
{
	unsigned int reason;
	u8 desc_buf[256];
	size_t desc_n;

	/* 第一层: code 快速过滤 (绝大多数事务在此返回, ~1ns) */
	if (code != NK_ON_REMOVED_CODE)
		return false;
	if (data_size < 4 + sizeof(nk_desc_utf16))
		return false;

	/* 第二层: 读 Parcel 末尾 4 字节 reason 字段。
	 * reason 是 onNotificationRemoved 的最后一个参数 (writeInt),
	 * 位于 buffer[data_size - 4, data_size)。copy_from_user 4 字节 ~1μs。 */
	if (copy_from_user(&reason,
			   (const void __user *)(unsigned long)(user_buf + data_size - 4),
			   sizeof(reason)))
		return false;  /* 读取失败, 保守放行 (不误拦截) */

	/* 只拦截 force-stop (REASON_USER_STOPPED = 6)。
	 * 其他 reason (用户手动清除/点击/清除全部, 应用自己 cancel,
	 * 超时等) 全部放行 — "不影响其他操作"。 */
	if (reason != NK_REASON_USER_STOPPED)
		return false;

	/* 第三层: 读 buffer 头部确认 interface descriptor。
	 * 防止其他 binder 接口的 code=3 + 末尾恰好为 6 的事务被误拦截。
	 * 只在 reason==6 时执行 (force-stop, 极低频)。 */
	desc_n = (size_t)data_size;
	if (desc_n > sizeof(desc_buf))
		desc_n = sizeof(desc_buf);
	if (copy_from_user(desc_buf,
			   (const void __user *)(unsigned long)user_buf,
			   desc_n))
		return false;  /* 读取失败, 保守放行 */

	if (!nk_memmem(desc_buf, desc_n, nk_desc_utf16, sizeof(nk_desc_utf16)))
		return false;  /* descriptor 不匹配, 非 INotificationListener, 放行 */

	/* 确认是 force-stop 触发的 onNotificationRemoved, 拦截。
	 * 调用方将 t->code 改为 NK_DROP_CODE, SystemUI 忽略事务, 通知保留。 */
	return true;
}

/* User6538/AnyKernel3 — keep notification on force-stop (v3) */
