#!/usr/bin/env bash
# 应用 SUSFS 补丁及各内核版本所需的上下文修复
#
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

# ==================== 目标内核位占用校验（把“假定空闲”变成“构建期可验证”） ====================
# SUSFS 把自己的私有标志塞进内核既有字段的空闲位/值，这些位都不是给第三方用的：
#   AS_FLAGS_SUS_PATH / SUS_MOUNT / SUS_KSTAT / OPEN_REDIRECT / SUS_MAP -> inode->i_mapping->flags
#   TIF_PROC_UMOUNTED / TIF_PROC_NO_SU / TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT -> thread_info.flags
#   ND_STATE_LOOKUP_LAST / ND_STATE_OPEN_LAST -> nd->state；ND_FLAGS_LOOKUP_LAST -> nd->flags
#   STATX_SUS_KSTAT -> statx 的 request_mark
# 上游会继续占用这些空间（如 6.12 起 AS_ 的 1~31 段被 folio order 等占满），厂商内核也可能
# 占用同一位；本次排查的崩溃正是该位被内核侧占用/残留所致。这里在应用补丁前对“本次真正要构建
# 的内核树”做一次实际扫描：解析目标内核头文件里这些字段已定义的位/值，并全树收集写在字段上的
# 字面量位，再与 SUSFS 选取的位逐一比对。冲突 -> ::error:: 中断构建；无法判定 -> ::warning::。
# 只做校验，不修改任何 SUSFS 特性开关。
if [ -d ./common ]; then
  echo "校验 SUSFS 私有位在目标内核中的占用情况..."
  python3 - <<'PYEOF'
import os, re, sys

KROOT = "common"

SUSFS_DEF_PATHS = ["common/include/linux/susfs_def.h"]
_env = os.environ.get("SUSFS4KSU", "")
if _env:
    SUSFS_DEF_PATHS.append(os.path.join(_env, "kernel_patches/include/linux/susfs_def.h"))

def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""

susfs_src = None
for _p in SUSFS_DEF_PATHS:
    if os.path.isfile(_p):
        susfs_src = _p
        break
if susfs_src is None:
    print("::warning::未找到 susfs_def.h，跳过 SUSFS 私有位占用校验")
    sys.exit(0)

NUM_RE = r"(?:0[xX][0-9a-fA-F]+|[0-9]+)"
DEF_RE = re.compile(r"^#define\s+([A-Z][A-Z0-9_]*)\s+([0-9A-Za-z_()\s+\-*<>x]+?)\s*(?:/\*.*)?$", re.M)
ENUM_RE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*([^,\n]+?)\s*,", re.M)
BITOP_RE = re.compile(r"\b(?:__)?(?:set|clear|test|test_and_set|change|assign)_bit\s*\(\s*(0[xX][0-9a-fA-F]+|[0-9]+)\s*,")

def resolve(expr, table):
    expr = expr.strip()
    expr = re.sub(r"[uUlL]+$", "", expr)
    if re.fullmatch(NUM_RE, expr):
        return int(expr, 0)
    if not re.fullmatch(r"[0-9A-Za-z_()\s+\-*<>]+", expr):
        return None
    tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_]*|0[xX][0-9a-fA-F]+|[0-9]+|[()+\-*<>]|\s+", expr)
    if "".join(tokens) != expr:
        return None
    parts = []
    for tok in tokens:
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tok):
            if tok not in table:
                return None
            parts.append(str(table[tok]))
        elif re.fullmatch(r"0[xX][0-9a-fA-F]+|[0-9]+", tok):
            parts.append(str(int(tok, 0)))
        else:
            parts.append(tok)
    try:
        return int(eval("".join(parts), {"__builtins__": {}}, {}))
    except Exception:
        return None

def collect(rel_path, prefix, table):
    path = os.path.join(KROOT, rel_path)
    if not os.path.isfile(path):
        return False
    text = read_text(path)
    for _ in range(3):
        for rx in (DEF_RE, ENUM_RE):
            for m in rx.finditer(text):
                name = m.group(1)
                if not name.startswith(prefix) or name in table:
                    continue
                val = resolve(m.group(2), table)
                if val is not None:
                    table[name] = val
    return True

SUSFS_WANTED = ("AS_FLAGS_", "TIF_PROC_", "ND_STATE_", "ND_FLAGS_", "STATX_")
susfs_defs = {}
_sdef_text = read_text(susfs_src)
for m in DEF_RE.finditer(_sdef_text):
    if not m.group(1).startswith(SUSFS_WANTED):
        continue
    val = resolve(m.group(2), susfs_defs)
    if val is None:
        try:
            val = int(m.group(2), 0)
        except ValueError:
            continue
    susfs_defs[m.group(1)] = val

FIELDS = {
    "mapping":     ("AS_",      ["include/linux/pagemap.h", "include/linux/fs.h"], "bits"),
    "thread_info": ("TIF_",     ["arch/arm64/include/asm/thread_info.h", "include/linux/thread_info.h"], "bits"),
    # nd->state 在内核里用的是 ND_ROOT_PRESET/ND_ROOT_GRABBED/ND_JUMPED（fs/namei.c），
    # nd->flags 用的是 LOOKUP_*（include/linux/namei.h），二者都按位掩码比对。
    "nd_state":    ("ND_",      ["fs/namei.c", "include/linux/namei.h"], "value_mask"),
    "nd_flags":    ("LOOKUP_",  ["include/linux/namei.h"], "value_mask"),
    "statx":       ("STATX_",   ["include/uapi/linux/stat.h"], "value_mask"),
}
CHECK = [
    ("AS_FLAGS_SUS_PATH", "mapping"),
    ("AS_FLAGS_SUS_MOUNT", "mapping"),
    ("AS_FLAGS_SUS_KSTAT", "mapping"),
    ("AS_FLAGS_OPEN_REDIRECT", "mapping"),
    ("AS_FLAGS_SUS_MAP", "mapping"),
    ("TIF_PROC_UMOUNTED", "thread_info"),
    ("TIF_PROC_NO_SU", "thread_info"),
    ("TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT", "thread_info"),
    ("ND_STATE_LOOKUP_LAST", "nd_state"),
    ("ND_STATE_OPEN_LAST", "nd_state"),
    ("ND_FLAGS_LOOKUP_LAST", "nd_flags"),
    ("STATX_SUS_KSTAT", "statx"),
]

occ = {}
for key, (prefix, files, kind) in FIELDS.items():
    table = {}
    present = False
    for _ in range(3):
        for rel in files:
            if collect(rel, prefix, table):
                present = True
    values = dict(table)
    if key == "mapping":
        mn = table.get("AS_FOLIO_ORDER_MIN")
        mx = table.get("AS_FOLIO_ORDER_MAX")
        if mn is not None and mx is not None and 0 <= mn <= mx < 512:
            for b in range(mn, mx + 1):
                values["AS_FOLIO_ORDER_RANGE@%d" % b] = b
    occ[key] = {"kind": kind, "values": values, "present": present}

HINTS = {
    "mapping": ["i_mapping->flags", "mapping->flags", "i_data.flags"],
    "thread_info": ["thread_info"],
    "nd_state": ["nd->state", "nameidata"],
    "nd_flags": ["nd->flags"],
    "statx": ["request_mask"],
}
SKIP_FILES = ("fs/susfs.c", "include/linux/susfs_def.h", "include/linux/susfs.h")

