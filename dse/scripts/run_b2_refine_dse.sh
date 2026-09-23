#!/usr/bin/env bash

# B2 refinement factorial screen:
# C0=baseline, C1=AND-mask PP, C2=direct 4:2, C3=both changes.
# All four run in Replica; only the best two run in the real Mesh.

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dse_dir=$(cd -- "${script_dir}/.." && pwd)
project_dir=$(cd -- "${dse_dir}/.." && pwd)
genus_tcl="${script_dir}/syn_arith_dse.tcl"
genus_bin=${GENUS_BIN:-genus}
summary="${dse_dir}/results/b2_refine_summary.txt"
rank_file=$(mktemp)
run_suffix="$(date +%Y%m%d_%H%M%S)_$$"
trap 'rm -f "${rank_file}"' EXIT

declare -a impls=(2 4 5 6)
declare -A labels=([2]=c0 [4]=c1 [5]=c2 [6]=c3)

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
    local constraints="${report_dir}/report_constraints.rpt"
    local timing_report="${report_dir}/report_timing_setup.rpt"
    local status tns_viol wns area muxes slew_viol

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
        tns_viol=$(awk '$1 == "clk" && NF >= 4 {print $3, $4; exit}' "${qor}")
        wns=$(sed -n 's/^Path 1:.*(\([-0-9.]*\) ps).*/\1/p' \
            "${timing_report}" | head -n 1)
        area=$(awk '/Total Cell Area \(Cell\+Physical\)/ {print $NF}' "${qor}")
        muxes=$(awk '$1 ~ /^MX/ {count += $2} END {print count + 0}' "${gates}")
        slew_viol=$(awk '/max_transition/{active=1;next}/max_fanout/{active=0}
            active && /default/{count++} END{print count+0}' "${constraints}")
        printf '  B2C%s impl=%d WNS=%s TNS_VIOL=%s area=%s mux=%s slew_viol=%s\n' \
            "${labels[${impl}]#c}" "${impl}" "${wns}" "${tns_viol}" "${area}" \
            "${muxes}" "${slew_viol}" | tee -a "${summary}"
        RUN_WNS=${wns}
        RUN_TNS=$(awk '$1 == "clk" && NF >= 4 {print $3; exit}' "${qor}")
        RUN_AREA=${area}
        RUN_MUX=${muxes}
    fi
    return "${status}"
}

overall=0
for impl in "${impls[@]}"; do
    tag="b2_replica_${labels[${impl}]}"
    if run_one dse_b_replica_top "${tag}" "${impl}"; then
        printf '%d %s %s %s %s\n' "${impl}" "${RUN_WNS}" "${RUN_TNS}" \
            "${RUN_AREA}" "${RUN_MUX}" >> "${rank_file}"
    else
        overall=1
    fi
done

if [[ $(wc -l < "${rank_file}") -ne 4 ]]; then
    echo "ERROR: B2 Replica screen incomplete; Mesh stage skipped." | tee -a "${summary}"
    printf 'COMPLETE status=1 %s\n' "$(date --iso-8601=seconds)" | tee -a "${summary}"
    exit 1
fi

# Timing is primary.  For equal timing results, prefer fewer muxes before area.
mapfile -t winners < <(
    sort -k2,2nr -k3,3nr -k5,5n -k4,4n "${rank_file}" |
        head -n 2 | awk '{print $1}'
)
printf 'B2_REPLICA_WINNERS C%s C%s (rank: WNS, TNS, mux, area)\n' \
    "${labels[${winners[0]}]#c}" "${labels[${winners[1]}]#c}" | tee -a "${summary}"

for impl in "${winners[@]}"; do
    run_one dse_b_mesh2x2_top "b2_mesh_${labels[${impl}]}" "${impl}" || overall=1
done

printf 'COMPLETE status=%d %s\n' "${overall}" "$(date --iso-8601=seconds)" | tee -a "${summary}"
exit "${overall}"
