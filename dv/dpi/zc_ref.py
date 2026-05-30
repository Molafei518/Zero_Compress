#!/usr/bin/env python3
"""
zc_ref.py — DPI golden 的 Python 镜像 + 交叉校验。

用途:
  1) 作为"非 DPI scoreboard"的参考模型(cocotb / 后仿对比时直接调用 Python golden)。
  2) 校验 dv/golden/vectors/ 与 tools/ golden 自洽(防止向量陈旧)。
  3) 定义 C(zc_dpi.c)↔ Python 的契约;C 自检 main() 与本文件应给出相同结果。

运行:python dv/dpi/zc_ref.py   (无需 gcc/仿真器)
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import compress_eval as ce          # noqa: E402
import page_header_codec as ph      # noqa: E402

VEC = os.path.join(ROOT, 'dv', 'golden', 'vectors', 'vectors.json')


# ---- 参考模型 API(scoreboard 调用)----
def ref_compress(line: bytes):
    """→ (algo, mode, size),等价 DPI zc_compress。"""
    return ce.compress_line(line)


def ref_crc8(data: bytes) -> int:
    """→ crc8,等价 DPI zc_crc8。"""
    return ph.crc8(data)


def ref_crc32(data: bytes) -> int:
    return ph.crc32_ieee(data)


# ---- 交叉校验:重算 vectors.json,逐条比对 ----
def cross_check() -> int:
    if not os.path.exists(VEC):
        print(f"[zc_ref] vectors 不存在,先跑 dv/golden/gen_vectors.py")
        return 1
    d = json.load(open(VEC, encoding='utf-8'))
    fails = 0

    for v in d['crc8']:
        data = bytes.fromhex(v['data'])
        if ref_crc8(data) != v['crc8']:
            fails += 1; print(f"  CRC8 mismatch: {v}")
    for v in d['compress']:
        line = bytes.fromhex(v['line'])
        a, m, s = ref_compress(line)
        if (a, m, s) != (v['algo'], v['mode'], v['size']):
            fails += 1
            print(f"  COMPRESS mismatch: got ({a},{m},{s}) exp ({v['algo']},{v['mode']},{v['size']})")
    for v in d['pagehdr']:
        blob = bytes.fromhex(v['blob'])
        _, ok = ph.decode_page_header(blob)
        if not ok:
            fails += 1; print(f"  PAGEHDR crc fail: {v['name']}")

    n = len(d['crc8']) + len(d['compress']) + len(d['pagehdr'])
    if fails == 0:
        print(f"[zc_ref] OK:{n} 条向量与 golden 自洽")
    else:
        print(f"[zc_ref] FAIL:{fails}/{n} 条不一致")
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(cross_check())
