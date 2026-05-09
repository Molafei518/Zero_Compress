#!/usr/bin/env python3
"""
compress_eval.py — DDR Cache+Compress IP 评估器

输入:.zctrace 二进制文件 (定义见 docs/01_phase0_trace_eval.md §3.1)
       或 --mock 模式生成合成 trace
输出:JSON 报告 + Markdown 摘要 + 直方图

用法:
    python compress_eval.py trace.zctrace --out report.json
    python compress_eval.py --mock --workload mlperf --out demo.json
    python compress_eval.py trace.zctrace --gen-bypass-cfg > bypass.cfg
"""
import argparse
import json
import os
import struct
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from typing import Iterable, List, Tuple

# ====================================================================
# 常量
# ====================================================================
LINE_SIZE = 64
PAGE_SIZE = 4096
LINES_PER_PAGE = PAGE_SIZE // LINE_SIZE  # 64

ALGO_BDI = 0
ALGO_ZERO = 1
ALGO_BYTEDELTA = 2
ALGO_NONE = 3
ALGO_NAMES = ['BDI', 'Zero', 'ByteDelta', 'None']

# ====================================================================
# 压缩算法(简化但保持与 RTL 实现等价的尺寸)
# ====================================================================

def compress_zero(line: bytes) -> Tuple[int, int]:
    """Zero-Value Compression. 返回 (mode, size_bytes).
    Mode 0: 全零              -> 1 B
    Mode 1: 16个4B word中只有少量非零, 用 bitmap+values
    Mode 2: 不可压             -> 64 B (向上层报告"不适合", 由 ByteDelta/BDI 接管)
    """
    if all(b == 0 for b in line):
        return (0, 1)
    # 检测稀疏:按 4B word 计数非零
    nonzero_words = 0
    for i in range(0, 64, 4):
        if line[i:i+4] != b'\x00\x00\x00\x00':
            nonzero_words += 1
    # mode 1: 16 word bitmap (2B) + 非零 word (4B each) + mode (1B)
    if nonzero_words <= 8:  # 至少省一半
        return (1, 1 + 2 + 4 * nonzero_words)
    return (2, 64)

def compress_bdi(line: bytes) -> Tuple[int, int]:
    """BDI (Base-Delta-Immediate). 返回 (mode, size_bytes).
    Mode 0: 全零        -> 0 B 数据 (Zero 通常更优)
    Mode 1: 单值重复     -> 4 B
    Mode 2: B(4)+D(1)x16 -> 20 B
    Mode 3: B(4)+D(2)x16 -> 36 B
    Mode 4: B(8)+D(1)x8  -> 16 B
    Mode 5: B(8)+D(2)x8  -> 24 B
    Mode 6: B(8)+D(4)x8  -> 40 B
    Mode 7: 不可压        -> 64 B
    """
    if all(b == 0 for b in line):
        return (0, 1)

    # 单值重复(按 4B word 比较)
    w0 = line[0:4]
    if all(line[i:i+4] == w0 for i in range(0, 64, 4)):
        return (1, 4)

    # 4B base, 各种 delta 宽度
    words32 = [int.from_bytes(line[i:i+4], 'little', signed=True)
               for i in range(0, 64, 4)]
    base32 = words32[0]
    deltas32 = [w - base32 for w in words32]
    max_abs32 = max(abs(d) for d in deltas32)

    if max_abs32 < 128:    # 1B delta
        return (2, 4 + 16 * 1)  # 20 B
    if max_abs32 < 32768:  # 2B delta
        # 但先检查 8B base 的可能性, 取最优
        pass

    # 8B base
    words64 = [int.from_bytes(line[i:i+8], 'little', signed=True)
               for i in range(0, 64, 8)]
    base64 = words64[0]
    deltas64 = [w - base64 for w in words64]
    max_abs64 = max(abs(d) for d in deltas64)

    candidates = []
    if max_abs32 < 32768:
        candidates.append((3, 4 + 16 * 2))  # 36 B
    if max_abs64 < 128:
        candidates.append((4, 8 + 8 * 1))   # 16 B
    if max_abs64 < 32768:
        candidates.append((5, 8 + 8 * 2))   # 24 B
    if max_abs64 < (1 << 31):
        candidates.append((6, 8 + 8 * 4))   # 40 B

    if candidates:
        return min(candidates, key=lambda x: x[1])
    return (7, 64)

