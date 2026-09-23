#!/usr/bin/env python3
"""Run verified RTL GEMM shape benchmarks; no external Python dependencies."""
import argparse
import csv
import pathlib
import subprocess

FIELDS = 'm n k int4 cycles first_output issue_cycles wait_bank drain row_prepare capture other output_stall a_packets b_packets outputs'.split()
CASES = [('tile',16,16,16), ('long_k',16,16,64), ('square',64,64,64),
         ('tail',17,17,33), ('gemv',1,64,64), ('skinny',64,1,64),
         ('conv3x3_shape',16,16,36), ('attention_shape',32,32,64)]

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--binary', required=True, type=pathlib.Path)
    ap.add_argument('--output', type=pathlib.Path, default=pathlib.Path('bench/results.csv'))
    ap.add_argument('--extended', action='store_true', help='include K=129/255/256 tests')
    ap.add_argument('--freq-mhz', type=float, default=1000,
                    help='assumed frequency, not an STA-validated claim')
    args = ap.parse_args()
    if args.freq_mhz <= 0: ap.error('frequency must be positive')
    rows = []
    cases = CASES + ([('k129',16,16,129),('k255_tail',17,3,255),('k256_gemv',1,17,256)] if args.extended else [])
    for name,m,n,k in cases:
        for mode in (0,1):
            for stalls in (False,True):
                cmd = [str(args.binary.resolve()), '+bench', f'+m={m}',f'+n={n}',f'+k={k}',f'+int4={mode}']
                if stalls: cmd.append('+stalls')
                run = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=True)
                lines = [line for line in run.stdout.splitlines() if line.startswith('PERF,')]
                if len(lines) != 1 or 'PASS: benchmark output verified' not in run.stdout:
                    raise RuntimeError(run.stdout + run.stderr)
                values = list(map(int, lines[0].split(',')[1:]))
                if len(values) != len(FIELDS): raise RuntimeError('invalid PERF record')
                row = dict(zip(FIELDS, values))
                assert sum(row[f] for f in ('wait_bank','drain','row_prepare','capture','other')) == row['cycles']
                assert row['outputs'] == m*n
                assert row['a_packets'] == row['b_packets'] == ((m+15)//16)*((n+15)//16)*((k+mode)//(1+mode))
                ops = 2*m*n*k
                row.update(case=name, traffic='stalled' if stalls else 'ideal',
                           assumed_mhz=args.freq_mhz, useful_ops=ops,
                           latency_us=row['cycles']/args.freq_mhz,
                           gops=ops*args.freq_mhz/(row['cycles']*1000),
                           utilization=ops/(row['cycles']*512*(1+mode)),
                           interface_bytes=16*(row['a_packets']+row['b_packets'])+4*row['outputs'])
                rows.append(row)
                print(f"{name:18} INT{4 if mode else 8} {row['traffic']:7} {row['cycles']:6} cycles {row['gops']:7.2f} GOPS", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    print(f'Wrote {args.output}; frequency is an assumption, DMA/operator transforms excluded.')

if __name__ == '__main__': main()
