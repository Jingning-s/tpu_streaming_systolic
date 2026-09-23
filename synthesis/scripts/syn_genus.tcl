# Genus flow for the SRAM-free streaming TPU.
# Run from any directory:
#   genus -batch -files synthesis/scripts/syn_genus.tcl
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set SYN_DIR    [file dirname $SCRIPT_DIR]
set PROJ_DIR   [file dirname $SYN_DIR]

set TOP        tpu_stream_top
if {[info exists ::env(TPU_SYNTH_TOP)] &&
    ([string trim $::env(TPU_SYNTH_TOP)] ne "")} {
    set TOP [string trim $::env(TPU_SYNTH_TOP)]
}
set RTL_DIR    [file join $PROJ_DIR src]
set SDC_FILE   [file join $PROJ_DIR constr tpu_stream_top.sdc]
# Select the PE accumulator at elaboration. A1 is now the E3 two-row/fused-CSA
# production candidate; A0 remains available only as the CPA reference.
set ACCUM_MODE 1
if {[info exists ::env(TPU_ACCUM_MODE)]} {
    set ACCUM_MODE $::env(TPU_ACCUM_MODE)
}
if {($ACCUM_MODE != 0) && ($ACCUM_MODE != 1)} {
    error "TPU_ACCUM_MODE must be 0 (A0 CPA) or 1 (A1 CSA)"
}
# Keep every architectural phase isolated. TPU_RUN_TAG can name a new
# checkpoint without changing the elaborated A0/A1 top-level design.
set RUN_TAG arch_kstream_rowprefetch_u100_a${ACCUM_MODE}
if {[info exists ::env(TPU_RUN_TAG)] &&
    ([string trim $::env(TPU_RUN_TAG)] ne "")} {
    set RUN_TAG [string trim $::env(TPU_RUN_TAG)]
}
# Genus materializes a separately named top-level design when a top parameter
# is overridden. With the default parameter naming style the concrete design
# is tpu_stream_top_USE_CSA_ACCUM0/1, not the RTL architecture name above.
set IS_DSE_TOP [string match "tpu_stream_dse_*" $TOP]
if {$IS_DSE_TOP} {
    # DSE wrappers hard-code all architecture settings, including A1.
    set ELAB_TOP $TOP
} else {
    set ELAB_TOP ${TOP}_USE_CSA_ACCUM${ACCUM_MODE}
}
set RUN_DIR    [file join $SYN_DIR checkpoints $RUN_TAG]
set OUT_DIR    [file join $RUN_DIR outputs]
set RPT_DIR    [file join $RUN_DIR reports]
set WORK_DIR   [file join $RUN_DIR work]

if {![info exists ::env(GPDK_ROOT)] || $::env(GPDK_ROOT) eq ""} {
    error "Set GPDK_ROOT to the gsclib045 installation directory."
}
set GPDK_ROOT $::env(GPDK_ROOT)
set LIB_SLOW  [file join $GPDK_ROOT timing slow_vdd1v0_basicCells.lib]

set RTL_FILES [list \
    [file join $RTL_DIR pe.sv] \
    [file join $RTL_DIR systolic_array.sv] \
    [file join $RTL_DIR tpu_stream_top.sv] \
    [file join $RTL_DIR tpu_stream_dse_tops.sv]]

foreach required_file [concat [list $LIB_SLOW $SDC_FILE] $RTL_FILES] {
    if {![file exists $required_file]} {
        error "Required input does not exist: $required_file"
    }
}

file mkdir $OUT_DIR
file mkdir $RPT_DIR
file mkdir $WORK_DIR

set_db max_cpus_per_server 8
set_db information_level 7
set_db init_lib_search_path [list [file dirname $LIB_SLOW]]
set_db library [list $LIB_SLOW]

# Optimize aggressively for the 1.000 ns target. Retiming is intentionally not
# enabled here because the streaming protocol and controller cycle boundaries
# must remain unchanged unless they are verified separately.
set_db syn_generic_effort high
set_db syn_map_effort high
set_db syn_opt_effort high

read_hdl -sv $RTL_FILES
if {$IS_DSE_TOP} {
    elaborate $TOP
} else {
    elaborate $TOP -parameters [list [list USE_CSA_ACCUM $ACCUM_MODE]]
}
current_design $ELAB_TOP
read_sdc $SDC_FILE

set_max_fanout 12 [current_design]
set_max_transition 0.100 [current_design]
set_max_capacitance 0.100 [current_design]

check_design -unresolved > [file join $RPT_DIR check_design.rpt]
report_clocks > [file join $RPT_DIR report_clocks.rpt]

syn_generic
syn_map
syn_opt

write_hdl -mapped > [file join $OUT_DIR ${TOP}_syn.v]
write_sdc > [file join $OUT_DIR ${TOP}_syn.sdc]
write_sdf > [file join $OUT_DIR ${TOP}_syn.sdf]

report_qor > [file join $RPT_DIR report_qor.rpt]
report_area > [file join $RPT_DIR report_area.rpt]
report_gates > [file join $RPT_DIR report_gates.rpt]
# In this single slow-corner synthesis view, report_timing reports setup paths.
# Split driver/load rows expose cell versus net delay; the selected fields also
# preserve fanout, capacitance (load), transition, and arrival for path audit.
# Hold closure belongs in Innovus with a separate fast-corner analysis view.
report_timing -max_paths 50 -nworst 1 -path_type full -split_delay -nets \
    -fields {timing_point arc edge cell fanout load transition delay arrival} \
    > [file join $RPT_DIR report_timing_setup.rpt]
report_power > [file join $RPT_DIR report_power.rpt]
report_constraint -all_violators > [file join $RPT_DIR report_constraints.rpt]

puts "============================================================"
puts "Genus completed: $ELAB_TOP"
puts "Netlist: [file join $OUT_DIR ${TOP}_syn.v]"
puts "SDC:     [file join $OUT_DIR ${TOP}_syn.sdc]"
puts "Target:  1.000 ns (1 GHz)"
puts "Setup uncertainty: 0.100 ns"
if {$IS_DSE_TOP} {
    puts "DSE root: $TOP (fixed A1 E3 fused CSA)"
} else {
    puts "PE accum: A${ACCUM_MODE} ([expr {$ACCUM_MODE ? "E3 fused CSA" : "CPA reference"}])"
}
puts "============================================================"
exit