def compress_bytedelta(line: bytes) -> Tuple[int, int]:
    """ByteDelta. 返回 (mode, size_bytes).
    Mode 0: 全零              -> 1 B
    Mode 1: 单 byte 重复      -> 2 B
    Mode 2: B(1)+4bit*63      -> 34 B
    Mode 3: B(2)+8bit*31      -> 34 B (16bit word delta)
    Mode 4: B(4)+16bit*15     -> 35 B (32bit word delta)
    Mode 5: 不可压             -> 64 B
    """
    if all(b == 0 for b in line):
        return (0, 1)
    if all(b == line[0] for b in line):
        return (1, 2)

    # Mode 2: 相邻 byte delta <= +-7
    base = line[0]
    deltas = [line[i] - base for i in range(1, 64)]
    if all(-8 <= d < 8 for d in deltas):
        return (2, 34)

    # Mode 3: 16-bit word delta <= 8 bit
    words16 = [int.from_bytes(line[i:i+2], 'little', signed=False)
               for i in range(0, 64, 2)]
    base16 = words16[0]
    deltas16 = [w - base16 for w in words16[1:]]
    if all(-128 <= d < 128 for d in deltas16):
        return (3, 34)

    # Mode 4: 32-bit word delta <= 16 bit
    words32 = [int.from_bytes(line[i:i+4], 'little', signed=True)
               for i in range(0, 64, 4)]
    base32 = words32[0]
    deltas32 = [w - base32 for w in words32[1:]]
    if all(-32768 <= d < 32768 for d in deltas32):
        return (4, 35)

    return (5, 64)

def compress_line(line: bytes) -> Tuple[int, int, int]:
    """三引擎并行,选最小. 返回 (algo_id, mode, size_bytes).
    Tie breaker: Zero > ByteDelta > BDI(解压延迟优先)
    """
    z_mode, z_size = compress_zero(line)
    bd_mode, bd_size = compress_bytedelta(line)
    bdi_mode, bdi_size = compress_bdi(line)

    candidates = [
        (ALGO_ZERO, z_mode, z_size),
        (ALGO_BYTEDELTA, bd_mode, bd_size),
        (ALGO_BDI, bdi_mode, bdi_size),
    ]
    candidates.sort(key=lambda x: (x[2], x[0]))  # 先比 size, 再按 algo 优先级
    algo, mode, size = candidates[0]
    if size >= 64:
        return (ALGO_NONE, 0, 64)
    return (algo, mode, size)

# ====================================================================
# Trace 读取
# ====================================================================

@dataclass
class TraceRecord:
    la_addr: int
    rw: int
    data: bytes
    tag: int

TRACE_MAGIC = b'ZCTRACE\0'

def read_trace(path: str) -> Iterable[TraceRecord]:
    with open(path, 'rb') as f:
        header = f.read(32)
        if header[:8] != TRACE_MAGIC:
            raise ValueError(f"{path}: not a zctrace file")
        # version, workload_name, n_lines 不强制使用
        while True:
            buf = f.read(80)
            if len(buf) < 80:
                break
            la_addr = struct.unpack('<Q', buf[0:8])[0]
            rw = buf[8]
            data = buf[9:73]
            tag = struct.unpack('<I', buf[73:77])[0]
            yield TraceRecord(la_addr, rw, data, tag)

def write_trace(path: str, records: List[TraceRecord], workload: str):
    with open(path, 'wb') as f:
        wlname = workload.encode('ascii')[:16].ljust(16, b'\0')
        f.write(TRACE_MAGIC)
        f.write(struct.pack('<I', 0x00010000))
        f.write(wlname)
        f.write(struct.pack('<I', len(records)))
        for r in records:
            f.write(struct.pack('<Q', r.la_addr))
            f.write(bytes([r.rw]))
            assert len(r.data) == 64, "data must be 64 bytes"
            f.write(r.data)
            f.write(struct.pack('<I', r.tag))
            f.write(b'\0\0\0')

