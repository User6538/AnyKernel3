#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
inject_binder_notif.py — inject the notification-keep helper into binder.c

行号无关注入器, 跨 Android 13..16 / kernel 5.10..6.12 稳健。

两个注入点, 均锚定在所有版本都存在且唯一的代码模式:

  1. HELPER DEFINITION
     插入在 binder_proc_transaction() 文档注释前 (或函数签名前)。
     文档注释: "* binder_proc_transaction() - sends a transaction to a process"
     无注释时回退到函数签名: "binder_proc_transaction(struct binder_transaction *t,"

  2. CALL SITES (所有匹配, 通常 2 处: 同步路径 + 异步路径)
     插入在 binder_transaction() 中每次调用 binder_proc_transaction() 前。
     调用点特征: "binder_proc_transaction(t,"
     — 定义处是 "binder_proc_transaction(struct binder_transaction *t,"
       (括号后紧跟 struct, 不含 "(t,", 不会误匹配)
     — helper 注释中写 "binder_proc_transaction()" (带空括号, 不含 "(t,")
     跨版本兼容两种调用写法:
       旧版 (5.x):   "if (!binder_proc_transaction(t, ...))"
       新版 (6.6+):  "return_error = binder_proc_transaction(t, ...)"
     两种都包含 "binder_proc_transaction(t," 子串, 统一匹配。

     onNotificationRemoved 是 oneway (异步) 接口, 走异步路径调用点。
     但同步路径也可能传递通知相关事务, 因此所有调用点都需要注入。
     nk_should_drop 内部三层过滤确保非目标事务在 ~1ns 内放行, 冗余检查
     对性能无可测量影响。

     注入内容 (插入在调用所在行行首前):
         if (nk_should_drop(tr->data.ptr.buffer, tr->data_size, t->code))
             t->code = NK_DROP_CODE;
     此时 tr (binder_transaction_data *) 在作用域内, t->code 已赋值,
     数据已拷贝到目标 buffer, 可用 copy_from_user 从调用方用户空间读取。

Usage:
    python3 inject_binder_notif.py <binder.c path> <helper.c path>

