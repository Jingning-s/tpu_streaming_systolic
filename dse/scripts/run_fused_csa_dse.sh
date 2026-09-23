#!/usr/bin/env bash

# Sequentially synthesize the lean fused accumulator, then the selected
# arithmetic combination in a single PE and four-PE replication.

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dse_dir=$(cd -- "${script_dir}/.." && pwd)
project_dir=$(cd -- "${dse_dir}/.." && pwd)
genus_tcl="${script_dir}/syn_arith_dse.tcl"
genus_bin=${GENUS_BIN:-genus}
summary="${dse_dir}/results/fused_csa_summary.txt"

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

    printf 'START %-32s %s\n' "${tag}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
    (
        cd "${project_dir}" || exit 125
        DSE_TOP="${top}" DSE_RUN_TAG="${tag}" \
        DSE_PARAM_NAMES="${names}" DSE_PARAM_VALUES="${values}" \
            "${genus_bin}" -batch -files "${genus_tcl}" -log "${log}"
    )
    status=$?

    # Genus can print "Encountered problems processing file" and still exit
    # with shell status zero.  Require both the explicit Tcl completion marker
    # and a non-empty QoR report so a parser/elaboration failure cannot be
    # recorded as a successful experiment.
    if [[ ${status} -eq 0 ]]; then
        if [[ ! -s "${log_file}" ]] ||
           ! grep -q '^DSE completed:' "${log_file}" ||
           [[ ! -s "${report}" ]]; then
            status=1
        fi
    fi
    printf 'END   %-32s status=%d\n' "${tag}" "${status}" | tee -a "${summary}"
    if [[ ${status} -eq 0 && -s "${report}" ]]; then
        awk '$1 == "clk" {print "  timing: " $0}' "${report}" | tee -a "${summary}"
        awk '/Total Cell Area \(Cell\+Physical\)/ {print "  " $0}' \
            "${report}" | tee -a "${summary}"
    fi
    return "${status}"
}

overall=0
run_one dse_acc32_fused_top acc32_fused_csa "" "" || overall=1
run_one dse_pe_single_top pe_single_selected_fused \
    "INT4_IMPL INT8_IMPL CPA16_IMPL ACC32_IMPL" "2 1 1 4" || overall=1
run_one dse_pe_array2x2_top pe_array2x2_selected_fused \
    "INT4_IMPL INT8_IMPL CPA16_IMPL ACC32_IMPL" "2 1 1 4" || overall=1

printf 'COMPLETE status=%d %s\n' "${overall}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
exit "${overall}"
