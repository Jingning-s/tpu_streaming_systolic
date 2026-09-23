#!/usr/bin/env bash

# A0-primary/A1-comparison batch for the split scheduler checkpoint.
set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TPU_BATCH_PREFIX=scheduler_split exec "${script_dir}/run_phase3_a0_a1.sh"