def scan_literals():
    found = {k: {} for k in HINTS}
    for root, dirs, files in os.walk(KROOT):
        dirs[:] = [d for d in dirs if d not in (".git", ".tmp_versions")]
        for fn in files:
            if not fn.endswith((".c", ".h")):
                continue
            rel = os.path.relpath(os.path.join(root, fn), KROOT).replace(os.sep, "/")
            if rel in SKIP_FILES:
                continue
            path = os.path.join(root, fn)
            try:
                if os.path.getsize(path) > 6 * 1024 * 1024:
                    continue
            except OSError:
                continue
            text = read_text(path)
            for m in BITOP_RE.finditer(text):
                ln_start = text.rfind("\n", 0, m.start()) + 1
                ln_end = text.find("\n", m.end())
                line = text[ln_start:(ln_end if ln_end != -1 else len(text))]
                if "SUSFS" in line:
                    continue
                where = "%s:%d" % (rel, text.count("\n", 0, m.start()) + 1)
                for key, hints in HINTS.items():
                    if not any(h in line for h in hints):
                        continue
                    if key == "thread_info" and "->flags" not in line:
                        continue
                    if key == "nd_state" and "state" not in line:
                        continue
                    found[key].setdefault(int(m.group(1), 0), where)
    return found

for key, lit in scan_literals().items():
    for val, where in lit.items():
        occ[key]["values"].setdefault("literal@%s" % where, val)
    if lit:
        occ[key]["present"] = True

errors, warns, rows = [], [], []
for macro, field in CHECK:
    if macro not in susfs_defs:
        rows.append((macro, "-", "-", "该分支未定义，跳过"))
        warns.append("%s 未在 susfs_def.h 中定义（该内核分支可能未启用该宏），跳过校验" % macro)
        continue
    val = susfs_defs[macro]
    info = occ[field]
    values = info["values"]
    if not info["present"] or not values:
        rows.append((macro, str(val), "未知", "无法判定"))
        warns.append("未能从目标内核解析 %s 字段（%s），%s=%s 未被校验" % (field, "/".join(FIELDS[field][1]), macro, val))
        continue
    hit = None
    for oname, oval in sorted(values.items()):
        if info["kind"] == "bits" or info["kind"] == "value_eq":
            if val == oval:
                hit = (oname, oval)
                break
        else:
            if val == oval or (val and (val & oval) == val):
                hit = (oname, oval)
                break
    if hit:
        rows.append((macro, str(val), "%s=%s" % (hit[0], hit[1]), "冲突"))
        errors.append("%s=%s 已被目标内核占用：%s=%s（%s 字段）" % (macro, val, hit[0], hit[1], field))
    else:
        rows.append((macro, str(val), "已占用 %d 项，均不相交" % len(values), "空闲"))

print("--- SUSFS 私有位占用校验（目标内核目录：%s）---" % KROOT)
for macro, val, used, verdict in rows:
    print("  %-36s %-6s %-30s %s" % (macro, val, used, verdict))
for w in warns:
    print("::warning::" + w)
if errors:
    for e in errors:
        print("::error::" + e)
    print("::error::SUSFS 私有位与目标内核冲突，请调整 kernel_patches/include/linux/susfs_def.h 的位选择，"
          "或改用不会与内核自有位重叠的存储方案；不要通过关闭 SUSFS/SUS_PATH 等特性来规避")
    sys.exit(1)
print("SUSFS 私有位占用校验通过：%d 项位/值均未被目标内核占用" % len([r for r in rows if r[3] == "空闲"]))
PYEOF
else
  echo "::warning::未找到 ./common 内核源码目录，跳过 SUSFS 私有位占用校验"
fi

# FinaSU 上游自 cdf8711a + 5b83330b（2026-10-23）起树内原生集成 SUSFS，官方
# docs/builtin-integration.md 明确要求**不要**应用 susfs4ksu 的
# 10_enable_susfs_for_ksu.patch（该补丁面向上游 KernelSU 手动钩子模型，会把
# hook/tp_marker.o 等编译单元移出 Kbuild，而 FinaSU 的 kprobe 模型仍引用这些
# 符号，驱动侧一旦打补丁就会在 vmlinux 链接阶段报 undefined symbol）。
# 至此 FinaSU 与 SukiSU/BakaSU 形态一致：驱动侧不打补丁；差异仅在于 FinaSU
# 的原生集成较新，这里顺带校验其结构（内核侧 50_add 主补丁的内联钩子依赖
# 这些入口点/符号），漂移时立即报错而不是静默退化。
verify_finasu_native_susfs() {
  local FINASU_KSU="$KERNEL_ROOT/KernelSU/kernel"
  local OPT SYM

  if [ ! -f "$FINASU_KSU/extension/susfs.c" ]; then
    echo "::error::FinaSU 未包含原生 SUSFS 集成（缺少 KernelSU/kernel/extension/susfs.c）。" >&2
    echo "::error::当前检出的 FinaSU 早于 5b83330b（2026-10-23），或上游结构再次变化；" >&2
    echo "::error::旧的 10_enable 驱动侧补丁方案已随上游原生集成废弃，请确认 ksuCommit 指向最新 Release。" >&2
    exit 1
  fi

  # Kconfig 自带完整 KSU_SUSFS 菜单（「添加 SUSFS 配置」写入的 CONFIG_KSU_SUSFS*
  # 必须全部有对应定义，否则 olddefconfig 会静默丢弃）
  for OPT in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
             KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
             KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP; do
    grep -q "^config $OPT\$" "$FINASU_KSU/Kconfig" \
      || { echo "::error::FinaSU Kconfig 缺少 config $OPT（上游结构可能已变化）" >&2; exit 1; }
  done

  # extension/susfs.c 提供 50_add 主补丁在 fs/exec.c 内联调用的入口点；
  # preinit 入口在较新 FinaSU 中已移到 kernel/preinit/preinit.c，兼容旧布局。
  for SYM in ksu_handle_execveat ksu_handle_execveat_sucompat ksu_handle_post_execveat_sucompat; do
    grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/extension/susfs.c" \
      || { echo "::error::FinaSU extension/susfs.c 缺少全局入口点: $SYM" >&2; exit 1; }
  done

  for SYM in ksu_setup_preinit_file ksu_preinit_handle_post_execveat; do
    if grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/preinit/preinit.c" 2>/dev/null; then
      continue
    fi
    grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/extension/susfs.c" \
      || { echo "::error::FinaSU 缺少全局入口点: $SYM（已检查 preinit/preinit.c 与 extension/susfs.c）" >&2; exit 1; }
  done

  # 三参数 SUSFS 实现（内核侧 kernel/sys.c 的 3 参调用依赖该签名）
  grep -q '^int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)$' "$FINASU_KSU/hook/setuid_hook.c" \
    || { echo "::error::FinaSU setuid_hook.c 缺少三参数 ksu_handle_setresuid（上游结构可能已变化）" >&2; exit 1; }

  # my_* 符号已全局导出（6.6/6.12 主补丁在 security/selinux/{hooks,selinuxfs}.c 内联调用）
  for SYM in my_write_context my_write_access my_setprocattr; do
    grep -qE "^(ssize_t|int) $SYM\(" "$FINASU_KSU/feature/selinux_hide.c" \
      || { echo "::error::FinaSU selinux_hide.c 未全局导出 $SYM（SUSFS 内联 SELinux 钩子将无法链接）" >&2; exit 1; }
  done

  # susfs_init() 由驱动 init 原生调用
  grep -q 'susfs_init();' "$FINASU_KSU/core/init.c" \
    || { echo "::error::FinaSU init.c 未调用 susfs_init()（上游结构可能已变化）" >&2; exit 1; }

  echo "FinaSU 原生 SUSFS 集成校验通过"
}

