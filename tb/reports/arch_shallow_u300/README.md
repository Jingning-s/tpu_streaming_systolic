# Verilator validation — shallow architecture u300

Validated on September 20, 2026 with Verilator 5.032, `--timing` and
`--assert`. Both final commands exited 0.

| Run | Parameters | GEMM cases | Reset scenarios | Result |
|---|---|---:|---:|---|
| a1 | A1 S2 R0 F0 | 28 | 9 | PASS |
| a0 | A0 S2 R0 F0 | 28 | 9 | PASS |

Both runs cover 64x64 INT8/INT4, boundary shapes, K=1/2/15/16/17/31/32/33,
odd-K padding, independent activation/weight stalls, result backpressure,
runtime mode changes and full-array far-corner completion. Standalone RTL lint
also exited 0 without RTL warnings.

This checkpoint removes the PE D payload/token register boundary and uses the
two-stage 16-bit result finalizer. It does not include a Genus, STA, clock-gating
coverage or power result. The synthesis SDC uses 0.300 ns setup uncertainty.
