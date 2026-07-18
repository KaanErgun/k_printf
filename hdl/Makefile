# k_printf_hdl - local verification (no CI; mirrors the C side's `make test`).
#
# Recipes run from the repository root (one level above this file) so the tool
# invocations match hdl/README.md exactly. Toolchain: python3 (+cffi), a C
# compiler (the golden model links src/k_printf.c), Icarus Verilog (SV core),
# GHDL --std=08 (VHDL core). Missing optional tools cause a skip, not a failure.
#
# Targets:
#   make -C hdl fmtgen         messages.h -> uop ROM / pools / dispatch / vectors / hw hdr
#   make -C hdl gold           build kp_gold, emit expected.txt, syntax-check k_printf_hw.h
#   make -C hdl sim-sv/-vhdl   core differential test vs the C golden (Icarus / GHDL)
#   make -C hdl equiv          triple-diff C = SV = VHDL byte streams
#   make -C hdl sim-uart-sv/-vhdl   core -> UART, serial sampled at real bit times
#   make -C hdl sim-sys-sv/-vhdl    trig -> core -> tee -> captures (atomic snapshot, DROP)
#   make -C hdl sim-regs-sv/-vhdl   register window (write-to-fire SEND, arg snapshot)
#   make -C hdl config-test    G_EN_DEC=0,G_EN_STR=0 gated core vs a reduced message set
#   make -C hdl fuzz [FUZZ_SEED= FUZZ_N=]   same differential, fresh random vectors
#   make -C hdl test           every check above in order (the one to run pre-commit)
#   make -C hdl clean          remove hdl/gen and hdl/gen_min build outputs

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

.PHONY: all test fmtgen gold sim-sv sim-vhdl sim-uart-sv sim-uart-vhdl \
        sim-sys-sv sim-sys-vhdl sim-regs-sv sim-regs-vhdl config-test \
        equiv fuzz clean

all: test

# ---- code generation ----
# FMTGEN_ARGS lets the fuzz target thread a different seed/vector count through
# the whole dependency chain (fmtgen -> gold -> sims) consistently.
FMTGEN_ARGS ?=
fmtgen:
	cd $(ROOT) && python3 tools/k_fmtgen.py hdl/fmt/messages.h -o $(GEN) $(FMTGEN_ARGS)

# ---- golden model (the C library is the oracle) ----
gold: fmtgen
	cd $(ROOT) && $(CC) -std=c11 -Wall -Wextra -Iinclude -I$(GEN) \
	    src/k_printf.c hdl/gold/kp_gold.c -o $(GEN)/kp_gold
	cd $(ROOT) && ./$(GEN)/kp_gold $(GEN)/vectors.txt > $(GEN)/expected.txt
	cd $(ROOT) && $(CC) -std=c11 -Wall -Wextra -fsyntax-only $(GEN)/k_printf_hw.h

# ---- SystemVerilog core (Icarus) ----
sim-sv: gold
	cd $(ROOT) && $(IVERILOG) -g2012 -grelative-include -I$(GEN) $(SVDEFS) \
	    -o $(GEN)/kp_tb.vvp hdl/rtl/sv/kp_core.sv hdl/tb/kp_tb.sv
	cd $(ROOT) && $(VVP) $(GEN)/kp_tb.vvp | tee $(GEN)/sv_run.log
	cd $(ROOT) && grep -q "SV-DIFF: PASS" $(GEN)/sv_run.log

# ---- VHDL core (GHDL, with the macOS/Rosetta link fallback) ----
sim-vhdl: gold
	cd $(ROOT) && sh hdl/tb/run_ghdl.sh kp_tb "VHDL-DIFF: PASS"

# ---- system-level: core -> UART, serial line sampled at real bit times ----
sim-uart-sv: gold
	cd $(ROOT) && $(IVERILOG) -g2012 -grelative-include -I$(GEN) $(SVDEFS) \
	    -o $(GEN)/kp_uart_tb.vvp \
	    hdl/rtl/sv/kp_core.sv hdl/rtl/sv/kp_uart_tx.sv hdl/tb/kp_uart_tb.sv
	cd $(ROOT) && $(VVP) $(GEN)/kp_uart_tb.vvp | tee $(GEN)/uart_sv_run.log
	cd $(ROOT) && grep -q "UART-DIFF: PASS" $(GEN)/uart_sv_run.log

sim-uart-vhdl: gold
	cd $(ROOT) && sh hdl/tb/run_ghdl.sh kp_uart_tb "UART-DIFF: PASS"