case "$KSU_VARIANT" in
  "SukiSU"|"BakaSU")
    echo "SukiSU/BakaSU 使用内置 SUSFS 支持"
    ;;
  "FinaSU")
    echo "FinaSU 使用树内原生 SUSFS 集成（驱动侧不打补丁，形态同 SukiSU/BakaSU）"
    verify_finasu_native_susfs
    ;;
esac

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# 兼容缺少 VMA padding 接口的 5.10.66～209、5.15.74～144 和 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# 临时调整旧内核源码上下文，使 SUSFS 主补丁可以匹配
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "临时调整 Android 12 5.10 base.c 上下文"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "临时调整 Android 12 5.10 fdinfo.c 上下文"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "临时调整 Android 13 5.15 namespace.c/open.c/fdinfo.c 上下文"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  # 5.15.220(LTS) 原生含 #include <trace/hooks/{mm,blk}.h>。上游 rebase 后
  # 主补丁已把这两行当作 susfs_def.h 插入 hunk 的上下文，旧版「先删后补」的
  # 临时调整反而会让 hunk 整段被拒，故不再删除；缺失上下文的版本由
  # normalize_trace_ctx.py 归一化补丁副本处理。
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 sched.h 上下文"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    echo "临时调整 Android 14 6.1 namespace.c 上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 15 6.6 base.c 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "临时调整 Android 15 6.6 memory.c 上下文"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

# 6.12 主补丁的 fs/exec.c 首个 hunk 以 `#include <linux/dma-buf.h>`（紧跟 ksm.h）
# 作为插入 susfs_def.h 的上下文锚点。GKI 6.12.58+ 的 exec.c 原生就是这个形态，
# 补丁可直接匹配；6.12.23~38 没有这行 dma-buf.h，hunk 会被整段拒绝，exec.c 因此
# 缺少 susfs_def.h，do_execveat_common() 里的 susfs_is_current_proc_no_su()
# 变成隐式声明，clang -Werror 直接中断编译。
# 仅当源码缺少该上下文时改写补丁副本：丢掉这行陈旧上下文并重算 hunk 行数；
# 源码本身不做任何增删（原「先删 dma-buf.h、事后补到文件头」的错位调整已移除）。
normalize_exec_include_hunk() {
  python3 - "$SUSFS_PATCH" <<'PYEOF'
import re
import sys

path = sys.argv[1]
src = open("fs/exec.c", encoding="utf-8", errors="surrogateescape").read()
if "#include <linux/ksm.h>\n#include <linux/dma-buf.h>" in src:
    print("fs/exec.c 原生含 dma-buf.h 锚点，主补丁可直接匹配，跳过归一化")
    raise SystemExit(0)

with open(path, encoding="utf-8", errors="surrogateescape") as f:
    lines = f.read().splitlines()

hdr = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
out, i, dropped = [], 0, 0

while i < len(lines):
    line = lines[i]
    m = hdr.match(line)
    if not m:
        out.append(line)
        i += 1
        continue

    j = i + 1
    body = []
    while j < len(lines) and not lines[j].startswith(("@@", "diff --git")):
        body.append(lines[j])
        j += 1

    # 只处理「插入 susfs_def.h 且以 dma-buf.h 为上下文」的那个 hunk
    if any(l.strip() == "#include <linux/dma-buf.h>" for l in body) \
            and any("susfs_def.h" in l for l in body):
        kept = [l for l in body if l.strip() != "#include <linux/dma-buf.h>"]
        dropped += len(body) - len(kept)
        old = sum(1 for l in kept if l[:1] in (" ", "-"))
        new = sum(1 for l in kept if l[:1] in (" ", "+"))
        line = "@@ -%s,%d +%s,%d @@" % (m.group(1), old, m.group(3), new)
        body = kept

    out.append(line)
    out.extend(body)
    i = j

if dropped:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("\n".join(out) + "\n")
    print("fs/exec.c 补丁上下文已归一化（移除 %d 行陈旧 dma-buf 上下文）" % dropped)
else:
    print("fs/exec.c 补丁上下文无需归一化")
PYEOF
}

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  echo "归一化 Android 16 6.12 主补丁的 fs/exec.c 头文件上下文"
  normalize_exec_include_hunk
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

# 上游 rebase 到 5.15.211 后，susfs_def.h 的插入 hunk 把 trace/hooks 头文件
# 当成了上下文：5.15.74~194 源码没有这些行，hunk 会整段被拒，最终因
# SUSFS_IS_INODE_* 隐式声明在 clang -Werror 处中断。按源码实际内容归一化补丁副本。
echo "归一化 SUSFS 头文件上下文"
python3 "$SCRIPT_DIR/normalize_trace_ctx.py" "$SUSFS_PATCH"

patch -p1 < "$SUSFS_PATCH" || true

# ==================== FinaSU 新 selinux_hide 模型适配 ====================
# 自 FinaSU v0.1.0-preview1 起，kernel/feature/selinux_hide.c 换成了 tiann 新形态：
#   移除 fake_state；统一用 backup_sepolicy + security_context_to_sid_with_policy(..., &orig_sid_p, &orig_rc_p)（8 参）；
#   且该函数内部已做“双策略 + 全局 sidtab 同步”（KernelSU #3877/#3873）。
# 此形态下把 SUSFS 主补丁 <6.6 的 SELinux 代码也从 &fake_state 切到 backup_sepolicy + 8 参 _with_policy，
# 并补上权限检查顺序（df03912f）；sidtab 同步由上游 _with_policy 内置，无需外部再移植。
NEW_MODEL=0
FINASU_SELINUX_HIDE="$KERNEL_ROOT/KernelSU/kernel/feature/selinux_hide.c"
if [ -f "$FINASU_SELINUX_HIDE" ] && ! grep -q 'fake_state' "$FINASU_SELINUX_HIDE"; then
  NEW_MODEL=1
fi
# 触发条件：
#   <6.6（5.10/5.15/6.1）主补丁内联改 selinuxfs 调用点 / selinux_setprocattr，引用 &fake_state；
#   >=6.6（6.6/6.12）主补丁用 backup_sepolicy + 内核侧自含的 my_security_context_to_sid，
#   不引用 fake_state，无需本分支（条件里两个 grep 均不命中，自动跳过）。
# <6.6 必须从 fake_state 切到 backup_sepolicy + 8 参 _with_policy，否则新形态 FinaSU 无
# fake_state 定义会导致 ThinLTO 链接报 undefined symbol: fake_state。
if [ "$NEW_MODEL" = 1 ] && [ -f security/selinux/selinuxfs.c ] \
  && { grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c \
       || grep -q '&fake_state' security/selinux/selinuxfs.c; }; then
  echo "检测到 FinaSU 新 selinux_hide 形态：SUSFS <6.6 的 SELinux 代码切换到 backup_sepolicy + 8 参 _with_policy"
  python3 - <<'PYEOF'
