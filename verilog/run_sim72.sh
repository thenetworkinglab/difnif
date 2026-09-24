#!/bin/bash
#
# Run difnif72_t.v across board, POS mode, timing and machine cycle time.
#
#   ./run_sim72.sh              full matrix
#   ./run_sim72.sh quick        one seed per worst-case configuration
#
# Needs Icarus Verilog and the iCE40 cell models from oss-cad-suite
# (PATH should include /opt/oss-cad-suite/bin). Builds into a temporary
# directory, so nothing is left in the source tree.
#
# This file is part of a fork of DifNif; CERN-OHL-S-2.0.

set -u
cd "$(dirname "$0")"

CELLS=$(dirname "$(command -v yosys)")/../share/yosys/ice40/cells_sim.v
SRC="difnif72_t.v difnif_top.v mcabus.v teensy.v $CELLS"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SEEDS="1 2 3 4 5 6 7 8"
# Seed 4 has most data lines slower than -CMD, so it exercises the write race
[ "${1:-}" = "quick" ] && SEEDS="4"

machine() {
    case $1 in 300) echo "50Z";; 250) echo "55SX";; 200) echo "Model 70";; esac
}

printf "%-9s %-8s %-8s %-9s %5s  %s\n" "board" "POS" "timing" "machine" "runs" "failing tests (runs failed)"
for fix in 0 1; do
  for pos in 0 1; do
    for worst in 0 1; do
      for cycle in 300 250 200; do
        seeds=1
        [ $worst = 1 ] && seeds="$SEEDS"
        def=""
        [ $pos = 1 ] && def="-DMCA_USE_POS"
        : > "$TMP/fails"
        runs=0
        for seed in $seeds; do
          iverilog -g2012 $def -o "$TMP/sim" -s difnif72_t \
              -Pdifnif72_t.CYCLE=$cycle -Pdifnif72_t.WORST=$worst \
              -Pdifnif72_t.FIX_CHRESET=$fix -Pdifnif72_t.SEED=$seed $SRC 2>/dev/null || {
                echo "compile failed"; exit 1; }
          (cd "$TMP" && vvp -n sim) > "$TMP/log" 2>&1
          grep -q '^RESULT: cycle' "$TMP/log" || echo "TIMEOUT" >> "$TMP/fails"
          grep '^FAIL ' "$TMP/log" | sed 's/^FAIL //' >> "$TMP/fails"
          runs=$((runs + 1))
        done
        summary=$(sort "$TMP/fails" | uniq -c | awk '{n=$1; $1=""; sub(/^ /,""); printf "%s%s (%d)", sep, $0, n; sep="; "}')
        [ -z "$summary" ] && summary="all pass"
        printf "%-9s %-8s %-8s %-9s %5d  %s\n" \
            "$([ $fix = 1 ] && echo bridged || echo as-built)" \
            "$([ $pos = 1 ] && echo enabled || echo bypass)" \
            "$([ $worst = 1 ] && echo limit || echo typical)" \
            "$(machine $cycle)" "$runs" "$summary"
      done
    done
  done
done
