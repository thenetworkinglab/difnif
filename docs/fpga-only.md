# An FPGA-only DifNif (work in progress)

The Rev P2 board can run without the Teensy. The FPGA has its own SD card
socket (J3, wired for 4-bit SD mode: clock, command, four data lines and the
card-detect switch, with pull-ups), its own 3.3 V and 1.2 V regulators fed
from the PS/2's 5 V, its oscillator and its configuration flash. The
current design uses about 800 of the FPGA's 7680 logic cells.

What the Teensy does now would move into the FPGA in three parts:

1. **An SD card host controller** (`verilog/sdhost.v`): sends commands and
   moves 512-byte blocks. Done in simulation; see below.
2. **A small processor** (PicoRV32, RISC-V) running a C port of the
   command handling in `difnift.ino`: the ESDI commands and status blocks,
   the card's start-up sequence, and the sync after writes. Not started.
3. **The disk image** as one contiguous run of sectors on the card, found
   once at start-up, so that drive sector N is card sector start + N. Not
   started.

During development a Teensy stays in its socket as a USB serial port for
the processor's log; its pins are already wired to the FPGA. Without a
Teensy, the board needs 5 V on the socket's VIN pin (U13 pin 48) to be
programmed on the bench.

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

## Next

- Connect `sdhost` to the sector buffer in simulation, so a block read from
  the card goes to the host's DMA without the Teensy.
- The processor and its firmware (needs a RISC-V C compiler).
- On hardware: a test build that starts the card and reads a sector, with
  the result on the LEDs or through the Teensy's serial port.
