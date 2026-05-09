# Compression Eval — spec_int

- Lines analyzed: **30,000**
- Pages analyzed: **469**

## Overall

| Metric | Value |
|---|---|
| Mean ratio | **1.568x** |
| p1 ratio (worst-case anchor) | 1.439x |
| p50 ratio | 1.569x |
| p99 ratio | 1.737x |
| Uncompressible lines | 20.8% |

## Algorithm distribution

| Algo | Share |
|---|---|
| BDI | 30.1% |
| Zero | 28.7% |
| ByteDelta | 20.3% |
| None | 20.8% |

## Page-size histogram

| Bin | Share |
|---|---|
| 1024-2048 | 0.2% |
| 2048-3072 | 99.8% |

## CapRatio safety

| CapRatio | Verdict |
|---|---|
| 1.25x | safe (p1=1.44x) |
| 1.50x | marginal (p1=1.44x, expect SOFT_HIGH ~1-2%/h) |
| 1.75x | risky (p1=1.44x, frequent pressure) |
