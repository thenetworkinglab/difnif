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
| 14 | Low | The Teensy's "16-bit transfer" flag shows the width of the last bus cycle of any kind, not the last data transfer | Both boards |
| 15 | High | Channel reset (CHRESET) doesn't reset the card: POS, BCR, flags and DMA state survive it, and the Teensy isn't told (fixed) | Both boards |
| 16 | High | 8-bit reads drive `FF` on D8-D15, which fights a 32-bit planar's own byte copy: the Model 70 read the adapter ID as FF9F (fixed in the FPGA; board change for Rev P3) | Both boards |
| 17 | High | The last sector written before the power goes off can be lost: the SD driver leaves each write open on the card (fixed in the firmware) | Firmware |

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
a plain 98.8 x 93.0 mm rectangle with no slot. The 55SX's cable-end socket has a
key ridge, so Rev P1 won't go into a 55SX without a slot cut by hand. The Model
70's riser socket has no key, so Rev P1 fits there as it is.

Measured on a WD-3158: the slot is **11.7 mm deep** and about **1.0 mm wide**,
cut right up against the edges of fingers 2 and 3 with no copper margin. The
IBM fingers are about 1.5 mm wide, the same as Eric's 1.524 mm, so the slot
fills the roughly 1.0 mm gap between them. The key ridge in the 55SX
flat-flex cable socket measures about **0.7 mm** thick, and the cable is keyed
at both ends. The Model 70's riser socket is **not** keyed (checked on a real
machine): its chassis makes it practically impossible to fit a drive upside
down, whereas the 55SX's loose flex cable could be plugged in either way with
the machine apart. The slot is harmless in the Model 70.

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
tests in that mode. Build the 72-pin board's FPGA program with
`make BOARD=ps2` in `verilog/`, which sets it (plain `make` builds the
ThinkPad version, POS bypassed, into a separate folder). Program it with
`make prog BOARD=ps2`.

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

### 14. "16-bit transfer" flag tracks every bus cycle

The FPGA gives the Teensy a flag (`t_treq_16`, flag register bit 9,
`FLAG_TRANSFER_16` in `difnift.ino`) meant to say whether the last data
register (DREG) transfer was 8 or 16 bits wide. [mcabus.v](../verilog/mcabus.v)
sets it from `-SBHE`, which is latched on the falling edge of `-CMD` in
**every** bus cycle, including other devices' cycles and the host's own status
polls. In simulation it read 0 after every transfer, even 16-bit ones, because
the host's 8-bit reads of the status register came in between.

The firmware never reads the flag; it treats every transfer as 16 bits. That's
fine as long as the host always moves sector data 16 bits at a time, which it
should, since the card asserts `-CD DS 16` for DREG and DMA cycles. If 8-bit
transfers ever need supporting, the FPGA should latch `-SBHE` only on DREG and
DMA cycles, and the firmware should check the flag.

### 15. Channel reset doesn't reset the card

Found on real hardware. With the Teensy's USB connected, a 55SX cold boot
stopped after the memory test and disk check; with USB unplugged it booted.

In Eric's [mcabus.v](../verilog/mcabus.v), `chreset` only gates `addressed`
(the card ignores the bus while it's asserted). Nothing is reset: POS 2-4
(card enable, arbitration level, address), the BCR (DMA and interrupt
enables), the mailbox flags and the arbitration state (`dma_cycle`,
`la_arb_won`) keep their values, and the Teensy has no way to see CHRESET.
Micro Channel adapters are expected to return to their power-on state on
channel reset.

Normally this is hidden because the board is powered from the host, so it
powers up with it. The ThinkPad board is always powered that way. On the
72-pin board, the Teensy's USB connection keeps the FPGA and Teensy powered
while the PS/2 is off (D3 keeps it off the bus side), so the next power-on
found the card still enabled, with DMA enabled and possibly a DMA request
pending from the previous session. While the PS/2 is off the FPGA's bus
inputs also float, which can leave junk in those registers.

- **Verilog fix:** the BCR and POS 2-4 are written in their own block with an
  asynchronous reset on `chreset` (POS 2 back to its default: card disabled in
  the POS build, enabled in the bypass build); `dma_cycle` and `la_arb_won`
  reset the same way. A synchronized copy of `chreset` is ORed into
  `t_hard_reset`, which clears the flags and sets the Teensy's hard-reset flag;
  `difnift.ino` already waits on that flag and restarts its drive emulation
  (`esdiReset`) when it clears, so the firmware is unchanged.
- **Both boards** drive FPGA pin 76 from the connector's CHRESET (the ThinkPad
  board through U8 from J1 pin 2), so the reset can't fire from a floating
  input in a running machine.
- **Simulation:** a new test leaves the card enabled with DMA and interrupts
  on and a transfer requested, pulses CHRESET, and checks the Teensy sees the
  reset, the request is dropped, POS 2 is back to 78 (POS build) and the card
  stops answering until it's reconfigured, and the BSR reads 00. Against the
  old `mcabus.v` it fails; with the fix, the full matrix passes as before.
