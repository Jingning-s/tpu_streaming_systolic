# Tiled INT8/INT4 systolic GEMM engine

`tpu_stream_top` implements a 16x16 physical output-stationary systolic array.
Runtime `M`, `N`, and `K` configuration allows 64x64 and larger GEMMs through
M/N/K tiling. The same PE array supports one INT8 MAC or two independent INT4
MACs per PE per cycle.

## Runtime configuration

A job is accepted when `cfg_valid && cfg_ready` is true. `cfg_m`, `cfg_n`,
`cfg_k`, and `precision_mode` remain fixed until the job completes.

- `precision_mode == 0`: signed INT8
- `precision_mode == 1`: two packed signed INT4 operands per byte

## 128-bit tile streams

A and B are supplied as K-slice packets in `(mt, nt, kt)` order. Byte `i` of
the A stream belongs to physical row `i`; byte `i` of the B stream belongs to
physical column `i`.

- INT8: byte `i` contains the operand at K position `k`.
- INT4: bits `[3:0]` contain K position `k`, and bits `[7:4]` contain `k+1`.

Packed INT4 is retained in the ping-pong tile buffers and is interpreted as
two signed compute lanes only when read into the array. Invalid boundary rows,
columns, and an odd final K lane are masked by hardware.

Results are signed INT32 in tile-major order and row-major order within a tile.
`m_result_tile_last` marks the final valid element of every C tile;
`m_result_last` marks the final result of the complete GEMM.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the scheduler and dataflow details.

## Verification

The self-checking testbench covers boundary tiles, odd K, runtime mode changes,
K-tile accumulation, backpressure, and a 64x64x64 INT4 GEMM.

```sh
cd tb
make verilator          # A1, tile descriptors, two-stage 16-bit result CPA
# VERILATOR=/path/to/verilator make verilator
# make vcs              # Optional VCS flow
# make verilator ACCUM_MODE=0 # A0 conventional CPA reference
```

## Synthesis

The GPDK045 Genus flow targets a 1.000 ns clock with **0.100 ns setup
uncertainty** at the slow library corner. Hold uncertainty remains 0.050 ns.
The K-stream/row-prefetch RTL is functionally validated with
Verilator; timing and power require a new synthesis run.

```sh
TPU_SYNTH_TOP=tpu_stream_dse_arch \
TPU_RUN_TAG=arch_kstream_rowprefetch_u100_a1 \
/tools/cadence/DDI231/bin/genus -batch \
    -files synthesis/scripts/syn_genus.tcl \
    -log synthesis/genus_arch_kstream_rowprefetch_u100_a1

TPU_SYNTH_TOP=tpu_stream_top TPU_ACCUM_MODE=0 \
TPU_RUN_TAG=arch_kstream_rowprefetch_u100_a0 \
/tools/cadence/DDI231/bin/genus -batch \
    -files synthesis/scripts/syn_genus.tcl \
    -log synthesis/genus_arch_kstream_rowprefetch_u100_a0
```

The recommended run writes mapped outputs and reports under
`synthesis/checkpoints/arch_kstream_rowprefetch_u100_a1`.

To synthesize both phase-3 result-drain variants sequentially in an unattended
batch, run:

```sh
nohup synthesis/scripts/run_phase3_a0_a1.sh \
    > synthesis/phase3_result_batch_console.log 2>&1 &
```

The A0/A1 reports are written to `synthesis/checkpoints/phase3_result_a0` and
`synthesis/checkpoints/phase3_result_a1`. A compact completion summary is
written to `synthesis/checkpoints/phase3_result_batch_summary.txt`.

After the split-scheduler RTL change, synthesize the A0 primary and A1 retained
comparison sequentially with:

```sh
nohup synthesis/scripts/run_scheduler_a0_a1.sh \
    > synthesis/scheduler_split_batch_console.log 2>&1 &
```

The corresponding summary is
`synthesis/checkpoints/scheduler_split_batch_summary.txt`.

For the phase-4 feeder/tile-buffer/result-control checkpoint, run:

```sh
nohup synthesis/scripts/run_phase4_a0_a1.sh \
    > synthesis/phase4_control_batch_console.log 2>&1 &
```

Reports are isolated under `synthesis/checkpoints/phase4_control_a0` and
`synthesis/checkpoints/phase4_control_a1`; the compact status file is
`synthesis/checkpoints/phase4_control_batch_summary.txt`.

To synthesize only the A0 R0/R1 tile-buffer read-pipeline follow-up without
overwriting the phase-4 baseline reports, run:

```sh
TPU_ACCUM_MODE=0 TPU_RUN_TAG=phase4_r0r1_a0 \
genus -batch -files synthesis/scripts/syn_genus.tcl \
    -log synthesis/genus_phase4_r0r1_a0
```

The resulting A0 RTL/report baseline is frozen under
`checkpoints/rtl_phase4_r0r1_a0`.  Arithmetic experiments are isolated under
`dse/`; see `dse/DSE_PLAN.md` for the INT4 multiplier, INT8 two-row Booth,
16-bit CPA, 32-bit accumulator CPA, single-PE, and 2x2 sweep sequence.

## Current architecture update

See [ARCHITECTURE_UPDATE_OVERLAP.md](ARCHITECTURE_UPDATE_OVERLAP.md) for the changes,
latency costs, validation commands and remaining physical-power work. The
synthesis/test flows select A1 explicitly; the raw RTL accumulator parameter
retains its A0 compatibility default. Scheduler/result defaults are 2/0.

## Isolated top-level timing DSE

The S1/S2 scheduler, R1/R2 result-finalizer, and F1/F3 feeder experiments use
fixed A1 wrapper tops and run sequentially. Their selector settings remain
explicit, but common RTL fixes apply to every wrapper; these are no longer
bit-identical reproductions of the historical E3 RTL. They write separate checkpoints
and one compact summary without overwriting the E3 baseline:

```sh
nohup bash synthesis/scripts/run_timing_dse.sh \
    > synthesis/timing_dse_a1_console.log 2>&1 &
```

The summary is `synthesis/checkpoints/timing_dse_a1_summary.txt`. See
`dse/TOPLEVEL_TIMING_DSE.md` for the exact structural difference and required
directed regressions for each root.

## Operator mapping and performance benchmarks

See [bench/README.md](bench/README.md) for report-based architecture priorities,
operator mapping, and executable Verilator benchmarks.
The measured baseline is [bench/results_overlap_a1.csv](bench/results_overlap_a1.csv); its GOPS
assume 1 GHz and do not imply timing closure.
