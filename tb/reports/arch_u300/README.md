# Verilator validation — architecture u300

Verilator 5.032, --timing --assert. All commands exited 0. Standalone RTL lint also passed without warnings.

| Run | Parameters | GEMM cases | Reset scenarios | Result |
|---|---|---:|---:|---|
| a1 | A1 S2 R3 F0 | 28 | 11 | PASS |
| a0 | A0 S2 R3 F0 | 28 | 11 | PASS |
| legacy | A1 S0 R0 F0 | 28 | 9 | PASS |
| csel8 | exhaustive | 0 | 0 | PASS |

csel8 checked all 131072 (a,b,cin) combinations. A1/A0 used the four-byte
finalizer; legacy used the original two-half result selector and S0 scheduler
with common fixes. All end-to-end runs included 64x64 INT8/INT4, boundary
shapes, odd K, independent input stalls, backpressure and mode changes.

Build warnings are preserved separately. The testbench has intentional
integer-to-packet-width conversions. The legacy carry-select vector chain
also produces Verilator UNOPTFLAT (a feed-forward chain expressed through
vector slices); its simulation completed and all checks passed.

No synthesis, STA, clock-gating coverage or power result is implied by these
functional tests. Setup uncertainty is 0.300 ns in the synthesis SDC.