# ====================================================================
# Mock trace 生成(无真 trace 时用)
# ====================================================================

def mock_workload(name: str, n_lines: int = 10000) -> List[TraceRecord]:
    """根据 workload 名称生成有代表性的合成 trace.
    数据类型权重对齐 §6.1.3 主文档.
    """
    import random
    random.seed(hash(name) & 0xffffffff)
    rng = random.Random(hash(name) & 0xffffffff)

    profiles = {
        # workload -> [(weight, data_generator), ...]
        'mobile_video': [
            (0.30, lambda: gen_yuv()),
            (0.20, lambda: gen_rgb()),
            (0.15, lambda: gen_code_stack()),
            (0.25, lambda: gen_heap_mixed()),
            (0.10, lambda: gen_random()),
        ],
        'auto_adas': [
            (0.25, lambda: gen_yuv()),
            (0.30, lambda: gen_npu_int8_weight()),
            (0.20, lambda: gen_npu_activation()),
            (0.15, lambda: gen_intermediate()),
            (0.10, lambda: gen_rgb_or_code()),
        ],
        'aiot_inference': [
            (0.50, lambda: gen_npu_weight_mix()),
            (0.30, lambda: gen_npu_activation()),
            (0.10, lambda: gen_kvcache()),
            (0.10, lambda: gen_sys_control()),
        ],
        'mlperf': [
            (0.40, lambda: gen_npu_int8_weight()),
            (0.30, lambda: gen_npu_activation()),
            (0.20, lambda: gen_intermediate()),
            (0.10, lambda: gen_sys_control()),
        ],
        'spec_int': [
            (0.30, lambda: gen_pointer_array()),
            (0.20, lambda: gen_small_int_array()),
            (0.20, lambda: gen_struct_with_padding()),
            (0.15, lambda: gen_code_stack()),
            (0.15, lambda: gen_heap_mixed()),
        ],
    }

    profile = profiles.get(name, profiles['mobile_video'])
    weights = [w for w, _ in profile]
    gens = [g for _, g in profile]

    records = []
    base_addr = 0x80000000
    for i in range(n_lines):
        gen = rng.choices(gens, weights=weights, k=1)[0]
        data = gen()
        records.append(TraceRecord(
            la_addr=base_addr + (i * 64) % 0x40000000,
            rw=1,  # 全部 write,评估压缩
            data=data,
            tag=0,
        ))
    return records

# 数据生成器 ----------------------------------------------------------

import random
_rng_g = random.Random(42)

def gen_yuv() -> bytes:
    """YUV 帧数据:相邻 byte 差小."""
    base = _rng_g.randint(60, 200)
    return bytes((base + _rng_g.randint(-3, 3)) & 0xff for _ in range(64))

def gen_rgb() -> bytes:
    """RGB 帧:byte 间无规律."""
    return bytes(_rng_g.randint(0, 255) for _ in range(64))

def gen_code_stack() -> bytes:
    """代码段或栈:近似随机,偶有零."""
    if _rng_g.random() < 0.2:
        # 部分零(栈空闲槽)
        return bytes(_rng_g.choices([0, _rng_g.randint(1, 255)],
                                    weights=[0.4, 0.6], k=64))
    return bytes(_rng_g.randint(0, 255) for _ in range(64))

def gen_heap_mixed() -> bytes:
    """堆数据:混合,有指针、整数、padding."""
    out = bytearray(64)
    for i in range(0, 64, 8):
        kind = _rng_g.random()
        if kind < 0.3:
            out[i:i+8] = (_rng_g.randint(0, 1<<48)).to_bytes(8, 'little')
        elif kind < 0.6:
            out[i:i+8] = b'\x00' * 8  # padding
        else:
            out[i:i+8] = _rng_g.randint(0, 1000).to_bytes(8, 'little')
    return bytes(out)

def gen_random() -> bytes:
    return bytes(_rng_g.randint(0, 255) for _ in range(64))

