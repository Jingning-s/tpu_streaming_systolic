#!/usr/bin/env bash

# Usage: run_pe_candidate.sh INT4_IMPL INT8_IMPL CPA16_IMPL ACC32_IMPL [single|array2x2]

set -u
set -o pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "Usage: $0 INT4_IMPL INT8_IMPL CPA16_IMPL ACC32_IMPL [single|array2x2]" >&2
    exit 2
fi

i4=$1
i8=$2
c16=$3
a32=$4
shape=${5:-single}

case "${shape}" in
    single) top=dse_pe_single_top ;;
    array2x2) top=dse_pe_array2x2_top ;;
    *) echo "shape must be single or array2x2" >&2; exit 2 ;;
esac

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dse_dir=$(cd -- "${script_dir}/.." && pwd)
project_dir=$(cd -- "${dse_dir}/.." && pwd)
tag="pe_${shape}_i4${i4}_i8${i8}_c16${c16}_a32${a32}"
genus_bin=${GENUS_BIN:-genus}

cd "${project_dir}" || exit 125
DSE_TOP="${top}" DSE_RUN_TAG="${tag}" \
DSE_PARAM_NAMES="INT4_IMPL INT8_IMPL CPA16_IMPL ACC32_IMPL" \
DSE_PARAM_VALUES="${i4} ${i8} ${c16} ${a32}" \
    "${genus_bin}" -batch -files "${script_dir}/syn_arith_dse.tcl" \
    -log "${dse_dir}/results/genus_${tag}"
