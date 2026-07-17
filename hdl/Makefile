# k_printf_hdl - local verification (no CI; mirrors the C side's `make test`).
#
# Recipes run from the repository root (one level above this file) so the tool
# invocations match hdl/README.md exactly. Toolchain: python3 (+cffi), a C
# compiler (the golden model links src/k_printf.c), Icarus Verilog (SV core),
# GHDL --std=08 (VHDL core). Missing optional tools cause a skip, not a failure.
#
# Targets:
#   make -C hdl fmtgen     messages.h -> uop ROM / pools / dispatch / vectors
#   make -C hdl gold       build kp_gold and emit the golden expected.txt
#   make -C hdl sim-sv     Icarus differential test (SV core vs C golden)
#   make -C hdl sim-vhdl   GHDL  differential test (VHDL core vs C golden)
#   make -C hdl equiv      triple-diff C = SV = VHDL byte streams
#   make -C hdl test       all of the above in order (the one to run pre-commit)
#   make -C hdl clean

SHELL  := /bin/bash
ROOT   := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/..)
GEN    := hdl/gen
CC     ?= cc
IVERILOG ?= iverilog
VVP    ?= vvp
GHDL   ?= ghdl

MEMS := UOP_FILE=\"$(GEN)/uop_rom.mem\" LIT_FILE=\"$(GEN)/lit_pool.mem\" \
        STR_FILE=\"$(GEN)/str_pool.mem\" STRTAB_FILE=\"$(GEN)/str_table.mem\" \
        MSTART_FILE=\"$(GEN)/msg_start.mem\" MARITY_FILE=\"$(GEN)/msg_arity.mem\"
SVDEFS := $(addprefix -D,$(MEMS)) \
          -DVEC_FILE=\"$(GEN)/vectors.txt\" -DEXP_FILE=\"$(GEN)/expected.txt\" \
          -DOUT_FILE=\"$(GEN)/sv_out.txt\"

.PHONY: all test fmtgen gold sim-sv sim-vhdl equiv clean

all: test

# ---- code generation ----
fmtgen:
	cd $(ROOT) && python3 tools/k_fmtgen.py hdl/fmt/messages.h -o $(GEN)

# ---- golden model (the C library is the oracle) ----
gold: fmtgen
	cd $(ROOT) && $(CC) -std=c11 -Wall -Wextra -Iinclude -I$(GEN) \
	    src/k_printf.c hdl/gold/kp_gold.c -o $(GEN)/kp_gold
	cd $(ROOT) && ./$(GEN)/kp_gold $(GEN)/vectors.txt > $(GEN)/expected.txt

# ---- SystemVerilog core (Icarus) ----
sim-sv: gold
	cd $(ROOT) && $(IVERILOG) -g2012 -grelative-include -I$(GEN) $(SVDEFS) \
	    -o $(GEN)/kp_tb.vvp hdl/rtl/sv/kp_core.sv hdl/tb/kp_tb.sv
	cd $(ROOT) && $(VVP) $(GEN)/kp_tb.vvp | tee $(GEN)/sv_run.log
	cd $(ROOT) && grep -q "SV-DIFF: PASS" $(GEN)/sv_run.log

# ---- VHDL core (GHDL, with the macOS/Rosetta link fallback) ----
sim-vhdl: gold
	cd $(ROOT) && sh hdl/tb/run_ghdl.sh

# ---- triple equivalence: C = SV = VHDL (case-insensitive on the hex dump) ----
equiv: sim-sv sim-vhdl
	cd $(ROOT) && \
	  if diff -q <(tr 'A-F' 'a-f' < $(GEN)/sv_out.txt) \
	             <(tr 'A-F' 'a-f' < $(GEN)/vhdl_out.txt) >/dev/null; then \
	    echo "TRIPLE-DIFF: PASS (C = SV = VHDL)"; \
	  else \
	    echo "TRIPLE-DIFF: FAIL"; \
	    diff <(tr 'A-F' 'a-f' < $(GEN)/sv_out.txt) <(tr 'A-F' 'a-f' < $(GEN)/vhdl_out.txt) | head; \
	    exit 1; \
	  fi

test: equiv
	@echo "k_printf_hdl: all local checks passed (SV + VHDL vs C golden, and equivalent)."

clean:
	cd $(ROOT) && rm -rf $(GEN)/*.mem $(GEN)/*.svh $(GEN)/*_pkg.vhd $(GEN)/*.inc \
	    $(GEN)/vectors.txt $(GEN)/expected.txt $(GEN)/*.txt $(GEN)/kp_gold \
	    $(GEN)/kp_tb.vvp $(GEN)/kp_tb_ghdl $(GEN)/*.log $(GEN)/ghdl \
	    $(GEN)/messages_report.md $(GEN)/work-obj*.cf 2>/dev/null || true
