#!/usr/bin/env bash

# Sequential external-finalizer DSE.  Unique log names avoid Cadence's .log1
# rotation and make completion checking unambiguous.

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dse_dir=$(cd -- "${script_dir}/.." && pwd)
project_dir=$(cd -- "${dse_dir}/.." && pwd)
genus_tcl="${script_dir}/syn_arith_dse.tcl"
genus_bin=${GENUS_BIN:-genus}
if [[ ${DSE_MUXLIGHT_ONLY:-0} == 1 ]]; then
    summary="${dse_dir}/results/muxlight_summary.txt"
else
    summary="${dse_dir}/results/external_csa_summary.txt"
fi
run_suffix="$(date +%Y%m%d_%H%M%S)_$$"

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
    local log="${dse_dir}/results/genus_${tag}_${run_suffix}"
    local log_file="${log}.log"
    local report="${dse_dir}/results/${tag}/reports/report_qor.rpt"
    local status

    printf 'START %-32s %s\n' "${tag}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
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
    printf 'END   %-32s status=%d log=%s\n' \
        "${tag}" "${status}" "${log_file}" | tee -a "${summary}"
    if [[ ${status} -eq 0 ]]; then
        awk '$1 == "clk" {print "  timing: " $0}' "${report}" | tee -a "${summary}"
        awk '/Total Cell Area \(Cell\+Physical\)/ {print "  " $0}' \
            "${report}" | tee -a "${summary}"
    fi
    return "${status}"
}

overall=0
if [[ ${DSE_MUXLIGHT_ONLY:-0} != 1 ]]; then
    run_one dse_acc32_csa_state_top acc32_csa_state "" "" || overall=1
    run_one dse_result_row_finalizer_top result_row_finalizer16 \
        "LANES CPA_IMPL" "16 1" || overall=1
    run_one dse_pe_state_single_top pe_state_single "" "" || overall=1
    run_one dse_pe_state_array2x2_top pe_state_array2x2 "" "" || overall=1
fi
run_one dse_pe_token_single_top pe_token_single "" "" || overall=1
run_one dse_pe_token_array2x2_top pe_token_array2x2 "" "" || overall=1

printf 'COMPLETE status=%d %s\n' "${overall}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
exit "${overall}"
