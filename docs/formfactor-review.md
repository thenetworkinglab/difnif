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
| 3 | Resolved | `-ADL` not connected: not needed (IBM allows latching on `-CMD`; 17 ns hold margin) | 72-pin only |
| 4 | Medium | `-CD SFDBK` not driven (Verilog fixed; needs Rev P2 wiring) | 72-pin only |
| 5 | Low | Address decode ignores POS alternate address, answers at 0x3518-351F (fixed) | 72-pin only |
| 6 | Low | `addr_sel_l` is a `wire` assigned in an `always` block (fixed) | Verilog |
| 7 | Low | Only 6 debug signals reach the logic-analyzer header | Both boards |
| 8 | High | No key slot in the board outline | 72-pin only |
| 9 | High | Write data is captured on the falling edge of `-CMD`, where IBM guarantees 0 ns setup (fixed) | Both boards |
| 10 | High | Eric's default build hides the POS registers, including the `DF9F` adapter ID | Build setting |
| 11 | Low | Status register can change during a read cycle | Both boards |
| 12 | High | Card can bid for DMA again with a request already serviced (fixed) | Both boards |
| 13 | Note | Card relies on the planar re-arbitrating after every DMA transfer | Both boards |

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

### 3. `-ADL` not connected

On the ThinkPad connector, the system board decodes the address and hands the
drive `-ADDR_SEL` plus A0-A3. On the 72-pin connector the card gets A0-A15 raw,
and [difnif_top.v](../verilog/difnif_top.v) decodes A15-A4 without a latch. The
result is sampled on the falling edge of `-CMD`, and `-ADL` (pin A20) isn't
connected.

**Resolved: `-ADL` isn't needed.** Figure 2-34 guarantees that address and
status stay valid for at least 30 ns after `-CMD` falls (T9, T10), and note 2
explicitly allows latching on the leading edge of `-CMD` instead of `-ADL`. The
simulation passes with the address going invalid exactly at the 30 ns limit,
and the timing check below leaves 17 ns of hold margin inside the FPGA.

- **Rev P2 (optional):** A20 could still go to the spare U8 channel, freed by
  the finding 1 fix, as a debug aid. Nothing depends on it.

### 4. `-CD SFDBK` not driven

Pin B08 is `-CD SFDBK` (card selected feedback). The board leaves it open.
IBM Figure 2-34, note 1: "All slaves must drive -CD SFDBK whenever selected."
It has to come from the unlatched address decode (note 3).