- **Until the fixed FPGA is loaded:** have USB unplugged when the PS/2 is
  switched on, and plug it in afterwards.

### 16. 8-bit reads drive the upper byte lane

Found on real hardware. In the Model 70 the card wasn't recognised: POST
error 165, then the Reference Diskette asked for a description file for the
adapter in slot 4. In the 55SX it was fine.

The adapter ID is read one byte at a time from ports 100h and 101h, during a
setup cycle. Reading the POS registers by hand with DEBUG in the 70 gave
`9F FF 78 FF`, where it should be `9F DF 78 00`: every **odd** address read
`FF`.

**Why:** for an 8-bit slave the data belongs on D0-D7. A 16-bit (or 32-bit)
machine reading an odd address from such a slave has to move the byte to the
upper lane itself, and the Model 70 does that on the bus, driving D8-D15 with
a copy of D0-D7. The 55SX does it internally, so the upper lane doesn't
matter there.

The DifNif can't leave D8-D15 alone:

- The data buffers U6 (D0-D7) and U7 (D8-D15) share one direction line,
  `DATA_DIR` (FPGA pin 130), and both have their output enables tied to
  ground. So whenever the card answers a read, it drives all 16 lines.
- On 8-bit reads Eric's [mcabus.v](../verilog/mcabus.v) puts `FF` on the
  upper byte for the POS registers, and `00` for the status (BSR) and
  interrupt status (ISR) registers.
- The card's buffers won against the 70's copy: 101h read `FF` instead of
  `DF`, the only bit that differs being the one that was fought over, and
  103h read `FF` instead of `00`.

The same thing would have hit the ISR at 3513h (odd) once the drive was
running.

**Fixes:**

- **FPGA:** every 8-bit read (POS 0-4, BSR, ISR) now puts the same byte on
  both lanes. The 70's copy and the card's then agree, and a machine that
  reads D0-D7 sees no difference. With this the 70 reads `9F DF 78 00`,
  configures the drive and boots from it.
- **Board, for a Rev P3:** give U7 its own direction (or output enable) line
  from a spare FPGA pin, so the card drives D8-D15 only on 16-bit cycles,
  which is what IBM intends. Two buffers fighting over the same value is
  harmless in practice, but there's no reason to do it.
- **Simulation:** the host model now checks that on every stable 8-bit read
  whatever the card drives on D8-D15 is a copy of D0-D7. Against the
  released FPGA it fails at 100h (`ff` on D8-D15 where `9f` is on D0-D7) and
  101h (`ff` where `df` belongs); with the fix the full matrix passes as
  before. The check skips reads where the status changes during the cycle
  (finding 11), which the T20 check already reports.

### 17. The last write before power-off can be lost

Found on real hardware. After a 20-round copy test in the Model 70, with the
board powered only from the PS/2, the log file's last line ("Done") was in
its data cluster but its directory entry still had the old size, so the line
didn't show. The PS/2 had been switched off 2-5 minutes after the test
ended. The lost `AUTOEXEC.BAT` directory update during the DOS install
(`FILE0001.CHK`) looks like the same thing.

Tracing it:

- **DOS sends the update straight away.** With the USB serial log on,
  `ECHO hello >> D:\FCLOG.TXT` produced a write to the file's data sector
  and, right after, to the directory sector holding its entry (RBA 245921),
  both logged by the firmware as written.
- **The card lost it anyway.** The PS/2 was switched off a minute later and
  then USB was unplugged; on the Mac the directory sector still had the old
  size. The whole image held no other copy of the entry, so the write
  hadn't gone to a wrong sector.
- **Cause:** `difnift.ino` opens the card with `SdioConfig(FIFO_SDIO)`. In
  that mode the Teensy SD driver (`SdioTeensy.cpp`, `writeSector`) starts a
  multi-block write (CMD25) and leaves it open, so the next sector can follow
  without a new command. The write is only ended (CMD12) when the card is
  next accessed elsewhere, or on a sync. The card is allowed to hold that
  last sector in its buffer until then, and this one does. During a copy
  test the next access comes almost at once, so nothing goes missing; the
  last write before the machine goes idle stays open until the power goes.

**Fix (firmware):** at the end of each write command, after its last sector
and before the host is told the command is complete, the firmware calls the
driver's `syncDevice()`, which ends the write and waits until the card has
stored it (about 1.1 ms on this card). A multi-sector command still streams
to the card as one write.

With the fix, `ECHO fixed >> D:\FCLOG.TXT` twice, the second time switching
the PS/2 off within a second, left both lines in the file. A 20-round copy
test in the 55SX then ended with "Done" in the log.

**Related:** with the board powered from USB, the Teensy doesn't restart when
the PS/2 is switched on, and the firmware used to open the SD card only when
it started. With the card out at that moment, the drive answered but had no
disk. It now tries the card again at each hard reset (each PS/2 power-on)
if the disk image isn't open.

### The "shifted by one byte" write bug (open)

