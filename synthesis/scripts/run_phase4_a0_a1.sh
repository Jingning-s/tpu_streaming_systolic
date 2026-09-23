#!/usr/bin/env bash

# A0-primary/A1-comparison batch for the phase-4 feeder, tile-buffer, result,
# and reset/control-cone refactor. The common runner executes variants
# sequentially and records fresh-report timestamps and exit status.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TPU_BATCH_PREFIX=phase4_control exec "${script_dir}/run_phase3_a0_a1.sh"
