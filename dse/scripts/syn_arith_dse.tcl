# Genus flow for isolated arithmetic DSE runs.  Required environment:
#   DSE_TOP, DSE_RUN_TAG
# Optional whitespace-separated parameter names/values:
#   DSE_PARAM_NAMES="IMPL" DSE_PARAM_VALUES="0"

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set DSE_DIR    [file dirname $SCRIPT_DIR]
set PROJ_DIR   [file dirname $DSE_DIR]

if {![info exists ::env(DSE_TOP)] || [string trim $::env(DSE_TOP)] eq ""} {
    error "DSE_TOP is required"
}
if {![info exists ::env(DSE_RUN_TAG)] || [string trim $::env(DSE_RUN_TAG)] eq ""} {
    error "DSE_RUN_TAG is required"
}
set TOP [string trim $::env(DSE_TOP)]
set RUN_TAG [string trim $::env(DSE_RUN_TAG)]

set PARAM_NAMES {}
set PARAM_VALUES {}
if {[info exists ::env(DSE_PARAM_NAMES)]} {
    set PARAM_NAMES [split [string trim $::env(DSE_PARAM_NAMES)]]
}
if {[info exists ::env(DSE_PARAM_VALUES)]} {
    set PARAM_VALUES [split [string trim $::env(DSE_PARAM_VALUES)]]
}
if {[llength $PARAM_NAMES] != [llength $PARAM_VALUES]} {
    error "DSE_PARAM_NAMES and DSE_PARAM_VALUES lengths differ"
}

set PARAM_OVERRIDES {}
set ELAB_TOP $TOP
foreach param_name $PARAM_NAMES param_value $PARAM_VALUES {
    lappend PARAM_OVERRIDES [list $param_name $param_value]
    append ELAB_TOP _${param_name}${param_value}
}

set RTL_DIR [file join $DSE_DIR rtl]
set SDC_FILE [file join $DSE_DIR constr arith_dse.sdc]
set RUN_DIR [file join $DSE_DIR results $RUN_TAG]
set OUT_DIR [file join $RUN_DIR outputs]
set RPT_DIR [file join $RUN_DIR reports]
set WORK_DIR [file join $RUN_DIR work]

if {![info exists ::env(GPDK_ROOT)] || $::env(GPDK_ROOT) eq ""} {
    error "Set GPDK_ROOT to the gsclib045 installation directory."
}
set GPDK_ROOT $::env(GPDK_ROOT)
set LIB_SLOW [file join $GPDK_ROOT timing slow_vdd1v0_basicCells.lib]
set RTL_FILES [list \
    [file join $RTL_DIR arith_primitives.sv] \
    [file join $RTL_DIR arith_dse_tops.sv] \
    [file join $RTL_DIR arith_state_dse.sv] \
    [file join $RTL_DIR b_mesh_dse.sv]]

foreach required_file [concat [list $LIB_SLOW $SDC_FILE] $RTL_FILES] {
    if {![file exists $required_file]} {
        error "Required input does not exist: $required_file"
    }
}
file mkdir $OUT_DIR
file mkdir $RPT_DIR
file mkdir $WORK_DIR

set_db max_cpus_per_server 4
set_db information_level 7
set_db init_lib_search_path [list [file dirname $LIB_SLOW]]
set_db library [list $LIB_SLOW]
set_db syn_generic_effort high
set_db syn_map_effort high
set_db syn_opt_effort high

read_hdl -sv $RTL_FILES
if {[llength $PARAM_OVERRIDES] == 0} {
    elaborate $TOP
} else {
    elaborate $TOP -parameters $PARAM_OVERRIDES
}
current_design $ELAB_TOP
read_sdc $SDC_FILE

set_max_fanout 12 [current_design]
set_max_transition 0.100 [current_design]
set_max_capacitance 0.100 [current_design]
check_design -unresolved > [file join $RPT_DIR check_design.rpt]

syn_generic
syn_map
syn_opt

write_hdl -mapped > [file join $OUT_DIR ${TOP}_syn.v]
write_sdc > [file join $OUT_DIR ${TOP}_syn.sdc]
write_sdf > [file join $OUT_DIR ${TOP}_syn.sdf]
report_qor > [file join $RPT_DIR report_qor.rpt]
report_area > [file join $RPT_DIR report_area.rpt]
report_gates > [file join $RPT_DIR report_gates.rpt]
report_power > [file join $RPT_DIR report_power.rpt]
report_timing -max_paths 30 -nworst 1 -path_type full -split_delay -nets \
    -fields {timing_point arc edge cell fanout load transition delay arrival} \
    > [file join $RPT_DIR report_timing_setup.rpt]
report_constraint -all_violators > [file join $RPT_DIR report_constraints.rpt]

puts "DSE completed: $ELAB_TOP"
puts "DSE result: $RUN_DIR"
exit
