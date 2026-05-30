/* ============================================================================
 * zc_dpi.h — DPI-C golden 声明(供 SV import "DPI-C")
 *
 *   C 实现是 Python golden(tools/compress_eval.py + page_header_codec.py)的镜像,
 *   并由 dv/dpi/zc_ref.py 交叉验证一致。
 *   SV 侧声明见 dv/uvm/zc_dv_pkg.sv。
 * ========================================================================== */
#ifndef ZC_DPI_H
#define ZC_DPI_H

#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

/* CRC-8/SAE-J1850, poly=0x1D, init=0xFF;覆盖 data[0..len-1] */
unsigned char zc_crc8(const unsigned char* data, int len);

/* CRC-32 IEEE 802.3(refin/refout, xorout=0xFFFFFFFF) */
unsigned int  zc_crc32(const unsigned char* data, int len);

/* 三引擎压缩:返回 size(1..64);*algo/*mode 输出
 *   algo: 0=BDI 1=Zero 2=ByteDelta 3=None  (与 zc_pkg::algo_e 一致)
 *   tie-break: Zero > ByteDelta > BDI(架构 §6.4) */
int zc_compress(const unsigned char line[64], int* algo, int* mode);

#ifdef __cplusplus
}
#endif
#endif /* ZC_DPI_H */
