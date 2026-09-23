set CLK_NAME   clk
set CLK_PERIOD 1.000

create_clock -name $CLK_NAME -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty -setup 0.100 [get_clocks $CLK_NAME]
set_clock_uncertainty -hold  0.050 [get_clocks $CLK_NAME]
set_clock_transition 0.050 [get_clocks $CLK_NAME]

set DATA_INPUTS [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  0.200 -clock [get_clocks $CLK_NAME] $DATA_INPUTS
set_output_delay 0.200 -clock [get_clocks $CLK_NAME] [all_outputs]
set_driving_cell -lib_cell INVX1 -pin Y $DATA_INPUTS
set_load 0.020 [all_outputs]