# ---- system: trig (atomic snapshot + arbiter + DROP) -> core -> tee -> captures
sim-sys-sv: gold
	cd $(ROOT) && $(IVERILOG) -g2012 -grelative-include -I$(GEN) $(SVDEFS) \
	    -o $(GEN)/kp_sys_tb.vvp \
	    hdl/rtl/sv/kp_core.sv hdl/rtl/sv/kp_trig.sv hdl/rtl/sv/kp_tee.sv \
	    hdl/rtl/sv/kp_capture.sv hdl/tb/kp_sys_tb.sv
	cd $(ROOT) && $(VVP) $(GEN)/kp_sys_tb.vvp | tee $(GEN)/sys_sv_run.log
	cd $(ROOT) && grep -q "SYS-DIFF: PASS" $(GEN)/sys_sv_run.log

sim-sys-vhdl: gold
	cd $(ROOT) && sh hdl/tb/run_ghdl.sh kp_sys_tb "SYS-DIFF: PASS"

# ---- register-window front-end (write-to-fire SEND) ----
sim-regs-sv: gold
	cd $(ROOT) && $(IVERILOG) -g2012 -grelative-include -I$(GEN) $(SVDEFS) \
	    -o $(GEN)/kp_regs_tb.vvp \
	    hdl/rtl/sv/kp_core.sv hdl/rtl/sv/kp_regs.sv hdl/rtl/sv/kp_capture.sv \
	    hdl/tb/kp_regs_tb.sv
	cd $(ROOT) && $(VVP) $(GEN)/kp_regs_tb.vvp | tee $(GEN)/regs_sv_run.log
	cd $(ROOT) && grep -q "REGS-DIFF: PASS" $(GEN)/regs_sv_run.log

sim-regs-vhdl: gold
	cd $(ROOT) && sh hdl/tb/run_ghdl.sh kp_regs_tb "REGS-DIFF: PASS"

# ---- G_EN_* opt-out config: reduced message set, gated core (SV matrix run) --
GENMIN := hdl/gen_min
config-test:
	cd $(ROOT) && python3 tools/k_fmtgen.py hdl/fmt/messages_min.h -o $(GENMIN) \
	    --disable dec,oct,bin,str,ptr
	cd $(ROOT) && $(CC) -std=c11 -Wall -Wextra -Iinclude -I$(GENMIN) \
	    src/k_printf.c hdl/gold/kp_gold.c -o $(GENMIN)/kp_gold
	cd $(ROOT) && ./$(GENMIN)/kp_gold $(GENMIN)/vectors.txt > $(GENMIN)/expected.txt
	cd $(ROOT) && $(IVERILOG) -g2012 -grelative-include -I$(GENMIN) \
	    -DKP_EN_DEC=0 -DKP_EN_STR=0 \
	    -DUOP_FILE=\"$(GENMIN)/uop_rom.mem\" -DLIT_FILE=\"$(GENMIN)/lit_pool.mem\" \
	    -DSTR_FILE=\"$(GENMIN)/str_pool.mem\" -DSTRTAB_FILE=\"$(GENMIN)/str_table.mem\" \
	    -DMSTART_FILE=\"$(GENMIN)/msg_start.mem\" -DMARITY_FILE=\"$(GENMIN)/msg_arity.mem\" \
	    -DVEC_FILE=\"$(GENMIN)/vectors.txt\" -DEXP_FILE=\"$(GENMIN)/expected.txt\" \
	    -DOUT_FILE=\"$(GENMIN)/sv_out.txt\" \
	    -o $(GENMIN)/kp_tb.vvp hdl/rtl/sv/kp_core.sv hdl/tb/kp_tb.sv
	cd $(ROOT) && $(VVP) $(GENMIN)/kp_tb.vvp | tee $(GENMIN)/run.log
	cd $(ROOT) && grep -q "SV-DIFF: PASS" $(GENMIN)/run.log

# ---- deterministic random re-run with a different seed / more vectors ----
FUZZ_SEED ?= 20260718
FUZZ_N    ?= 48
fuzz:
	$(MAKE) -C $(ROOT)/hdl sim-sv sim-vhdl equiv \
	    FMTGEN_ARGS="--seed $(FUZZ_SEED) --nrandom $(FUZZ_N)"
	cd $(ROOT) && python3 tools/k_fmtgen.py hdl/fmt/messages.h -o $(GEN)

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

test: equiv sim-uart-sv sim-uart-vhdl sim-sys-sv sim-sys-vhdl \
      sim-regs-sv sim-regs-vhdl config-test
	@echo "k_printf_hdl: all local checks passed (core diff + equiv, UART, trig/tee/capture, regs, config matrix)."

clean:
	cd $(ROOT) && rm -rf $(GEN)/* $(GENMIN)/* 2>/dev/null || true
