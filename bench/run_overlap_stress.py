#!/usr/bin/env python3
"""Verify row-prefetch boundary timing and independent A/B starvation."""
import argparse
import pathlib
import subprocess


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--binary', required=True, type=pathlib.Path)
    ap.add_argument('--output', required=True, type=pathlib.Path)
    args = ap.parse_args()
    cases = []
    for mode in (0, 1):
        for n in range(1, 17):
            for stalls in (False, True):
                cases.append((f'rows_n{n}_i{mode}_stall{int(stalls)}',
                              ['+m=3', f'+n={n}', '+k=17', f'+int4={mode}'] +
                              (['+stalls'] if stalls else [])))
        for a, b in ((17, 0), (0, 19)):
            cases.append((f'starve_i{mode}_a{a}_b{b}',
                          ['+m=17', '+n=3', '+k=255', f'+int4={mode}',
                           f'+a_gap={a}', f'+b_gap={b}', '+stalls']))
    output = []
    for name, flags in cases:
        result = subprocess.run([str(args.binary.resolve()), '+bench'] + flags,
                                capture_output=True, text=True, timeout=120)
        if result.returncode or 'PASS: benchmark output verified' not in result.stdout:
            raise RuntimeError(f'{name}\n{result.stdout}\n{result.stderr}')
        perf = next(line for line in result.stdout.splitlines() if line.startswith('PERF,'))
        output.append(f'{name}: PASS {perf}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text('\n'.join(output) + '\n')
    print(f'PASS: {len(cases)} overlap stress cases; {args.output}')


if __name__ == '__main__':
    main()
