/* ============================================================================
 * zc_dpi.c — DPI-C golden 实现(Python golden 的 C 镜像)
 *   镜像:tools/compress_eval.py(compress_*)+ page_header_codec.py(crc8/crc32)
 *   一致性由 dv/dpi/zc_ref.py 交叉验证;另有 main() 自检(独立编译)。
 *
 *   Questa 下编译:vlog -dpiheader ... ; vsim -sv_lib zc_dpi
 *   独立自检(若有 gcc):gcc -DZC_DPI_SELFTEST zc_dpi.c -o zc_dpi_test && ./zc_dpi_test
 * ========================================================================== */
#include <string.h>
#ifndef ZC_DPI_SELFTEST
#include "zc_dpi.h"
#endif

enum { ALGO_BDI=0, ALGO_ZERO=1, ALGO_BYTEDELTA=2, ALGO_NONE=3 };

/* ---------------- CRC ---------------- */
unsigned char zc_crc8(const unsigned char* data, int len) {
    unsigned char crc = 0xFF;                 /* init */
    for (int i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++)
            crc = (crc & 0x80) ? (unsigned char)((crc << 1) ^ 0x1D)
                               : (unsigned char)(crc << 1);
    }
    return crc;
}

unsigned int zc_crc32(const unsigned char* data, int len) {
    unsigned int crc = 0xFFFFFFFFu;
    for (int i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++)
            crc = (crc & 1u) ? ((crc >> 1) ^ 0xEDB88320u) : (crc >> 1);
    }
    return crc ^ 0xFFFFFFFFu;
}

/* ---------------- 三引擎(镜像 compress_eval.py)---------------- */
static int rd32s(const unsigned char* p) { /* little-endian signed 32 */
    return (int)((unsigned)p[0] | ((unsigned)p[1]<<8) | ((unsigned)p[2]<<16) | ((unsigned)p[3]<<24));
}
static long long rd64s(const unsigned char* p) {
    unsigned long long v = 0;
    for (int i = 7; i >= 0; i--) v = (v<<8) | p[i];
    return (long long)v;
}
static long long llabs64(long long x){ return x<0 ? -x : x; }

static int comp_zero(const unsigned char* L, int* mode) {
    int all0 = 1; for (int i=0;i<64;i++) if (L[i]) { all0=0; break; }
    if (all0) { *mode=0; return 1; }
    int nz=0; for (int i=0;i<64;i+=4) if (L[i]||L[i+1]||L[i+2]||L[i+3]) nz++;
    if (nz<=8) { *mode=1; return 1+2+4*nz; }
    *mode=2; return 64;
}

static int comp_bdi(const unsigned char* L, int* mode) {
    int all0=1; for(int i=0;i<64;i++) if(L[i]){all0=0;break;}
    int same32=1; for(int i=4;i<64;i+=4) if(memcmp(L+i,L,4)){same32=0;break;}
    long long ma32=0, base32=rd32s(L);
    for(int i=0;i<64;i+=4){ long long d=llabs64((long long)rd32s(L+i)-base32); if(d>ma32)ma32=d; }
    long long ma64=0, base64=rd64s(L);
    for(int i=0;i<64;i+=8){ long long d=llabs64(rd64s(L+i)-base64); if(d>ma64)ma64=d; }
    int sz[8];
    sz[0]= all0            ? 1  : 64;
    sz[1]= same32          ? 4  : 64;
    sz[2]= (ma32<128)      ? 20 : 64;
    sz[3]= (ma32<32768)    ? 36 : 64;
    sz[4]= (ma64<128)      ? 16 : 64;
    sz[5]= (ma64<32768)    ? 24 : 64;
    sz[6]= (ma64<2147483648LL) ? 40 : 64;
    sz[7]= 64;
    int bm=7, bs=64;
    for(int m=7;m>=0;m--) if(sz[m]<=bs){bs=sz[m];bm=m;}
    *mode=bm; return bs;
}

static int comp_bd(const unsigned char* L, int* mode) {
    int all0=1; for(int i=0;i<64;i++) if(L[i]){all0=0;break;}
    int sameb=1; for(int i=1;i<64;i++) if(L[i]!=L[0]){sameb=0;break;}
    int okb=1; for(int i=1;i<64;i++){ int d=(int)L[i]-(int)L[0]; if(!(d>=-8 && d<8)){okb=0;break;} }
    int okw16=1;
    for(int i=2;i<64;i+=2){ int w=L[i]|(L[i+1]<<8), w0=L[0]|(L[1]<<8); int d=w-w0;
                            if(!(d>=-128 && d<128)){okw16=0;break;} }
    int okw32=1;
    for(int i=4;i<64;i+=4){ int d=rd32s(L+i)-rd32s(L); if(!(d>=-32768 && d<32768)){okw32=0;break;} }
    int sz[6];
    sz[0]= all0  ? 1  : 64;
    sz[1]= sameb ? 2  : 64;
    sz[2]= okb   ? 34 : 64;
    sz[3]= okw16 ? 34 : 64;
    sz[4]= okw32 ? 35 : 64;
    sz[5]= 64;
    int bm=5, bs=64;
    for(int m=5;m>=0;m--) if(sz[m]<=bs){bs=sz[m];bm=m;}
    *mode=bm; return bs;
}

int zc_compress(const unsigned char line[64], int* algo, int* mode) {
    int zm,bdm,bdim;
    int zs  = comp_zero(line,&zm);
    int bds = comp_bd(line,&bdm);
    int bdis= comp_bdi(line,&bdim);
    /* tie-break: Zero > ByteDelta > BDI (rank 0/1/2) */
    int best_algo=ALGO_ZERO, best_mode=zm, best_sz=zs, best_rank=0;
    if (bds < best_sz || (bds==best_sz && 1<best_rank)) { best_algo=ALGO_BYTEDELTA; best_mode=bdm; best_sz=bds; best_rank=1; }
    if (bdis< best_sz || (bdis==best_sz&& 2<best_rank)) { best_algo=ALGO_BDI;       best_mode=bdim;best_sz=bdis;best_rank=2; }
    if (best_sz >= 64) { *algo=ALGO_NONE; *mode=0; return 64; }
    *algo=best_algo; *mode=best_mode; return best_sz;
}

#ifdef ZC_DPI_SELFTEST
#include <stdio.h>
int main(void){
    unsigned char z[64]={0}; int a,m,s;
    s=zc_compress(z,&a,&m); printf("all-zero: algo=%d mode=%d size=%d (exp Zero/1)\n",a,m,s);
    unsigned char one[1]={0}; printf("crc8(0x00,1)=0x%02x (exp 0xc4)\n", zc_crc8(one,1));
    return 0;
}
#endif
