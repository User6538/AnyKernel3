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

  2. CALL SITE
     插入在 binder_transaction() 中调用 binder_proc_transaction() 的位置前。
     调用点特征: "if (!binder_proc_transaction(t,"
     (定义处是 "static int binder_proc_transaction(struct binder_transaction *t,"
      不含 "!binder_proc_transaction(t,", 不会误匹配)

     注入内容:
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


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


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

    # --- 锚点 2: 调用点 ---
    # binder_transaction() 中: if (!binder_proc_transaction(t, ...))
    # 定义处不含 "!binder_proc_transaction(t,", 不会误匹配
    call_needle = "!binder_proc_transaction(t,"
    call_idx = src.find(call_needle, block_open + len(helper_block))
    if call_idx < 0:
        print("anchor 2 not found: !binder_proc_transaction(t, call site "
              "in binder_transaction()", file=sys.stderr)
        print("helper was inserted but call site was not — manual fix needed",
              file=sys.stderr)
        # 仍写入 helper, 编译时会因未定义符号报错 (清晰可定位)
    else:
        # 找到调用所在行的行首
        line_start = src.rfind("\n", 0, call_idx) + 1
        # 提取缩进 (行首到 'if' 前的空白)
        if_prefix = src[line_start:call_idx]
        # 去掉 'if (' 或 'if(' 部分, 只保留缩进
        indent = ""
        for ch in if_prefix:
            if ch in " \t":
                indent += ch
            else:
                break
        # 如果缩进为空, 默认用 tab (binder_transaction 函数体一级缩进)
        if not indent:
            indent = "\t"
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
    if "nk_should_drop(" not in src:
        print("verification failed: nk_should_drop call not present",
              file=sys.stderr)
        return 1
    if "NK_DROP_CODE" not in src:
        print("verification failed: NK_DROP_CODE not present",
              file=sys.stderr)
        return 1
    print(f"patched {binder_path}: helper injected + call site wired "
          f"({MARKER})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
