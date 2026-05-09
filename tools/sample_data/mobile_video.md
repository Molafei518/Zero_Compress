# Compression Eval — mobile_video

- Lines analyzed: **30,000**
- Pages analyzed: **469**

## Overall

| Metric | Value |
|---|---|
| Mean ratio | **1.285x** |
| p1 ratio (worst-case anchor) | 1.179x |
| p50 ratio | 1.281x |
| p99 ratio | 1.405x |
| Uncompressible lines | 55.0% |

## Algorithm distribution

| Algo | Share |
|---|---|
| BDI | 0.4% |
| Zero | 14.2% |
| ByteDelta | 30.3% |
| None | 55.0% |

## Page-size histogram

| Bin | Share |
|---|---|
| 2048-3072 | 18.3% |
| 3072-4096 | 81.7% |

## CapRatio safety

| CapRatio | Verdict |
|---|---|
| 1.25x | marginal (p1=1.18x, expect SOFT_HIGH ~1-2%/h) |
| 1.50x | marginal (p1=1.18x, expect SOFT_HIGH ~1-2%/h) |
| 1.75x | risky (p1=1.18x, frequent pressure) |
