#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
disable_verity.py — disable dm-verity enforcement in the kernel source

在 drivers/md/dm-verity.c 中找到两个核心函数并在函数体入口插入 return 0:

  1. verity_verify_io — 主校验函数, 遍历每个数据块计算哈希并比对。
     return 0 = 校验通过, 跳过全部哈希计算和 hash block IO。
     对应酷安方案的 "verity_verify_io 不再返回错误码" (二进制层面
     改 verity_handle_err 返回 0, 源码层面直接短路 verify_io 更高效)。

  2. verity_handle_err — 错误处理函数, 决定 restart/panic/eio。
     return 0 = 非致命 (等同 DM_VERITY_MODE_LOGGING)。
     作为兜底: 即使有其他代码路径直接调用 verity_handle_err,
     也返回 0 不触发 restart/panic。

原理 (参考酷安 dm-verity.txt 方案):
  fstab verify flag → init.real SetUpDmVerity → AvbHandle::SetUpAvbHashtree
  → HashtreeDmVeritySetup → BlockDevInitializer::InitDmDevice
  → kernel device-mapper dm-verity → verity_map → verity_verify_io
  → verity_handle_err

  酷安原文指出: 只删 fstab flag 不够 (init 仍创建 dm 设备), 只改 kernel
  也不一定阻止 init 创建 dm 设备。在内核源码层面短路 verity_verify_io,
  使 dm 设备创建成功但校验恒过 — init 正常走完 dm-verity 创建链路,
  kernel 侧校验永远返回成功, 修改过的分区照常挂载。

  与酷安方案的对应:
  - 酷安: 二进制 patch verity_handle_err → MOV W0,#0; RET
  - 本补丁: 源码 patch verity_verify_io → return 0 (更上游, 更高效)
           + verity_handle_err → return 0 (兜底, 等同酷安方案)

不影响:
  - dm-verity 模块正常加载 (CONFIG_DM_VERITY=y)
  - first-stage init 正常创建 dm 设备 (不报错)
  - fs-verity (文件级校验, 独立链路, 符号 fsverity_verify_page 等)
  - 其他 device-mapper target (dm-crypt, dm-linear 等)

Usage:
    python3 disable_verity.py <dm-verity.c path>

幂等: 对已注入的文件重复运行是 no-op。
"""
import sys
import os

MARKER = "User6538/AnyKernel3 — dm-verity enforcement disabled"

# 要 patch 的函数名列表。每个函数在文件中应该只出现一次定义。
TARGETS = [
    "verity_verify_io",
    "verity_handle_err",
]


def read(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def find_function_body_open(src, func_name):
    """
    在 src 中找到 func_name 的函数定义, 返回函数体起始 { 的索引。

    匹配策略:
    - 找到 "func_name" 出现的位置
    - 确认前面是函数定义 (不是调用): 前面应有返回类型关键字
      (static/int/void/bool/sector_t 等) 或换行/空白
    - 从 func_name 位置向后找函数参数列表的结束 )
    - 从 ) 向后找 { (函数体起始), 跳过空白和换行

    返回: { 的索引, 或 -1 如果未找到。
    """
    pos = 0
    while True:
        idx = src.find(func_name, pos)
        if idx < 0:
            return -1

        # 检查 func_name 前面的字符, 确认是定义而非调用
        # 定义前应该有空白或返回类型关键字, 且 func_name 后面应该跟 (
        after = idx + len(func_name)
        # 跳过可能的空白
        paren_pos = after
        while paren_pos < len(src) and src[paren_pos] in " \t":
            paren_pos += 1
        if paren_pos >= len(src) or src[paren_pos] != "(":
            pos = idx + 1
            continue

        # 找到匹配的右括号 ) (考虑嵌套)
        depth = 1
        i = paren_pos + 1
        while i < len(src) and depth > 0:
            if src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
            i += 1
        if depth != 0:
            pos = idx + 1
            continue
        close_paren = i - 1  # ) 的位置

        # 从 ) 向后找 { (函数体起始)
        # 跳过空白、换行, 可能中间有 __init 之类的属性
        brace_pos = close_paren + 1
        while brace_pos < len(src):
            ch = src[brace_pos]
            if ch == "{":
                return brace_pos
            elif ch in " \t\n\r":
                brace_pos += 1
            elif ch == ";":
                # 这是一个声明 (如函数原型), 不是定义
                break
            else:
                # 可能是属性如 __init, __read_mostly 等, 继续找
                brace_pos += 1
                # 找下一个 { 或 ;
                while brace_pos < len(src) and src[brace_pos] not in "{;":
                    brace_pos += 1
                if brace_pos < len(src) and src[brace_pos] == "{":
                    return brace_pos
                break

        pos = idx + 1

    return -1


def inject_return_zero(src, func_name):
    """
    在 func_name 函数体入口 ( { 之后) 插入 return 0; 并返回修改后的 src。
    如果已包含标记则跳过该函数。
    返回 (src, injected: bool)
    """
    brace_idx = find_function_body_open(src, func_name)
    if brace_idx < 0:
        return src, False

    # 检查是否已注入 (标记可能在 { 后的注释中)
    check_region = src[brace_idx:brace_idx + 200]
    if "dm-verity enforcement disabled" in check_region:
        return src, False  # 已注入

    # 在 { 后插入 return 0;
    # 保持缩进: 用一个 tab (内核函数体一级缩进)
    inject = (
        "\n\t/* " + MARKER + " */\n"
        "\treturn 0;\n"
    )
    src = src[:brace_idx + 1] + inject + src[brace_idx + 1:]
    return src, True


def main():
    if len(sys.argv) != 2:
        print("usage: disable_verity.py <dm-verity.c>", file=sys.stderr)
        return 2

    verity_path = sys.argv[1]
    if not os.path.isfile(verity_path):
        print(f"file not found: {verity_path}", file=sys.stderr)
        return 1

    src = read(verity_path)

    # 幂等: 已含标记则跳过
    if MARKER in src:
        print(f"already patched ({MARKER}), skipping")
        return 0

    patched_count = 0
    for func_name in TARGETS:
        src, injected = inject_return_zero(src, func_name)
        if injected:
            patched_count += 1
            print(f"  patched: {func_name} → return 0")
        else:
            # 检查是否因为已注入而跳过
            if MARKER in src:
                print(f"  already patched: {func_name}")
            else:
                print(f"  WARNING: {func_name} not found or could not patch",
                      file=sys.stderr)

    if patched_count == 0 and MARKER not in src:
        print("ERROR: no functions were patched", file=sys.stderr)
        print("the dm-verity source may have been refactored or renamed",
              file=sys.stderr)
        return 1

    # 写回
    with open(verity_path, "w", encoding="utf-8",
              errors="surrogateescape") as f:
        f.write(src)

    # 校验
    if MARKER not in src:
        print("verification failed: marker not present after injection",
              file=sys.stderr)
        return 1

    # 校验 return 0 在每个目标函数中
    for func_name in TARGETS:
        if func_name not in src:
            print(f"verification warning: {func_name} not found in output",
                  file=sys.stderr)

    print(f"patched {verity_path}: {patched_count} function(s) short-circuited "
          f"({MARKER})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
