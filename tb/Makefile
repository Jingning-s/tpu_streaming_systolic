VCS       ?= vcs
VCS_FLAGS ?= -sverilog -full64 -debug_access+all -timescale=1ns/1ps
VERILATOR ?= verilator
VERILATOR_JOBS ?= 4
VERILATOR_DIR ?= obj_dir_a$(ACCUM_MODE)_s$(SCHED_MODE)_r$(RESULT_MODE)_f$(FEEDER_MODE)
ACCUM_MODE ?= 1
SCHED_MODE ?= 2
RESULT_MODE ?= 0
FEEDER_MODE ?= 0
SRC        = ../src/pe.sv ../src/systolic_array.sv \
	     ../src/tpu_stream_top.sv
TB         = tb_tpu_stream_top.sv
SIM        = ./simv

.PHONY: all vcs compile run clean verilator verilator-build
all: verilator

vcs: compile run

compile:
	$(VCS) $(VCS_FLAGS) $(SRC) $(TB) -top tb_tpu_stream_top \
		-pvalue+tb_tpu_stream_top.USE_CSA_ACCUM=$(ACCUM_MODE) \
		-pvalue+tb_tpu_stream_top.SCHED_IMPL=$(SCHED_MODE) \
		-pvalue+tb_tpu_stream_top.RESULT_IMPL=$(RESULT_MODE) \
		-pvalue+tb_tpu_stream_top.FEEDER_IMPL=$(FEEDER_MODE) -o $(SIM)

run:
	$(SIM)

verilator: verilator-build
	$(VERILATOR_DIR)/Vtb_tpu_stream_top

verilator-build:
	$(VERILATOR) --binary --timing --assert -Wno-fatal -j $(VERILATOR_JOBS) \
		--Mdir $(VERILATOR_DIR) --top-module tb_tpu_stream_top \
		-GUSE_CSA_ACCUM=$(ACCUM_MODE) -GSCHED_IMPL=$(SCHED_MODE) \
		-GRESULT_IMPL=$(RESULT_MODE) -GFEEDER_IMPL=$(FEEDER_MODE) $(SRC) $(TB)

wave:
	$(SIM) +vcs+vcdpluson

dve: wave
	dve -vpd $(VPD) &

clean:
	rm -rf csrc simv simv.daidir ucli.key vc_hdrs.h *.log *.vpd *.fsdb
