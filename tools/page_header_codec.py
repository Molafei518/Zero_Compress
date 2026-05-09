#!/usr/bin/env python3
"""
page_header_codec.py — Reference encode/decode for ZC Page Header v2 (176 byte).

Spec: docs/02_page_header_spec.md
Used as the golden model for RTL verification.
"""
import struct
import sys
from dataclasses import dataclass, field
from typing import List, Tuple

ZC_PAGE_HEADER_SIZE = 176
ZC_LINES_PER_PAGE = 64
ZC_PAGE_MAGIC = 0xCC55

# CRC8/SAE-J1850 polynomial: x^8 + x^4 + x^3 + x^2 + 1 (0x1D)
CRC8_POLY = 0x1D
CRC8_INIT = 0xFF


def crc8(data: bytes) -> int:
    crc = CRC8_INIT
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ CRC8_POLY) & 0xFF if (crc & 0x80) else (crc << 1) & 0xFF
    return crc


def crc32_ieee(data: bytes) -> int:
    """Standard IEEE 802.3 CRC-32 (poly 0xEDB88320, refin=true, refout=true, xorout=0xFFFFFFFF)."""
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if (crc & 1) else crc >> 1
    return crc ^ 0xFFFFFFFF


@dataclass
class LineInfo:
    algo: int  # 2 bit
    mode: int  # 3 bit
    size: int  # 1..64 byte (compressed)


@dataclass
class PageHeader:
    generation: int = 0
    total_comp_size: int = 0  # bytes
    line_infos: List[LineInfo] = field(default_factory=list)
    line_crc8s: List[int] = field(default_factory=list)

    def __post_init__(self):
        if not self.line_infos:
            self.line_infos = [LineInfo(0, 0, 1) for _ in range(ZC_LINES_PER_PAGE)]
        if not self.line_crc8s:
            self.line_crc8s = [0] * ZC_LINES_PER_PAGE


def pack_line_info(infos: List[LineInfo]) -> bytes:
    """Pack 64 × 11 bit into 88 byte (LSB-first within each 11-bit slot)."""
    assert len(infos) == ZC_LINES_PER_PAGE
    bits = bytearray(88)
    for i, li in enumerate(infos):
        assert 0 <= li.algo <= 3, f"algo out of range: {li.algo}"
        assert 0 <= li.mode <= 7, f"mode out of range: {li.mode}"
        assert 1 <= li.size <= 64, f"size out of range: {li.size}"
        val = (li.algo & 0x3) | ((li.mode & 0x7) << 2) | (((li.size - 1) & 0x3F) << 5)
        bit_offset = i * 11
        for b in range(11):
            byte_pos = (bit_offset + b) // 8
            bit_pos = (bit_offset + b) % 8
            if (val >> b) & 1:
                bits[byte_pos] |= (1 << bit_pos)
    return bytes(bits)


def unpack_line_info(packed: bytes) -> List[LineInfo]:
    assert len(packed) == 88
    out = []
    for i in range(ZC_LINES_PER_PAGE):
        bit_offset = i * 11
        val = 0
        for b in range(11):
            byte_pos = (bit_offset + b) // 8
            bit_pos = (bit_offset + b) % 8
            if (packed[byte_pos] >> bit_pos) & 1:
                val |= 1 << b
        algo = val & 0x3
        mode = (val >> 2) & 0x7
        size = ((val >> 5) & 0x3F) + 1
        out.append(LineInfo(algo, mode, size))
    return out


def encode_page_header(hdr: PageHeader) -> bytes:
    """Encode a PageHeader struct into 176 byte."""
    line_info_bytes = pack_line_info(hdr.line_infos)
    line_crc_bytes = bytes(hdr.line_crc8s)
    body = (
        struct.pack('<H', ZC_PAGE_MAGIC)
        + b'\x00\x00'                                # reserved0
        + struct.pack('<I', hdr.generation)
        + struct.pack('<H', hdr.total_comp_size)
        + b'\x00\x00'                                # reserved1
        + b'\x00\x00\x00\x00'                        # crc32 placeholder
        + line_info_bytes
        + line_crc_bytes
        + b'\x00' * 8                                # reserved2
    )
    assert len(body) == ZC_PAGE_HEADER_SIZE
    # Compute CRC32 over header[0x00..0xAF] except crc32 field itself (offset 0x0C..0x0F)
    crc_input = body[:0x0C] + body[0x10:]
    page_crc = crc32_ieee(crc_input)
    return body[:0x0C] + struct.pack('<I', page_crc) + body[0x10:]


