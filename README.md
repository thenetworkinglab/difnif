# DifNif: DBA-ESDI Solid State Drive Emulator

DifNif is a drive emulator that replaces an IBM DBA-ESDI hard drive. 
It was designed by Eric Schlaepfer ([schlae/difnif](https://github.com/schlae/difnif)),
with the project's initial release intended to replace the hard drive in 
IBM ThinkPad 700C laptops, also including an alpha version of a PS/2 desktop 
form-factor emulator.  This fork is an attempt to complete 
the development of the 72-pin board for PS/2 desktops; the changes are 
listed in [docs/formfactor-review.md](docs/formfactor-review.md).

And before you ask: the name 'DifNif' comes from DF9F, 
the Micro Channel adapter ID that IBM's DBA-ESDI drives report.

**Status:** the Rev P2 PS/2 board works in a PS/2 55SX and Model 70, with or
without a Teensy, booting DOS 6.22 and OS/2 1.1. Releases are listed in
[CHANGELOG.md](CHANGELOG.md).

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

DifNif implements the DBA-ESDI interface in a Lattice iCE40 FPGA and keeps
the disk as an image file on an SD card. Eric's design pairs the FPGA with a
Teensy 4.1 microcontroller; this fork adds a build that runs a small RISC-V
processor inside the FPGA instead, so the board needs no Teensy.

## Status

The Rev P2 board for PS/2 desktops (this fork) can be built two ways from
the same board:

- **FPGA-only** (recommended): no Teensy; the SD card goes in the board's
  own socket. Release v2026.11.22-1.
- **With a Teensy 4.1**, Eric's arrangement, with this fork's fixes; the SD
  card goes in the Teensy. Firmware v2026.11.21-5 and FPGA v2026.11.21-1.

Both work in a PS/2 55SX and a Model 70: they're set up with the Reference
Diskette, boot DOS 6.22, and pass a copy test that checks every file written.
OS/2 1.1 installs and boots with the Teensy build in both machines, and boots
with the FPGA-only build in the Model 70 (not yet tried in its 55SX). With
the FPGA-only build, switching the PS/2 off straight after a write loses
nothing.

Speed, measured with DiskMeter (random / sequential / buffered, KB/s) and
sunbench (raw BIOS reads and writes, 64 KB blocks, MB/s), in a Model 70
(8570-A21: 25 MHz 80386DX, 64 KB cache) and a 55SX (8555-061: 16 MHz
80386SX, no cache):

| | Model 70 | 55SX |
|---|---|---|
| FPGA-only, DiskMeter | 3555 / 3206 / 3213 | 2222 / 2241 / 2432 |
| FPGA-only, sunbench read / write | 2.99 / 2.50 | 2.13 / 1.87 |
| Teensy build, DiskMeter | 1942 / 2036 / 2010 | 2108 / 2266 / 2305 |
| Eric's original design, DiskMeter | about 990 | about 690 |
| McIDE (an IDE adapter), DiskMeter | 2477 / 2477 / 2477 | 1867 / 1876 / 2005 |

Not yet tested: the PS/2 50Z, and this fork's FPGA changes on the ThinkPad
board (Eric's ThinkPad board works with his original design, on the `main`
branch).

**Data loss:** this is a hobby project with no formal testing. Keep backup
copies of all disk images.

## Making a board

This needs surface-mount assembly (an assembly service will do it), a
computer with the open-source FPGA tools, and an FTDI FT232H adapter. These
steps are for the FPGA-only build; the Teensy build differs in steps 4 to 6
(see below).

1. **Order the board.** `pcb_formfactor/fab/` has the Gerber and drill files
   (`DifNifFormFactor-RevP2.zip`), a parts list and a placement file for an
   assembly service. Order it 1.6 mm thick, with gold fingers and a bevelled
   connector edge; [docs/formfactor-review.md](docs/formfactor-review.md),
   "Fab files", has the details. Fit the 2x4 header J2 yourself (for
   programming); the Teensy socket is only needed for the Teensy build.
2. **Print the sled.** [mech/difnif_PS2_drive_sled.STL](mech/difnif_PS2_drive_sled.STL)
   replaces the IBM drive's sled; the board screws into it.
3. **Install the tools:** yosys, nextpnr and icestorm (for example
   [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build)), and a
   RISC-V C compiler, `riscv64-elf-gcc` (for example from Homebrew).
4. **Build and program the FPGA.** In `verilog/`:

       make BOARD=ps2 CPU=1          # firmware and FPGA, into build/ps2-cpu/
       make prog BOARD=ps2 CPU=1     # writes the FPGA's flash through J2

   Wire the FT232H to J2:

   | J2 pin | Signal | FT232H pin |
   |---|---|---|
   | 1 | Flash chip select | AD4 |
   | 2 | CDONE | AD6 |
   | 3 | SCK | AD0 |
   | 4 | CRESET | AD7 |
   | 5 | Flash data out (CIPO) | AD2 |
   | 6 | GND | GND |
   | 7 | Flash data in (COPI) | AD1 |
   | 8 | +3.3 V (leave unconnected) | |

   The board must be powered while it's programmed: in a switched-on PS/2,
   or on the bench with 5 V on the Teensy socket's VIN pin (U13 pin 48).
5. **Make the disk image.** The drive is a file called `disk0.img`, a whole
   number of megabytes up to 1023 MB, in the root directory of a FAT32 or
   exFAT SD card. For 120 MB:

       dd if=/dev/zero of=disk0.img bs=1048576 count=120

   The file may be in up to 32 pieces on the card. The card goes in the
   board's socket, J3.
6. **Optional: the serial log.** The board reports what it found on the card
   (and why, if it can't use the image) on a 1 Mbaud, 8N1 serial line at the
   Teensy socket: it sends on the pin where a Teensy 4.1's pin 16 would go,
   and listens on pin 17's. Use a 3.3 V USB-serial adapter (never RS-232
   levels): the FT232H when it isn't programming (AD1 to pin 16, AD0 to pin
   17, and GND), or a Teensy running
   [fw/teensy_log/teensy_log.ino](fw/teensy_log/teensy_log.ino). Any key
   prints the summary again; `v` traces every command; `p` changes the bus
   release time after another device's -PREEMPT (6 us by default).
7. **Fit it in the PS/2.** In the Model 70, check the orientation first: its
   drive socket isn't keyed, and the board fitted upside down puts +12 V on
   signal pins. The component side (where `A01` is printed) faces the same way
   as the side of the IBM drive's board that faces the drive casing. The 55SX
   socket is keyed. The first start gives error 165 (configuration changed):
   run the Reference Diskette's automatic configuration. Then let it create
   the reference partition if the machine needs one, and install DOS or OS/2
   as on a new drive.
8. **Check it.** [tools/copytest](tools/copytest/) copies test files back
   and forth under DOS (`TEST.BAT`, or `FOREVER.BAT` overnight), and
   `copytest.py check` verifies every copy by reading `disk0.img` on another
   computer afterwards.

## The Teensy build

The same board with a Teensy 4.1 in its socket: Eric's arrangement, with
the SD card in the Teensy's slot instead of J3. This fork fixed a good deal
of it along the way ([docs/formfactor-review.md](docs/formfactor-review.md)
has each finding, [CHANGELOG.md](CHANGELOG.md) each release):

- **The board (Rev P2):** the reset input, which floated and was the likely
  cause of Eric's Rev P1 board failing in a 50Z; level shifters that had
  5 V on a pin rated for 4.6 V; the missing key slot in the edge connector;
  the -CD SFDBK signal, which wasn't driven.
- **The FPGA design:** write data latched too early to work at IBM's timing
  limits; the POS
  registers (the card's adapter ID); 8-bit reads that the Model 70 read
  wrongly; the PS/2's channel reset, which didn't reset the card; DMA
  requests that dropped too late; DMA left enabled at terminal count, which
  hung OS/2 1.1 at its second disk read.
- **The Teensy firmware:** the last write before the PS/2 is switched off
  could be lost; status words OS/2 left unread were still waiting at its
  next command; the answer to OS/2's probe for a second drive.
- **Speed:** a sector buffer and burst DMA in the FPGA took DiskMeter from
  about 690-990 KB/s with Eric's design to about 2 MB/s.

To build it:

- Load [difnift/difnift.ino](difnift/difnift.ino) with the Arduino IDE and
  PJRC's Teensy support (Teensy 4.1).
- Build the FPGA with `make BOARD=ps2` and program it with
  `make prog BOARD=ps2` (the Teensy's USB powers the board on the bench).
- [difbench/difbench.ino](difbench/difbench.ino) tests the Teensy-to-FPGA
  link on the bench, before the board goes in a PS/2.
- [docs/formfactor-review.md](docs/formfactor-review.md), "Bring-up", takes
  a new board from first power to a PS/2 one step at a time.

## What's in the repository

| | |
|---|---|
| [pcb_formfactor/](pcb_formfactor/) | the PS/2 board (KiCad), with fab files in `fab/` |
| [verilog/](verilog/) | the FPGA design: `mcabus.v` (the Micro Channel interface and ESDI registers), `sectorbuf.v`, and for the FPGA-only build `soc.v` (the processor), `sdhost.v` and `sdbridge.v` (the SD card); `teensy.v` for the Teensy build |
| [fw/](fw/) | the FPGA-only build's firmware (C, RISC-V) |
| [difnift/](difnift/) | the Teensy build's firmware |
| [tools/](tools/) | `timing_budget.py` (checks the design against IBM's bus timing), `copytest/`, and board-checking scripts |
| [mech/](mech/) | 3D-printed sled and carriers |
| [pcb_thinkpad/](pcb_thinkpad/) | Eric's ThinkPad 700C board |
| [docs/](docs/) | the design notes below |

The simulations: in `verilog/`, `./run_sim72.sh` runs a model of the PS/2's
bus against the design at IBM's timing limits (`./run_sim72.sh cpu` for the
FPGA-only build, with its firmware and an SD card model), and
`./run_sdsim.sh` and `./run_socsim.sh` test the SD controller and the
processor's start-up. They need Icarus Verilog.

## Design notes

- [docs/fpga-only.md](docs/fpga-only.md): the FPGA-only build, how it works
  and how it was tested and tuned.
- [docs/formfactor-review.md](docs/formfactor-review.md): the review of
  Eric's Rev P1 board, the Rev P2 changes, bring-up, and the speed work on
  the Teensy build.
- [docs/os2.md](docs/os2.md): what it took to boot OS/2 1.1.
- [docs/verify-findings.md](docs/verify-findings.md): how to check each
  finding against Eric's files and IBM's documents.
- [docs/rev-p3-spec.md](docs/rev-p3-spec.md): a draft specification for
  the next board: FPGA-only, USB-C, full-size SD socket.

## Reference documents

- [IBM DBA-ESDI reference](https://ardent-tool.com/docs/pdf/j_mcspec.pdf)
- [DBA-ESDI 72-pin connector pinout](https://ardent-tool.com/storage/DBA_ESDI.html)
- [IBM PS/2 Hardware Interface Technical Reference, Micro Channel chapter](https://ardent-tool.com/docs/pdf/ps2_50-60_techref_ch2_microchannel_architecture.pdf)

## License

Designed by Eric Schlaepfer; modified in this fork by thenetworkinglab (2026).
Licensed under the
[CERN Open Hardware Licence Version 2 - Strongly Reciprocal](https://ohwr.org/cern_ohl_s_v2.txt).
