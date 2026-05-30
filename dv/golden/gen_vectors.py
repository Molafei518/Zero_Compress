#!/usr/bin/env python3
"""
gen_vectors.py — 从已验证的 Python golden model 生成 RTL 验证向量。

复用:
  tools/compress_eval.py   (compress_line → algo/mode/size)
  tools/page_header_codec.py (crc8 / crc32_ieee / encode_page_header)

产出(dv/golden/vectors/):
  crc8_in.mem / crc8_len.mem / crc8_exp.mem   → 测 rtl/line_crc8.sv(已实现,可直接对拍)
  compress_in.mem / compress_exp.mem          → 测 rtl/compress_top.sv(algo/mode/size)
  pagehdr_*.mem / pagehdr_vectors.json        → 测 page_header pack/crc
  vectors.json                                → 全部向量(供 DPI/cocotb-style scoreboard)

.mem 格式:每行一个十六进制值,$readmemh 直接读。
用法:python dv/golden/gen_vectors.py [--n 256] [--seed 1]
"""
import argparse, json, os, random, struct, sys

# 定位 repo 根与 tools/
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

import compress_eval as ce          # noqa: E402
import page_header_codec as ph      # noqa: E402

OUT = os.path.join(HERE, 'vectors')

ALGO_NAMES = ce.ALGO_NAMES


def line_to_hex(line: bytes) -> str:
    """64 byte → 128 hex 字符(byte0 在最右,匹配 SV [7:0] 在 LSB)。"""
    # $readmemh 读成一个 512-bit 向量;让 byte0 落在 bit[7:0]
    return ''.join(f'{b:02x}' for b in reversed(line))


def emit_mem(path, rows):
    with open(path, 'w', encoding='utf-8') as f:
        for r in rows:
            f.write(r + '\n')


def gen_compress_vectors(n, rng):
    """代表性 + 随机 64B line → 期望 {algo,mode,size}。"""
    lines = []
    # 定向 pattern(覆盖各 algo)
    lines.append(bytes(64))                                   # 全零
    lines.append(bytes([0xAB]*64))                            # 单 byte 重复
    lines.append(b''.join(struct.pack('<i', 1000+i) for i in range(16)))  # 小整数(BDI)
    yuv = bytes((100 + rng.randint(-3, 3)) & 0xff for _ in range(64))     # YUV(ByteDelta)
    lines.append(yuv)
    sparse = bytearray(64)                                    # 稀疏(Zero)
    sparse[0:4] = struct.pack('<I', 0x1234)
    lines.append(bytes(sparse))
    lines.append(bytes(rng.randint(0, 255) for _ in range(64)))          # 随机(可能 None)
    # 随机补足
    gens = [ce.gen_yuv, ce.gen_npu_int8_weight, ce.gen_npu_activation,
            ce.gen_pointer_array, ce.gen_small_int_array, ce.gen_struct_with_padding,
            ce.gen_heap_mixed, ce.gen_random]
    while len(lines) < n:
        lines.append(rng.choice(gens)())

    in_rows, exp_rows, jvec = [], [], []
    for ln in lines:
        algo, mode, size = ce.compress_line(ln)
        # 期望打包:{algo[1:0], mode[2:0], size[6:0]} → 12 bit
        packed = (algo & 0x3) | ((mode & 0x7) << 2) | ((size & 0x7f) << 5)
        in_rows.append(line_to_hex(ln))
        exp_rows.append(f'{packed:03x}')
        jvec.append({'line': ln.hex(), 'algo': algo, 'algo_name': ALGO_NAMES[algo],
                     'mode': mode, 'size': size})
    return in_rows, exp_rows, jvec


def gen_crc8_vectors(n, rng):
    """任意 1..64 byte 序列 → 期望 crc8(测 line_crc8.sv,该模块已实现)。"""
    in_rows, len_rows, exp_rows, jvec = [], [], [], []
    fixed = [bytes([0]), bytes([0xff]*64), bytes(range(20)), b'\xCC\x55']
    seqs = list(fixed)
    while len(seqs) < n:
        L = rng.randint(1, 64)
        seqs.append(bytes(rng.randint(0, 255) for _ in range(L)))
    for s in seqs:
        padded = s + bytes(64 - len(s))           # 左对齐到 64B(高位 0 填充)
        in_rows.append(line_to_hex(padded))
        len_rows.append(f'{len(s):02x}')
        exp_rows.append(f'{ph.crc8(s):02x}')
        jvec.append({'data': s.hex(), 'len': len(s), 'crc8': ph.crc8(s)})
    return in_rows, len_rows, exp_rows, jvec


def gen_pagehdr_vectors(rng):
    """构造若干 Page Header → 176B 编码 + crc32(测 pack/unpack/crc)。"""
    jvec, hex_rows = [], []
    cases = []
    # 全零页(每行压到 1B)
    h0 = ph.PageHeader(generation=1, total_comp_size=64)
    for i in range(ph.ZC_LINES_PER_PAGE):
        h0.line_infos[i] = ph.LineInfo(algo=1, mode=0, size=1)
    cases.append(('all_zero', h0))
    # 混合页
    h1 = ph.PageHeader(generation=42, total_comp_size=2048)
    for i in range(ph.ZC_LINES_PER_PAGE):
        h1.line_infos[i] = ph.LineInfo(algo=i % 4, mode=(i*3) % 8, size=(i % 64)+1)
        h1.line_crc8s[i] = (i*7) & 0xff
    cases.append(('mixed', h1))
    for name, h in cases:
        blob = ph.encode_page_header(h)
        assert len(blob) == ph.ZC_PAGE_HEADER_SIZE
        crc = struct.unpack('<I', blob[12:16])[0]
        hex_rows.append(''.join(f'{b:02x}' for b in reversed(blob)))  # 176B → hex
        jvec.append({'name': name, 'blob': blob.hex(), 'page_crc32': crc,
                     'generation': h.generation, 'total_comp_size': h.total_comp_size})
    return hex_rows, jvec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=256)
    ap.add_argument('--seed', type=int, default=1)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    os.makedirs(OUT, exist_ok=True)

    c_in, c_exp, c_jv = gen_compress_vectors(args.n, rng)
    emit_mem(os.path.join(OUT, 'compress_in.mem'), c_in)
    emit_mem(os.path.join(OUT, 'compress_exp.mem'), c_exp)

    k_in, k_len, k_exp, k_jv = gen_crc8_vectors(args.n, rng)
    emit_mem(os.path.join(OUT, 'crc8_in.mem'), k_in)
    emit_mem(os.path.join(OUT, 'crc8_len.mem'), k_len)
    emit_mem(os.path.join(OUT, 'crc8_exp.mem'), k_exp)

    p_hex, p_jv = gen_pagehdr_vectors(rng)
    emit_mem(os.path.join(OUT, 'pagehdr_blob.mem'), p_hex)

    with open(os.path.join(OUT, 'vectors.json'), 'w', encoding='utf-8') as f:
        json.dump({'compress': c_jv, 'crc8': k_jv, 'pagehdr': p_jv}, f, indent=1)

    print(f"Wrote vectors to {OUT}/")
    print(f"  compress: {len(c_jv)}  crc8: {len(k_jv)}  pagehdr: {len(p_jv)}")
    # 自检:算法分布,确认覆盖
    from collections import Counter
    dist = Counter(v['algo_name'] for v in c_jv)
    print(f"  compress algo dist: {dict(dist)}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
