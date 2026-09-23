#!/usr/bin/env bash

# Run the phase-3 result-drain synthesis for both accumulator variants.
# The runs are intentionally sequential to avoid two high-memory Genus jobs
# competing on the same host. A failure in one run does not prevent the other
# variant from being attempted.

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "${script_dir}/../.." && pwd)
synthesis_dir="${project_dir}/synthesis"
genus_tcl="${script_dir}/syn_genus.tcl"
genus_bin=${GENUS_BIN:-genus}
run_prefix=${TPU_BATCH_PREFIX:-phase3_result}
summary_file="${synthesis_dir}/checkpoints/${run_prefix}_batch_summary.txt"

if ! command -v "${genus_bin}" >/dev/null 2>&1; then
    echo "ERROR: Genus executable not found: ${genus_bin}" >&2
    echo "Set GENUS_BIN to the executable path and retry." >&2
    exit 127
fi

mkdir -p "${synthesis_dir}/checkpoints"
: > "${summary_file}"

record() {
    printf '%s\n' "$*" | tee -a "${summary_file}"
}

run_variant() {
    local mode=$1
    local tag="${run_prefix}_a${mode}"
    local checkpoint_dir="${synthesis_dir}/checkpoints/${tag}"
    local report_dir="${checkpoint_dir}/reports"
    local log_base="${synthesis_dir}/genus_${tag}"
    local start_marker="${checkpoint_dir}/.batch_start"
    local start_epoch
    local end_epoch
    local status

    start_epoch=$(date +%s)
    mkdir -p "${checkpoint_dir}"
    : > "${start_marker}"
    record "============================================================"
    record "START A${mode}: $(date --iso-8601=seconds)"
    record "Checkpoint: ${checkpoint_dir}"
    record "Log base:   ${log_base}"

    (
        cd "${project_dir}" || exit 125
        TPU_ACCUM_MODE="${mode}" TPU_RUN_TAG="${tag}" \
            "${genus_bin}" -batch -files "${genus_tcl}" -log "${log_base}"
    )
    status=$?

    end_epoch=$(date +%s)
    record "END A${mode}: $(date --iso-8601=seconds)"
    record "Exit status: ${status}"
    record "Elapsed seconds: $((end_epoch - start_epoch))"

    if [[ -s "${report_dir}/report_qor.rpt" &&
          "${report_dir}/report_qor.rpt" -nt "${start_marker}" ]]; then
        record "QoR clock row:"
        awk '$1 == "clk" {print "  " $0}' \
            "${report_dir}/report_qor.rpt" | tee -a "${summary_file}"
        awk '/Total Cell Area \(Cell\+Physical\)/ {print "  " $0}' \
            "${report_dir}/report_qor.rpt" | tee -a "${summary_file}"
    else
        record "Fresh QoR report missing: ${report_dir}/report_qor.rpt"
    fi

    if [[ -s "${report_dir}/report_timing_setup.rpt" &&
          "${report_dir}/report_timing_setup.rpt" -nt "${start_marker}" ]]; then
        awk '/^Path 1:/ {print "Worst path: " $0; exit}' \
            "${report_dir}/report_timing_setup.rpt" | tee -a "${summary_file}"
    else
        record "Fresh setup timing report missing."
    fi

    record ""
    return "${status}"
}

overall_status=0

if ! run_variant 0; then
    overall_status=1
fi

if ! run_variant 1; then
    overall_status=1
fi

record "============================================================"
record "BATCH COMPLETE: $(date --iso-8601=seconds)"
record "Overall status: ${overall_status}"
record "A0 reports: ${synthesis_dir}/checkpoints/${run_prefix}_a0/reports"
record "A1 reports: ${synthesis_dir}/checkpoints/${run_prefix}_a1/reports"

exit "${overall_status}"
