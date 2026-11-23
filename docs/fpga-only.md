# An FPGA-only DifNif

The Rev P2 board can run without the Teensy. The FPGA has its own SD card
socket (J3, wired for 4-bit SD mode: clock, command, four data lines and the
card-detect switch, with pull-ups), its own 3.3 V and 1.2 V regulators fed
from the PS/2's 5 V, its oscillator and its configuration flash.

What the Teensy did is now in the FPGA, in three parts:

1. **An SD card host controller** (`verilog/sdhost.v`), and a bridge
   (`verilog/sdbridge.v`) between it and the sector buffer the PS/2 side
   already uses.
2. **A small processor** (PicoRV32, RISC-V, `verilog/soc.v`) running a C
   port of the command handling in `difnift.ino` (`fw/`).
3. **The disk image** found once at start-up, as up to 32 runs of sectors
   on the card, so that no filesystem work is needed after that.

`make BOARD=ps2 CPU=1` builds it; the first release is v2026.11.22-1
(CHANGELOG.md). It works in the Model 70 and the 55SX, the latter on a
second board with no Teensy fitted. A Teensy in its socket (running
`fw/teensy_log`), or a 3.3 V USB-serial adapter, serves as the processor's
serial port; without either, the board needs 5 V on the socket's VIN pin
(U13 pin 48) to be programmed on the bench. This document follows the work
in the order it was done, with what each step found.

## The SD host controller

`sdhost.v` is the low-level half. It leaves which commands to send, and
error recovery, to whatever drives its registers (the processor later, the
testbench now). Its header lists the registers and the data streams, which
are 16 bits wide with byte 0 in bits 7:0, like the sector buffer's.

- 1-bit and 4-bit bus; clock divided from 50 MHz (25 MHz to 195 kHz),
  running only when needed.
- 48-bit and 136-bit responses with CRC7 checks, R1b busy, and the 8
  clocks the card needs after each command or response (NCC).
- Single and multiple block reads and writes with CRC16 on each data line,
  the card's CRC status token after each written block, and its busy
  while it programs.
- Flow control: between blocks the SD clock stops until the other side
  has room for, or has ready, a whole block.
- Two sampling points: as the SD clock rises, or one 50 MHz clock later
  (`sample_late`).

Size and speed (nextpnr, on its own): about 1,200 logic cells, no block
RAM, 79 MHz against the 50 MHz it needs.

### Simulation

`verilog/run_sdsim.sh` runs `sd_t.v`, which plays the processor:
start-up at 400 kHz (CMD0, CMD8, ACMD41, CMD2, CMD3, CMD9, CMD7, ACMD6),
then at 25 MHz in 4-bit mode single and 8-block writes and reads, reads and
writes with the other side not ready between blocks, a 0.8 ms write busy, a
read block with a bad CRC, a write the card rejects, a command with no
response, and the 1-bit bus. It also checks the CRC functions against the
SD specification's examples. 14 tests.

`sdcard_model.v` is a high-capacity card. It changes its outputs anywhere
from 0 to 14 ns after the clock falls (X in between, as the specification
allows), and reports the clock too fast for the card's state, host
changes within 5 ns of a rising clock edge, X or Z from the host, bad
command CRCs, fewer than 8 clocks between commands, and the host and card
driving a line at the same time.

Results, with the FPGA's pin delays out to the card and back:

| Sampling | Pin delays (out + in) | Data changing at | Result |
|---|---|---|---|
| late (40 ns) | 0 + 0 | 0-14 ns | pass |
| late | 6 + 4 | 10-24 ns | pass |
| late | 12 + 8 | 20-34 ns | pass |
| as the clock rises (20 ns) | 0 + 0 | 0-14 ns | pass |
| as the clock rises | 3 + 2 | 5-19 ns | pass |
| as the clock rises | 6 + 4 | 10-24 ns | fails, as expected |
| late | 16 + 12 | 28-42 ns | fails, as expected |

So sampling as the clock rises only works with fast pins, and late
sampling is the default to try first. The iCE40's real pin delays will
decide it; if neither point is safe, the input registers' second edge (the
falling edge of the 50 MHz clock) gives a sampling point between the two.

An 8-block read takes 340 us including the command: 12 MB/s, against the
bus's 2 MB/s.

Each of these deliberately broken versions of `sdhost.v` fails the tests:
7 clocks instead of 8 after a command, the read bytes swapped, the wrong
CRC16 polynomial on writes, the read CRC not checked, write busy or R1b
busy not waited for, the start-up clock at 25 MHz, `rd_ready` ignored, and
CMD released a clock early.

## The bridge to the sector buffer