import re as _re, sys as _sys

NEW_FS_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
    "extern int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext, u32 *scontext_len);\n"
    "extern void security_compute_av_user_with_policy(struct selinux_policy *policy, u32 ssid, u32 tsid, u16 tclass, struct av_decision *avd);\n"
)
NEW_HK_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
)

def _sub(path, name, old, new):
    s = open(path, encoding="utf-8", errors="surrogateescape").read()
    n = s.count(old)
    if n != 1:
        print("::warning::%s: %s count=%d (expect 1)" % (path, name, n))
        return
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old, new, 1))
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
_sub(fs, "extern", "extern struct selinux_state fake_state;\n", NEW_FS_EXTERNS)
_sub(fs, "ctx", "security_context_to_sid(&fake_state, buf, size, &sid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "sid2ctx", "security_sid_to_context(&fake_state, sid, &canon, &len)",
     "security_sid_to_context_with_policy(backup_sepolicy, sid, &canon, &len)")
_sub(fs, "scon", "security_context_str_to_sid(&fake_state, scon, &ssid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, scon, strlen(scon), &ssid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "tcon", "security_context_str_to_sid(&fake_state, tcon, &tsid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, tcon, strlen(tcon), &tsid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "av", "security_compute_av_user(&fake_state, ssid, tsid, tclass, &avd)",
     "security_compute_av_user_with_policy(backup_sepolicy, ssid, tsid, tclass, &avd)")

hk = "security/selinux/hooks.c"
_sub(hk, "extern", "extern struct selinux_state fake_state;\n", NEW_HK_EXTERNS)

# <6.6 形态：resolve(&fake_state, value) -> _with_policy(8 参)
#   6.1 主补丁为多行 &sid；5.15 主补丁为单行 &tmp_sid。两种都归一化。
_hs = open(hk, encoding="utf-8", errors="surrogateescape").read()
_hs, _n = _re.subn(r"security_context_to_sid\(&fake_state, value, size,\s*\n\s*&sid, GFP_KERNEL\)",
                   "security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", _hs)
_hs, _n15 = _re.subn(r"security_context_to_sid\(&fake_state, value, size, &tmp_sid, GFP_KERNEL\)",
                     "security_context_to_sid_with_policy(backup_sepolicy, value, size, &tmp_sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", _hs)
print("%s: setprocattr.ctx <6.6=%d/%d" % (hk, _n, _n15))
open(hk, "w", encoding="utf-8", errors="surrogateescape").write(_hs)

# >=6.6 形态：把已有的 6 参 _with_policy 声明/调用补成 8 参（新模型签名）
#   6.6 主补丁在 security/selinux/{hooks,selinuxfs}.c 里自带 6 参 extern 声明，
#   只把调用补成 8 参会报 "too many arguments to function call, expected 6, have 8"。
#   因此 extern 声明必须与调用一起改成 8 参（新 FinaSU 的定义是 8 参）。
for _lab, _f in (("selinuxfs", fs), ("hooks", hk)):
    _s = open(_f, encoding="utf-8", errors="surrogateescape").read()
    # (?!, NULL, NULL) 保证幂等：<6.6 已由上文 _sub 切成 8 参的调用不再重复追加
    _s, _n2 = _re.subn(r"(security_context_to_sid_with_policy\(backup_sepolicy,[^;]*?, GFP_KERNEL)\)(?!, NULL, NULL)", r"\1, NULL, NULL)", _s)
    _s, _nd = _re.subn(r"(security_context_to_sid_with_policy\(struct selinux_policy \*policy, const char \*scontext, u32 scontext_len,\s*\n\s*u32 \*sid, u32 def_sid, gfp_t gfp_flags)\);", r"\1, u32 *orig_sid_p, int *orig_rc_p);", _s)
    open(_f, "w", encoding="utf-8", errors="surrogateescape").write(_s)
    print("%s: _with_policy 8-arg normalize=%d decl=%d" % (_lab, _n2, _nd))

_hs = open(hk, encoding="utf-8", errors="surrogateescape").read()
# 主补丁 setprocattr 两种形态：
#   旧形态（~2026-08 前的主补丁）：定义 my_setprocattr，内含无条件 SETCURRENT avc_has_perm
#     —— 需要 rm_early 移除 + seq 重排（df03912f）；
#   现行形态（2026-10 起的主补丁）：内联改 selinux_setprocattr，用 should_check_current +
#     fake_error 门控 —— 权限顺序天然满足 df03912f，且 fake 解析经上文 setprocattr.ctx
#     转换后已走 8 参 _with_policy（sidtab 同步内置），rm_early/seq 无目标代码。
if "should_check_current" in _hs and "fake_error = security_context_to_sid_with_policy(backup_sepolicy, value, size, &tmp_sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)" in _hs:
    print("%s: 主补丁为现行门控形态（should_check_current+fake_error），rm_early_setcurrent/seq 不适用，侧信道语义已覆盖" % hk)
else:
    # 去掉无条件 SETCURRENT 检查（df03912f）：覆盖 <6.6(&selinux_state) 与 >=6.6(无 state) 两种形态
    _removed = False
    for _rm in ("\terror = avc_has_perm(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n",
                "\terror = avc_has_perm(mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n"):
        if _hs.count(_rm) == 1:
            _hs = _hs.replace(_rm, "", 1)
            _removed = True
            print("%s: rm_early_setcurrent OK" % hk)
            break
    if not _removed:
        print("::warning::%s: rm_early_setcurrent not matched" % hk)
    # 仅在 backup 解析失败时才检查 SETCURRENT
    _seq_done = False
    for _old2, _new2, _lab in (
        ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error)\n\t\t\treturn error;\n",
         "\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n", "<6.6"),
        ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error)\n\t\t\treturn error;\n",
         "\t\terror = security_context_to_sid_with_policy(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n", ">=6.6")):
        if _hs.count(_old2) == 1:
            _hs = _hs.replace(_old2, _new2, 1)
            _seq_done = True
            print("%s: seq(%s) OK" % (hk, _lab))
            break
    if not _seq_done:
        print("::warning::%s: seq not matched" % hk)
open(hk, "w", encoding="utf-8", errors="surrogateescape").write(_hs)
for _f in (fs, hk):
    _s = open(_f, encoding="utf-8", errors="surrogateescape").read()
    if "fake_state" in _s:
        _sys.stderr.write("::error::%s 仍有 fake_state 残留\n" % _f)
        _sys.exit(1)
PYEOF
  # 仅作信息输出；5.15 主补丁不含 perm_error（权限顺序重排只适配 my_write_context 形态），
  # 这里 grep 可能无命中，必须 || true，否则 set -e 会中断整个补丁步骤。
  grep -n 'backup_sepolicy' security/selinux/selinuxfs.c | head -3 || true
  grep -n 'perm_error' security/selinux/hooks.c | head -3 || true
fi