Eric's README reports occasional sector writes that come out shifted by one
byte. The cause isn't known. Checked so far:

- **8-bit transfers: ruled out as the cause.** A temporary simulation had the
  host write known bytes to DREG with 8-bit cycles, while a Teensy model
  stored two bytes per transfer as `difnift.ino` does. The host sent
  `11 22 33 44`; the Teensy stored `11 88 22 88 33 88 44 88` (the `88` left
  over from an earlier 16-bit write). An 8-bit transfer interleaves junk bytes
  and doubles the length; it doesn't shift the data by one byte.
- **The Teensy's read-then-write of the flag register: harmless.** `setFlag`
  and `clearFlag` read the flags and write them back. In
  [teensy.v](../verilog/teensy.v) the only stored bits are the Teensy's own
  (command in progress and clear all); "set transfer request" (bit 5) reads
  back as 0 and "clear busy" (bit 7) as 1, so writing back what was read never
  triggers either.
- **Finding 12, stale DMA requests: no data corruption seen.** With the fix
  undone, the card wins the bus once more after its last transfer and then
  disturbs the host's next I/O cycles, but in simulation every sector word
  still reached the Teensy intact.
- **Finding 9, write data timing:** would corrupt individual words rather than
  shift them, and Eric's 50Z gives about 50 ns of setup, so it probably isn't
  the cause either.
- **Teensy-to-FPGA register timing: ruled out on the bench.** `difnift.ino`
  raises WR almost immediately after putting data on the bus, which the
  simulation never modelled. On the first Rev P2 board, `difbench` ran
  200,000 random writes and reads at the firmware's timing, then 50,000 each
  at 0, 20 and 50 ns of write setup with 200, 100, 50 and 25 ns read strobes:
  no errors anywhere (room temperature, one board).

To try on real hardware:

- **Turn off the USB serial output.** The firmware prints for every command
  and sector, and prints the first word of each sector written. The data
  handshake waits for the Teensy, so slowness alone shouldn't lose data, but
  the extra time changes the timing and could expose a race or a host timeout.
  Comparing runs with and without the prints is a cheap test.
- **Look at a damaged sector.** Whether the shift is really one byte or one
  16-bit word points in different directions: a word shift means a transfer
  lost or repeated, a byte shift needs some byte-wide event.
- **Reproduce it with DIFDIAG's Int13 test** (writes, reads back and compares)
  while capturing the bus with a logic analyzer.
