#!/bin/sh
# run_ghdl.sh [top] [pass-string] - analyze, elaborate and run a VHDL testbench.
#
# Defaults: top = kp_tb, pass-string = "VHDL-DIFF: PASS".
# Run from the repository root. Uses the standard GHDL flow (ghdl -a/-e/-r) that
# works on Linux and native macOS. Falls back to a manual x86_64 link when GHDL
# is an x86_64 (Rosetta) build on Apple Silicon, where its object files don't
# match the native arm64 linker - it binds, then links the listed objects with
# `arch -x86_64 clang -arch x86_64`.
#
# Exits non-zero unless the testbench prints the pass-string.
set -e

TOP=${1:-kp_tb}
PASS=${2:-"VHDL-DIFF: PASS"}

WORK=hdl/gen/ghdl
SRC="hdl/gen/kp_msgs_pkg.vhd hdl/rtl/vhdl/kp_core.vhd hdl/rtl/vhdl/kp_uart_tx.vhd \
     hdl/rtl/vhdl/kp_trig.vhd hdl/rtl/vhdl/kp_tee.vhd hdl/rtl/vhdl/kp_capture.vhd hdl/rtl/vhdl/kp_regs.vhd \
     hdl/tb/kp_tb.vhd hdl/tb/kp_uart_tb.vhd hdl/tb/kp_sys_tb.vhd hdl/tb/kp_regs_tb.vhd"
STD="--std=08 -frelaxed"
mkdir -p "$WORK"

ghdl -a $STD --workdir="$WORK" $SRC

OUT="hdl/gen/${TOP}_run.log"
if ghdl -e $STD --workdir="$WORK" -o "hdl/gen/${TOP}_ghdl" "$TOP" 2>/dev/null; then
    ghdl -r $STD --workdir="$WORK" "$TOP" 2>&1 | tee "$OUT"
else
    echo "run_ghdl: native elaborate failed; using x86_64 link fallback" >&2
    ( cd "$WORK"
      ghdl --bind $STD --workdir=. "$TOP"
      ghdl --list-link $STD --workdir=. "$TOP" | tr '\n' ' ' | \
        xargs arch -x86_64 clang -arch x86_64 -o "../${TOP}_ghdl" )
    arch -x86_64 "hdl/gen/${TOP}_ghdl" 2>&1 | tee "$OUT"
fi

grep -q "$PASS" "$OUT"