# ==================== 移植 KernelSU 的 SELinux 隐藏侧信道修复（旧 fake_state 形态）====================
# 仅当 SUSFS 主补丁为旧形态（定义 my_write_context/my_write_access/my_setprocattr）时适用。
# 检测方把 /sys/fs/selinux/{context,access} 与 setprocattr 当 oracle：比对
# 假策略(fake_state)与全局 selinux_state 的 SID、以及权限检查顺序，来识别隐藏。
# SUSFS 主补丁实现的 my_write_context / my_write_access / my_setprocattr 缺这两点，
# 这里按 KernelSU 的做法补齐：
#   - sidtab 同步（KernelSU #3873）：用假策略解析后再同步进全局 sidtab，消除 SID 差异；
#   - 权限检查顺序（KernelSU df03912f）：仅当 backup 解析失败时才做 SETCURRENT 检查。
# 现行主补丁（2026-10 起）已不定义这三个函数：<6.6 的门控内联形态与 NEW_MODEL 分支的
# 8 参 _with_policy 转换（sidtab 同步内置）已覆盖同等的侧信道修复，见下方 else 分支说明。
if [ "${NEW_MODEL:-0}" != 1 ] && [ -f security/selinux/selinuxfs.c ] && grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c \
  && [ -f security/selinux/hooks.c ] && grep -q 'static int my_setprocattr' security/selinux/hooks.c; then
  python3 - <<'PYEOF'
import re

