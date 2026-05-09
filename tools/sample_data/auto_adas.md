# Compression Eval — auto_adas

- Lines analyzed: **30,000**
- Pages analyzed: **469**

## Overall

| Metric | Value |
|---|---|
| Mean ratio | **1.34x** |
| p1 ratio (worst-case anchor) | 1.199x |
| p50 ratio | 1.339x |
| p99 ratio | 1.534x |
| Uncompressible lines | 53.8% |

## Algorithm distribution

| Algo | Share |
|---|---|
| BDI | 0.1% |
| Zero | 20.4% |
| ByteDelta | 25.8% |
| None | 53.8% |

## Page-size histogram

| Bin | Share |
|---|---|
| 2048-3072 | 54.4% |
| 3072-4096 | 45.6% |

## CapRatio safety

| CapRatio | Verdict |
|---|---|
| 1.25x | marginal (p1=1.20x, expect SOFT_HIGH ~1-2%/h) |
| 1.50x | marginal (p1=1.20x, expect SOFT_HIGH ~1-2%/h) |
| 1.75x | risky (p1=1.20x, frequent pressure) |