`sdbridge.v` takes the Teensy's place on the sector buffer's Teensy side
(`sectorbuf.v`, unchanged), so sectors go between the card and the PS/2's
DREG and DMA accesses directly. `mcabus.v` sees the buffer behave exactly
as it does with the Teensy.

- **Reads:** each word from the card goes into the buffer's free half, and
  a good block is handed to the PS/2 side. The SD clock stops while both
  halves are full, so the card waits for the PS/2. A block with a bad CRC
  isn't handed over, and the bridge stops until the controller retries;
  the half's pointer has wrapped back to its start, so the retried block
  lands in the same half and the sectors still reach the PS/2 in order.
- **Writes:** the bridge arms one half per sector of the command, as halves
  come free. A full half goes to the card, but unlike the Teensy firmware,
  which frees a half as soon as it has read it, the bridge frees it only
  once the card has accepted the block and finished programming it. A
  block the card rejects is still there to send again. (`sdhost` gained
  `wr_blk_done` and `wr_blk_ok` for this.)
- **blocks_done** says how many blocks got through, so the controller
  knows where to resume after a failure.
- **restart** begins a transfer and empties the sector buffer at the same
  time. The first version left that to the controller, and arming for a
  write could start from a count left over from the previous read, before
  the buffer had been emptied: the PS/2 side was then offered room for a
  sector more than the command had.

### Simulation

`sdbuf_t.v` (also run by `run_sdsim.sh`) connects the card model, `sdhost`,
the bridge, the sector buffer and a stand-in for the PS/2 side, which
reads or writes one word per access with a random gap, at least 200 ns
apart as on the real bus. 8 tests:

| Test | Result |
|---|---|
| Read 16 sectors, PS/2 side 0.5-1 us per word | pass, 2.5 MB/s (limited by the PS/2 side) |
| Read 16 sectors, PS/2 side 200 ns per word | pass, 8.6 MB/s |
| Write 16 sectors, 0.5-1 us per word | pass, 2.5 MB/s |
| Write 16 sectors, 200 ns per word | pass, 8.6 MB/s |
| Read 8, the 4th with a bad CRC, retried from it | pass |
| Write 6, the 3rd rejected by the card, retried from it | pass |
| Read abandoned after 1 of 4 sectors, then a new read | pass |
| Card start-up | pass |

Each test checks the data end to end, that every word from the card was
stored, that the PS/2 side never read a word before the buffer had fetched
it, and that no half is left offered to the PS/2 after a write.

These broken versions of the bridge fail: a bad block handed to the PS/2
side, reads ignoring a full buffer, a half freed before the card accepts
it, more halves armed than sectors, and the buffer not emptied at restart.
Two other guards (ignoring the card after a failure, and not sending a
half twice) can't be caught, because `sdhost` already prevents those
cases; they stay as a second line of defence.

## The processor (in progress)

`verilog/soc.v` puts a PicoRV32 (RV32IC, from oss-cad-suite's examples;
ISC licence) in the Teensy's place. Toward `mcabus.v` and the sector buffer
it has the same ports as `teensy.v`, so the bus side is unchanged. Inside:
12 KB of RAM loaded with the firmware at power-up, the Teensy's mailbox
registers (numbered as before, with the strobes `mcabus.v` expects),
`sdhost` and the bridge, a 512-byte buffer for blocks the processor reads
itself, a 1 Mbaud serial port for its log, a microsecond timer and the
LEDs. Its header has the memory map.

`make BOARD=ps2 CPU=1` builds it into `build/ps2-cpu` (and the firmware
first). The normal build is unchanged: `make BOARD=ps2` gives the same
bitstream, bit for bit, as release v2026.11.21-1. The processor build uses
about 4,500 of 7,680 logic cells and 23 of 32 block RAMs, and runs at up to
59 MHz against the 50 MHz it needs.

It places with nextpnr's `--no-promote-ce`. Without it, the processor's
clock enables took the last of the FPGA's 8 global buffers, and `ARB/-GNT`
and `-TC`, which clock parts of `mcabus.v`, were left on ordinary routing.
`tools/timing_budget.py --pos --cpu` checks the bus timing of this build:
everything passes, the tightest being T54 (`-BURST` released after `-TC`)
at 3.3 ns on stacked worst cases (5.2 ns in the normal build).

T54 seemed to depend on placement, and the processor build kept needing a
new seed: but `timing_budget.py` took T54 from the slowest pin-to-pin path
anywhere in the design, which belongs to something else entirely and
moves with every placement. `tools/sdfpath.py` now measures the actual
-TC to -BURST route from nextpnr's SDF (9.7 ns inside the FPGA for seed 7,
the slow way round, through the `tc_seen` latch's clock): T54 then passes
with 3.0-6.0 ns to spare for every seed from 1 to 16 in the processor
build, 5.2 ns in the Teensy build. The Makefile keeps seed 7 only so that a
build is reproducible.

