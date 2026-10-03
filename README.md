# DifNif: DBA-ESDI Solid State Drive Replacement for IBM PS/2 Computers

DifNif is a drive emulator that replaces an IBM DBA-ESDI hard drive. 
It was designed by Eric Schlaepfer ([schlae/difnif](https://github.com/schlae/difnif)),
with the project's initial release intended to replace the hard drive in 
IBM ThinkPad 700C laptops, also including an alpha version of a PS/2 desktop 
form-factor emulator.  This fork is an attempt to complete 
the development of the 72-pin board for PS/2 desktops; the changes are 
listed in [docs/formfactor-review.md](docs/formfactor-review.md).

And before you ask: the name 'DifNif' comes from DF9F, 
the Micro Channel adapter ID that IBM's DBA-ESDI drives report.

**Status: alpha.** See "Status" below before building anything.

## Background

IBM PS/2 computers from the late 1980s and early 1990s typically used a
disk interface called DBA-ESDI (Direct Bus Attach - Enhanced
Small Device Interface). A DBA-ESDI drive has its controller integrated
with the drive electronics, and sits directly on the Micro Channel
bus, more like an IDE drive, but with its own register interface.

These drives are becoming rare because many have failed mechanically or
been damaged by leaking capacitors. MCA SCSI cards are an alternative on some
machines, but are getting expensive and difficult to find as well and 
aren't compatible with all PS/2s. Some PS/2s also need an IML (initial microcode load)
partition on their disk, and can only load it from a DBA-ESDI drive.

DifNif uses a Teensy 4.1 microcontroller and a Lattice iCE40 FPGA to implement the
DBA-ESDI interface, and stores the disk as an image file on an SD card. 

## Two boards, one design

The boards share the FPGA design (`verilog/`) and the Teensy firmware
(`difnift/`), and differ in how they connect to the computer.

| | ThinkPad board | PS/2 desktop board |
|---|---|---|
| Folder | [pcb_thinkpad](pcb_thinkpad/) | [pcb_formfactor](pcb_formfactor/) |
| Machines | ThinkPad 700C | PS/2 desktops that take a 72-pin DBA-ESDI drive, such as the 50Z, 55SX and 70 |
| Connector | 2 mm header, wired to the flex cable taken from a stock 700-series 2.5" drive | 72-pin (2 x 36) card edge, plugging straight into the drive socket |
| Carrier | [mech/df9f_carrier.STL](mech/df9f_carrier.STL) | [mech/difnif_PS2_drive_sled.STL](mech/difnif_PS2_drive_sled.STL), replacing the IBM drive sled |
| FPGA build | `make` | `make BOARD=ps2` |

There are also debugging aids:

- [pcb_finglonger](pcb_finglonger/), the "Fing Longer", for the ThinkPad board.
  It fits a 3D-printed sled ([mech/finglong.STL](mech/finglong.STL)) held by two
  clips ([mech/2finglong.STL](mech/2finglong.STL)). One acts as an extender
  that brings the connector forward, and a second as a breakout for logic
  analyzer probes on the bus lines.
- For the 72-pin board, a card in a spare Micro Channel slot gives access to
  the bus signals; Eric used a spare
  [Snark Barker MCA](https://github.com/schlae/snark-barker-mca).

## Status

- **ThinkPad board:** Eric's board works in a ThinkPad 700C,
  running Windows 3.1. The FPGA design has since been changed in this fork (see
  [docs/formfactor-review.md](docs/formfactor-review.md)), and those changes
  have **not** been tested on a ThinkPad. Eric's original files are on the
  `main` branch.
- **PS/2 desktop board, Rev P1** (Eric's): register communication didn't work
  reliably in a 50Z.
- **PS/2 desktop board, Rev P2** (this fork): fixes the problems found in a
  review of Rev P1, including a floating reset input that is the likely cause
  of the 50Z problem. The fixes have been checked in simulation against IBM's
  bus timing, but **Rev P2 has not yet been built or tested on real hardware.**
- Both boards' original design powers the 74LVC4245A level shifters the wrong
  way round, putting 5V on a supply pin rated for 4.6V at most. Rev P2 uses
  the TI SN74LVC8T245 instead, which accepts 5V on either side and fits the
  same footprint. The same swap should work on the ThinkPad board but hasn't
  been tried.
- Known bugs: writes occasionally produce a sector shifted by one byte; the
  cause hasn't been found.

[docs/formfactor-review.md](docs/formfactor-review.md) has the full list of
findings and changes, and [docs/verify-findings.md](docs/verify-findings.md)
explains how to check each one against Eric's original files and IBM's
documents.

**Data loss:** this is a hobby project with no formal testing. Keep backup
copies of all disk images.

## Building

This is an advanced project. It needs surface-mount soldering (or an
assembly service), two programmable devices to load, and probably debugging
with an oscilloscope and a logic analyzer.

### Boards

Each board folder has a `fab/` folder with Gerber and drill files. For the
Rev P2 PS/2 board, `pcb_formfactor/fab/` also has a parts list
(`DifNifFormFactor-RevP2-BOM.csv`) and a placement file
(`DifNifFormFactor-RevP2-positions.csv`) for an assembly service. The
ordering notes in [docs/formfactor-review.md](docs/formfactor-review.md)
cover board thickness, gold fingers and the bevelled edge.

The Teensy 4.1 plugs into two 24-pin female header strips (2.54 mm pitch, rows
15.24 mm apart). The SD card goes in the Teensy's own card slot.

### Teensy firmware

Load [difnift/difnift.ino](difnift/difnift.ino) with the Arduino IDE and
PJRC's Teensy board support, selecting Teensy 4.1.

For register loopback testing with DIFDIAG, comment out the two lines at the
start of `loop()` that call `esdiReset()` and `mainLoop()`. The serial monitor
then accepts the single-letter test commands listed at startup.

### FPGA

The FPGA design is built with the open-source iCE40 tools (yosys, nextpnr and
icestorm, for example from
[oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build)). In
`verilog/`:

    make                  # ThinkPad board
    make BOARD=ps2        # PS/2 desktop board

The PS/2 build turns on the POS registers, so the card reports its `DF9F`
ID. Each build goes into its own folder, `build/thinkpad/` or `build/ps2/`.

The FPGA loads its program from an SPI flash chip on the board, which is
written through header J2 with an FTDI FT232H or FT2232H adapter and
`iceprog`:

    make prog BOARD=ps2

| J2 pin | Signal | FT232H pin |
|---|---|---|
| 1 | Flash chip select | AD4 |
| 2 | CDONE | AD6 |
| 3 | SCK | AD0 |
| 4 | CRESET | AD7 |
| 5 | Flash data out (CIPO) | AD2 |
| 6 | GND | GND |
| 7 | Flash data in (COPI) | AD1 |
| 8 | +3.3 V (board supply, leave unconnected) | |

The board must be powered while programming. The Teensy's USB connection can
power it on the bench.

The source files are:

- `difnif_top.v`: top level, wiring up the other modules.
- `mcabus.v`: the Micro Channel bus interface, with the ESDI registers, POS
  registers and DMA.
- `teensy.v`: the register interface that lets the Teensy, in its own clock
  domain, reach the ESDI mailbox registers and flags.

The self-checking bus simulation for the PS/2 board is `difnif72_t.v`, run with
`./run_sim72.sh` (needs Icarus Verilog).

## Drive images

The Teensy firmware uses a file called `disk0.img` in the root of the SD card.
Its size must be a whole number of megabytes, up to 1023 MB; for example, for
120 MB:

    dd if=/dev/zero of=disk0.img bs=1048576 count=120

Then use the machine's reference disk to create the IML and reference
partitions, and install DOS to partition and format the rest of the disk.

## DIFDIAG

[difdiag/DIFDIAG.CPP](difdiag/DIFDIAG.CPP) is a diagnostic utility for
DBA-ESDI drives that works directly with the drive hardware at a very low
level. Don't use it on drives containing data you care about, but it can help
with troubleshooting dead drives. It compiles with Borland C++ using the Large
memory model.

Menus:

- **Settings:** DMA configuration. Autoconfigure tries to get the DMA channel
  through a BIOS call, and failing that from the extended BIOS data area
  (EBDA). The channel can also be set by hand, or PIO mode chosen instead.
- **Mailbox tests:** not for real drives. With DifNif in loopback test mode
  (see "Teensy firmware"), runs millions of register cycles to look for timing
  problems.
- **Low level commands:** the lowest-level commands, which must be run in the
  sequence given by the flowcharts in the
  [ESDI spec](https://ardent-tool.com/docs/pdf/j_mcspec.pdf).
- **Drive information:** query commands; generally safe on real drives.
- **POST tests:** modelled on the drive tests run by the PS/2 BIOS.
- **Run diagnostics:** the DBA-ESDI interface's own low-level hardware
  diagnostic command.
- **Int13 tests:** destructive. Writes data through the BIOS int13 routines,
  reads it back and compares.
- **Read sector:** reads one or more sectors and shows them in hex.

## Reference documents

- [IBM DBA-ESDI reference](https://ardent-tool.com/docs/pdf/j_mcspec.pdf)
- [DBA-ESDI 72-pin connector pinout](https://ardent-tool.com/storage/DBA_ESDI.html)
- [IBM PS/2 Hardware Interface Technical Reference, Micro Channel chapter](https://ardent-tool.com/docs/pdf/ps2_50-60_techref_ch2_microchannel_architecture.pdf)

## License

Designed by Eric Schlaepfer; modified in this fork by thenetworkinglab (2026).
Licensed under the
[CERN Open Hardware Licence Version 2 - Strongly Reciprocal](https://ohwr.org/cern_ohl_s_v2.txt).