def gen_npu_int8_weight() -> bytes:
    """INT8 权重:集中在 center 附近."""
    center = _rng_g.randint(-30, 30)
    return bytes(((center + _rng_g.randint(-10, 10)) & 0xff) for _ in range(64))

def gen_npu_activation() -> bytes:
    """ReLU 激活:大量零 + 稀疏正值."""
    out = bytearray(64)
    for i in range(0, 64, 4):
        if _rng_g.random() < 0.7:
            out[i:i+4] = b'\x00\x00\x00\x00'
        else:
            v = _rng_g.randint(1, 1<<14)
            out[i:i+4] = v.to_bytes(4, 'little')
    return bytes(out)

def gen_intermediate() -> bytes:
    """中间张量:小 float, 部分零."""
    out = bytearray(64)
    for i in range(0, 64, 4):
        if _rng_g.random() < 0.3:
            out[i:i+4] = b'\x00\x00\x00\x00'
        else:
            v = _rng_g.randint(0, 1<<20)
            out[i:i+4] = v.to_bytes(4, 'little')
    return bytes(out)

def gen_kvcache() -> bytes:
    return gen_npu_int8_weight()  # 类似分布

def gen_sys_control() -> bytes:
    return gen_code_stack()

def gen_npu_weight_mix() -> bytes:
    if _rng_g.random() < 0.5:
        return gen_npu_int8_weight()
    # FP16 简化模拟:相邻值有相关
    base = _rng_g.randint(0, 0x4000)
    out = bytearray(64)
    for i in range(0, 64, 2):
        v = (base + _rng_g.randint(-100, 100)) & 0xffff
        out[i:i+2] = v.to_bytes(2, 'little')
    return bytes(out)

def gen_rgb_or_code() -> bytes:
    return gen_rgb() if _rng_g.random() < 0.5 else gen_code_stack()

def gen_pointer_array() -> bytes:
    """指针数组:8B 一致前缀."""
    base = _rng_g.randint(0, 1<<48) & ~0xffff
    out = bytearray(64)
    for i in range(0, 64, 8):
        v = base + _rng_g.randint(0, 0xffff)
        out[i:i+8] = v.to_bytes(8, 'little')
    return bytes(out)

def gen_small_int_array() -> bytes:
    out = bytearray(64)
    for i in range(0, 64, 4):
        v = _rng_g.randint(0, 1000)
        out[i:i+4] = v.to_bytes(4, 'little')
    return bytes(out)

def gen_struct_with_padding() -> bytes:
    """4 个 16B struct,每个 struct 前 8B 数据 + 后 8B padding."""
    out = bytearray(64)
    for i in range(0, 64, 16):
        v = _rng_g.randint(0, 1<<48)
        out[i:i+8] = v.to_bytes(8, 'little')
        # 后 8B 保持零
    return bytes(out)

# ====================================================================
# 评估主体
# ====================================================================

@dataclass
class PageStat:
    la_page: int
    n_lines: int = 0
    total_orig: int = 0
    total_comp: int = 0
    algo_count: Counter = field(default_factory=Counter)
    uncompressible_lines: int = 0

    @property
    def ratio(self):
        return self.total_orig / max(self.total_comp, 1)

@dataclass
class EvalResult:
    workload: str
    n_lines: int = 0
    n_pages: int = 0
    total_orig: int = 0
    total_comp: int = 0
    algo_count: Counter = field(default_factory=Counter)
    page_stats: List[PageStat] = field(default_factory=list)
    page_size_bins: Counter = field(default_factory=Counter)
    danger_pages: List[PageStat] = field(default_factory=list)

def evaluate(records: Iterable[TraceRecord], workload: str = '') -> EvalResult:
    res = EvalResult(workload=workload)
    pages = defaultdict(lambda: PageStat(la_page=0))

    for r in records:
        if r.rw != 1:  # 只评估写
            continue
        la_page = r.la_addr & ~(PAGE_SIZE - 1)
        ps = pages[la_page]
        ps.la_page = la_page
        ps.n_lines += 1
        ps.total_orig += LINE_SIZE
        algo, mode, size = compress_line(r.data)
        ps.total_comp += size
        ps.algo_count[algo] += 1
        if algo == ALGO_NONE:
            ps.uncompressible_lines += 1

        res.n_lines += 1
        res.total_orig += LINE_SIZE
        res.total_comp += size
        res.algo_count[algo] += 1

    res.page_stats = list(pages.values())
    res.n_pages = len(res.page_stats)

    for ps in res.page_stats:
        if ps.ratio < 1.0:
            res.danger_pages.append(ps)
        bin_name = page_size_bin(ps.total_comp)
        res.page_size_bins[bin_name] += 1

    return res

