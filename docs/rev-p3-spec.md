# Rev P3: draft specification

A draft for the next PS/2 board, before any schematic work. Rev P3 is the
FPGA-only design (docs/fpga-only.md) on a board made for it: no Teensy, USB-C
for programming and a serial console, a full-size SD socket, activity LEDs,
and the fixes Rev P2's bring-up called for. The bus side doesn't change:
`mcabus.v`, the sector buffer and burst DMA are what's been checked against
IBM's timing and tested in the 55SX and Model 70.

## Keep from Rev P2

- **Outline and edge connector:** the 72-pin DBA-ESDI edge (2 x 36), key slot,
  gold fingers and bevel as in Rev P2, so the board still fits the same
  sled (mech/difnif_PS2_drive_sled.STL) and both the 55SX's keyed cable and
  the Model 70's riser.
- **Bus interface parts:** the SN74LVC8T245 transceivers and the buffers
  (U6-U12 on Rev P2), the open-drain drivers for -BURST, -PREEMPT, ARB and
  IRQ14, the oscillator and the 3.3 V and 1.2 V regulators.
- **FPGA:** the iCE40HX (TQ144) and its SPI configuration flash. The
  processor build uses 4939 of 7680 logic cells, 96 of 107 I/O pins and 31
  of 32 block RAMs.

## Changes

### Remove the Teensy

Drop the Teensy socket (U13) and its 25 FPGA connections: 16 data, 4 address,
read, write, clock, interrupt and one spare. With the 11 pins unused now, that
leaves about 36 FPGA pins for the additions below.

### USB-C: programming and serial console

One USB-C port with an RP2040 as the board's USB chip, as on the pico-ice and
pico2-ice boards (iCE40 or similar plus an RP2040/RP2350), whose open-source
firmware already does most of this:

- **Programming:** the board appears as a USB drive; copying an FPGA image
  onto it writes the configuration flash (the RP2040 drives the flash's SPI
  lines, CRESET and CDONE, as the FT232H does through J2 now), then lets
  the FPGA boot. `make prog` becomes that copy (or `picotool`/`dfu-util`).
- **Serial console:** a USB serial device bridged to two FPGA pins, the
  processor's 1 Mbaud log out and its keys in, replacing teensy_log and the
  FT232H. Both use the operating system's own drivers.
- **Its own firmware** goes on through the RP2040's USB bootloader in ROM
  (hold BOOTSEL while plugging in), so the board can't be bricked from USB
  and needs no other programmer. Fit a BOOTSEL button and SWD test pads.
- **Parts:** the RP2040, a QSPI flash for its firmware (2 MB is plenty), a
  12 MHz crystal and decoupling.
- **Power-up:** the RP2040's pins come up as inputs with weak pull-downs.
  CRESET and the configuration flash's chip select need firm pull-ups (and
  series resistors on the shared SPI lines), so the FPGA boots from its
  flash whether the RP2040 is running, held in reset or unpowered, and the
  RP2040 must leave those lines undriven except while programming.
- **Room for later:** reading or replacing disk0.img over USB while the PS/2
  is off (the SD card's lines would need to reach the RP2040 too, with the
  FPGA letting go of them; decide before the schematic), watching the
  power-fail signal, a status display, a small logic analyser on spare
  pins.
- 5.1 kOhm pull-downs on CC1 and CC2 so USB-C sources supply 5 V; USB 2.0
  full speed; ESD protection on D+/D- (for example a USBLC6-2).