The log goes out on Teensy data line 7 (FPGA pin 25), which is the
Teensy's pin 16, its Serial4 input; Teensy pin 17 (Serial4 output) comes
back on line 6. A Teensy running a few lines that copy Serial4 to USB
serves as the log's USB port (`fw/teensy_log`).

These lines have explicit `SB_IO` pads in `difnif_top.v`: line 7 an
output, the other 15 inputs with pull-ups. The first version wrote
`assign tn_d = {8'bz, uart_tx, 7'bz}`, and yosys turned the constant `z`
bits into constant 0, so the FPGA drove 15 lines low, against the
Teensy's serial output on line 6. Simulation can't show that (the pins
really are undriven there), so the Makefile now runs
`tools/check_inouts.py` on the synthesized netlist, which fails the
build if any bidirectional pin is tied to a constant. Without a Teensy, the LEDs show where
bring-up stopped.

The firmware is in `fw/` (`make` there builds `verilog/fw.hex`). So far it
only brings the card up, read-only: start-up at 400 kHz, then 4-bit at
25 MHz; finds disk0.img in the root directory of a FAT32 or exFAT
filesystem (on the whole card or in its first partition); checks it's
contiguous; and reads its first block. `verilog/run_socsim.sh` builds it
and runs `soc_t.v` against the card model holding a 64 MB FAT32 card made
by `mksdimg.py`. It passes: the card ready in 4.2 ms, disk0.img found at
block 4097 and checked contiguous, and its first block read correctly. The
firmware is 2.9 KB. (The contiguity check reads the FAT a byte at a time
and takes 31 ms for 2,048 clusters; worth speeding up for large images with
small clusters.)

For hardware, `fw/teensy_log/teensy_log.ino` makes a Teensy the log's USB
serial port: it copies Serial4 to USB and back, and leaves every other pin
an input. Only with the processor build.

## The drive (ESDI) firmware

`fw/esdi.c` is a port of `difnift.ino`'s command handling (up to
v2026.11.21-5): the same commands, status blocks, interrupts, resets and
EOI handling, through the same mailbox registers. Disk reads and writes
go straight between the card and the sector buffer: the firmware starts a
CMD17/18 or CMD24/25 at the image's offset, sends "data transfer ready",
and watches the bridge. Differences from the Teensy firmware:

- A block the card reports bad is retried from that block, up to 3 times,
  then the command fails (device error 05h for a read, 0Dh for a write).
- A transfer past the end of the image fails with device error 07h (RBA
  out of range). The Teensy firmware answered with whatever was in its
  buffer.
- A write is on the card before the host hears it's done (CMD12's busy,
  or a single block's), as with v2026.11.21-5's `w` setting off. Moving
  CMD12 after the interrupt, as v2026.11.21-5 does with its sync, is a
  later speed-up.
- At EOI it empties the command interface before clearing busy, not
  after. In simulation at the Model 70's limit timing the host started its
  next command as soon as busy cleared, and the Teensy order threw away
  that command's first word. The Teensy firmware had the same race,
  with a log line making its window several microseconds; it's fixed there
  too (CHANGELOG, Unreleased). It wasn't seen on hardware.
- The log goes through a buffer, so it doesn't hold up the host.

The firmware is 6.9 KB of code and 0.7 KB of data, in 10 KB of RAM (it
was 8 KB until the firmware left itself 92 bytes of stack and overwrote
its own data in simulation). `fw/link.ld` now refuses to link with less
than 1 KB left for the stack. The attachment buffer lives in the
processor's block buffer (cbuf), which is idle once the card is up.

### Simulation with the bus