def decode_page_header(blob: bytes) -> Tuple[PageHeader, bool]:
    """Returns (header, crc_ok)."""
    assert len(blob) == ZC_PAGE_HEADER_SIZE
    magic = struct.unpack('<H', blob[0:2])[0]
    if magic != ZC_PAGE_MAGIC:
        raise ValueError(f"bad magic: 0x{magic:04x}")
    generation = struct.unpack('<I', blob[4:8])[0]
    total_comp_size = struct.unpack('<H', blob[8:10])[0]
    page_crc_stored = struct.unpack('<I', blob[12:16])[0]
    line_info = unpack_line_info(blob[0x10:0x68])
    line_crc8s = list(blob[0x68:0xA8])

    # Verify CRC32
    crc_input = blob[:0x0C] + blob[0x10:]
    crc_calc = crc32_ieee(crc_input)
    crc_ok = (crc_calc == page_crc_stored)

    hdr = PageHeader(
        generation=generation,
        total_comp_size=total_comp_size,
        line_infos=line_info,
        line_crc8s=line_crc8s,
    )
    return hdr, crc_ok


def line_offset(hdr: PageHeader, idx: int) -> int:
    """Compute byte offset (within compressed page) of line `idx`. Excludes header itself."""
    return sum(li.size for li in hdr.line_infos[:idx])


# ====================================================================
# Self-test
# ====================================================================

def _test_round_trip():
    hdr = PageHeader(generation=42, total_comp_size=2048)
    for i in range(ZC_LINES_PER_PAGE):
        hdr.line_infos[i] = LineInfo(algo=i % 4, mode=(i * 3) % 8, size=(i % 64) + 1)
        hdr.line_crc8s[i] = (i * 7) & 0xFF

    blob = encode_page_header(hdr)
    assert len(blob) == 176
    hdr2, crc_ok = decode_page_header(blob)
    assert crc_ok, "CRC should match on clean encode"
    assert hdr2.generation == 42
    assert hdr2.total_comp_size == 2048
    for i in range(ZC_LINES_PER_PAGE):
        assert hdr2.line_infos[i].algo == hdr.line_infos[i].algo
        assert hdr2.line_infos[i].mode == hdr.line_infos[i].mode
        assert hdr2.line_infos[i].size == hdr.line_infos[i].size
        assert hdr2.line_crc8s[i] == hdr.line_crc8s[i]
    print("OK: round-trip")


def _test_crc_detect():
    hdr = PageHeader(generation=1, total_comp_size=128)
    for i in range(ZC_LINES_PER_PAGE):
        hdr.line_infos[i] = LineInfo(1, 0, 2)
    blob = bytearray(encode_page_header(hdr))
    blob[20] ^= 0x01  # flip a bit in line_info
    _, crc_ok = decode_page_header(bytes(blob))
    assert not crc_ok, "CRC must detect single-bit flip"
    print("OK: CRC detection")


def _test_all_zero_page():
    """Page where every line is zero-compressed to 1 byte."""
    hdr = PageHeader(generation=1, total_comp_size=64)
    for i in range(ZC_LINES_PER_PAGE):
        hdr.line_infos[i] = LineInfo(algo=1, mode=0, size=1)  # Zero, mode 0, 1 byte
    blob = encode_page_header(hdr)
    hdr2, ok = decode_page_header(blob)
    assert ok
    for i in range(ZC_LINES_PER_PAGE):
        assert line_offset(hdr2, i) == i  # contiguous 1-byte each
    print("OK: all-zero page")


def _test_uncompressible_page():
    """Page where every line is 64 byte (uncompressed)."""
    hdr = PageHeader(generation=99, total_comp_size=64 * 64)
    for i in range(ZC_LINES_PER_PAGE):
        hdr.line_infos[i] = LineInfo(algo=3, mode=0, size=64)
    blob = encode_page_header(hdr)
    hdr2, ok = decode_page_header(blob)
    assert ok
    assert line_offset(hdr2, 63) == 63 * 64
    print("OK: uncompressible page")


def _test_offset_calc():
    hdr = PageHeader()
    sizes = [1, 4, 20, 36, 16, 64, 1, 8] * 8  # 64 entries
    for i in range(ZC_LINES_PER_PAGE):
        hdr.line_infos[i] = LineInfo(algo=0, mode=0, size=sizes[i])
    expected = 0
    for i in range(ZC_LINES_PER_PAGE):
        assert line_offset(hdr, i) == expected
        expected += sizes[i]
    print("OK: offset calc")


def main():
    _test_round_trip()
    _test_crc_detect()
    _test_all_zero_page()
    _test_uncompressible_page()
    _test_offset_calc()
    print("All tests passed.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