def page_size_bin(size: int) -> str:
    if size < 256:    return '0-256'
    if size < 512:    return '256-512'
    if size < 1024:   return '512-1024'
    if size < 2048:   return '1024-2048'
    if size < 3072:   return '2048-3072'
    if size < 4096:   return '3072-4096'
    return '4096+'

def percentile(sorted_vals: List[float], p: float) -> float:
    if not sorted_vals:
        return 0.0
    idx = int(len(sorted_vals) * p / 100)
    idx = max(0, min(len(sorted_vals) - 1, idx))
    return sorted_vals[idx]

def cap_ratio_safety(p1: float, p50: float) -> dict:
    out = {}
    for cr in [1.25, 1.50, 1.75]:
        if p1 >= cr:
            verdict = f"safe (p1={p1:.2f}x)"
        elif p1 >= 1.1 and cr <= 1.5:
            verdict = f"marginal (p1={p1:.2f}x, expect SOFT_HIGH ~1-2%/h)"
        elif p1 >= 0.95:
            verdict = f"risky (p1={p1:.2f}x, frequent pressure)"
        else:
            verdict = f"unsafe (p1={p1:.2f}x < 1.0)"
        out[f"{cr:.2f}x"] = verdict
    return out

def to_json(res: EvalResult, top_danger: int = 32) -> dict:
    page_ratios = sorted(p.ratio for p in res.page_stats)
    overall_ratio = res.total_orig / max(res.total_comp, 1)
    p1 = percentile(page_ratios, 1)
    p50 = percentile(page_ratios, 50)
    p99 = percentile(page_ratios, 99)
    uncomp = res.algo_count[ALGO_NONE] / max(res.n_lines, 1)

    res.danger_pages.sort(key=lambda p: p.ratio)
    danger_top = [
        {
            'la_page': f"0x{p.la_page:x}",
            'ratio': round(p.ratio, 3),
            'uncompressible_lines': p.uncompressible_lines,
        }
        for p in res.danger_pages[:top_danger]
    ]

    bins = {k: round(res.page_size_bins[k] / max(res.n_pages, 1), 4)
            for k in sorted(res.page_size_bins)}

    algo_dist = {ALGO_NAMES[i]: round(res.algo_count[i] / max(res.n_lines, 1), 4)
                 for i in range(4)}

    return {
        'workload': res.workload,
        'n_lines': res.n_lines,
        'n_pages': res.n_pages,
        'overall': {
            'compression_ratio_mean': round(overall_ratio, 3),
            'compression_ratio_p1': round(p1, 3),
            'compression_ratio_p50': round(p50, 3),
            'compression_ratio_p99': round(p99, 3),
            'uncompressible_ratio': round(uncomp, 4),
        },
        'algo_distribution': algo_dist,
        'page_size_histogram': bins,
        'danger_pages_count': len(res.danger_pages),
        'danger_pages_top': danger_top,
        'cap_ratio_safety': cap_ratio_safety(p1, p50),
    }