def sed(path, name, pat, repl):
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    new, n = re.subn(pat, repl, src, count=1)
    if n == 0:
        print("::warning::%s: %s not matched (skip)" % (path, name))
        return
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(new)
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
# my_write_context（<6.6 用 fake_state；>=6.6 用 backup_sepolicy 的 _with_policy 解析）
sed(fs, "ctx(<6.6)", r"(\tlength = security_context_to_sid\(&fake_state, buf, size, &sid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(&selinux_state, buf, size, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "ctx(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(buf, size, &tmp_sid, GFP_KERNEL);\n\t}\n")
# my_write_access scon / tcon
sed(fs, "scon(<6.6)", r"(\tlength = security_context_str_to_sid\(&fake_state, scon, &ssid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_str_to_sid(&selinux_state, scon, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "scon(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, scon, strlen\(scon\), &ssid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(scon, strlen(scon), &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "tcon(<6.6)", r"(\tlength = security_context_str_to_sid\(&fake_state, tcon, &tsid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_str_to_sid(&selinux_state, tcon, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "tcon(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, tcon, strlen\(tcon\), &tsid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(tcon, strlen(tcon), &tmp_sid, GFP_KERNEL);\n\t}\n")

hk = "security/selinux/hooks.c"
# 去掉无条件 SETCURRENT 检查（<6.6 带 &selinux_state；>=6.6 不带）
sed(hk, "rm_early(<6.6)", r"\terror = avc_has_perm\(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL\);\n\n\tif \(error\)\n\t\treturn error;\n\n", "")
sed(hk, "rm_early(>=6.6)", r"\terror = avc_has_perm\(mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL\);\n\n\tif \(error\)\n\t\treturn error;\n\n", "")
# 仅在 backup 解析失败时才检查 SETCURRENT，并同步全局 sidtab
sed(hk, "seq+sync(<6.6)", r"(\t\terror = security_context_to_sid\(&fake_state, value, size,\n\t\t\t\t\t\t&sid, GFP_KERNEL\);\n)\t\tif \(error\)\n\t\t\treturn error;\n",
    "\\1\t\tif (error) {\n\t\t\t/* FINASU_SEQ: 仅当 backup 解析失败时才做 SETCURRENT 检查（KernelSU df03912f） */\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n\t\t{\n\t\t\tu32 tmp_sid;\n\t\t\t/* FINASU_SIDTAB_SYNC (KernelSU #3873) */\n\t\t\tsecurity_context_to_sid(&selinux_state, value, size, &tmp_sid, GFP_KERNEL);\n\t\t}\n")
sed(hk, "seq+sync(>=6.6)", r"(\t\terror = security_context_to_sid_with_policy\(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL\);\n)\t\tif \(error\)\n\t\t\treturn error;\n",
    "\\1\t\tif (error) {\n\t\t\t/* FINASU_SEQ: 仅当 backup 解析失败时才做 SETCURRENT 检查（KernelSU df03912f） */\n\t\t\tint perm_error = avc_has_perm(mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n\t\t{\n\t\t\tu32 tmp_sid;\n\t\t\t/* FINASU_SIDTAB_SYNC (KernelSU #3873) */\n\t\t\tsecurity_context_to_sid(str, size, &tmp_sid, GFP_KERNEL);\n\t\t}\n")
PYEOF
  # 仅作信息输出；旧形态模式部分失配时 grep 无命中，必须 || true，否则 pipefail 会中断整个补丁步骤
  grep -n 'FINASU_SIDTAB_SYNC' security/selinux/selinuxfs.c | head || true
  grep -n 'FINASU_SIDTAB_SYNC\|FINASU_SEQ' security/selinux/hooks.c | head || true
else
  # 主补丁形态判定：
  #   旧形态定义 my_write_context/my_write_access/my_setprocattr，缺失即异常，保留告警；
  #   现行形态（2026-10 起的主补丁）不再定义这三个函数：<6.6 内联改 selinux_setprocattr /
  #   selinuxfs 调用点（should_check_current+fake_error 门控），>=6.6 用 backup_sepolicy +
  #   my_security_context_to_sid（内核侧自含）。侧信道修复（sidtab 同步 #3873、权限顺序
  #   df03912f）由 NEW_MODEL 分支的 8 参 _with_policy 转换与门控校验覆盖，无需旧形态移植。
  if grep -qE 'static ssize_t my_write_(context|access)' security/selinux/selinuxfs.c 2>/dev/null \
    || grep -q 'static int my_setprocattr' security/selinux/hooks.c 2>/dev/null; then
    echo "::warning::未找到 SUSFS 的 my_write_context/my_setprocattr，跳过 SELinux 侧信道移植"
  else
    echo "SUSFS 主补丁为现行形态（无 my_write_context/my_setprocattr）：侧信道修复由门控校验与 8 参 _with_policy 内置同步覆盖，无需旧形态移植"
  fi
fi

# ==================== SUSFS 路径隐藏回退（跨命名空间 / FUSE） ====================
# susfs_add_sus_path（非 loop）在“调用方命名空间”里 kern_path 解析路径；管理器/ksud 常解析不到
# /storage/emulated 这类 FUSE 路径（-ENOENT），于是规则加不进去、路径隐藏失效。
# 这里加回退：解析失败时自动改走 LOOP 机制（内核 workqueue 在 init 命名空间稍后解析并打标记）。
if [ -f fs/susfs.c ] && grep -qF 'void susfs_add_sus_path(void __user **user_info)' fs/susfs.c \
  && ! grep -qF 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c; then
  python3 - <<'PYEOF'
p = "fs/susfs.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
old1 = "void susfs_add_sus_path(void __user **user_info) {"
new1 = "void susfs_add_sus_path_loop(void __user **user_info);\n" + old1
if s.count(old1) != 1:
    print("::warning::fs/susfs.c: susfs_add_sus_path 签名不是预期形态，跳过")
else:
    s = s.replace(old1, new1, 1)
    old2 = ("\tif (copy_from_user(&info, (struct st_susfs_sus_path __user*)*user_info, sizeof(info))) {\n"
            "\t\tinfo.err = -EFAULT;\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n\n"
            "\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
            "\tif (info.err) {\n"
            "\t\tSUSFS_LOGE(\"failed opening file '%s'\\n\", info.target_pathname);\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n")
    new2 = ("\tif (copy_from_user(&info, (struct st_susfs_sus_path __user*)*user_info, sizeof(info))) {\n"
            "\t\tinfo.err = -EFAULT;\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n\n"
            "\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
            "\tif (info.err) {\n"
            "\t\tSUSFS_LOGE(\"failed opening '%s' in current ns, fallback to sus_path_loop\\n\", info.target_pathname);\n"
            "\t\t/* FINASU_SUS_PATH_LOOP_FALLBACK: 调用方命名空间解析不到（常见于 /storage/emulated 等 FUSE 路径）时，\n"
            "\t\t   退回 LOOP 机制，交由内核 workqueue 在 init 命名空间稍后解析并重新打标记 */\n"
            "\t\tsusfs_add_sus_path_loop(user_info);\n"
            "\t\treturn;\n"
            "\t}\n")
    if s.count(old2) != 1:
        print("::warning::fs/susfs.c: susfs_add_sus_path 代码形态不是预期，跳过回退")
    else:
        open(p, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old2, new2, 1))
        print("fs/susfs.c: 已加 SUSFS 路径隐藏 LOOP 回退")
PYEOF
  grep -n 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c | head
else
  echo "::warning::未找到 fs/susfs.c 的 susfs_add_sus_path，跳过路径隐藏回退"
fi


# ==================== SUSFS sus_path 误伤修复（共用位域 -> 身份校验） ====================
# 背景：本版 SUSFS 用 inode->i_mapping->flags 的第 33 位（AS_FLAGS_SUS_PATH）承载 sus_path 判定
# 结果，并在各 VFS 入口用 susfs_is_inode_sus_path() 检查。该位并非 SUSFS 独占：厂商内核可能
# 使用同一位，或因 inode/address_space 复用而残留该位。一旦与 SUSFS 无关的文件带上该位，就会被
# 判为“应隐藏路径”：/data/app 下的 APK 属主为 system，任何非 system 的应用进程打开都会得到
# ENOENT/EIO，应用在 ActivityThread 阶段拿不到 Resources 直接 NPE 崩溃；命中集合随 inode
# 分配/复用变化，表现为“每次重启崩的应用不同、本次开机中招的应用持续崩溃”。
# 实测（vivo V2507A / android15 6.6.57）：内核整段启动日志（t=0 起）中不存在任何
# flagged/re-flag AS_FLAGS_SUS_PATH 或 CMD_SUSFS_ADD_SUS_PATH 记录（sus_path 列表为空），
# 却仍对应用自身的 6 个 APK 输出 hiding 判定 —— 属杂散置位误判，而非配置出来的隐藏规则。
# 修复：sus_path 判定除该位外，还要求该 inode 的 (s_dev, i_ino) 已被 SUSFS 登记；杂散置位不再
# 误伤。SUSFS 与 SUS_PATH 的功能、行为均保持不变（置位点与登记点一一对应）。
if [ -f fs/susfs.c ] && grep -qF 'test_bit(AS_FLAGS_SUS_PATH,' fs/susfs.c \
  && grep -qF 'set_bit(AS_FLAGS_SUS_PATH,' fs/susfs.c \
  && ! grep -qF 'FINASU_SUS_PATH_ID_GUARD' fs/susfs.c; then
  echo "为 sus_path 判定加入身份校验（消除共用位域误伤）"
  python3 - <<'PYEOF'
import sys

P = "fs/susfs.c"
src = open(P, encoding="utf-8", errors="surrogateescape").read()

if "FINASU_SUS_PATH_ID_GUARD" in src:
    print("fs/susfs.c 已含 sus_path 身份校验，跳过")
    raise SystemExit(0)

if "test_bit(AS_FLAGS_SUS_PATH," not in src or "set_bit(AS_FLAGS_SUS_PATH," not in src:
    print("::error::fs/susfs.c: 未找到 sus_path 置位/判定代码，形态与预期不符")
    raise SystemExit(1)

GUARD = '''
/* FINASU_SUS_PATH_ID_GUARD: sus_path 的判定原本只看 i_mapping->flags 第 33 位
 * (AS_FLAGS_SUS_PATH)。该位不是 SUSFS 独占的：厂商内核可能使用同一位，或因
 * inode/address_space 复用而残留，从而把与 SUSFS 无关的文件误判成隐藏路径
 * （实测应用自身在 /data/app 下的 APK 被误伤，应用启动即 NPE 崩溃）。
 * 这里为 sus_path 增加身份表：登记被 SUSFS 标记过的 (s_dev, i_ino)，判定时要求身份
 * 匹配，杂散置位不再误伤；SUSFS 的置位点与登记点一一对应，功能语义不变。 */
static DEFINE_MUTEX(susfs_mutex_lock_sus_path_id);
static DEFINE_HASHTABLE(SUS_PATH_ID_HLIST, 8);

struct st_susfs_sus_path_id {
	struct hlist_node node;
	dev_t s_dev;
	unsigned long i_ino;
};

static void susfs_sus_path_id_add(struct inode *inode)
{
	struct st_susfs_sus_path_id *entry, *tmp_entry;
	struct hlist_node *tmp_node;
	dev_t s_dev;
	unsigned long i_ino;

	if (!inode || !inode->i_sb)
		return;

	s_dev = inode->i_sb->s_dev;
	i_ino = inode->i_ino;

	mutex_lock(&susfs_mutex_lock_sus_path_id);
	hash_for_each_possible_safe(SUS_PATH_ID_HLIST, tmp_entry, tmp_node, node, i_ino) {
		if (tmp_entry->s_dev == s_dev && tmp_entry->i_ino == i_ino) {
			mutex_unlock(&susfs_mutex_lock_sus_path_id);
			return;
		}
	}
	entry = kzalloc(sizeof(*entry), GFP_KERNEL);
	if (!entry) {
		mutex_unlock(&susfs_mutex_lock_sus_path_id);
		SUSFS_LOGE("sus_path id entry alloc failed\\n");
		return;
	}
	entry->s_dev = s_dev;
	entry->i_ino = i_ino;
	hash_add_rcu(SUS_PATH_ID_HLIST, &entry->node, i_ino);
	mutex_unlock(&susfs_mutex_lock_sus_path_id);
}

static bool susfs_sus_path_id_match(struct inode *inode)
{
	struct st_susfs_sus_path_id *entry;
	dev_t s_dev;
	unsigned long i_ino;
	bool found = false;

	if (!inode || !inode->i_sb)
		return false;

	s_dev = inode->i_sb->s_dev;
	i_ino = inode->i_ino;

	rcu_read_lock();
	hash_for_each_possible_rcu(SUS_PATH_ID_HLIST, entry, node, i_ino) {
		if (entry->s_dev == s_dev && entry->i_ino == i_ino) {
			found = true;
			break;
		}
	}
	rcu_read_unlock();
	return found;
}
'''
# 自检：注释块里出现嵌套的 /* 或 */ 会被内核的 -Werror,-Wcomment 直接判为编译错误
# （历史上就踩过：注释里写 "/data/app/*.apk" 时其中的 "/" + "*" 被当成嵌套注释）。
if GUARD.count("/*") != 1 or GUARD.count("*/") != 1:
    print("::error::身份校验注释块内含嵌套的 /* 或 */（内核以 -Werror,-Wcomment 构建会直接报错），请修正脚本内注释文字")
    raise SystemExit(1)

if "#include <linux/hashtable.h>" not in src:
    src = src.replace("#include <linux/list.h>\n",
                      "#include <linux/list.h>\n#include <linux/hashtable.h>\n", 1)

lines = src.split("\n")
out = []
anchor = False
added = 0

for line in lines:
    out.append(line)
    if not anchor and "susfs_fake_qstr_name" in line:
        out.append(GUARD)
        anchor = True
        continue
    if "set_bit(AS_FLAGS_SUS_PATH, &fi->inode.i_mapping->flags);" in line:
        out.append(line[:len(line) - len(line.lstrip())] + "susfs_sus_path_id_add(&fi->inode);")
        added += 1
    elif "set_bit(AS_FLAGS_SUS_PATH, &inode->i_mapping->flags);" in line:
        out.append(line[:len(line) - len(line.lstrip())] + "susfs_sus_path_id_add(inode);")
        added += 1

if not anchor:
    print("::error::fs/susfs.c: 未找到 sus_path 代码段锚点，跳过修复")
    raise SystemExit(1)

pending = None
guarded = 0

for idx, line in enumerate(out):
    if "test_bit(AS_FLAGS_SUS_PATH, &fi->inode.i_mapping->flags)" in line:
        pending = "fuse"
    elif "test_bit(AS_FLAGS_SUS_PATH, &inode->i_mapping->flags)" in line:
        pending = "self"
    elif pending and line.strip().startswith("is_i_uid_not_allowed(") and line.rstrip().endswith(")))"):
        expr = "&fi->inode" if pending == "fuse" else "inode"
        out[idx] = line.rstrip()[:-3] + ") && susfs_sus_path_id_match(" + expr + ")))"
        guarded += 1
        pending = None

if added < 2 or guarded < 2 or added != guarded:
    print("::error::fs/susfs.c: 身份登记/判定改写数量异常 (add=%d, guard=%d)" % (added, guarded))
    raise SystemExit(1)

new_text = "\n".join(out)
if new_text.count("/*") - src.count("/*") != 1 or new_text.count("*/") - src.count("*/") != 1:
    print("::error::fs/susfs.c: 写出内容引入的注释标记数量异常，可能触发 -Wcomment，已中止")
    raise SystemExit(1)

open(P, "w", encoding="utf-8", errors="surrogateescape").write(new_text)
print("fs/susfs.c: sus_path 身份校验已写入 (add=%d, guard=%d)" % (added, guarded))
PYEOF
  grep -n 'FINASU_SUS_PATH_ID_GUARD' fs/susfs.c | head
else
  echo "::warning::fs/susfs.c 未匹配 sus_path 身份校验修复条件（sus_path 代码形态不符），跳过"
fi


# ---- 预期冲突处理：上游已包含同款修改的 .rej 剔除，真实缺失的手工补齐 ----

# 1) fs/unicode：ASB 内核已包含上游 "unicode: don't special case ignorable code
#    points" 提交，主补丁删除 ignore_init / 重生成 utf8data 的 hunk 已天然满足
if [[ -f fs/unicode/mkutf8data.c.rej ]] && ! grep -q 'ignore_init' fs/unicode/mkutf8data.c; then
  echo "fs/unicode .rej 为上游已包含同款修改，剔除预期冲突文件"
  rm -f fs/unicode/*.rej
fi

# 2) mm/rmap.c：6.6.127+ 已包含 huge_pmd_unshare 的 tlb 化改造
if [[ -f mm/rmap.c.rej ]] && grep -q 'tlb_gather_mmu_vma' mm/rmap.c; then
  echo "mm/rmap.c .rej 为上游已包含同款修改，剔除预期冲突文件"
  rm -f mm/rmap.c.rej
fi

# 3) fs/proc/task_mmu.c（6.12.69+）：show_smap 重构（vma_pages → vma_data_pages）
#    导致 SUS_MAP 检查 hunk 上下文失配被拒，属于真实缺失，手工补回
if [[ -f fs/proc/task_mmu.c.rej ]] \
  && grep -qF 'static int show_smap(struct seq_file *m, void *v)' fs/proc/task_mmu.c; then
  SHOW_SMAP_BODY="$(sed -n '/^static int show_smap(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c)"
  if [[ -n "$SHOW_SMAP_BODY" ]] && ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' <<< "$SHOW_SMAP_BODY"; then
    echo "为 show_smap 手工补入 SUS_MAP 检查（6.12.69+ 上下文漂移）"
    perl -0pi -e 's/(static int show_smap\(struct seq_file \*m, void \*v\)\n\{\n\tstruct vm_area_struct \*vma = v;\n\tstruct mem_size_stats mss = \{\};\n)/$1\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (vma->vm_file) {\n\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\treturn 0;\n\t}\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n/' fs/proc/task_mmu.c
    if ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' fs/proc/task_mmu.c; then
      echo "::error::show_smap SUS_MAP 检查手工补丁失败，请人工核对 fs/proc/task_mmu.c"
      exit 1
    fi
  fi

  # 同一个文件在 6.12.69+ 还把 show_smaps_rollup 重写成 VMA_ITERATOR + for_each_vma
  # （删掉了 out_unlock 分支），主补丁那两段 hunk 依赖旧上下文全部被拒；虽然不影响
  # 编译，但 SUS_MAP 标记的 VMA 会经 /proc/<pid>/smaps_rollup 泄露。这里在 do 循环
  # 入口整段跳过该 VMA，并同步 last_vma_end，语义与主补丁的 bypass_orig_flow 一致。
  if grep -qF 'bypass_orig_flow' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    echo "为 show_smaps_rollup 手工补入 SUS_MAP 跳过逻辑（6.12.69+ 上下文漂移）"
    python3 - <<'PYEOF'
p = "fs/proc/task_mmu.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
start = s.find("static int show_smaps_rollup(struct seq_file *m, void *v)")
end = s.find("\n}\n", start)
if start < 0 or end < 0:
    print("::error::fs/proc/task_mmu.c: 未找到 show_smaps_rollup")
    raise SystemExit(1)
body = s[start:end]
needle = "\tdo {\n\t\tsmap_gather_stats(vma, &mss, 0);\n"
insert = (
    "\tdo {\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\t/* SUS_MAP 标记的 VMA 整体跳过，避免 rollup 中泄露 */\n"
    "\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))) {\n"
    "\t\t\tlast_vma_end = vma->vm_end;\n"
    "\t\t\tcontinue;\n"
    "\t\t}\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tsmap_gather_stats(vma, &mss, 0);\n"
)
if "SUSFS_IS_INODE_SUS_MAP" in body:
    print("show_smaps_rollup 已含 SUS_MAP 检查，跳过")
elif body.count(needle) != 1:
    print("::error::show_smaps_rollup 循环入口形态不是预期，跳过")
    raise SystemExit(1)
else:
    s = s[:start] + body.replace(needle, insert, 1) + s[end:]
    open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("show_smaps_rollup: 已补入 SUS_MAP 跳过逻辑")
PYEOF
    if ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
      echo "::error::show_smaps_rollup SUS_MAP 跳过逻辑手工补丁失败，请人工核对 fs/proc/task_mmu.c"
      exit 1
    fi
  fi

  # 拒绝内容已全部补齐，删除 .rej，避免继续污染 Rejects 产物
  TASK_MMU_UNRESOLVED=0
  if grep -qF 'bypass_orig_flow' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    TASK_MMU_UNRESOLVED=1
  fi
  if grep -qF 'static int show_smap(struct seq_file *m, void *v)' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smap(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    TASK_MMU_UNRESOLVED=1
  fi
  if [[ "$TASK_MMU_UNRESOLVED" -eq 0 ]]; then
    # 仅当拒绝内容全部落在已处理的两个函数上时才删除，避免掩盖新出现的漂移
    UNKNOWN_HUNK="$(grep '^@@' fs/proc/task_mmu.c.rej | grep -vE 'show_smap|show_smaps_rollup' || true)"
    if [[ -z "$UNKNOWN_HUNK" ]]; then
      echo "fs/proc/task_mmu.c 拒绝内容已全部补齐，剔除 .rej"
      rm -f fs/proc/task_mmu.c.rej
    else
      echo "::warning title=task_mmu 冲突::仍有未识别的 hunk，保留 .rej 供排查："
      echo "$UNKNOWN_HUNK"
    fi
  fi
fi

# 上游 5.10 主补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# fs/statfs.c 的使用点之后（vfs_statfs 之前），clang -Werror 报隐式声明；
# 声明属于 SUSFS 接口，直接补进公共头 include/linux/susfs_def.h：
# 不依赖 statfs.c 内锚点与行号比较，声明重复合法，上游后续自行修复也不冲突。
# 注意：FinaSU 的 setuid_hook.c / sucompat.c 会在仅有 <linux/types.h> 等基础
# 头文件时就包含 susfs_def.h，此时 struct kstatfs 尚未声明，原型内引入新
# struct 标签会触发 clang -Werror,-Wvisibility（上游内核构建日志实证），
# 因此必须连同 struct 前置声明一起插入。
SUSFS_DEF_H="$KERNEL_ROOT/common/include/linux/susfs_def.h"
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c \
  && [[ -f "$SUSFS_DEF_H" ]] \
  && ! grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' "$SUSFS_DEF_H"; then
  echo "将 susfs_sus_kstat_spoof_vfs_statfs 声明补入 include/linux/susfs_def.h"
  sed -i '/^#endif \/\/ #ifndef KSU_SUSFS_DEF_H$/i struct inode;\nstruct kstatfs;\nextern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' "$SUSFS_DEF_H"
fi

# 上游 susfs.c 直接调用 security_sb_statfs 却没有包含 linux/security.h，
# 5.15+ 靠其他头文件间接带入，5.10 没有这条路径，clang -Werror 报隐式声明；缺失时补上
if [[ -f fs/susfs.c ]] && grep -qF 'security_sb_statfs(' fs/susfs.c \
  && ! grep -qF '#include <linux/security.h>' fs/susfs.c; then
  echo "为 susfs.c 补充 linux/security.h 头文件"
  sed -i '0,/^#include <linux\/fs.h>$/s//#include <linux\/fs.h>\n#include <linux\/security.h>/' fs/susfs.c
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件
SUSFS_REJ_COUNT=$(find . -name '*.rej' | wc -l)
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  find . -name '*.rej' -print
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "还原 Android 13 5.15 LTS 头文件上下文"
    if ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

# Android 16 - 6.12 修复
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # 固定旧版 SukiSU 在 6.12 上会重复定义 setresuid hook
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -n "$LEGACY_SUKISU_CONFIG" && -f "$SETUID_HOOK" ]] \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "已修复 setuid_hook.c 重复定义问题"
  fi
fi

# 守护：主补丁若再次因上下文漂移漏掉 susfs_def.h，在这里给出可读错误，
# 而不是等到编译 fs/proc/task_mmu.c 时才报一串 SUSFS_IS_INODE_* 隐式声明
for SUSFS_SRC in fs/proc/task_mmu.c fs/namespace.c; do
  [[ -f "$SUSFS_SRC" ]] || continue
  if grep -qE 'SUSFS_IS_INODE_|CL_COPY_MNT_NS' "$SUSFS_SRC" \
    && ! grep -qF '#include <linux/susfs_def.h>' "$SUSFS_SRC"; then
    echo "::error::$SUSFS_SRC 使用了 SUSFS 宏但缺少 linux/susfs_def.h，主补丁 hunk 未应用"
    exit 1
  fi
done


# ==================== 厂商模块越界导致整机 panic 重启的修复（关闭 UBSAN trap） ====================
# 现象（本机实测，现场已留存为 console-ramoops）：
#   上电后 863s 打印  Internal error: UBSAN: array index out of bounds: ... [#1] PREEMPT SMP
#   出错指令在 ___slab_alloc+0x8fc/0x980，进程 Comm: zcache_mm
#   调用链：用户态写 /sys/zcache/prio → prio_store [zcache]（厂商树外模块，/proc/modules 中带 OE）
#           → alloc_io_context → kmem_cache_alloc_node → ___slab_alloc
#           → ubsan_handler → die → ipanic_die → mrdump_common_die → 转储后整机重启
#   重启原因记录：ro.boot.bootreason / persist.sys.boot.reason.history = kernel_panic
# 为什么会从“越界报告”升级成“整机重启”：
#   本内核 CONFIG_UBSAN_TRAP=y，运行时 kernel.panic_on_oops=1；
#   TRAP 模式下 UBSAN 的边界检查一旦命中就直接执行 trap 指令 → die → oops → panic。
#   （Android 官方 errata 亦明确：CONFIG_UBSAN_TRAP 启用时，边界排错程序发现问题即触发内核崩溃。）
# 处理：把 UBSAN 从“命中即 trap”改成“打印完整报告后继续”，只去掉 trap 这一步；
#   边界检查本身、KASAN、panic_on_oops 都保持原样，不做扩大改动。
#   效果：厂商模块触发的越界不再把整机带走；下次发生时 dmesg 会给出完整报告
#   （含 file:line、越界索引与数组类型），可据此定位真正的越界点再决定是否要更彻底的修法。
# 落点：基准 gki_defconfig + 全树所有 defconfig/fragment 一并处理，最后出现者生效。
#   仅改 gki_defconfig 不够：若 ksu.fragment 或其他 fragment 在 defconfig 之后又写入
#   CONFIG_UBSAN_TRAP=y，会覆盖这里的修改（本次刷入的内核实测仍是 TRAP=y，即为此类漏网）。
#   因此这里先改基准 defconfig，再全树扫描一切可能携带该配置的文件并逐一关闭；
#   存在无法安全修改的携带者时直接 ::error:: 中断构建，绝不静默放过。
DEFCONFIG_FILE="common/arch/arm64/configs/gki_defconfig"
if [[ -f "$DEFCONFIG_FILE" ]]; then
  if grep -qE '^# CONFIG_UBSAN_TRAP is not set$' "$DEFCONFIG_FILE"; then
    echo "CONFIG_UBSAN_TRAP 已是关闭状态，跳过"
  else
    sed -i '/^CONFIG_UBSAN_TRAP=/d' "$DEFCONFIG_FILE"
    printf '# CONFIG_UBSAN_TRAP is not set\n' >> "$DEFCONFIG_FILE"
    echo "已在 $DEFCONFIG_FILE 关闭 CONFIG_UBSAN_TRAP（UBSAN 改为报告而非 trap，避免厂商模块越界直接 panic 重启）"
  fi
else
  echo "::warning::未找到 $DEFCONFIG_FILE，跳过基准 defconfig 的 UBSAN_TRAP 调整"
fi
