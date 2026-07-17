#!/bin/sh
# run_ghdl.sh - analyze, elaborate and run the VHDL differential testbench.
#
# Run from the repository root. Uses the standard GHDL flow (ghdl -a/-e/-r) that
# works on Linux and native macOS. Falls back to a manual x86_64 link when GHDL
# is an x86_64 (Rosetta) build on Apple Silicon, where its object files don't
# match the native arm64 linker - it binds, then links the listed objects with
# `arch -x86_64 clang -arch x86_64`.
#
# Exits non-zero unless the testbench prints "VHDL-DIFF: PASS".
set -e

WORK=hdl/gen/ghdl
SRC="hdl/gen/kp_msgs_pkg.vhd hdl/rtl/vhdl/kp_core.vhd hdl/tb/kp_tb.vhd"
STD="--std=08 -frelaxed"
mkdir -p "$WORK"

ghdl -a $STD --workdir="$WORK" $SRC

OUT=hdl/gen/ghdl_run.log
if ghdl -e $STD --workdir="$WORK" -o hdl/gen/kp_tb_ghdl kp_tb 2>/dev/null; then
    ghdl -r $STD --workdir="$WORK" kp_tb 2>&1 | tee "$OUT"
else
    echo "run_ghdl: native elaborate failed; using x86_64 link fallback" >&2
    ( cd "$WORK"
      ghdl --bind $STD --workdir=. kp_tb
      ghdl --list-link $STD --workdir=. kp_tb | tr '\n' ' ' | \
        xargs arch -x86_64 clang -arch x86_64 -o ../kp_tb_ghdl )
    arch -x86_64 hdl/gen/kp_tb_ghdl 2>&1 | tee "$OUT"
fi

grep -q "VHDL-DIFF: PASS" "$OUT"