幂等: 对已注入的文件重复运行是 no-op。
"""
import sys
import os

MARKER = "User6538/AnyKernel3 — keep notification on force-stop"

# 调用点锚点: 匹配 binder_transaction() 中对 binder_proc_transaction() 的调用。
# 定义处签名 "binder_proc_transaction(struct binder_transaction *t," 含 "struct",
# 不会匹配 "(t,"。helper 注释用 "binder_proc_transaction()" (空括号), 也不匹配。
CALL_NEEDLE = "binder_proc_transaction(t,"


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def find_all(haystack, needle, start=0):
    """返回 needle 在 haystack 中从 start 起所有出现位置的索引列表。"""
    positions = []
    pos = start
    while True:
        idx = haystack.find(needle, pos)
        if idx < 0:
            break
        positions.append(idx)
        pos = idx + len(needle)
    return positions


def extract_indent(src, line_start, target_idx):
    """从 line_start 到 target_idx 的文本中提取前导空白 (tab/space)。"""
    prefix = src[line_start:target_idx]
    indent = ""
    for ch in prefix:
        if ch in " \t":
            indent += ch
        else:
            break
    if not indent:
        indent = "\t"
    return indent


def main():
    if len(sys.argv) != 3:
        print("usage: inject_binder_notif.py <binder.c> <helper.c>",
              file=sys.stderr)
        return 2
    binder_path = sys.argv[1]
    helper_path = sys.argv[2]
    if not os.path.isfile(binder_path):
        print(f"binder.c not found: {binder_path}", file=sys.stderr)
        return 1
    if not os.path.isfile(helper_path):
        print(f"helper not found: {helper_path}", file=sys.stderr)
        return 1

    src = read(binder_path)
    helper = read(helper_path)

    # 幂等: 已注入则跳过
    if MARKER in src:
        print(f"already patched ({MARKER}), skipping")
        return 0

    # --- 锚点 1: helper 定义 ---
    # 优先: binder_proc_transaction() 文档注释前
    # 回退: 函数签名行前
    doc_needle = "* binder_proc_transaction() - sends a transaction"
    sig_needle = "binder_proc_transaction(struct binder_transaction *t,"
    doc_idx = src.find(doc_needle)
    if doc_idx >= 0:
        block_open = src.rfind("/**", 0, doc_idx)
        if block_open < 0:
            block_open = src.rfind("\n", 0, doc_idx) + 1
        else:
            block_open = src.rfind("\n", 0, block_open) + 1
    else:
        sig_idx = src.find(sig_needle)
        if sig_idx < 0:
            print("anchor 1 not found: neither binder_proc_transaction doc "
                  "comment nor function signature present", file=sys.stderr)
            print("the function may have been renamed or removed",
                  file=sys.stderr)
            return 1
        block_open = src.rfind("\n", 0, sig_idx) + 1

    helper_block = helper.rstrip("\n") + "\n\n"
    src = src[:block_open] + helper_block + src[block_open:]

    # --- 锚点 2: 所有调用点 ---
    # 从 helper 注入后的整个文件搜索 (不限制搜索起点)。
    # binder_proc_transaction 通常定义在 binder_transaction 之前 (C 语言要求
    # 先定义后调用), helper 插入在定义前, 调用点在 helper 之后。
    # 但某些版本可能用前向声明, 定义在调用之后, 因此从文件开头搜索最安全。
    #
    # CALL_NEEDLE = "binder_proc_transaction(t," 精确匹配调用点:
    # - 定义处 "binder_proc_transaction(struct binder_transaction *t," → 有 struct, 不匹配
    # - helper 注释 "binder_proc_transaction()" → 空括号, 不匹配
    # - 调用处 "binder_proc_transaction(t, target_proc, ...)" → 匹配 ✓
    # 跨版本兼容: "if (!binder_proc_transaction(t, ...)" (旧 5.x) 和
    #             "return_error = binder_proc_transaction(t, ...)" (新 6.6+) 都匹配。
    call_sites = find_all(src, CALL_NEEDLE, block_open + len(helper_block))

    # 如果 helper 之后没找到, 从文件开头搜索 (前向声明场景: 定义在调用之后)
    if not call_sites:
        call_sites = find_all(src, CALL_NEEDLE, 0)

    if not call_sites:
        print(f"anchor 2 not found: '{CALL_NEEDLE}' call sites "
              "in binder_transaction()", file=sys.stderr)
        print("helper was inserted but no call sites were found — "
              "binder_proc_transaction may have been refactored",
              file=sys.stderr)
        # 不写入文件: helper 无调用点会导致 -Wunused-function 编译错误,
        # 不如直接失败, 让构建流程报错 (exit 1), 避免写入半成品。
        return 1

    # 逆序注入: 从最后一个调用点开始向前插入, 保持前面调用点的索引不变。
    for call_idx in reversed(call_sites):
        line_start = src.rfind("\n", 0, call_idx) + 1
        indent = extract_indent(src, line_start, call_idx)
        inject = (
            f"\n{indent}/* User6538/AnyKernel3 — keep notification "
            f"on force-stop */\n"
            f"{indent}if (nk_should_drop(tr->data.ptr.buffer, "
            f"tr->data_size, t->code))\n"
            f"{indent}\tt->code = NK_DROP_CODE;\n"
        )
        src = src[:line_start] + inject + src[line_start:]

    # --- 写回 ---
    with open(binder_path, "w", encoding="utf-8") as f:
        f.write(src)

    # --- 校验 ---
    if MARKER not in src:
        print("verification failed: marker not present after injection",
              file=sys.stderr)
        return 1
    # 校验调用点: nk_should_drop(tr->data.ptr.buffer 只出现在注入的调用中,
    # 不出现在 helper 定义 (定义用 binder_uintptr_t user_buf)。
    call_count = src.count("nk_should_drop(tr->data.ptr.buffer")
    if call_count == 0:
        print("verification failed: nk_should_drop call site not present "
              "(only definition found)", file=sys.stderr)
        return 1
    if "NK_DROP_CODE" not in src:
        print("verification failed: NK_DROP_CODE not present",
              file=sys.stderr)
        return 1
    print(f"patched {binder_path}: helper injected + {call_count} call "
          f"site(s) wired ({MARKER})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