`./run_sim72.sh cpu` runs `difnif72_t.v` with the processor build on the
Rev P2 board, POS on: the real firmware, the SD card model holding a
600 MB FAT32 card (4 KB clusters) with a 1 MB disk0.img, and the PS/2
side sending ESDI commands as the BIOS does, with burst DMA and memory
refresh. 16 tests: POS ID and setup, the reset interrupt after power-on,
get configuration (the image's size), reads and writes of 1 and 8
sectors by DMA, each checked against the card, reads of what was
written, a read past the end, a command to device 1, the attachment
buffer through DREG, a soft reset, and a read of the image's last
sectors. All pass for the 50Z, 55SX and Model 70, at typical timing and
at the limits (two seeds each), with the card model reporting no
protocol errors. A run takes about 30 s.

DMA runs at 0.54 us per word for 8 sectors at the Model 70's cycle, as
with the Teensy build's burst DMA (0.57): the bus is still the limit.

The normal build's matrix (`./run_sim72.sh quick`) is unchanged, and
`tools/timing_budget.py --pos --cpu` passes (T54 3.3 ns on stacked worst
cases, measured on the -TC to -BURST route).

On a P2 board on the bench (21 November) it started first time: card up
on the 4-bit bus at 25 MHz, FAT32 in a partition at block 8192, disk0.img
at block 0xA0FC0, contiguous, 311,296 blocks (a 152 MB image). The
serial input (any key reprints the summary) didn't work in that image,
because of the driven Teensy lines above; fixed since.

In a Model 70 (21 November) POST passed and the boot got as far as
"Starting MS-DOS...", then hung; an earlier boot had followed a FAT chain
to a cluster that doesn't exist (block 0x40219), as if a read had handed
the PS/2 wrong data, with no SD errors logged. For that the firmware has a
trace, on at start-up ('v' in the serial monitor toggles it): every
attention request and reset interrupt with a microsecond time, and after
each disk transfer a Fletcher checksum of the words on each side of the
sector buffer (registers at 0x1000_020C-0214 in soc.v). `tools/blocksum.py
disk0.img LOG` checks each read in a saved log against the image: a host
sum that differs from the card's points between the buffer and the bus,
both agreeing but differing from the image points at the card side.

The next boot reached the DOS prompt (DiskMeter 2113.6 / 2119.2 / 2119.2
KB/s, against 1941.7 / 2035.6 / 2010.0 for the Teensy build; CHKDSK
clean), but the trace showed 8 of about 45 reads with `MISMATCH`: the host
had taken 3-6 words of the last sector when the command ended. The
firmware took "the host side is idle" from the flags read at the top of
its loop and the block count from BR_STATUS later; when the last block
reached the buffer in between, the stale flag said idle and the command
ended, switching the buffer off under the PS/2's DMA. Both now come from
the one BR_STATUS read (bit 17 and the count change on the same clock).
The simulations never hit the window.

With that fixed, boot4 had 0 mismatches in 207 reads, all of which match
the image. A copy test (the part of the log the serial monitor kept:
8,590 reads, 176 writes) had none either; every write nothing later
overwrote is on the card as sent (`blocksum.py --writes`), and
`copytest.py check` found every finished copy correct.

A card taken out and put back while the board stays powered (on the
bench the Teensy's USB keeps it running) has forgotten its set-up: the
first read hung, waiting for data that never came, until the PS/2 reset
the channel. Now:
- a failed read or write command checks the card with CMD13; if it doesn't
  answer, the firmware starts it again, finds disk0.img again and tries
  once more, else a device error;
- a transfer that ends short (sdhost gives up after 0.67 s without data)
  is retried from where it stopped, like a CRC error;
- a hard reset checks the card the same way.
The card model has a `power_cycle` hook for this, and the processor-mode
bus tests swap the card twice (once before a read, once before a channel
reset).

The firmware only sees a channel reset while it lasts: while its log is
full it can be away for milliseconds. A PS/2's resets are much longer, but
a latched "hard reset seen" bit would make that certain.

On the Model 70 (22 November) both work: a card taken out to the Mac and
put back, with the board kept powered by USB, was started again at the
first hard reset ("SD card not answering: starting it again") and DOS
booted. A 1 MB COPY to C:\W.BIN with the power switched off 1-2 s
afterwards was complete on the image (SHA-256 identical to the source,
size in the directory entry): a write's completion interrupt only comes
after the card has finished programming, so there's nothing to lose.

### Bus release time after -PREEMPT

Scope captures of the processor build on the Model 70 (22 November, probe
image `make CPU=1 PROBES=1`, signals on spare Teensy lines) showed the
system board preempting about 1.3 us into every grant, for one CPU bus
cycle during the next arbitration. The card let go at once, as the Teensy
build does, so each 2.6 us grant carried 3 words (a word every 0.5 us
inside it) and about a quarter of the time went on arbitration: 0.91 us a
word on average, about 2.2 MB/s.

IBM's DASD interface spec (3.4.3.3) has POS 4 bits 2:1 for this: 00 let go
at once, 01 carry on for 3 us, 1x for 6 us. The processor build now honours
it (`mcabus.v`, `PREEMPT_HOLD`), stopping after the transfer in progress,
well inside T40's 7.8 us; `p` in the serial monitor overrides it (POS 4,
at once, 3 us, 6 us). The Model 70's BIOS sets POS 4 to 00 and the
configuration utility doesn't offer it. DiskMeter on the 70:

| Release | Transfer rates (KB/s) | Last three fields |
|---|---|---|
| at once | 2159.2 / 2173.9 / 2176.8 | .1 / .1 / .1 |
| 3 us | 3007.5 / 3041.8 / 2519.6 | .53 / .53 / .53 |
| 6 us | 3555.5 / 3206.4 / 3212.8 | .53 / .53 / .53 |

The McIDE in the same machine gives 2476.7. The last three fields (seek
times?) follow the setting, but sunbench's raw sweep (`--rewrite`) shows 6
us faster at every size, so they're DiskMeter's own artifact:

| Block | seqR at once / 6 us | randR | seqW |
|---|---|---|---|
| 1 KB | 1.11 / 1.36 | 0.80 / 0.92 | 0.49 / 0.51 |
| 4 KB | 1.73 / 2.40 | 1.50 / 1.99 | 1.31 / 1.59 |
| 64 KB | 2.01 / 2.99 | 1.99 / 2.95 | 1.82 / 2.51 |

So the firmware's default is 6 us whatever POS 4 says (`p` cycles 6 us,
POS 4, at once, 3 us).

