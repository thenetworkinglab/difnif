#!/bin/bash
#
# Builds the FPGA-only firmware (../fw) and runs soc_t.v: the SoC and its
# firmware against an SD card model holding a FAT32 card from mksdimg.py.
#
# Needs Icarus Verilog (PATH should include /opt/oss-cad-suite/bin) and the
# RISC-V cross compiler (see ../fw/Makefile).
#
# This file is part of a fork of DifNif; CERN-OHL-S-2.0.

set -eu
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

make -C ../fw
DEFS=$(python3 mksdimg.py "$TMP/sdimg.hex")
iverilog -g2012 -o "$TMP/sim" $DEFS -DSDIMG="\"$TMP/sdimg.hex\"" \
    soc_t.v soc.v picorv32.v sdhost.v sdbridge.v sectorbuf.v sdcard_model.v
vvp -n "$TMP/sim"
