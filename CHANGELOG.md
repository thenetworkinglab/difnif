# Changelog

The Teensy firmware (`difnift/`) and the FPGA design (`verilog/`) have separate
versions, so that a problem report can say which of each was running. The
firmware prints both when it starts and after each hard reset (each time the
PS/2 is switched on), and on the `v` command:

    DifNif firmware v2026.11.18-1, FPGA v2026.11.18-1 (ps2)

A version is the release date and a count of releases that day:
`v2026.11.18-1` is the first release on 18 November 2026. Git tags are
`fw-v…` for the firmware and `fpga-v…` for the FPGA. To make a release, change
`FW_VERSION` in `difnift/difnift.ino` or the values in `verilog/version.vh`,
and add an entry here.

Earlier code (Eric Schlaepfer's, on `main`) has no version; an FPGA built from
it, or from this fork before v2026.11.18-1, is reported as "has no version".

## Firmware

### v2026.11.18-1

First versioned release of this fork's `difnift.ino`. Changes from Eric's:

- **Version banner:** prints the firmware and FPGA versions at startup, after
  a hard reset, and on the `v` serial command.
- **Faster Teensy-to-FPGA register port:** RD and WR strobes cut from 200 ns
  to 80 ns. Accesses that change a flag in the FPGA (writing FLAGS, ISR or
  SIFR; reading ATN or CIFR) are followed by a 120 ns wait, so the next flag
  poll sees the new state after the FPGA's synchronizers.
- **Flag writes without a read first:** `setFlag` and `clearFlag` keep a
  copy of the Teensy-owned flag bits (command in progress, clear all) instead
  of reading the flag register and writing it back.
- **Read-ahead:** a multi-sector read fetches up to 32 sectors from the SD
  card in one go instead of one seek and read per sector. Any write empties
  it.

Tested on a Rev P2 board in a PS/2 55SX with DOS 6.22, with the FPGA design
below (built just before the version registers were added):

- DiskMeter about 705 KB/s, up from about 665 KB/s with Eric's firmware.
- Copy test (`tools/copytest`), run overnight with the strobe, flag and
  read-ahead changes:
  - 196 rounds, about 1 GB written.
  - All 1179 `FC /B` comparisons identical, every file's SHA-256 correct.
  - CHKDSK clean on both drives.

## FPGA

### v2026.11.18-1

First versioned release of this fork's FPGA design. Changes from Eric's (the
numbers are findings in [docs/formfactor-review.md](docs/formfactor-review.md)):

- **Version registers:** the Teensy can read the version (BCD) at registers
  10-12, and at register 13 which build it is (1 for `make BOARD=ps2`, 0 for
  the ThinkPad build).
- **Channel reset (15):** CHRESET returns the card to its power-on state
  (POS 2-4, BCR and DMA arbitration state) and tells the Teensy through the
  hard-reset flag. Before this, a PS/2 switched on while the Teensy's USB
  kept the board powered could hang at boot.
- **Write data timing (9):** host write data is stored on the rising edge of
  `-CMD`, where IBM guarantees setup time, instead of the falling edge, where
  it guarantees none. Mailbox events now happen once per host cycle.
- **Stale DMA request (12):** the card no longer bids for the bus again with
  a request that has already been serviced.
- **72-pin address decode (5):** follows the POS 2 alternate-address bit (3510
  or 3518) and the card-enable bit.
- **`-CD SFDBK` output (4)** on FPGA pin 134, wired to the connector on Rev P2.
- **Verilog cleanup (6):** a `wire` assigned in an `always` block, and
  declarations reordered for Icarus Verilog 14.
- **Build:** `make BOARD=ps2` builds the 72-pin version with the POS
  registers on (the `DF9F` adapter ID, finding 10); plain `make` is the
  ThinkPad build. Each goes into `build/<board>/`.

Checked against IBM's Micro Channel timing:

- **Simulation:** `verilog/run_sim72.sh` passes at typical timing and at
  IBM's limits for the 50Z, 55SX and Model 70.
- **Timing budget:** `tools/timing_budget.py --pos` passes; the smallest
  margin is 8.9 ns, on T22.

On hardware, with the build from just before the version registers: a Rev P2
board boots DOS 6.22 in a PS/2 55SX, from cold and warm, with and without
USB connected, and passed the overnight copy test (see the firmware entry).
**Not tested** in a Model 70 or a ThinkPad 700C.
