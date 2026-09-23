#!/usr/bin/env bash

# Sequential Genus sweep for isolated S1/S2/R1/R2/F1/F3 timing experiments.
# All roots use the frozen A1 CSA PE; each differs from the base only in the
# named scheduler, result, or feeder structure. Runs are deliberately serial
# because a single full Genus job already consumes several GiB of memory.

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "${script_dir}/../.." && pwd)
synthesis_dir="${project_dir}/synthesis"
genus_tcl="${script_dir}/syn_genus.tcl"
genus_bin=${GENUS_BIN:-genus}
run_prefix=${TPU_BATCH_PREFIX:-timing_dse_a1}
summary_file="${synthesis_dir}/checkpoints/${run_prefix}_summary.txt"

if ! command -v "${genus_bin}" >/dev/null 2>&1; then
    echo "ERROR: Genus executable not found: ${genus_bin}" >&2
    echo "Set GENUS_BIN to the correct executable and rerun." >&2
    exit 127
fi

mkdir -p "${synthesis_dir}/checkpoints"
: > "${summary_file}"

record() {
    printf '%s\n' "$*" | tee -a "${summary_file}"
}

run_variant() {
    local name=$1
    local top=$2
    local tag="${run_prefix}_${name}"
    local checkpoint_dir="${synthesis_dir}/checkpoints/${tag}"
    local report_dir="${checkpoint_dir}/reports"
    local log_base="${synthesis_dir}/genus_${tag}"
    local start_marker="${checkpoint_dir}/.batch_start"
    local start_epoch end_epoch status

    start_epoch=$(date +%s)
    mkdir -p "${checkpoint_dir}"
    : > "${start_marker}"
    record "============================================================"
    record "START ${name}: $(date --iso-8601=seconds)"
    record "Top: ${top}"
    record "Checkpoint: ${checkpoint_dir}"

    (
        cd "${project_dir}" || exit 125
        TPU_SYNTH_TOP="${top}" TPU_RUN_TAG="${tag}" \
            "${genus_bin}" -batch -files "${genus_tcl}" -log "${log_base}"
    )
    status=$?
    end_epoch=$(date +%s)

    record "END ${name}: $(date --iso-8601=seconds)"
    record "Exit status: ${status}; elapsed: $((end_epoch - start_epoch)) s"
    if [[ -s "${report_dir}/report_qor.rpt" &&
          "${report_dir}/report_qor.rpt" -nt "${start_marker}" ]]; then
        awk '$1 == "clk" {print "QoR: " $0}' "${report_dir}/report_qor.rpt" | tee -a "${summary_file}"
        awk '/Total Cell Area \(Cell\+Physical\)/ {print "Area: " $0}' "${report_dir}/report_qor.rpt" | tee -a "${summary_file}"
    else
        record "Fresh QoR report missing."
    fi
    if [[ -s "${report_dir}/report_timing_setup.rpt" &&
          "${report_dir}/report_timing_setup.rpt" -nt "${start_marker}" ]]; then
        awk '/^Path 1:/ {print "Worst path: " $0; exit}' "${report_dir}/report_timing_setup.rpt" | tee -a "${summary_file}"
    else
        record "Fresh setup timing report missing."
    fi
    record ""
    return "${status}"
}

overall_status=0
while read -r name top; do
    if ! run_variant "${name}" "${top}"; then
        overall_status=1
    fi
done <<'VARIANTS'
base tpu_stream_dse_base
s1 tpu_stream_dse_s1
s2 tpu_stream_dse_s2
r1 tpu_stream_dse_r1
r2 tpu_stream_dse_r2
f1 tpu_stream_dse_f1
f3 tpu_stream_dse_f3
VARIANTS

record "============================================================"
record "BATCH COMPLETE: $(date --iso-8601=seconds)"
record "Overall status: ${overall_status}"
record "Summary: ${summary_file}"
exit "${overall_status}"