def to_markdown(report: dict) -> str:
    o = report['overall']
    lines = [
        f"# Compression Eval — {report['workload']}",
        "",
        f"- Lines analyzed: **{report['n_lines']:,}**",
        f"- Pages analyzed: **{report['n_pages']:,}**",
        "",
        "## Overall",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Mean ratio | **{o['compression_ratio_mean']}x** |",
        f"| p1 ratio (worst-case anchor) | {o['compression_ratio_p1']}x |",
        f"| p50 ratio | {o['compression_ratio_p50']}x |",
        f"| p99 ratio | {o['compression_ratio_p99']}x |",
        f"| Uncompressible lines | {o['uncompressible_ratio']*100:.1f}% |",
        "",
        "## Algorithm distribution",
        "",
        "| Algo | Share |",
        "|---|---|",
    ]
    for a, v in report['algo_distribution'].items():
        lines.append(f"| {a} | {v*100:.1f}% |")
    lines += ["", "## Page-size histogram", "", "| Bin | Share |", "|---|---|"]
    for k, v in report['page_size_histogram'].items():
        lines.append(f"| {k} | {v*100:.1f}% |")
    lines += ["", "## CapRatio safety", "", "| CapRatio | Verdict |", "|---|---|"]
    for k, v in report['cap_ratio_safety'].items():
        lines.append(f"| {k} | {v} |")
    if report['danger_pages_count']:
        lines += [
            "", f"## Danger pages: {report['danger_pages_count']} total "
            f"({report['danger_pages_count']/max(report['n_pages'],1)*100:.2f}% of pages)", "",
            "| LA Page | Ratio | Uncomp Lines |", "|---|---|---|",
        ]
        for d in report['danger_pages_top'][:8]:
            lines.append(f"| {d['la_page']} | {d['ratio']} | {d['uncompressible_lines']} |")
    return '\n'.join(lines) + '\n'

def gen_bypass_cfg(report: dict) -> str:
    """生成 BYPASS_CFG 寄存器配置.
    简单聚类:连续地址段中 ratio<1 的页 -> 一个 bypass region.
    """
    danger = report.get('danger_pages_top', [])
    if not danger:
        return "# No danger pages -> no bypass needed\n"
    addrs = sorted(int(d['la_page'], 16) for d in danger)
    regions = []
    cur_start = addrs[0]
    cur_end = cur_start + PAGE_SIZE
    for a in addrs[1:]:
        if a <= cur_end + PAGE_SIZE * 4:  # 4 页内的 gap 视为同区
            cur_end = a + PAGE_SIZE
        else:
            regions.append((cur_start, cur_end))
            cur_start, cur_end = a, a + PAGE_SIZE
    regions.append((cur_start, cur_end))

    out = ["# Auto-generated BYPASS_CFG (max 8 regions)\n"]
    for i, (s, e) in enumerate(regions[:8]):
        out.append(f"[{i}] start=0x{s:x} end=0x{e:x} attr=NoCompress\n")
    if len(regions) > 8:
        out.append(f"# WARNING: {len(regions)} candidate regions, keeping top 8\n")
    return ''.join(out)

# ====================================================================
# CLI
# ====================================================================

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace', nargs='?', help='Path to .zctrace file')
    ap.add_argument('--mock', action='store_true',
                    help='Generate mock trace instead of reading file')
    ap.add_argument('--workload', default='mobile_video',
                    help='Workload name (used by --mock or as trace label)')
    ap.add_argument('--n-lines', type=int, default=20000,
                    help='Mock trace size')
    ap.add_argument('--out', default=None,
                    help='Output JSON report path (also writes .md beside it)')
    ap.add_argument('--gen-bypass-cfg', action='store_true',
                    help='Print BYPASS_CFG suggestion to stdout')
    ap.add_argument('--save-mock-trace', default=None,
                    help='If set with --mock, write the generated trace to this path')
    args = ap.parse_args()

    if args.mock:
        records = mock_workload(args.workload, args.n_lines)
        if args.save_mock_trace:
            write_trace(args.save_mock_trace, records, args.workload)
        result = evaluate(iter(records), workload=args.workload)
    else:
        if not args.trace:
            ap.error("trace path required (or use --mock)")
        result = evaluate(read_trace(args.trace), workload=args.workload)

    report = to_json(result)

    if args.gen_bypass_cfg:
        sys.stdout.write(gen_bypass_cfg(report))
        return 0

    md = to_markdown(report)
    if args.out:
        with open(args.out, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=2)
        md_path = os.path.splitext(args.out)[0] + '.md'
        with open(md_path, 'w', encoding='utf-8') as f:
            f.write(md)
        print(f"Wrote {args.out} and {md_path}")
    else:
        print(md)
    return 0

if __name__ == '__main__':
    sys.exit(main())
