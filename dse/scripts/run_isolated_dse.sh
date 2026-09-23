#!/usr/bin/env bash

# Run each isolated arithmetic experiment sequentially.  This script never
# modifies production RTL.  GENUS_BIN may override the executable name.

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dse_dir=$(cd -- "${script_dir}/.." && pwd)
project_dir=$(cd -- "${dse_dir}/.." && pwd)
genus_tcl="${script_dir}/syn_arith_dse.tcl"
genus_bin=${GENUS_BIN:-genus}
summary="${dse_dir}/results/isolated_summary.txt"

if ! command -v "${genus_bin}" >/dev/null 2>&1; then
    echo "ERROR: Genus executable not found: ${genus_bin}" >&2
    exit 127
fi

mkdir -p "${dse_dir}/results"
: > "${summary}"

run_one() {
    local top=$1
    local tag=$2
    local names=$3
    local values=$4
    local log="${dse_dir}/results/genus_${tag}"
    local log_file="${log}.log"
    local report="${dse_dir}/results/${tag}/reports/report_qor.rpt"
    local status

    printf 'START %-24s %s\n' "${tag}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
    (
        cd "${project_dir}" || exit 125
        DSE_TOP="${top}" DSE_RUN_TAG="${tag}" \
        DSE_PARAM_NAMES="${names}" DSE_PARAM_VALUES="${values}" \
            "${genus_bin}" -batch -files "${genus_tcl}" -log "${log}"
    )
    status=$?
    if [[ ${status} -eq 0 ]]; then
        if [[ ! -s "${log_file}" ]] ||
           ! grep -q '^DSE completed:' "${log_file}" ||
           [[ ! -s "${report}" ]]; then
            status=1
        fi
    fi
    printf 'END   %-24s status=%d\n' "${tag}" "${status}" | tee -a "${summary}"
    if [[ ${status} -eq 0 && -s "${report}" ]]; then
        awk '$1 == "clk" {print "  timing: " $0}' "${report}" | tee -a "${summary}"
        awk '/Total Cell Area \(Cell\+Physical\)/ {print "  " $0}' "${report}" | tee -a "${summary}"
    fi
    return "${status}"
}

overall=0

run_one dse_int4_mul_top int4_inferred "IMPL" "0" || overall=1
run_one dse_int4_mul_top int4_baugh_wooley "IMPL" "1" || overall=1
run_one dse_int4_mul_top int4_booth "IMPL" "2" || overall=1

run_one dse_int8_mul_top int8_inferred "IMPL CPA_IMPL" "0 0" || overall=1
run_one dse_int8_mul_top int8_booth_two_row "IMPL CPA_IMPL" "1 0" || overall=1

run_one dse_cpa16_top cpa16_inferred "IMPL" "0" || overall=1
run_one dse_cpa16_top cpa16_csel4 "IMPL" "1" || overall=1
run_one dse_cpa16_top cpa16_brent_kung "IMPL" "2" || overall=1
run_one dse_cpa16_top cpa16_han_carlson "IMPL" "3" || overall=1

run_one dse_acc32_top acc32_inferred "IMPL" "0" || overall=1
run_one dse_acc32_top acc32_csel8 "IMPL" "1" || overall=1
run_one dse_acc32_top acc32_brent_kung "IMPL" "2" || overall=1
run_one dse_acc32_top acc32_han_carlson "IMPL" "3" || overall=1

printf 'COMPLETE status=%d %s\n' "${overall}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
exit "${overall}"
