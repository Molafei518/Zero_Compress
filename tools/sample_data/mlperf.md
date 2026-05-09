# Compression Eval — mlperf

- Lines analyzed: **30,000**
- Pages analyzed: **469**

## Overall

| Metric | Value |
|---|---|
| Mean ratio | **1.257x** |
| p1 ratio (worst-case anchor) | 1.138x |
| p50 ratio | 1.254x |
| p99 ratio | 1.429x |
| Uncompressible lines | 68.4% |

## Algorithm distribution

| Algo | Share |
|---|---|
| BDI | 0.1% |
| Zero | 30.7% |
| ByteDelta | 0.8% |
| None | 68.4% |

## Page-size histogram

| Bin | Share |
|---|---|
| 2048-3072 | 12.8% |
| 3072-4096 | 87.2% |

## CapRatio safety

| CapRatio | Verdict |
|---|---|
| 1.25x | marginal (p1=1.14x, expect SOFT_HIGH ~1-2%/h) |
| 1.50x | marginal (p1=1.14x, expect SOFT_HIGH ~1-2%/h) |
| 1.75x | risky (p1=1.14x, frequent pressure) |