- **Copy test:** [tools/copytest](../tools/copytest/) has DOS batch files that
  copy test files D: -> C: -> D: 20 times, comparing every copy with `FC /B`,
  and `copytest.py`, which checks the results by reading `disk0.img` directly
  on another computer (read-only; nothing is mounted), so the files the
  DifNif wrote are checked without relying on its own read path. One of the
  test files has each 32-bit word holding its own offset, so a shift shows up
  as a number of bytes. On the first Rev P2 board in a 55SX, about 1 GB of
  copies produced no shifted or damaged data (see "Bring-up"). So either the
  bug was specific to Rev P1 or the 50Z (finding 1's floating reset, say), or
  it's rare enough to need longer runs or other workloads to show up.

## Mechanical

Confirmed against a real drive (IBM FRU 6128291, model WD-3158, 120 MB):

| Item | WD-3158 | Rev P1 board | Match |
|---|---|---|---|
| Connector tab width | 93 mm (measured) | 93.0 mm (Edge.Cuts) | Yes |
| Finger pitch | 2.54 mm, 36 per side | 2.54 mm, 36 per side | Yes |
| Finger length | about 7 mm (from photo); the gold stops about 1 mm short of the edge | 6.86 mm, running to the edge (Rev P2: starting 1.15 mm in) | Yes |
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
102 x 155 x 18.5 mm open frame with side rails that replaces the IBM drive
sled, and its four 2.5 mm holes (85 x 77 mm apart) match the board's four
2.7 mm mounting holes, for M2.5 screws. Rev P2 keeps those holes where they
were, so the plan is to print Eric's sled and test-fit it in a 55SX and a
Model 70 before designing anything new.

Carriers are cheap to print and reprint, so fitting them can be done by trial
without touching the PCB. The PCB only has to get the edge connector right
(width, pitch, key, thickness) and keep its mounting holes where the carrier
expects them.

To check during the test fit, per machine:

- How the drive is held in the bay (rails, screws, tray) and the positions of
  those mounting points
- Clearance above and below the drive, including the 55SX cable yoke
- Whether the tall parts (the socketed Teensy 4.1) and the microSD slot fit and
  stay reachable

## Verilog fixes

Findings 4, 5, 6, 9, 12 and 15 are fixed in `verilog/` (12 and 15 are
described with the findings).

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
Rerun with `--pos` after the finding 15 fix: everything still passes, with
T22 the tightest at 9.2 ns, the hold rows at 17.1 ns and every other margin
over 17 ns.
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
| 2 | U6-U10, U14: value `74LVC8T245`, Mouser `595-SN74LVC8T245PWR` (was 74LVC4245 / 771-74LVC4245APW-T). Same TSSOP-24 footprint and pinout; the existing supply wiring (pin 1 = 3.3 V, pins 23/24 = 5 V) is correct for this part. The schematic symbol is renamed `74LVC8T245`, with TI's pin names (A1-A8 on pins 3-10, B1-B8 on pins 21-14; Nexperia calls the same pins A0-A7/B0-B7), TI's datasheet link, /OE typed as an input, and the DIR notes confirmed against TI's function table. Netlist connectivity is identical before and after the rename. |
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
3. ~~Silkscreen.~~ Done: front reads "REV P2 / 09/26"; the back credits add
   "thenetworkinglab: Rev P2 changes".
4. **Debug header J4:** 10 of the 11 new debug connections are left unrouted
   for now (only `-CD SFDBK` on pin 11 is routed). DRC lists them as
   unconnected; the silkscreen still marks those pins "n".

### Fab files

`pcb_formfactor/fab/DifNifFormFactor-RevP2.zip`, the same 11 files as Eric's
RevP1 zip (9 Gerber layers with X2 attributes, separate PTH/NPTH Excellon
drill files in mm), exported with KiCad 9 after refilling the ground pours.

When ordering:

- **1.6 mm** FR-4, 2 layers.
- **Gold fingers** on the edge connector (hard gold if the board house offers
  it; ENIG is a cheaper second best for a board that won't be plugged in often).
- **Bevelled edge** on the connector side, typically 30-45 degrees.
- The fingers start **1.15 mm in from the edge**, so the bevel doesn't grind
  into the gold. PCBWay asked for this clearance for a 30 degree bevel leaving
  0.5 mm at the tip, and is trimming the ordered boards to match; the files now
  show it. The IBM drive's own fingers stop about 1 mm short of the edge.
- The key slot is a **1.0 mm routed slot** with 0.27 mm between it and the
  nearest finger copper. Check both against the board house's minimum slot
  width and copper-to-edge clearance.
- Look the files over in a Gerber viewer first (KiCad's GerbView works): the
  slot on Edge.Cuts, the narrowed fingers 2 and 3, the gap between the finger
  tips and the edge, and the silkscreen text.

## Bring-up

A staged checklist for the first Rev P2 boards, so that nothing reaches a PS/2
until it has passed on the bench. Stop at the first step that fails.

### How the board is powered

The edge connector's +5 V feeds the level shifters' bus side (VCCB), U11 and
U12 directly. It reaches everything else (`+5VD`: the Teensy's VIN and the
3.3 V and 1.2 V regulators, U4 and U5) only through the Schottky diode D3.

- The Teensy's USB connection, which is joined to its VIN, can power the
  Teensy, FPGA and regulators on the bench. D3 keeps it off the edge
  connector, so the bus side stays unpowered.
- With the board in a PS/2 and USB connected, the Mac powers `+5VD` (USB's
  5 V is higher than the PS/2's 5 V after D3's drop) and the PS/2 powers the
  bus side. Neither can feed the other, so USB serial output is safe to use
  in a machine.
- With the bus side unpowered, the SN74LVC8T245s put all their outputs in
  high impedance and U11/U12 have power-off protection on their inputs, so
  the board doesn't drive anything into an unpowered PS/2.

### The one dangerous mistake

**Inserting the board upside down in the Model 70.** Its riser socket isn't
keyed. Flipped, the PS/2's +12 V lands on signal pins and its +5 V on ground
pins, which could damage both the board and the machine. The 55SX socket is
keyed and the Rev P2 slot matches it, so the board can't go in wrongly there;
do the first live test in the 55SX.

For the Model 70, line the DifNif up against the original drive first: the
DifNif's component side (where `A01` is printed) goes the same way as the
side of the drive PCB that faces the drive casing. With the components facing
you and the fingers pointing away, A01 is on the right.

### Step 0: inspect and measure, unpowered

Inspect under magnification for solder bridges (especially the FPGA and the
level shifters), loose parts and damaged fingers.

Fingers are counted from the A01 end on the component side; A01 and A02 are
before the key slot, so A3 is the first finger after it. Each regulator (U4,
U5) has three legs on one side: with the fingers toward you, top is 5 V in,
middle is ground, bottom is the output (3.3 V on U4, 1.2 V on U5).

| Measure between | Expect | Stop if |
|---|---|---|
| A7 (+5 V) and A3 (GND) | some resistance | under about 10 ohms |
| U4 top leg (`+5VD`) and U4 middle leg | some resistance | under about 10 ohms |
| U4 bottom leg (3.3 V) and middle leg | some resistance | under about 10 ohms |
| U5 bottom leg (1.2 V) and middle leg | some resistance, possibly low | near 0 ohms |
| A19 and A27 (PS/2 +12 V) to GND and to +5 V | open | any reading |

Exact values depend on the chips; measure all four boards and look for the
one that disagrees.

### Step 1: fit the headers

J2 (needed for programming), optionally J4, and the two 24-pin socket strips
for the Teensy, soldered with the Teensy plugged into them to keep the rows
aligned.

### Step 2: first power, from USB, no PS/2

Plug the Teensy in with its **USB connector at the end next to the LEDs and
the "+" corner** (the socket's pin 1); backwards would short its VIN to
ground. Connect USB and keep a finger near the FPGA and regulators for the
first 30 seconds. Then measure:

| Point | Expect |
|---|---|
| U4 top leg | about 5 V |
| U4 bottom leg | 3.3 V |
| U5 bottom leg | 1.2 V |
| Finger A7 | about 0 V (D3 keeping USB off the bus side) |

### Step 3: program the FPGA

Wire an FT232H to J2 (table in the README) and run `make BOARD=ps2`, then
`make prog BOARD=ps2`, in `verilog/`. iceprog reads the flash chip's ID
first, which checks the SPI wiring.

With a scope: CDONE (J2 pin 2) steady at 3.3 V, 10 MHz at X1 pin 3, and an
11.92 Hz square wave (50 MHz / 2^22) at the FPGA end of R13, which also makes
LED D2 flicker.

### Step 4: bench test of the Teensy-to-FPGA link

Load [difbench/difbench.ino](../difbench/difbench.ino) on the Teensy and open
the Serial Monitor. It checks that the FPGA answers, all 16 data and 4
address lines (naming the Teensy and FPGA pins of any that fail), which FPGA
build and version are loaded, the Teensy-owned flags, the FPGA's clock and
the interrupt line, then runs 200,000 random writes and reads at `difnift.ino`'s timing
with a small table of timing margins. It can't test the PS/2 side, which is
unpowered on the bench. Bench only: not with the board in a PS/2.

First board (November 2026): rails 3.33 V and 1.21 V from USB, A7 at 0 V;
flash ID `BF 26 18`, programmed and verified with `iceprog -p` (which clears
the SST26VF080A's power-up write protection); every `difbench` check passed,
with no errors in the timing table even at 0 ns write setup and a 25 ns read
strobe.

### Step 5: first time in a PS/2 (55SX)

1. **No Teensy, no USB.** (If the Teensy is soldered in rather than
   socketed, leave it in and just leave USB unplugged; the PS/2 then powers
   it through D3.) With the original drive removed and the machine
   unplugged, fit the DifNif, then power on. The PS/2 should start and
   complain about the fixed disk; the card starts disabled until the BIOS
   configures it. Measure 5 V at A7 and the regulator outputs, keep the run
   short, and watch for heat.
2. **With the Teensy and USB serial.** Load `difnift.ino` and have the
   Reference Diskette ready, since the machine will probably want to be
   reconfigured. Commands from the BIOS appearing in the serial output mean
   the board and the PC are talking. With an FPGA built before the finding
   15 fix, switch the PS/2 on with USB unplugged and plug it in afterwards.

First board, 55SX (November 2026): POSTs; the Reference Diskette's
configuration found the drive as "Integrated Fixed Disk and Controller"
(primary address, arbitration level 5), and the serial log showed POS info,
seek, soft reset, and DMA sector reads and writes. DOS 6.22 partitioned and
formatted the disk. A cold boot with USB connected hung, which led to
finding 15.

With the finding 15 fix:

- **Booting:** DOS 6.22 boots from the DifNif from cold and warm, with USB
  connected or not.
- **Copy test:** the test in [tools/copytest](../tools/copytest/) ran 10
  rounds, then overnight (about 9 hours) as `FOREVER.BAT`:
  - 196 rounds, about 1 GB written and 3 GB read, with SMARTDRV off.
  - All 1179 `FC /B` comparisons identical.
  - Every file the DifNif wrote has the right SHA-256 when read straight
    from `disk0.img` on a Mac.
  - CHKDSK clean on both drives.
- **Speed:** DiskMeter measures about 665 KB/s with Eric's firmware and about
  705 KB/s with the faster register port and read-ahead in this fork's
  `difnift.ino` (see [CHANGELOG.md](../CHANGELOG.md)). For comparison, an MCA
  IDE adapter (McIDE) in the same machine measures about 1.9 MB/s.
- **Earlier problems:**
  - During the DOS install, one update to `AUTOEXEC.BAT`'s directory entry
    was lost; CHKDSK recovered it as `FILE0001.CHK`. Probably finding 17.
  - One warm-boot hang after FDISK, before the finding 15 fix, also hasn't
    recurred.

Only then the Model 70, after checking the orientation as above.

First board, Model 70 (November 2026), with the other adapters removed:

- **Orientation:** checked against the original drive as above. No damage,
  and the board powered up normally.
- **With FPGA v2026.11.18-1:** POST error 165, and the Reference Diskette
  (v1.12) asked for a description file for slot 4. DEBUG read the ID as
  FF9F, which led to finding 16.
- **With FPGA v2026.11.18-2:** DEBUG reads `9F DF 78 00`, the Reference
  Diskette configures the drive, and DOS boots from it.
- **Speed:** DiskMeter random 960 KB/s, sequential 990 KB/s, buffered
  998 KB/s, seek 0.25 ms. That's with the same firmware that gives 705 KB/s
  in the 55SX, so most of the time per word is the host's DMA, not the
  Teensy.

## Speed: the sector buffer

The original data path moves one 16-bit word per handshake: the Teensy
writes DREG and sets "transfer request", the card asks for DMA, the planar
arbitrates and transfers the word, and only then does the Teensy see the
request clear and start on the next word. That came to about 2.8 us per word
in the 55SX and 2.0 us in the Model 70 (about 705 and 990 KB/s).

[verilog/sectorbuf.v](../verilog/sectorbuf.v) adds two one-sector halves
(256 words each) in the FPGA's block RAM, on the 50 MHz clock:

- **Disk read:** the Teensy writes a whole sector into a free half through
  port register 14 (about 40 us), then hands it to the host side with a
  flag strobe. The host's DMA empties it while the Teensy loads the next
  sector into the other half.
- **Disk write:** the Teensy arms up to two halves; DMA fills them, and each
  full half is flagged to the Teensy, which reads it out and frees it.
- **Bidding:** while the buffer holds the next word (or room for it), the
  card keeps its DMA request up through each transfer instead of dropping it
  until the Teensy catches up. The buffer moves on within about 100 ns,
  well before the next transfer can reach the card. After the last word it
  stops, as finding 12 requires.
- **Interface:** the flag register's spare bits 11-15 hold the mode and
  direction (stored), the strobes, and the status bits. They read 0 with the
  buffer off, and with it off the old DREG/TREQ path is unchanged, so older
  firmware works with the new FPGA. The firmware detects the buffer by
  writing the mode bit and reading it back, and its `b` serial command
  switches it off for comparison.

**Simulation:** new tests move three sectors each way, with a fast Teensy
and with one slow enough that the host has to wait, with and without a
competing DMA device, checking every word and that the card stops bidding
after the last one. Two deliberate bugs (bidding after the last word, a
stale prefetched word) were both caught. The full matrix passes; it now
takes about 9 minutes. Simulated time per word at the 55SX's cycle went from
1.83 to about 1.1 us.

**Hardware** (DiskMeter random / sequential / buffered, KB/s):

| Machine | Before | With the buffer | Copy test |
|---|---|---|---|
| 55SX | 686 / 671 / 690 | 1107 / 1100 / 1151 | 120 of 120 identical |
| Model 70 | 960 / 990 / 998 | 1110 / 1062 / 1108 | 120 of 120 identical |

The 55SX gained about 60%, the 70 about 10%, and both now land near
1.1 MB/s although the 70's bus is faster. So the limit is no longer the
per-word bus transfer, and is probably something both machines share:
per-command overhead (the ATN, command block, status block and interrupt
exchange for each command) or the SD card's latency at the start of each
command. The firmware's debug pins now mark each command (Teensy pin 0,
high from the ATN command to the host's EOI) and each wait on the SD card
(pin 1), for measuring that with a scope.

### Where the time goes (scope, Model 70)

Measured on 19 November 2026 with a Rigol DS1074Z Plus while `READLOOP.BAT`
copied `D:\T2.BIN` to `NUL` over and over, with firmware and FPGA
v2026.11.18-3 and the sector buffer on. The guess above was wrong: the
limit is still the DMA, not per-command overhead or the SD card.

**Probe points.** J4 pins 4-14 carry bus-signal labels in the schematic but
have no copper on Rev P2 (only pins 3, 11, 15-19 and 20 are routed), so they
can't be probed. Instead, `make BOARD=ps2 PROBES=1` builds a debug image
(into `build/ps2-probes/`) that copies bus signals onto the SD card pins,
which are routed to J4. The SD socket J3 must be empty. Not for releases.

| J4 pin | Normal build | `PROBES=1` |
|---|---|---|
| 3 | low | `-CMD` |
| 19 | low | `ARB/-GNT` |
| 18 | low | `-PREEMPT` on the bus |
| 17 | low | the card is driving `-PREEMPT` (high = requesting) |
| 16 | low | a DMA cycle to the card |
| 15 | low | the card wants the bus or has the next word ready |

Ground is J4-20 (the PS/2 chassis works too). `tools/timing_budget.py --pos
--probes` checks that build; it passes, smallest margin 8.7 ns on T22.

**One command, at 1 ms/div** (Teensy pin 0 and pin 1, normal build). DOS reads
`T2.BIN` in commands longer than the 11 ms screen. At the start the Teensy
reads 32 sectors from the SD card in one go, in 720 us (about 22 MB/s), and
the host waits for that. After that the Teensy copies one sector from its
own RAM into the buffer every 0.45 ms, which is the rate the host empties
it: 512 bytes per 0.45 ms, about 1.1 MB/s, or 1.8 us per word. The SD card
is about 5% of the time.

**One word, at 500 ns/div** (`PROBES=1`):

| Part | Time |
|---|---|
| Arbitration (`ARB/-GNT` high) | 450-950 ns; the longer ones have another 360 ns bus cycle (probably the CPU or refresh) inside them |
| Grant, until the DMA controller's I/O read | about 370 ns |
| I/O read from the card (`-CMD` low) | about 100 ns |
| Memory write (`-CMD` low) | about 200 ns |
| Until the next arbitration | about 180 ns |
| **Per word** | **1.4-1.9 us** |

- The card wins every arbitration. It never needs `-PREEMPT` (J4-17 stays
  low), because the Model 70 re-arbitrates after every DMA transfer anyway
  (finding 13).
- The card always has the next word ready. Its request (J4-15) stays high
  except for a dip of about 30 ns, about 70 ns after each I/O read: the
  transfer's pending flag clears a clock or two before the buffer's next
  word is latched. The dip falls in the middle of the grant, far from the
  next arbitration, so it does no harm now. It needs fixing for burst mode,
  where the request must stay up between words.
- 256 words at about 1.6 us is about 410 us per sector, close to the 0.45 ms
  measured per sector, so the sector boundaries cost little.

So only about 300 ns of each word moves data. The rest is arbitration and
the DMA controller's setup and dead time for each grant, and burst transfers
would remove most of it.

## Speed: burst DMA

IBM's own DBA-ESDI drives transfer by burst DMA: 64-word bursts with
optional pacing gaps, at about 500 ns per word (IBM DASD Storage Interface
Specification, Micro Channel, Rev 2.2, section 3.4, at
[ardent-tool.com](https://ardent-tool.com/docs/pdf/j_mcspec.pdf)). In a burst
the card holds `-BURST` and the DMA controller moves word after word without
arbitrating again.

**IBM's rules** (PS/2 Model 50/60 Technical Reference, section 2, Figures
2-28, 2-29, 2-42, 2-43 and 2-46):

| | Rule | Limit |
|---|---|---|
| T43 | the winner pulls `-BURST` low after `ARB/-GNT` goes low | 50 ns max |
| | the DMA controller checks `-BURST` at the end of each I/O cycle and stops when it's high | |
| T55/T56 | the card releases `-BURST` by its last I/O cycle, high before that cycle's `-CMD` ends | 40 ns max from its status; 35 ns min before `-CMD` rises |
| T54 | released after `-TC` | 30 ns max |
| T40 | bus given up after another device asserts `-PREEMPT` | 7.8 us max, or an NMI and channel time-out |

**The design** ([verilog/mcabus.v](../verilog/mcabus.v), FPGA v2026.11.19-1):

- The card pulls `-BURST` low at the grant when the sector buffer holds two
  or more words (or two or more spaces, for a disk write), nobody else is
  waiting, and the Teensy allows it (register 15, bit 0). The decision is
  latched on the grant edge, and `-BURST` comes from it through logic only.
- It lets go only just after a transfer has gone through the buffer, about
  100 ns after that I/O cycle's `-CMD` rose and two bus cycles before the
  next I/O cycle can end, so the DMA controller does exactly one more
  transfer. It lets go when that one will use the last word (or space)
  ready, when another device asserts `-PREEMPT`, after 64 words (as IBM's
  drives do), or once `-TC` has been seen. `-TC` also gates `-BURST`
  directly, for T54.
- It doesn't burst without the sector buffer, so older firmware gets the old
  behaviour.
- The buffer's "word ready" signal now comes from the half's state instead of
  the prefetch, which removes the 30 ns dip in the card's request seen on the
  scope.

**Simulation:**

- The testbench's DMA controller now bursts while the card holds `-BURST`,
  checking it at the end of each I/O cycle.
- In the burst tests memory refresh runs every 15 us. It runs during
  arbitration and asserts `-PREEMPT`, so bursts get preempted as they would
  in a PS/2.
- Every rule above is checked as a failure, and so is `-BURST` low when
  arbitration starts, or asserted where bursts aren't allowed.
- The new tests:
  - burst reads and writes, fast and slow Teensy, with a competing device;
  - `-TC` in the middle of a burst;
  - the old path with bursts allowed, which must not burst.
- Four deliberately broken versions of the logic are each caught:
  over-bursting, ignoring `-TC`, ignoring `-PREEMPT`, and releasing at any
  moment.
- The full matrix passes with POS enabled on the bridged and Rev P2 boards.
  It now takes about 21 minutes.
- Simulated reads at the Model 70's cycle went from 1.04 to 0.57 us per word.

**Timing budget** (`tools/timing_budget.py --pos`):

| Rule | Margin |
|---|---|
| T43 | 21 ns |
| T54 | 1.2 ns |
| T56 | 215 ns |

The T54 figure stacks the slowest logic path in the design with doubled
buffer delays. In use, `-TC` arrives after the card has already let go,
because the DMA count matches the command's sectors.

**Hardware** (Rev P2, firmware and FPGA v2026.11.19-1; DiskMeter 1.3,
random / sequential / buffered, KB/s):

| Machine | Sector buffer only | Burst DMA | Copy test |
|---|---|---|---|
| 55SX | 1107 / 1100 / 1151 | 2108 / 2266 / 2305 | 120 of 120 identical |
| Model 70 | 1110 / 1062 / 1108 | 1956 / 2067 / 2102 | 120 of 120 identical |

Other adapters in the same machines, measured by Tim with DiskMeter 1.3:

| Adapter | 55SX | Model 70 |
|---|---|---|
| McIDE | 1867 / 1876 / 2005 | 2477 / 2477 / 2477 |
| IBM SCSI ("Tribble") | | 2041 / 2171 / 2089 |
| IBM SCSI with cache ("Spock") | | 1814 / 1709 / 1954 |
| MCS-350 | | 398 / 432 / 426 |

The DifNif is now faster than the McIDE in the 55SX and level with IBM's
SCSI adapters in the Model 70. In the 70 the McIDE is still about 20%
ahead: it's the same on all three tests and gains a lot from the 70's
faster processor, which fits programmed I/O. The DifNif gets nothing from
the faster processor, and is a little slower in the 70 than in the 55SX.

**Other timings** with [tools/copytest/TIMING.BAT](../tools/copytest/TIMING.BAT)
(five of each, on the 1 MB `T2.BIN`):

| | 55SX | Model 70 |
|---|---|---|
| `COPY` to `D:` (read + write) | 6.9 s | 6.0 s |
| `FC /B` compare | 133 s | 74 s |

- `FC /B` is CPU-bound. It's most of each round of the copy test, which is
  why rounds take about 2.5 minutes in the 55SX and 1.3 in the 70.
- Copies take about the same time in both machines, about 1.2-1.4 s per MB,
  so writes are probably near 1 MB/s. DiskMeter only measures reads. Writes
  are the likely next target.
- (`COPY` to `NUL`, also in the batch file, finishes faster than the bus
  could deliver the data, so it doesn't seem to read the whole file. It
  isn't a useful measurement.)

## Suggested next steps

Done: DMA in the testbench, the timing check, Rev P2 schematic and layout,
assembled boards from PCBWay, Eric's printed sled, bring-up in a 55SX
(including the overnight copy test), the Model 70 (finding 16), the sector
buffer and burst DMA.

1. **Rev P3 board change:** a separate direction line for U7 (finding 16),
   and route J4 pins 4-14 to their labelled signals (or drop the labels).
   Also worth considering: a way for the firmware to see the PS/2's 5 V
   going away, so it can finish writing before it loses power.
2. **Speed:** with burst DMA (see "Speed: burst DMA") reads run at about
   2.0-2.3 MB/s in both machines. The simulated bus does better than that,
   so the limit has moved again. Next:
   - **Writes:** measure them properly. The copy timings suggest about
     1 MB/s.
   - **Reads:** take a scope capture during bursts, with the `PROBES` build,
     to see the gaps between bursts and whether the buffer runs dry.
   - **Smaller gains:** start the SD read for the first sectors of a command
     sooner (the 720 us wait).
3. **The one-byte shift:** keep the copy test running on other machines and
   with other workloads (Windows 3.1, large compiles); run DIFDIAG's Int13
   test.
4. **Other adapters:** a 3Com EtherLink/MC wasn't recognised after
   reconfiguring the 55SX with the DifNif fitted. Probably the adapter's ADF
   or its configuration rather than the DifNif, but not yet checked.
5. **ThinkPad 700C:** the FPGA changes also apply to the ThinkPad build and
   haven't been tried there.

## Toolchain status

oss-cad-suite 2026-09-23 build (Yosys 0.69, nextpnr 0.11.1, Icarus Verilog 14
devel), installed in `/opt/oss-cad-suite`.

- **FPGA build (`make` in `verilog/`)** works unchanged. The nextpnr and icetime
  timing estimate is about 80 MHz worst case, against the 50 MHz internal clock.
  The Makefile now takes `BOARD=thinkpad` (the default) or `BOARD=ps2`
  (the 72-pin board, POS registers on) and builds each into `build/<board>/`.
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
  card must never answer those cycles. Since FPGA v2026.11.19-1 the DMA
  controller also does burst transfers while the card holds `-BURST`, and
  memory refresh preempts them (see "Speed: burst DMA").

Run `verilog/run_sim72.sh` (about 50 seconds for 162 simulations;
`run_sim72.sh quick` runs one delay set). Results **before** the Verilog fixes:

| Board | POS | Timing | Result (all three machines) |
|---|---|---|---|
| As built | either | either | Every register test fails (finding 1) |
| Bridged | bypass | typical | Mailboxes pass; POS tests fail (finding 10); 3518 answered (finding 5) |
| Bridged | enabled | typical | All pass except 3518 answered (finding 5) |
| Bridged | either | IBM limits | Host writes fail on 7 of 8 delay sets (finding 9); reads pass |

**After** the fixes, the bridged board and Rev P2 pass everything with POS
enabled, including DMA in both directions with competing devices and a
channel reset in the middle of use (finding 15). See "Verilog fixes" above.

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