OS/2 1.1 on the 70 with 6 us (22 November): boots (twice, and cold with
the serial lead in and out), from a 19-piece image too. A floppy FORMAT
while a copy loop kept the DifNif busy failed twice at 84 and 95 percent
with the drive recalibrating, but then passed with no copy loop, with
release at once, with 3 us, and three times with 6 us: a freshly recapped
drive writing old disks for the first time, most likely, not the bus.
Still to check: the 55SX. The Teensy build is unchanged
(bit-identical to v2026.11.21-1).

### Fragmented images

Copied onto a freshly formatted 32 GB card by a Mac, an OS/2 image came
out in 15 runs of clusters, threaded between the small files macOS writes
there first (`.Spotlight-V100`, `.fseventsd`, `._disk0.img`), and the
firmware, which wanted one run, refused it (reason 7). Deleting and copying
it again made it worse; a dummy file to fill the gaps first got a
contiguous copy. Now `fat.c` follows the cluster chain at start-up and keeps
up to 32 runs (the summary says "in pieces: n"); `img_map()` turns a drive
block into a card block, card commands stop at a run's end, and
`disk_progress()` carries on at the next run (not a retry, nothing logged).
Read-ahead only holds the card within a run.

`mksdimg.py` now builds the simulated card's image in 4 runs, with a
cluster of junk between them, at drive blocks some of the bus tests cross.
That found a real bug: when a run ended with both sector buffer halves
full, the next CMD18 went out at once, and the card started sending its
first block during the command's response (the SD clock has to run for
it), with no free half: the block was counted but dropped, and the host
came up a sector short. The same could happen after a CRC retry. A read's
next card command now waits for a free half (`x_resume`), from the main
loop so a reset meanwhile is still seen.

The processor's RAM is now 12 KB (24 block RAMs, 31 of 32 in use): the
firmware had reached 10 KB again. `link.ld` asks for 768 bytes of stack;
the deepest call chain needs about 450 (gcc's `-fstack-usage`).

## Next

- An overnight copy test (`FOREVER.BAT`) on the Model 70, trace off, and
  the copy test on the 55SX (DOS and DiskMeter there already: 2222.2 /
  2240.8 / 2431.6 KB/s, against 2108.0 / 2266.2 / 2305.4 for the Teensy
  build).
- Release housekeeping: a version for this build (it says `cpu-dev`), the
  CHANGELOG, the README.
- Maybe: ending a write's card command after its interrupt, like
  v2026.11.21-5's sync (small writes; costs some power-off safety).
- Maybe: the pacing bits in POS register 3 (see below).

## POS 3 pacing

IBM's drives transfer in 64-word bursts with an optional pause between
them, set in POS register 3 bits 5-4 (00: no bursts; 01, 10, 11: 16, 24
or 30 us between bursts) and switched on by POS 4 bit 0 (DASD spec 3.4.3).
The Reference Diskette calls it "DMA Burst Pacing Interval". The DifNif
stores POS 3 but uses only bit 6 (finding 19), so the setting makes no
difference to it: it bursts whenever the firmware allows bursts. Honouring
"Burst disabled" at least would match IBM's drives, and the pauses would
keep it from holding the bus against other bus masters (network or SCSI
cards) on a busy machine. Pacing only applies when POS 4 bit 0 is set,
though, and the Model 70's BIOS writes POS 4 = 00, so as configured an
IBM drive wouldn't pace there either.
