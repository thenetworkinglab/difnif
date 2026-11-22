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

### Unreleased

- **End-of-interrupt empties the command interface before clearing busy,**
  instead of after. Once busy clears, the host may write its next command's
  first word straight away; the read that came after it, with a log line in
  between, could throw that word away. Found in simulation of the FPGA-only
  build (`fpga-only` branch) at the Model 70's limit timing; not seen on
  hardware. Unread status is dropped before busy clears too.

### v2026.11.21-5

Faster small writes, and the spec's answer to OS/2's probe for a second
drive. Use with FPGA v2026.11.21-1 (unchanged). Versions -2 to -4 were
development builds that appeared in test logs, so the release skips to -5.

- **Commands to devices 1-6** (OS/2 probes for a second drive with a seek to
  device 1) get a command block error with command error 13h, "invalid
  device number for the command", as the spec defines, instead of 03,
  "command not supported". OS/2 resets the card after either answer and
  carries on (docs/os2.md, "Device 1").
- **The command error code is cleared at each command.** It was never
  cleared, so after one rejected command every later status block, including
  successful reads and writes, reported "command not supported".
- **Write timing in the serial log:** one line per write command, `W <n>
  sectors, <us> us, <KB/s>: SD …, sync …, FPGA …, host and other …`,
  replacing the per-sector `wtime:` and per-command `stime:` lines.
- **The SD sync comes after a write's completion interrupt** (`w` switches
  it back), so it overlaps the host handling the interrupt. The host can't
  start another command until it has finished, but for about 1 ms the host
  has been told data is written that the card hasn't yet stored.

Tested in the Model 70 with sunbench's DOS file benchmark (32 MB file,
sequential, MB/s):

| Block | Write, sync first (-3) | Write, sync after | Read |
|---|---|---|---|
| 1 KB | 0.39 | 0.55 | 0.90 |
| 4 KB | 1.04 | 1.28 | 1.52 |
| 16 KB | 1.63 | 1.75 | 1.77 |
| 64 KB | 1.81 | 1.95 | 1.87 |

The 20-round copy test passed (120 of 120 identical), and a 1 MB file copied
to C: about 4 s before switching the PS/2 off was complete afterwards, with
its directory entry and FAT.

### v2026.11.21-1

OS/2 1.1 now installs and boots: see [docs/os2.md](docs/os2.md). Needs FPGA
v2026.11.21-1 for the fixes; older FPGAs work as before.

- **Unread status is dropped at each end-of-interrupt** (finding 18). IBM
  lets the host skip the status block and go straight to EOI (DASD spec
  3.3), which OS/2 does; the first word was left waiting, and "status
  interface full" showed at the next command.
- **DMA waits for the interrupt to be read** (finding 20): the firmware turns
  on the FPGA's hold on DMA requests while an interrupt is pending. OS/2
  doesn't need it, but it's on by default; the `g` serial command switches
  it.
- **Diagnostics:**
  - If a transfer makes no progress for 2 seconds, the flag register and
    the host's activity are printed at 2, 4 and 6 s. `f` prints them at any
    time.
  - Each command logs the DMA enable as it starts, and the number of times
    the host read the status register during it.
  - `d` sets a minimum delay before "data transfer ready" (0, 0.5, 1, 2 or
    5 ms); the default is 0.
- **difbench** allows register 15's new bits.

Tested with FPGA v2026.11.21-1, on a Rev P2 board. The hardware tests ran on
the development builds (firmware v2026.11.20-8, FPGA v2026.11.20-6), which
differ from this release only in the version numbers:

| Machine | OS/2 1.1 | DiskMeter, KB/s (random / sequential / buffered) | 20-round copy test |
|---|---|---|---|
| 55SX | Installs and boots from the disk | 1900 / 2111 / 2266 in DOS, 2139 / 2266 / 2305 in OS/2 | 120 of 120 identical, every SHA-256 correct |
| Model 70 | Boots to the desktop (with `g` off) | 2000 / 2078 / 2070 | 120 of 120 identical, every SHA-256 correct |

DiskMeter matches v2026.11.19-1.

### v2026.11.19-1

- **Burst DMA:** with FPGA v2026.11.19-1 or later, the firmware allows the
  FPGA's burst DMA (register 15) while the sector buffer is in use. Found at
  startup (the banner says "burst DMA on"). The `B` serial command switches it
  off and on, between commands. Older FPGAs read 0 at register 15 and work as
  before.
