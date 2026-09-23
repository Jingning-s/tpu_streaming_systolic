#!/usr/bin/env bash

# Stage 1 synthesizes B0/B1/B2/B3 only in the independent Replica harness.
# Stage 2 ranks by WNS, then TNS, then area, and sends only the top two into
# the legal-neighbor 2x2 Mesh harness.

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dse_dir=$(cd -- "${script_dir}/.." && pwd)
project_dir=$(cd -- "${dse_dir}/.." && pwd)
genus_tcl="${script_dir}/syn_arith_dse.tcl"
genus_bin=${GENUS_BIN:-genus}
summary="${dse_dir}/results/b_mesh_summary.txt"
rank_file=$(mktemp)
run_suffix="$(date +%Y%m%d_%H%M%S)_$$"
trap 'rm -f "${rank_file}"' EXIT

if ! command -v "${genus_bin}" >/dev/null 2>&1; then
    echo "ERROR: Genus executable not found: ${genus_bin}" >&2
    exit 127
fi

mkdir -p "${dse_dir}/results"
: > "${summary}"

run_one() {
    local top=$1
    local tag=$2
    local impl=$3
    local log="${dse_dir}/results/genus_${tag}_${run_suffix}"
    local log_file="${log}.log"
    local report_dir="${dse_dir}/results/${tag}/reports"
    local qor="${report_dir}/report_qor.rpt"
    local gates="${report_dir}/report_gates.rpt"
    local status
    local timing area muxes

    printf 'START %-28s %s\n' "${tag}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
    (
        cd "${project_dir}" || exit 125
        DSE_TOP="${top}" DSE_RUN_TAG="${tag}" \
        DSE_PARAM_NAMES="IMPL" DSE_PARAM_VALUES="${impl}" \
            "${genus_bin}" -batch -files "${genus_tcl}" -log "${log}"
    )
    status=$?
    if [[ ${status} -eq 0 ]]; then
        if [[ ! -s "${log_file}" ]] ||
           ! grep -q '^DSE completed:' "${log_file}" ||
           [[ ! -s "${qor}" ]]; then
            status=1
        fi
    fi
    printf 'END   %-28s status=%d log=%s\n' \
        "${tag}" "${status}" "${log_file}" | tee -a "${summary}"
    if [[ ${status} -eq 0 ]]; then
        timing=$(awk '$1 == "clk" && NF >= 4 {print $2, $3, $4; exit}' "${qor}")
        area=$(awk '/Total Cell Area \(Cell\+Physical\)/ {print $NF}' "${qor}")
        muxes=$(awk '$1 ~ /^MX/ {count += $2} END {print count + 0}' "${gates}")
        printf '  impl=B%d WNS_TNS_VIOL=%s area=%s mux_cells=%s\n' \
            "${impl}" "${timing}" "${area}" "${muxes}" | tee -a "${summary}"
        RUN_WNS=$(awk '$1 == "clk" && NF >= 4 {print $2; exit}' "${qor}")
        RUN_TNS=$(awk '$1 == "clk" && NF >= 4 {print $3; exit}' "${qor}")
        RUN_AREA=${area}
    fi
    return "${status}"
}

overall=0
for impl in 0 1 2 3; do
    if run_one dse_b_replica_top "b_replica_b${impl}" "${impl}"; then
        printf '%d %s %s %s\n' "${impl}" "${RUN_WNS}" "${RUN_TNS}" "${RUN_AREA}" \
            >> "${rank_file}"
    else
        overall=1
    fi
done

if [[ $(wc -l < "${rank_file}") -ne 4 ]]; then
    echo "ERROR: Replica screening incomplete; Mesh stage skipped." | tee -a "${summary}"
    printf 'COMPLETE status=1 %s\n' "$(date --iso-8601=seconds)" | tee -a "${summary}"
    exit 1
fi

mapfile -t winners < <(
    sort -k2,2nr -k3,3nr -k4,4n "${rank_file}" | head -n 2 | awk '{print $1}'
)
printf 'REPLICA_WINNERS B%s B%s (rank: WNS, TNS, area)\n' \
    "${winners[0]}" "${winners[1]}" | tee -a "${summary}"

for impl in "${winners[@]}"; do
    run_one dse_b_mesh2x2_top "b_mesh_b${impl}" "${impl}" || overall=1
done

printf 'COMPLETE status=%d %s\n' "${overall}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
exit "${overall}"