- **Rev P2:** drive it through U12's spare fourth 74VHCT125 section: FPGA signal
  on the input (pin 12), /OE (pin 13) grounded, output (pin 11) to B08. That
  makes it push-pull, which is the driver type Micro Channel specifies for
  `-CD SFDBK`, the same as `-CD DS 16`. (An earlier version used the enable pin
  as an open-drain driver; it was swapped during layout, see "Rev P2 schematic
  changes".)

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

- **Rev P2 (done):** a slot 1.0 mm wide and **8.7 mm** deep, centred between
  pins 2 and 3, with a rounded end, and fingers a2/a3/b2/b3 narrowed to 1.0 mm
  (centred) for 0.27 mm of copper-to-edge clearance. The slot doesn't need
  IBM's 11.7 mm: the drive goes only 7.5-7.8 mm into the 55SX cable socket
  (measured by fitting the socket on the WD-3158), so the key ridge can't
  reach further than that. 8.7 mm is the deepest slot that clears the existing
  traces fanning out from fingers A1/A2/B1/B2 (8.8 mm touches `A13`), leaving
  about 1 mm of margin. Check the board house's minimum routed slot width
  (often 1.0 mm) and copper-to-edge clearance.
- **Rev P1:** could be keyed by hand. A fine jeweller's saw (about 0.8 mm kerf)
  cutting down the 1.0 mm gap between fingers 2 and 3, about 8.5 mm deep,
  would clear the 0.7 mm ridge.

### 9. Write data captured at the falling edge of `-CMD`

[mcabus.v](../verilog/mcabus.v) stores host writes (CIFR, ATN, BCR, DREG and
POS registers) on `negedge cmd_l`. IBM Figure 2-34 only guarantees write data
**0 ns** before `-CMD` falls (T17), and 30 ns after `-CMD` *rises* (T18). With
data arriving at the limit, any data line whose path through the level shifter
is slower than the `-CMD` line's gets captured before the new value arrives.

The simulation reproduces this: at IBM's timing limits, host writes fail on 7
of 8 randomly chosen sets of level-shifter delays, on all three machines. Reads
are unaffected. Eric's measurements on his 50Z show about 50 ns of write setup,
which is why typical timing passes. How much setup the 55SX and Model 70 really
give is unknown.

This affects both boards and could contribute to the README's "sector written
is shifted by one byte" bug, though that isn't proven.

- **Verilog fix:** latch the address and status on the falling edge (as now),
  but store the write data on the rising edge of `-CMD`, where it is guaranteed
  valid for another 30 ns. The Teensy-facing "register full" flags have to move
  with it, so the Teensy never sees a flag before its data.

### 10. POS registers hidden in Eric's default build

`mcabus.v` defines `MCA_NO_POS` ("POS bypass", added January 2026). The card
is then always enabled but never answers setup cycles, so the host can't read
the `DF9F` adapter ID. The ThinkPad presumably doesn't need it. On the 72-pin
connector the drive has its own `-CD SETUP` line, and the 50Z/55SX/70 BIOS
probably reads the ID to find the drive. The define can now be overridden with
`-DMCA_USE_POS` without changing the default, and the simulation passes the POS
tests in that mode.

### 11. Status register can change during a read

The basic status register is read live, not snapshotted when the cycle starts.
If a flag changes while `-CMD` is low (for example the Teensy emptying CIFR),
the data on the bus changes mid-cycle. IBM wants read data valid within 60 ns
of `-CMD` falling (T20). Each bit is either the old or the new value, so this is
usually harmless, but a snapshot at the start of the cycle would be cleaner.
The simulation reports these as SPEC notes, not failures.

### 12. DMA request dropped too late

The card asks for DMA while its data-register request flag (`flag_treq`) is
set. A DMA transfer clears that flag through the 50 MHz synchronizer, 40-60 ns
after the transfer's `-CMD` rises. IBM allows the next arbitration cycle to
start 30 ns after the end of a transfer (Figure 2-46, T41). The card decides
whether to compete when `ARB/-GNT` rises, so on a planar that re-arbitrates
that quickly, it competes again with a request that has already been serviced,
wins, and receives (or supplies) a word the Teensy isn't ready for.

The simulation reproduces it at IBM's limits: a whole 16-word DMA transfer went
through on a single request. At typical timing (arbitration 100 ns after the
transfer) it doesn't happen. How fast real 55SX and Model 70 planars
re-arbitrate is unknown. This may also be what Eric's "fix rare dma glitch"
commit was working around.

**Fixed:** `dma_requested` is now also gated by `treq_pending`, which rises the
moment a DREG or DMA cycle's `-CMD` rises and falls one clock after `flag_treq`
clears, so the request never glitches back on.

### 13. Dependence on re-arbitration after DMA

After winning arbitration, the card stays "DMA selected" for any I/O cycle
until `ARB/-GNT` next goes high (`dma_cycle` only updates on that edge). If a
planar handed the bus back to the CPU without an arbitration cycle, the card
would treat the CPU's next I/O cycles as DMA transfers. IBM's timing (T41) and
Eric's note about the real 50Z in `mcabus_t.v` indicate the planar does
re-arbitrate after each transfer, and the simulation models it that way. This
is worth confirming with a logic analyzer on real hardware.

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
- The drive PCB is recessed about **1 mm** into the frame: the bottom edge of
  the frame sticks out about 1 mm further than the PCB's underside.
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

## Verilog fixes

Findings 4, 5, 6 and 9 are fixed in `verilog/`.

**Write capture (finding 9), [mcabus.v](../verilog/mcabus.v):**

- Address, status, byte enable, "addressed" and "DMA selected" are latched on
  the falling edge of `-CMD`, as before.
- Write data (CIFR, ATN, BCR, DREG, POS 2-4, and DMA writes to DREG) is stored
  on the rising edge of `-CMD`, using those latched values.
- The host-side mailbox events (ATN written, CIFR written, ISR read, SIFR read,
  DREG accessed) flip a toggle on the rising edge of `-CMD`. The 50 MHz domain
  detects each flip through a two-stage synchronizer. Each host cycle produces
  exactly one event, and the Teensy never sees a "full" flag before its data.
- Side effect: ISR, SIFR and DREG flags now clear as soon as the host's read
  ends, instead of partway into the host's *next* bus cycle. The old behaviour
  meant the last word of a transfer stayed "requested" until the host did
  something else.

**Address decode (finding 5), [difnif_top.v](../verilog/difnif_top.v):** the
72-pin decode compares A15-A3 against 3510 or, when POS 2 bit 1 is set, 3518.
Registers are selected by A2-A0, so both bases work. A disabled card (POS 2
bit 0 clear) now answers only setup cycles, including for `-CD DS 16`. The
ThinkPad path (`fulladdr_l` high) is unchanged.

**`-CD SFDBK` (finding 4):** new output `cd_sfdbk_l`, asserted from the
unlatched decode whenever the card is selected by the processor or DMA, but not
by `-CD SETUP` (IBM notes 1 and 3). It's assigned to FPGA pin 134 in
[difnif.pcf](../verilog/difnif.pcf), which is unconnected on Rev P1. Rev P2
needs it wired to U12 pin 12 (input of the spare 74VHCT125 section, /OE pin 13
grounded) with the output (pin 11) to J1 B08, push-pull. `tools/check_board.py`
reports it until then.

**Results:** `run_sim72.sh` passes every test on the bridged Rev P1 and Rev P2
models, on all three machines, at typical timing and at IBM's limits for all 8
delay sets, with POS enabled. In POS bypass mode only the two POS tests fail, by
design. Rev P2 also passes the `-CD SFDBK` timing check (valid within 60 ns of
the address, T14). The FPGA build uses 438 of 7680 logic cells, and the
`-CMD`-clocked logic reports about 88 MHz, far above what a 90 ns `-CMD` pulse
needs.

Because POS writes are now stored as `-CMD` rises, a new POS setting takes
effect when the POS write cycle ends. A host cycle overlapping that write still
sees the old setting. That's normal for Micro Channel cards.

**DMA (finding 12):** see finding 12. Also, a DMA I/O cycle can no longer
trigger mailbox flags, whatever address the DMA controller puts on the bus
(`la_io` excludes DMA cycles).

**Not yet verified:**

- **The ThinkPad 700C.** Finding 9's fix changes the ThinkPad build too. It's
  per IBM's timing rules, but nobody has run it on a 700C.

## Timing check

The simulations treat the FPGA as having no internal delay.
[tools/timing_budget.py](../tools/timing_budget.py) closes that gap. It builds
the design with yosys and nextpnr, takes nextpnr's worst delay for each class
of path, adds the clock-network delay from nextpnr's SDF file, allowances for
the FPGA's pad buffers, and worst-case delays of the board's other chips from
their datasheets, then compares the total with IBM's limits:

| IBM | Requirement | Limit | Budget | Margin |
|---|---|---|---|---|
| T13 | `-CD DS 16` from address | 55 max | 30.6 | 24.4 |
| T14 | `-CD SFDBK` from address | 60 max | 30.6 | 29.4 |
| T2/T15 | address/status setup at `-CMD` falling | 0 min | 39.8 | 39.8 |
| T9/T10 | address/status hold after `-CMD` falling | 2.4 min | 19.8 | 17.4 |
| T16/T17 | write data setup at `-CMD` rising | 0 min | 78.0 | 78.0 |
| T18 | write data hold after `-CMD` rising | 2.4 min | 19.8 | 17.4 |
| T16 | falling-edge latches to rising-edge logic | 0 min | 84.3 | 84.3 |
| T20 | read data valid from `-CMD` falling | 60 max | 35.6 | 24.4 |
| T22 | read data released after `-CMD` rising | 40 max | 30.6 | 9.4 |
| T42 | `-PREEMPT` released after `ARB/-GNT` low | 50 max | 22.2 | 27.8 |
| T45 | ARB drivers on after `ARB/-GNT` high | 50 max | 25.8 | 24.2 |
| T45A/T47 | ARB driver follows another ARB line | 50 max | 27.6 | 22.4 |
| T41 | DMA request dropped before next `ARB/-GNT` (finding 12) | 0 min | 17.8 | 17.8 |

All values in ns, default build; the `--pos` build is within 1 ns of these.
Every requirement passes. The tightest is T22 (the card letting go of the data
bus after a read) at 9.4 ns, and that's with the pessimistic assumptions below.

How pessimistic the numbers are:

- **FPGA:** each row uses the worst path nextpnr found in its whole class. For
  example, every pin-to-pin row uses 10.6 ns, the Teensy address-to-data path,
  not the faster address decoder paths. nextpnr doesn't model the pad buffers,
  so 1.5 ns is added at each pad. That matches Lattice's worst-case 7.3 ns for
  a pin-to-LUT-to-pin path on HX parts (85 °C, minimum core voltage).
- **Board:** level shifters use 7 ns worst case in either direction (SN74LVC8T245
  at 3.3 V/5 V is 6.0 and 4.4), 15 ns for the data transceivers to turn around,
  and 10 ns for the 74VHCT125 (from TI's equivalent SN74AHCT125 at 50 pF). The
  74LCX07 uses 7 ns, double TI's SN74LVC07A figure, because I couldn't get ST's
  datasheet.
- **Hold checks** assume the data path inside the FPGA takes 0 ns and the clock
  path takes its maximum.
- **Not covered:** Rev P1's 74LVC4245As have their supplies swapped (finding 2),
  so their delays aren't specified at all. PCB trace delays (about 0.2 ns) are
  left out. The rise time of open-drain lines depends on the planar's pull-ups.

Rerun it after any Verilog change, since placement moves paths around:
`python3 tools/timing_budget.py` and `python3 tools/timing_budget.py --pos`.

## Rev P2 schematic changes

Made directly in `pcb_formfactor/DifNif.kicad_sch` and `DifNifBus.kicad_sch`
(still KiCad 6 format; KiCad 9 converts them when saved). After the changes,
`tools/check_board.py` reports 0 errors (it was 9), and KiCad's ERC shows 12
fewer problems and no new ones.

| Finding | Change |
|---|---|
| 1 | Net at J1 B14 renamed `~{CHRESET}_5V` -> `CHRESET_5V`, which joins B14 to U8 pins 14 **and** 15. The FPGA's `chreset` (pin 76) now sees the real CHRESET; pin 52 gets it too, unused. |
| 2 | U6-U10, U14: value `74LVC8T245`, Mouser `595-SN74LVC8T245PWR` (was 74LVC4245 / 771-74LVC4245APW-T). Same TSSOP-24 footprint and pinout; the existing supply wiring (pin 1 = 3.3 V, pins 23/24 = 5 V) is correct for this part. Symbol graphics unchanged. |
| 4 | U12 section 4 is the `-CD SFDBK` driver, push-pull: pin 12 (input) connects to new hierarchical net `~{CD_SFDBK}` -> sheet pin -> FPGA pin 134 (and J4 pin 11); pin 13 (/OE) stays grounded; pin 11 (output) connects to J1 B08 via `~{CD_SFDBK}_5V`. No-connect flags removed from U12 pin 11 and J1 B08. First done with the signal on pin 13 (open-drain); swapped during layout because routing to pin 13 cut pin 12's ground off from the top pour, and push-pull is what IBM specifies anyway. |
| 7 | Logic-analyzer header J4: its 11 unused data pins now carry FPGA-side bus signals (below). No new parts. |

J4 (HP logic analyzer pod) assignments:

| J4 pin | Pod bit | Signal | | J4 pin | Pod bit | Signal |
|---|---|---|---|---|---|---|
| 4 | D15 | `-CMD` | | 5 | D14 | `-S0` |
| 6 | D13 | `-S1` | | 7 | D12 | `M/-IO` |
| 8 | D11 | `-CD SETUP` | | 9 | D10 | `CHRESET` |
| 10 | D9 | `-CD DS 16` | | 11 | D8 | `-CD SFDBK` |
| 12 | D7 | `DATA_DIR` | | 13 | D6 | `ARB/-GNT` |
| 14 | D5 | `-PREEMPT` | | 3, 15-19 | CLK, D4-D0 | SD-card pins, as before |

Not changed in the schematic:

- **`-ADL`** (finding 3): not needed, so A20 stays unconnected.
- **Pull-ups on the FPGA-driven buffer inputs.** Eric's `-IRQ14` and `-CHRDY`
  are driven through buffer enables, and `-CD DS 16` and `-CD SFDBK` through
  buffer inputs, straight from the FPGA. Before the FPGA has loaded its
  configuration, those pins only have whatever pull-up the iCE40 applies during
  configuration. If that isn't guaranteed, a 10 k pull-up to 3.3 V on each
  would keep them quiet at power-up. Worth checking in Lattice's configuration
  documentation.
- **The ThinkPad board** has the same swapped-supply 74LVC4245s (finding 2). The
  same part swap would fix it; not done here.

### Layout work (in KiCad's PCB editor)

1. **Update PCB from Schematic** (Tools menu, or F8). New connections to route:
   J1 B14 to U8 pin 15; J1 B08 to U12 pin 11; U12 pin 12 to FPGA pin 134
   (routed via J4 pin 11, whose through-hole pad doubles as a via); and J4 pins
   4-14 to their signals. Route the U12 pin 12 stub on the top layer away from
   pin 13, so pin 13 keeps its ground connection to the pour.
2. ~~**Key slot** (finding 8).~~ Done: Edge.Cuts slot x = 91.2 to 99.9 mm
   (8.7 mm deep, rounded end), y = 43.36 to 44.36 mm; pads a2, a3, b2 and b3
   narrowed to 1.0 mm, centred. DRC shows nothing new, and the ground pour is
   intact.
3. Rerun `python3 tools/check_board.py` and KiCad's DRC, and bump the silkscreen
   revision to P2.

## Suggested next steps

1. ~~Add DMA transfers to `difnif72_t.v`.~~ Done.
2. ~~Timing check of the FPGA's internal delays.~~ Done: see "Timing check".
3. ~~Rev P2 schematic changes.~~ Done: see "Rev P2 schematic changes".
   Remaining: the layout work listed there.
4. Measure the drive bays and design the per-machine carriers.

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

## Simulation

[verilog/difnif72_t.v](../verilog/difnif72_t.v) is a self-checking testbench
around the unmodified FPGA design. It models:

- **the host**, following IBM's Figure 2-34 timing either at its limits or at
  typical values Eric measured on a 50Z, with 300, 250 and 200 ns cycles
  (50Z, 55SX, Model 70). Address and status really do go invalid (`x`) once
  their hold times expire, and unused data lanes carry garbage.
- **the Rev P1 board**, with each level-shifter channel given its own delay in
  the datasheet's 1.0-7.0 ns range (varied by `SEED`), and the floating FPGA
  reset input (as built) or the U8 14/15 bridge.
- **the Teensy**, using the same register timing as `difnift.ino` and the same
  mailbox handshakes as DIFDIAG, checking every value.
- **the planar's central arbiter and DMA controller**: `-PREEMPT`, a 300 ns
  arbitration cycle with the ARB bus resolved by open-collector drivers, the
  winner releasing `-PREEMPT` within 50 ns (T42), two-cycle DMA transfers
  (memory then I/O for sector writes, I/O then memory for sector reads) with
  `-TC` on the last one, and a new arbitration cycle 30 ns (limit) or 100 ns
  (typical) after every transfer. A second DMA device at a higher or lower
  priority competes for the bus, and the CPU does unrelated I/O in between; the
  card must never answer those cycles.

Run `verilog/run_sim72.sh` (about 50 seconds for 162 simulations;
`run_sim72.sh quick` runs one delay set). Results **before** the Verilog fixes:

| Board | POS | Timing | Result (all three machines) |
|---|---|---|---|
| As built | either | either | Every register test fails (finding 1) |
| Bridged | bypass | typical | Mailboxes pass; POS tests fail (finding 10); 3518 answered (finding 5) |
| Bridged | enabled | typical | All pass except 3518 answered (finding 5) |
| Bridged | either | IBM limits | Host writes fail on 7 of 8 delay sets (finding 9); reads pass |

**After** the fixes, the bridged board and Rev P2 pass everything with POS
enabled, including DMA in both directions with competing devices. See
"Verilog fixes" above.

The simulated FPGA has no internal delays (it's RTL simulation), and a floating
input is modelled as "unknown", so on real hardware finding 1 would show up as
intermittent failures rather than constant ones. That matches "some sort of
timing error".

The existing [verilog/sim.sh](../verilog/sim.sh) (Eric's DMA-focused testbench)
still runs as before.

To make `difnif_top.v` and `teensy.v` compile in Icarus, two trailing commas
were removed and two `wire`s assigned in `always` blocks became `reg`s
(finding 6). Yosys proved the result logically identical to the original:
845 of 845 equivalence points.