- **difbench** checks the burst control bit. It no longer uses register 15 as
  an always-zero register.

Tested with FPGA v2026.11.19-1, on a Rev P2 board:

| Machine | DiskMeter, KB/s (random / sequential / buffered) | 20-round copy test |
|---|---|---|
| 55SX | 2108 / 2266 / 2305 (was 1107 / 1100 / 1151) | 120 of 120 identical, every SHA-256 correct |
| Model 70 | 1956 / 2067 / 2102 (was 1110 / 1062 / 1108) | 120 of 120 identical, every SHA-256 correct |

`difbench` passes.

### v2026.11.18-3

- **Sector buffer:** with FPGA v2026.11.18-3 or later, sector reads and
  writes go through the FPGA's sector buffer, a whole sector at a time,
  instead of one word per handshake. Found at startup (the banner says
  "sector buffer on"); the `b` serial command switches it off and on, from
  the next command. Other commands, and older FPGAs, use the old path.
- **Timing markers** for a scope: Teensy pin 0 is high from each ATN command
  until the host's EOI, pin 1 while the Teensy waits on the SD card. These
  replace Eric's debug toggles on the same pins.

Tested with FPGA v2026.11.18-3 (before the timing markers were added):
DiskMeter about 1.1 MB/s in both the 55SX (from about 690 KB/s) and the
Model 70 (from about 990 KB/s), and the 20-round copy test, 120 of 120
comparisons identical, in both.

### v2026.11.18-2

- **Writes are on the card before they're reported complete (finding 17).**
  The SD driver's FIFO mode leaves each write open on the card until the
  next access elsewhere, and the card can hold the last sector in its
  buffer until then. If the power went first, that sector was lost: after
  a copy test the log's last directory update went missing, and the same
  thing probably caused the lost `AUTOEXEC.BAT` update during a DOS
  install. The firmware now ends the write and waits for the card
  (`syncDevice()`, about 1 ms) at the end of each write command, before
  telling the host the command is complete.
- **SD card retried at power-on:** if the disk image isn't open (the card
  wasn't in when the Teensy started, which can happen while USB powers it),
  the firmware tries the card again at each hard reset.
- The serial log shows the sync time (`stime:`) for each write command.

Tested with FPGA v2026.11.18-2, on a Rev P2 board:

- **Power-off test (Model 70):** two appends to a file, the second followed
  within a second by switching the PS/2 off; both were on the card.
- **Model 70:** the SD card retry booted the machine with the card inserted
  after the Teensy had started. DiskMeter is unchanged, about 990 KB/s.
- **55SX:** 20-round copy test, 120 of 120 comparisons identical, every
  file's SHA-256 correct, and the log's final line present after the
  power-off. DiskMeter about 670-690 KB/s, a few percent below the morning's
  runs; DiskMeter only reads, so this is probably the card rather than the
  change.

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
- Then with this release and FPGA v2026.11.18-1:
  - `difbench` passed every check.
  - The 20-round copy test (`TEST.BAT`) gave 120 of 120 comparisons
    identical, with every file's SHA-256 correct.

## FPGA

### v2026.11.21-1

- **DMA enable is reset at terminal count** (finding 19, the cause of the
  OS/2 hang; [verilog/mcabus.v](verilog/mcabus.v)). With POS 3 bit 6 at 0,
  which the 55SX and Model 70 set, IBM's drives switch off their DMA enable
  when `-TC` ends a transfer, and keep it off until the host next writes the
  control register. OS/2 relies on this. `-TC` is caught using the card's DMA
  selection as latched when `-CMD` fell, because `-TC` can come after the
  cycle's address and status have gone. PS/2 builds only.
- **Register 15:**
  - Writing bit 1 as 1 drops an unread status word (finding 18).
  - Bit 2 holds the card's DMA requests while an interrupt is pending
    (finding 20).
  - The read bits report what the host is doing: a count of its status
    register reads, IRQ 14, the control register's interrupt and DMA
    enables, whether the card is requesting or holding the bus or driving
    `-PREEMPT`, and whether `-TC` has reset DMA enable.
- **`-BURST` after a short `-TC`:** `-TC`'s falling edge now latches the
  release of `-BURST` until the next arbitration. Before, a `-TC` that ended
  before the 50 MHz logic saw it let `-BURST` come back for about 20 ns.
