#!/bin/bash
#
# Run sd_t.v (sdhost.v against sdcard_model.v) at the timing corners.
#
#   ./run_sdsim.sh           all corners
#   ./run_sdsim.sh one       one run, sample_late, with any failures listed
#
# Needs Icarus Verilog (PATH should include /opt/oss-cad-suite/bin). Builds
# into a temporary directory.
#
# This file is part of a fork of DifNif; CERN-OHL-S-2.0.

set -u
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FMT="%-5s %5s %5s %5s  %-22s %-22s %s\n"
bad=0

run() {   # sample_late card_delay pad_out pad_in expect
    iverilog -g2012 -o "$TMP/sim" \
        -DSAMPLE_LATE=$1 -DODLY=$2 -DPAD_OUT=$3 -DPAD_IN=$4 \
        sd_t.v sdcard_model.v sdhost.v || exit 1
    out=$(vvp -n "$TMP/sim")
    result=$(echo "$out" | grep -E "^(ALL PASS|FAILED)" | tail -1)
    speed=$(echo "$out" | grep -o "8 blocks in .*" | head -1)
    if [ "$5" = pass ]; then
        case $result in "ALL PASS"*) mark="ok";; *) mark="UNEXPECTED"; bad=1;; esac
    else
        case $result in "ALL PASS"*) mark="UNEXPECTED"; bad=1;; *) mark="ok (expected to fail)";; esac
    fi
    printf "$FMT" "$1" "$2" "$3" "$4" "$result" "$mark" "$speed"
    if [ "${VERBOSE:-0}" = 1 ]; then echo "$out" | grep -E "FAIL|SD card" | head -20; fi
}

printf "$FMT" "late" "card" "out" "in" "result" "" "CMD18 speed"
if [ "${1:-}" = one ]; then
    VERBOSE=1 run 1 14.0 0.0 0.0 pass
    exit $bad
fi

# The card's outputs change anywhere from 0 to "card" ns after the clock
# falls. "out" and "in" are the FPGA's pin delays, to the card and back, so
# the data at the sampling flip-flop is changing from out+in to
# out+card+in ns after the 50 MHz edge that makes the clock fall. The host
# samples 20 ns after that edge (late 0) or 40 ns (late 1).
run 1 14.0  0.0  0.0 pass   # window 0-14 ns
run 1 14.0  6.0  4.0 pass   # window 10-24
run 1 14.0 12.0  8.0 pass   # window 20-34
run 0 14.0  0.0  0.0 pass   # window 0-14
run 0 14.0  3.0  2.0 pass   # window 5-19
run 0 14.0  6.0  4.0 fail   # window 10-24 contains 20 ns
run 1 14.0 16.0 12.0 fail   # window 28-42 contains 40 ns
exit $bad
