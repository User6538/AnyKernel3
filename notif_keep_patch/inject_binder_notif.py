#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
inject_binder_notif.py — inject the notification-keep helper into binder.c

This script performs a line-number-independent injection so the patch survives
across Android 13..16 / kernel 5.10..6.12 binder.c layout changes.

Two injection points, both anchored on stable, unique code patterns:

  1. HELPER DEFINITION
     Inserted immediately *before* the binder_proc_transaction() doc comment:
         * binder_proc_transaction() - sends a transaction to a process
     This doc comment exists in every binder.c version that has the function.

  2. CALL SITE
     Inserted immediately *after* the first executable statement inside
     binder_proc_transaction():
         BUG_ON(!node);
     followed by binder_node_lock(node);  — present in every version.

Usage:
    python3 inject_binder_notif.py <binder.c path> <helper.c path>

Exits 0 on success (and prints the verification marker), non-zero on failure.
Idempotent: re-running on an already-patched file is a no-op.
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

    # Idempotency: already patched.
    if MARKER in src:
        print(f"already patched ({MARKER}), skipping")
        return 0

    # --- Anchor 1: helper definition ---
    # Preferred: insert right before the binder_proc_transaction() doc comment.
    # Fallback: if the doc comment was stripped by a downstream, insert right
    # before the function signature line.
    doc_needle = "* binder_proc_transaction() - sends a transaction"
    sig_needle = "binder_proc_transaction(struct binder_transaction *t,"
    doc_idx = src.find(doc_needle)
    if doc_idx >= 0:
        # walk back to the '/**' that opens the comment, then to its line start
        block_open = src.rfind("/**", 0, doc_idx)
        if block_open < 0:
            block_open = src.rfind("\n", 0, doc_idx) + 1
        else:
            block_open = src.rfind("\n", 0, block_open) + 1
    else:
        # no doc comment — fall back to the function signature line
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

    # --- Anchor 2: call site ---
    # Inside binder_proc_transaction, after the first BUG_ON(!node);
    call_needle = "BUG_ON(!node);"
    call_idx = src.find(call_needle, block_open + len(helper_block))
    if call_idx < 0:
        print("anchor 2 not found: BUG_ON(!node) inside "
              "binder_proc_transaction", file=sys.stderr)
        print("helper was inserted but call site was not — manual fix needed",
              file=sys.stderr)
        # still write the helper in; the build will fail clearly with a
        # missing-symbol error rather than a silent mis-inject.
        pass
    else:
        end_of_line = src.find("\n", call_idx)
        if end_of_line < 0:
            end_of_line = len(src)
        inject = ("\n\t/* User6538/AnyKernel3 — keep notification "
                  "on force-stop */\n\tbinder_keep_notif_filter(t);\n")
        src = src[:end_of_line] + inject + src[end_of_line:]

    # --- write back ---
    with open(binder_path, "w", encoding="utf-8") as f:
        f.write(src)

    # --- verify ---
    if MARKER not in src:
        print("verification failed: marker not present after injection",
              file=sys.stderr)
        return 1
    if "binder_keep_notif_filter(t);" not in src:
        print("verification failed: call site not present after injection",
              file=sys.stderr)
        return 1
    print(f"patched {binder_path}: helper injected + call site wired "
          f"({MARKER})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