- **Simulation:**
  - `-TC` is asserted as late as IBM allows (T52), which the first version
    of the `-TC` reset failed.
  - New tests cover the dropped status, IRQ 14 at the edge connector, the
    `-TC` reset with POS 3 bit 6 clear and set, and the hold on DMA
    requests. Each fails on the design before its fix. 36 tests pass.
- **Timing budget** passes. The smallest margins are T54 at 0.8 ns (worst
  case stacked) and T22 at 7.8 ns. Uses 800 of 7680 logic cells.

Tested with firmware v2026.11.21-1: see the firmware entry.

### v2026.11.19-1

- **Burst DMA** ([verilog/mcabus.v](verilog/mcabus.v)): with the sector
  buffer in use and bursts allowed by the Teensy (register 15, bit 0), the
  card holds `-BURST` from the grant, so the DMA controller moves word after
  word without arbitrating again.
  - It stops after the next transfer when that one uses the last word or
    space in the buffer, when another device asserts `-PREEMPT`, after 64
    words, or at `-TC`.
  - It follows IBM's burst timing (T40, T43, T54 and T56; see
    docs/formfactor-review.md, "Speed: burst DMA").
  - It doesn't burst without the sector buffer.
- **Request steadiness:** the sector buffer's "word ready" signal comes from
  the half's state rather than the prefetch, so the card's request no longer
  dips for 30 ns after each word.
- **Register 15** is the burst control. Bit 0 reads back; the other bits
  read 0.
- **Debug build:** `make BOARD=ps2 PROBES=1` copies bus signals onto J4's SD
  pins for a scope. It builds into `build/ps2-probes/` and isn't for
  releases.
- **Simulation:**
  - The testbench's DMA controller does burst transfers, and memory refresh
    preempts them.
  - New tests cover burst reads and writes, `-TC` in the middle of a burst,
    and the old path with bursts allowed.
  - The full matrix passes with POS enabled.
- **Timing budget** passes, including the burst rules. The smallest margins
  are T54 at 1.2 ns (worst case stacked) and T22 at 8.2 ns. Uses 757 of 7680
  logic cells.

Tested with firmware v2026.11.19-1: see the firmware entry.

### v2026.11.18-3

- **Sector buffer** ([verilog/sectorbuf.v](verilog/sectorbuf.v)): two
  one-sector halves in block RAM between the Teensy and the host's DMA.
  The Teensy loads or unloads a whole sector through port register 14 while
  the host works through the other half, and the card keeps bidding for the
  bus while the buffer holds the next word. Controlled through the flag
  register's bits 11-15, which read 0 with it off; with it off the old path
  is unchanged.
- Register 14 reads 0 while the buffer is off.
- **Simulation:** sector-buffer tests in both directions, with fast and slow
  Teensy timing and a competing DMA device. The full matrix passes.
- **Timing budget** passes; the smallest margin is 8.5 ns, on T22. Uses 725
  of 7680 logic cells and 2 of 32 block RAMs.

Tested with firmware v2026.11.18-3: see the firmware entry.

### v2026.11.18-2

- **Model 70 (finding 16):** 8-bit reads (POS registers, BSR, ISR) put the
  byte on both D0-D7 and D8-D15. The board's two data buffers share one
  direction line, so the card drives all 16 lines on every read. It used to
  put `FF` (or `00`) on D8-D15, which beat the Model 70's own copy of the
  byte for odd addresses, so the 70 read the adapter ID as FF9F and didn't
  recognise the drive. The 55SX was unaffected.
- **Simulation:** the testbench checks that on 8-bit reads the card's D8-D15
  is a copy of D0-D7.

Tested on the same Rev P2 board:

- **Model 70, firmware v2026.11.18-1:** the POS registers read `9F DF 78 00`,
  the Reference Diskette (v1.12) configures the drive, and DOS boots.
  DiskMeter: random 960 KB/s, sequential 990 KB/s. 20-round copy test: 120 of
  120 comparisons identical and every file's SHA-256 correct; the log's last
  line was then lost at power-off, which led to firmware finding 17.
- **55SX, firmware v2026.11.18-2:** boots, and passes the 20-round copy test
  (see the firmware entry).

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
This release itself passed `difbench` and the 20-round copy test.
**Not tested** in a Model 70 or a ThinkPad 700C.
