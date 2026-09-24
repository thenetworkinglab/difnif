# 72-pin (form factor) board: static review

Review of `pcb_formfactor/` (Rev P1) and the matching Verilog, done before
building any hardware. The goal is to get the 72-pin DifNif working in the
PS/2 55SX and 70, which use the same 2x36 DBA-ESDI edge connector as the 50Z.

Original design by Eric Schlaepfer ([schlae/difnif](https://github.com/schlae/difnif)),
CERN-OHL-S-2.0. This document and `tools/check_board.py` are additions in this fork.

## How to rerun

```
python3 tools/check_board.py
```

It exports the netlist with KiCad's `kicad-cli` and checks it against the
published connector pinout (`tools/dba_esdi_72pin.csv`), the FPGA pin file
(`verilog/difnif.pcf`) and the 74LVC4245 datasheet. It exits non-zero while
any ERROR remains, so it can gate a Rev P2 schematic.

KiCad's own ERC was also run. Almost everything it reports is noise: missing
libraries (Eric's custom libraries aren't in the repo), unused Teensy pins, and
the half-populated logic-analyzer header. It did **not** catch findings 1 or 2,
because the level-shifter pins are typed "bidirectional".

## Findings

| # | Severity | Finding | Affects |
|---|----------|---------|---------|
| 1 | Critical | FPGA `chreset` input is floating | 72-pin only |
| 2 | High | 74LVC4245 supply rails are swapped (5 V on a 4.6 V abs-max pin) | Both boards |
| 3 | High | `-ADL` not connected; address decode is not latched | 72-pin only |
| 4 | Medium | `-CD SFDBK` not driven | 72-pin only |
| 5 | Low | Address decode ignores POS alternate address, answers at 0x3518-351F | 72-pin only |
| 6 | Low | `addr_sel_l` is a `wire` assigned in an `always` block | Verilog |
| 7 | Low | Only 6 debug signals reach the logic-analyzer header | Both boards |
| 8 | High | No key slot in the board outline | 72-pin only |

### 1. FPGA `chreset` input is floating

Connector pin **B14 is `CHRESET`, active high** (IBM pinout). The schematic
names it `~{CHRESET}` and routes it through U8 channel 7 (pin 14 to pin 10) to
FPGA pin 52 (`chreset_l`), which no logic uses.

The logic uses `chreset` on FPGA pin 76. That comes from U8 pin 15
(`CHRESET_5V`), and **nothing is connected to U8 pin 15**. On the ThinkPad
board it's fed from connector pin 2.

`chreset` gates every bus access
([mcabus.v](../verilog/mcabus.v) `assign addressed = ... & ~chreset`), so
whether the card answers depends on a floating CMOS input. This matches
the README's "register communications don't work correctly".

- **Rev P1 rework:** bridge U8 pins 14 and 15 (adjacent pads). Pin 76 then
  sees the real CHRESET. No firmware change is needed.
- **Rev P2:** connect B14 to U8 pin 15 (`CHRESET_5V`). This frees U8 channel 7
  for `-ADL` (finding 3).

### 2. 74LVC4245 supply rails are swapped

All six transceivers (U6-U10, U14) are Nexperia 74LVC4245APW, per the Mouser
field. The datasheet says **pin 1 is VCC(A), the 5 V side (up to 5.5 V)**, and
**pins 23/24 are VCC(B), the 3 V side (abs max 4.6 V)**, with VCC(A) >= VCC(B).
Both boards do the opposite: pin 1 is at +3V3 and pins 23/24 are at +5V. The A
port faces the FPGA and the B port faces the bus. This was confirmed in the PCB
files as well as the schematics.

The logic still works, because each port follows its own supply. But VCC(B)
sits 0.4 V above its absolute maximum rating. The ThinkPad board works in
practice, so this probably isn't the 72-pin failure. Still, parts running
outside their ratings can behave marginally or degrade over time.

- **Fix (no layout change):** fit **TI SN74LVC8T245PW** instead. It has the same
  TSSOP-24 package and pinout: pin 1 VCCA, pin 2 DIR, pins 3-10 A, pins 14-21 B,
  pin 22 /OE, pins 23/24 VCCB. Both rails can be anywhere from 1.65 V to 5.5 V.
  DIR and /OE are referenced to VCCA (3.3 V here), which suits the FPGA driving
  DIR. The function table is the same (DIR low = B to A, high = A to B), so
  the Verilog doesn't change. This applies to both the 72-pin and ThinkPad boards.

### 3. `-ADL` not connected; address decode not latched

On the ThinkPad connector, the system board decodes the address and hands the
drive `-ADDR_SEL` plus A0-A3. On the 72-pin connector the card gets A0-A15 raw,
and [difnif_top.v](../verilog/difnif_top.v) compares A15-A4 with no latch. The
result, together with A0-A3, M/-IO, -S0 and -S1, is then sampled on the falling
edge of `-CMD`. Micro Channel allows the address and status lines to move on to
the next cycle while `-CMD` is still active (address pipelining), which is why
cards latch them with `-ADL`. `-ADL` is on pin A20, which isn't connected.

- **Rev P1 rework (after finding 1):** cut the trace from B14 to U8 pin 14 on
  the far side of the 14/15 bridge, and wire A20 to U8 pin 14. `-ADL` then
  reaches FPGA pin 52, which is a global-buffer input.
- **Rev P2:** route A20 to U8 channel 7 properly.
- **Verilog:** latch the decode, A0-A3, M/-IO, -S0/-S1 and -SBHE while `-ADL`
  is low, and use the latched copies in the `-CMD` logic. `-CD DS16` stays
  combinational from the live address, as MCA requires.
- **To confirm in simulation:** the MCA hold times for address and status
  relative to `-CMD`. The existing testbench notes that its timings are
  guesses.

### 4. `-CD SFDBK` not driven

Pin B08 is `-CD SFDBK` (card selected feedback), driven by the drive. The board
leaves it open. The system may not need it for I/O cycles, but a real drive
drives it.

- **Rev P2:** drive it through an open-drain or tri-state buffer. U12's fourth
  74VHCT125 section is spare: output pin 11, input pin 12 and /OE pin 13 are all
  currently tied off. Put the FPGA signal on /OE (pin 13) with the input (pin 12)
  at GND. Assert it for the duration of an addressed cycle.

### 5. Address decode

`addr_sel_l <= ~(bus_a[15:4] == 12'h351)` matches 0x3510-351F. The ESDI ports
are 0x3510-3517 (primary) and 0x3518-351F (alternate, chosen by POS). As
written, the card also answers reads at the alternate address, driving `FFFF`
onto the bus and asserting `-CD DS16`. Decode A3 as well and select the base
from POS register 2 bit 1.

### 6. Verilog: `wire` assigned in `always`

`addr_sel_l` is declared `wire` in `difnif_top.v` but assigned inside
`always @(*)`. Standard Verilog rejects this and some tools refuse it. Use
`reg`, or better an `assign`, which the `-ADL` rewrite replaces anyway.

### 7. Debug visibility

The logic-analyzer header J4 only carries the six SD-card pins, which the FPGA
reuses as test outputs. For the first Rev P2 board, add test points or a second
header on `-ADL`, `-CMD`, `-S0`/`-S1`, `CHRESET`, the address decode, and
`-CD DS16`.

### 8. No key slot in the board outline

The IBM drive's edge connector has a key slot between pins 2 and 3, visible
on both rows of a WD-3158. Eric's `BUS_DBA_ESDI` footprint draws the slot, at
the right position (1.27 mm past pin 2), but only on the `Dwgs.User` layer. The
board outline and the fab Gerber (`DifNif-Edge_Cuts.gbr` in the RevP1 zip) are
a plain 98.8 x 93.0 mm rectangle with no slot. If the 55SX cable-end socket or
the Model 70 riser socket has a key ridge, Rev P1 won't go in.

Measured on a WD-3158: the slot is **11.7 mm deep** and about **1.0 mm wide**,
cut right up against the edges of fingers 2 and 3 with no copper margin. The
IBM fingers are about 1.5 mm wide, the same as Eric's 1.524 mm, so the slot
fills the roughly 1.0 mm gap between them. The key ridge in the 55SX
flat-flex cable socket measures about **0.7 mm** thick, and the cable is keyed
at both ends. The Model 70 riser is assumed to be keyed the same way.

- **Rev P2:** add a slot about 0.9-1.0 mm wide and 11.7 mm deep, centred
  between pins 2 and 3. That clears the 0.7 mm ridge. IBM's slot touches the
  fingers; a board house will want some copper-to-edge clearance, so narrow
  fingers a2/a3 and b2/b3 slightly on the slot side if the fab requires it.
  Check the minimum routed slot width, which is often 1.0 mm.
- **Rev P1:** could be keyed by hand. A fine jeweller's saw (about 0.8 mm kerf)
  cutting down the 1.0 mm gap between fingers 2 and 3 to 11.7 mm deep would
  clear the 0.7 mm ridge.

## Mechanical

Confirmed against a real drive (IBM FRU 6128291, model WD-3158, 120 MB):

| Item | WD-3158 | Rev P1 board | Match |
|---|---|---|---|
| Connector tab width | 93 mm (measured) | 93.0 mm (Edge.Cuts) | Yes |
| Finger pitch | 2.54 mm, 36 per side | 2.54 mm, 36 per side | Yes |
| Finger length | about 7 mm (from photo) | 6.86 mm | Yes |
| Row A side | top of PCB, facing the drive casing | F.Cu, the component side | Yes |
| Pin 1 end | A1 on the right, looking down with fingers pointing away | a1 on the right, same view | Yes |
| Board thickness | 1.6 mm (measured across fingers) | 1.6 mm | Yes |
| Finger width | about 1.5 mm | 1.524 mm | Yes |
| Key slot | between pins 2 and 3 | none | **No** (finding 8) |

Where the connector sits on the drive:

- The finger tips stick out **23.8 mm** past the end of the drive's black
  aluminium frame.
- The drive PCB sits about **1 mm above** the bottom of the frame.
- The frame has recesses along its sides for the screw holes, and the drive PCB
  has matching cutouts plus a few others.

### Approach

We are **not** trying to make a board shaped like the drive's own PCB that
bolts to a drive chassis. The DifNif stays a small board (Rev P1 is 93 x 98.8 mm)
that plugs into the machine's connector. A **3D-printed carrier** for each
machine then mounts in the drive bay the way the IBM drive does and holds the
board so its connector lands where the drive's did. Eric's
`mech/difnif_PS2_drive_sled.STL` already follows this pattern: it's a
102 x 155 x 18.5 mm open frame with side rails, and its two corner holes are
85 mm apart, matching the board's mounting holes.

Carriers are cheap to print and reprint, so fitting them can be done by trial
without touching the PCB. The PCB only has to get the edge connector right
(width, pitch, key, thickness) and keep its mounting holes where the carrier
expects them.

Still to measure, per machine, when it's time to design carriers:

- How the drive is held in the bay (rails, screws, tray) and the positions of
  those mounting points
- Clearance above and below the drive, including the 55SX cable yoke
- Whether the tall parts (the socketed Teensy 4.1) and the microSD slot fit and
  stay reachable

## Suggested next steps

1. ~~Install the FPGA toolchain and get Eric's existing testbench running.~~
   Done. See "Toolchain status" below.
2. Extend the testbench with a host model that behaves like real Micro Channel
   timing (pipelined address, `-ADL`), reproduce findings 1 and 3, then fix
   them in Verilog.
3. Make the Rev P2 schematic and outline changes (including the key slot) and
   rerun `tools/check_board.py` until it's clean.
4. Measure the drive bays and design the per-machine carriers. This can happen
   any time, since printed carriers don't depend on the PCB beyond its mounting
   holes.

## Toolchain status

oss-cad-suite 2026-09-23 build (Yosys 0.69, nextpnr 0.11.1, Icarus Verilog 14
devel), installed in `/opt/oss-cad-suite`.

- **FPGA build (`make` in `verilog/`)** works unchanged. The nextpnr and icetime
  timing estimate is about 80 MHz worst case, against the 50 MHz internal clock.
- **Simulation (`verilog/sim.sh`)** failed with Icarus 14: `mcabus.v` used six
  signals before declaring them, which newer Icarus rejects. The declarations
  were moved to the top of the module. A Yosys formal equivalence check
  (`equiv_make`/`equiv_induct`) proved the reordered module identical to the
  original: 297 of 297 equivalence points proven. The testbench now runs to
  completion and writes `sim.vcd`.
- The testbench has no self-checks yet: it drives bus cycles and dumps
  waveforms but never compares results. Adding checks is part of the next step.
