#!/usr/bin/env python3
"""Cycle-free reference model for sysa_backhand's streaming TPU."""

from __future__ import annotations
import argparse
import random
from typing import List, Sequence

ARRAY_SIZE = 16

def tiled_gemm(a: Sequence[Sequence[int]], b: Sequence[Sequence[int]], int4=False) -> List[List[int]]:
    m, k = len(a), len(a[0])
    if len(b) != k or any(len(row) != k for row in a):
        raise ValueError("incompatible or ragged A/B")
    n = len(b[0])
    if any(len(row) != n for row in b):
        raise ValueError("ragged B")
    limit = 8 if int4 else 128
    lo, hi = -limit, limit - 1
    aa = [[max(lo, min(hi, int(x))) for x in row] for row in a]
    bb = [[max(lo, min(hi, int(x))) for x in row] for row in b]
    return [[sum(aa[i][kk] * bb[kk][j] for kk in range(k))
             for j in range(n)] for i in range(m)]

def rtl_output_order(a, b, int4=False) -> List[int]:
    """Return tile-major, row-major-within-tile output like the RTL."""
    m, n = len(a), len(b[0])
    result = tiled_gemm(a, b, int4)
    output = []
    for mb in range(0, m, ARRAY_SIZE):
        for nb in range(0, n, ARRAY_SIZE):
            for row in range(min(ARRAY_SIZE, m - mb)):
                for col in range(min(ARRAY_SIZE, n - nb)):
                    output.append(result[mb + row][nb + col])
    return output

def signed(value, width):
    value &= (1 << width) - 1
    return value - (1 << width) if value & (1 << (width - 1)) else value

def pack_a_packet(a, k_base, k_len, step, int4=False):
    """Pack one 128-bit A packet using the RTL lane convention."""
    packet = 0
    for row in range(min(ARRAY_SIZE, len(a))):
        k0 = k_base + (2 * step if int4 else step)
        if k0 >= k_base + k_len:
            continue
        if int4:
            packet |= (a[row][k0] & 0xf) << (row * 8)
            k1 = k0 + 1
            if k1 < k_base + k_len:
                packet |= (a[row][k1] & 0xf) << (row * 8 + 4)
        else:
            packet |= (a[row][k0] & 0xff) << (row * 8)
    return packet

def pack_b_packet(b, n_base, n_len, k_base, k_len, step, int4=False):
    """Pack one 128-bit B packet using the RTL lane convention."""
    packet = 0
    for col in range(min(ARRAY_SIZE, n_len)):
        k0 = k_base + (2 * step if int4 else step)
        if k0 >= k_base + k_len:
            continue
        if int4:
            packet |= (b[k0][n_base + col] & 0xf) << (col * 8)
            k1 = k0 + 1
            if k1 < k_base + k_len:
                packet |= (b[k1][n_base + col] & 0xf) << (col * 8 + 4)
        else:
            packet |= (b[k0][n_base + col] & 0xff) << (col * 8)
    return packet

def self_test():
    random.seed(0x51A)
    for int4 in (False, True):
        for m, n, k in ((1, 1, 1), (3, 5, 7), (16, 16, 16), (17, 19, 33)):
            limit = 8 if int4 else 128
            a = [[random.randrange(-limit, limit) for _ in range(k)] for _ in range(m)]
            b = [[random.randrange(-limit, limit) for _ in range(n)] for _ in range(k)]
            ref = tiled_gemm(a, b, int4)
            expected = [ref[mb + r][nb + c]
                        for mb in range(0, m, ARRAY_SIZE)
                        for nb in range(0, n, ARRAY_SIZE)
                        for r in range(min(ARRAY_SIZE, m - mb))
                        for c in range(min(ARRAY_SIZE, n - nb))]
            assert rtl_output_order(a, b, int4) == expected
    print("TPU reference self-test: PASS")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    self_test()

