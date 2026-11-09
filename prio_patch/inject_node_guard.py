#!/usr/bin/env python3
"""版本无关的 slab node guard 注入器。

当 slab_node_guard.patch 因内核版本差异（函数签名/行号不匹配）无法 apply 时，
用 ___slab_alloc（三下划线，slab 慢路径核心函数，5.10-6.12 所有版本共用此名）
作为锚点，在函数体开头注入 node 范围校验。

效果与固定 patch 相同：非法 node（< NUMA_NO_NODE 或 >= nr_node_ids）收敛为
NUMA_NO_NODE（走本地节点），合法调用方行为不变，不阻止任何合法写入。
"""
import re
import sys

P = "mm/slub.c"

try:
    src = open(P, encoding="utf-8", errors="surrogateescape").read()
except OSError as e:
    print("::error::无法读取 mm/slub.c: %s" % e)
    raise SystemExit(1)

# 幂等：已含守卫则跳过
if "ZCACHE_NODE_GUARD" in src:
    print("mm/slub.c 已含 ZCACHE_NODE_GUARD，跳过")
    raise SystemExit(0)

# 锚点：___slab_alloc 是 slab 慢路径核心函数（所有版本共用此名）。
# 函数签名可能跨多行，用 [\s\S]*? 非贪婪匹配到 )，再匹配到函数体 {。
# ^static 确保匹配的是函数定义而非注释/字符串中的引用。
pat = re.compile(
    r'^(static\s+(?:__always_inline\s+)?void\s*\*\s*'
    r'___slab_alloc\s*\([\s\S]*?\)\s*)\{',
    re.MULTILINE,
)
m = pat.search(src)
if not m:
    print("::error::未找到 ___slab_alloc 函数定义，无法注入 node 校验")
    print("::error::请检查 mm/slub.c 是否使用了不同的慢路径函数名")
    raise SystemExit(1)

inject_pos = m.end()  # 函数体 { 之后

GUARD = (
    '\n'
    '\t/* ZCACHE_NODE_GUARD: 厂商树外 zcache 模块在启动早期会把未初始化/越界\n'
    '\t * 的 node 值沿 prio_store -> alloc_io_context 传进 slab 慢路径；该值\n'
    '\t * 随后被 get_partial() -> get_node() 用来索引定长数组 s->node[node]\n'
    '\t * （node[MAX_NUMNODES]），触发 UBSAN array index out of bounds；\n'
    '\t * CONFIG_UBSAN_TRAP=y 时直接整机 panic 重启。这里把非法 node 收敛为\n'
    '\t * NUMA_NO_NODE（由 slab 走本地节点），合法调用方行为不变，该越界\n'
    '\t * 也就无法再从任何入口（sysfs / ioctl / 其它）发生。 */\n'
    '\tif (unlikely(node < NUMA_NO_NODE || node >= nr_node_ids))\n'
    '\t\tnode = NUMA_NO_NODE;\n'
)

src = src[:inject_pos] + GUARD + src[inject_pos:]

open(P, "w", encoding="utf-8", errors="surrogateescape").write(src)

# 验证写入成功
verify = open(P, encoding="utf-8", errors="surrogateescape").read()
if "ZCACHE_NODE_GUARD" not in verify:
    print("::error::注入后校验失败：ZCACHE_NODE_GUARD 未出现在 mm/slub.c")
    raise SystemExit(1)

print("已通过版本无关锚点注入 node 校验到 ___slab_alloc（非法值收敛为 NUMA_NO_NODE）")
