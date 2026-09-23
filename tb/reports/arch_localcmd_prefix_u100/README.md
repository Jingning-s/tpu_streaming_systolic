# Verilator validation — local commands and prefix16 u100

Validated on September 21, 2026 with Verilator 5.032, `--timing` and
`--assert`.

| Run | Parameters | GEMM cases | Reset scenarios | Result |
|---|---|---:|---:|---|
| a1 | A1 S2 R0 F0 | 28 | 9 | PASS |
| a0 | A0 S2 R0 F0 | 28 | 9 | PASS |
| prefix16 | 200005 directed/random vectors | — | — | PASS |

The result pipeline retains the same cycle schedule. The SDC setup uncertainty
is 0.100 ns. No new Genus/STA or power result is implied by this functional
validation.
