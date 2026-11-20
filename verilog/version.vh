// DifNif FPGA version
//
// The Teensy reads these from teensy.v's registers 10-12, as BCD, so
// v2026.11.18-1 reads 2026, 1118, 0001. The version is the release date
// plus a count of releases that day; change it for each release and note
// the change in CHANGELOG.md.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

`ifndef DIFNIF_VERSION_VH
`define DIFNIF_VERSION_VH

`define FPGA_VERSION_YEAR  16'h2026
`define FPGA_VERSION_DATE  16'h1119
`define FPGA_VERSION_COUNT 16'h0001

`endif