- Keep a 2 x 4 programming header footprint (J2's pinout), unfitted, as a
  fallback if the USB side doesn't work on a new board.

Alternative: an FTDI FT2232H (as on the iCEBreaker), one channel for `iceprog`
and one for the serial port. No firmware at all and `make prog` unchanged,
but about $4-5 more per board and nothing beyond those two jobs.

### Power

- The board runs from the PS/2's +5 V in the machine, or from USB-C on the
  bench. OR the two with ideal diodes (or Schottkys), so neither can feed the
  other: USB 5 V must never reach the PS/2's supply rail, or the other way
  round. The bus-side transceivers (VCCB) stay on the PS/2's +5 V only, so
  on USB power the board doesn't drive the edge connector.
- This replaces Rev P2's "5 V on the Teensy socket's VIN pin" for bench
  programming.
- **Power-fail warning:** a comparator (or a supervisor chip) on the PS/2's
  +5 V to an FPGA pin, set a little below 4.75 V, so the firmware knows
  power is going before the 3.3 V rail does. Writes already finish before
  their completion interrupt; this would let the firmware stop starting
  new card commands, and log it.

### SD card

- **A full-size SD socket** in place of the microSD (J3), with its
  card-detect and write-protect switches on FPGA pins. Full-size cards and
  adapters, and extension cables that bring the slot out to the case, are
  then possible.
- Keep the 4-bit wiring and pull-ups, and short, matched traces to the
  socket. Check the read sampling margin (`sample_late`, docs/fpga-only.md)
  with an extension cable fitted, since the cable adds delay.
- **Write-protect:** the firmware makes the drive read-only when the switch
  is on (writes fail with a write fault), for keeping a known-good OS image.

### LEDs

- **Activity** (green): on while a command is running, driven by the FPGA.
- **Status** (red or amber): no card, image unusable, card errors; the
  firmware already has codes for these (LEDS in fw/main.c).
- A 2-pin header in parallel with the activity LED, for an LED in the
  PS/2's bezel or front panel.

### Rev P2 findings to fix

- **U7's direction (finding 16):** give the upper data byte's transceiver
  its own direction or output-enable line, instead of sharing U6's, so 8-bit
  reads leave D8-D15 alone. The FPGA currently copies the byte to both lanes
  to work around it.
- **Test points:** route real test points (or a small header) for -CMD,
  ARB/-GNT, -PREEMPT, -BURST, -TC and a few FPGA spare pins. On Rev P2, J4's
  labelled pins 4-14 have no copper, and the scope work had to borrow the SD
  card lines or the Teensy socket.
- **-TC and -BURST:** keep their FPGA pins, and the buffers between them and
  the connector, close together. T54 passes with 3-6 ns to spare now; a
  shorter path keeps it that way.

## FPGA pin budget

| Use | Pins |
|---|---|
| Freed: Teensy socket | +25 |
| Unused on Rev P2 | +11 |
| USB-C UART (out, in) | -2 |
| SD write-protect | -1 |
| Power-fail | -1 |
| U7 direction / enable | -1 |
| LEDs (activity, status; Rev P2 has two) | 0 |
| Test points on spare pins | -4 |
| **Left** | **27** |
| QSPI PSRAM, if option A below | -6 (leaving 21) |

## Open questions

- **SD card over USB:** wire the card to the RP2040 as well, for copying
  disk0.img over USB while the PS/2 is off, or leave it for a later board?
- **Processor RAM:** see "FPGA and RAM" below.
- **USB-C position:** reachable with the board in its sled in each machine
  (the 55SX's drive bay and the Model 70's riser), or only on the bench?
- **SD extension cable:** which cable, and is a sampling margin check on
  the bench enough, or a test in each machine?

## FPGA and RAM

The processor build already uses 31 of the iCE40's 32 block RAMs, 12 KB of
them for the firmware, so a P3 with more firmware features needs more RAM.
Other iCE40s don't help: an iCE40HX8K in a larger package has more pins but
the same 32 block RAMs, and the iCE40UP5K has 128 KB of extra RAM but only
39 pins. The board will be assembled by a service either way, so package
(QFP or BGA) isn't a constraint. Two options:

**A. Keep the iCE40, add a QSPI PSRAM.** An APS6404L-3SQR-SN (8 MB, SOP-8,
about $2-3) on four FPGA pins plus clock and chip select (6 pins, within
the budget above). The processor runs from the block RAM as now and uses
the PSRAM through a small cache, or for data only (larger buffers, a FAT
cache, a log). Everything else stays as it is: board, FPGA, timing work.
Costs some logic cells for the PSRAM controller and cache; 2700 are free.

**B. Move to a Lattice ECP5** (LFE5U-25F, caBGA-256, 0.8 mm pitch):

- About 126 KB of block RAM (8 times the iCE40's), 24K logic cells and 197
  I/O pins, so RAM, logic and pins all stop being limits.
- The same open-source tools (yosys, nextpnr-ecp5, prjtrellis), so the
  Verilog, simulations and `timing_budget.py`/`sdfpath.py` carry over; the
  iCE40 primitives (`SB_IO` for the pads, `SB_PLL40_PAD`) change to the
  ECP5's. Programmed through the RP2040 (or an FT2232H with
  `openFPGALoader` or `ecpprog`).
- The board needs a 1.1 V core supply and 2.5 V auxiliary supply as well as
  3.3 V, and the BGA probably needs a 4-layer board.
- Price (November 2026, quantity 1): about $16-21 at Western distributors
  against about $10 for the iCE40HX4K-TQ144 at Digi-Key, so about $6-12
  more per board, plus a regulator and the extra layers; LCSC lists the
  ECP5 at about $5.50, so through an assembly service that buys from LCSC
  it may cost no more than the iCE40.

Intel's MAX 10 (EQFP-144, configuration flash on-chip) and AMD's Spartan-7
also have more RAM, but their tools (Quartus, Vivado) don't run on macOS
and nothing of the timing tooling would carry over.

Recommendation: neither, yet. The firmware fits in 12 KB today, and the P3
additions hardly add to it (the RP2040 handles USB itself; LEDs,
write-protect and power-fail are a few lines each). Keep the iCE40 and the
2-layer board, and put option A's PSRAM footprint on the board unfitted:
six pins and no cost until the firmware needs it. B is the fallback if RAM,
logic or pins ever run out; it costs an extra regulator, probably two more
board layers and BGA assembly.

## Cost

The aim is value, not a product: a target of about $60 per assembled
board, parts and assembly included, for a run of a few boards. The Teensy
4.1 (about $31) was the largest single part on Rev P2, and the FPGA-only
design has already removed it. For the rest:

- 2-layer board and the iCE40HX4K-TQ144 (about $10), as on Rev P2.
- The RP2040 (about $1-1.50 with its flash, plus a crystal) for USB-C,
  about $4 a board less than an FT2232H, and with room for later features.
- The PSRAM footprint unfitted (about $2-3 if it's ever needed).
- The full-size SD socket and LEDs cost about the same as Rev P2's microSD
  socket.

Prices are quantity-1 distributor prices from November 2026; assembly
services that buy from LCSC are often cheaper. Gold fingers and the
bevelled edge are a large share of the bare board's cost, and setup fees
are shared across the boards in an order, so a larger run costs less per
board.

## Checking it before ordering

As for Rev P2: update `difnif.pcf` and `difnif_top.v` for the new pins first,
then run the bus simulations (`./run_sim72.sh`, `./run_sim72.sh cpu`) and
`tools/timing_budget.py --pos --cpu`, and check the schematic's netlist with
`tools/check_board.py` before layout.
