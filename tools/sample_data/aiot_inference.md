# Compression Eval — aiot_inference

- Lines analyzed: **30,000**
- Pages analyzed: **469**

## Overall

| Metric | Value |
|---|---|
| Mean ratio | **1.308x** |
| p1 ratio (worst-case anchor) | 1.158x |
| p50 ratio | 1.307x |
| p99 ratio | 1.473x |
| Uncompressible lines | 61.7% |

## Algorithm distribution

| Algo | Share |
|---|---|
| BDI | 0.1% |
| Zero | 29.0% |
| ByteDelta | 9.2% |
| None | 61.7% |

## Page-size histogram

| Bin | Share |
|---|---|
| 2048-3072 | 35.8% |
| 3072-4096 | 64.2% |

## CapRatio safety

| CapRatio | Verdict |
|---|---|
| 1.25x | marginal (p1=1.16x, expect SOFT_HIGH ~1-2%/h) |
| 1.50x | marginal (p1=1.16x, expect SOFT_HIGH ~1-2%/h) |
| 1.75x | risky (p1=1.16x, frequent pressure) |
