SIM ?= icarus
TOPLEVEL_LANG ?= verilog

# Pipeline depth under test (0..3). Override: make PIPE_STAGES=1
PIPE_STAGES ?= 3
export PIPE_STAGES

VERILOG_SOURCES += $(PWD)/../rtl/booth_pp_gen.v
VERILOG_SOURCES += $(PWD)/../rtl/csa.v
VERILOG_SOURCES += $(PWD)/../rtl/wallace_tree.v
VERILOG_SOURCES += $(PWD)/../rtl/mac_int8.v

COMPILE_ARGS += -DPIPE_STAGES=$(PIPE_STAGES)

TOPLEVEL = mac_int8
MODULE   = test_mac

SIM_BUILD = sim_build_p$(PIPE_STAGES)
COCOTB_RESULTS_FILE = results_p$(PIPE_STAGES).xml

include $(shell cocotb-config --makefiles)/Makefile.sim

# Run the whole regression against every pipeline depth
.PHONY: all-depths
all-depths:
	@for d in 0 1 2 3; do \
	  echo "=== PIPE_STAGES=$$d ==="; \
	  $(MAKE) --no-print-directory PIPE_STAGES=$$d || exit 1; \
	done
