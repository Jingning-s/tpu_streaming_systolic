# K-stream / row-prefetch validation

Verilator 5.032, --timing --assert, A0/A1 S2 R0 F0.
Each configuration passed 34 GEMM cases and 15 reset cases (regression logs),
44 performance cases (../../../bench/results_overlap_a0.csv and results_overlap_a1.csv),
and 68 row-boundary / starvation stress cases (stress logs).

The performance CSV files are in the project bench/ directory. All outputs
were numerically checked. Frequency-derived metrics assume 1 GHz, not STA closure.
RTL source: src/tpu_stream_top.sv; full explanation: ARCHITECTURE_UPDATE_OVERLAP.md.
