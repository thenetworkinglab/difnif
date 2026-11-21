# Getting OS/2 to boot

OS/2 1.1 wouldn't install on a DifNif in a PS/2 55SX. It showed its logo,
then the screen went black and the machine stopped. DOS had been working
fine on the same board. The cause was two places where the
DifNif didn't do what IBM's DBA-ESDI drives do, plus a third deviation found
along the way. With firmware and FPGA v2026.11.21-1, OS/2 1.1 installs: it
reformats the disk and boots from it.

The reference throughout is IBM's *DASD Storage Interface Specification,
Micro Channel*, Rev 2.2 ([ardent-tool.com](https://ardent-tool.com/docs/pdf/j_mcspec.pdf)),
which describes the interface the DifNif emulates, and the PS/2 Model 50/60
Technical Reference, section 2, for the bus timing.

## What the log showed

Every command OS/2 sent during startup worked, including reading the
partition table (relative block address, RBA, 0). The next read, the boot
sector of C: (RBA 0x20), never finished. The firmware had the sector ready
and had raised "data transfer ready", but OS/2 never read the interrupt
status that goes with it.

Things ruled out first:

- **Burst DMA and the sector buffer.** It hung the same way with both
  switched off, which is the old word-at-a-time path.
- **Answering too fast.** The DifNif signals "data transfer ready" in 0.2 ms;
  a real drive takes milliseconds. A 2 ms minimum delay (firmware command
  `d`) made no difference.
- **The interrupt line.** A meter on U12 pin 6 read 65 mV while the card held
  IRQ 14: driven low, with current from the planar's pull-up. And the DOS
  logs showed the PS/2 BIOS reading the status register exactly twice per
  command, once per interrupt, so IRQ 14 has always worked.
- **OS/2 itself.** With a real IBM DBA-ESDI drive fitted (failing
  mechanics, good electronics), OS/2 got past the same point.

## Diagnostics added

These stay in the design. They cost little, and they found the problem.

- **Stuck transfers:** if a transfer makes no progress for 2 seconds, the
  firmware prints the flag register at 2, 4 and 6 s. The `f` command prints
  it at any time.
- **What the host is doing** (FPGA register 15, read bits):

  | Bits | Meaning |
  |---|---|
  | 15-9 | A count of the host's reads of the basic status register (BSR) |
  | 8 | The card is driving `-PREEMPT` |
  | 7 | The card holds the bus |
  | 6 | The card is requesting the bus |
  | 5 | IRQ 14 |
  | 4, 3 | The control register's interrupt and DMA enables |
  | 1 | DMA enable was reset at terminal count |

  The firmware logs the BSR reads during each command (a few means the host
  waited for an interrupt, many means it polled). It also logs the DMA
  enable at the start of each command, and all of these in the stuck-transfer
  lines.

## Finding 18: unread status stayed visible

When a command finishes, the card offers a status block one word at a time
in the status interface register. IBM lets the host skip it and go straight
to end-of-interrupt (spec section 3.3). OS/2 does that after reads. The
firmware left the first word sitting there, so "status interface full" was
still set when the next command started.

This wasn't the cause of the hang, but it isn't what a real drive does.
**Fix:** writing register 15 with bit 1 set drops an unread status word
(FPGA), and the firmware does that at every end-of-interrupt. It's in
register 15 rather than the flag register because Eric's original firmware
writes back the flag bits it reads, and would have cleared its own status.

## Finding 19: DMA enable wasn't reset at terminal count (the cause)

POS register 3, bit 6, set to 0 means "Reset DMA Enable at Terminal Count".
The 55SX and Model 70 both set POS 3 to 00. When the DMA controller signals
the last transfer of a block (`-TC`, terminal count), a real drive switches
off its own DMA enable, "to prevent unsolicited DMA requests after
activation of terminal count" (spec Figures 4 and 10). Eric's design never
did; it was a TODO in `mcabus.v`.

OS/2 relies on it:

1. It turns on DMA for the read of RBA 0.
2. After that read it leaves DMA on, expecting the drive to have switched it
   off.
3. For the next read, it waits for "data transfer ready", programs the DMA
   controller, and only then turns DMA on again.

The DifNif's DMA was still on, so the card asked for the bus before OS/2 had
programmed the DMA controller. No transfer could follow, and OS/2 waited
forever. DOS writes the control register itself for every transfer, so it
never noticed.

**Fix (FPGA):** when `-TC` ends a DMA transfer to the card and POS 3 bit 6 is
0, the card's DMA enable clears until the host next writes the control
register. The host sees it cleared in BSR bit 7. PS/2 builds only, since the
ThinkPad build has no POS registers.

**The first version of this fix missed `-TC` on the real 55SX.** It looked
for `-TC` during an I/O cycle to the card. But the planar only has to assert
`-TC` 30 ns before `-CMD` rises (T52), while the cycle's address and status
are only guaranteed for 30 ns after `-CMD` falls (T9/T10). On the 55SX the
status had already moved on by the time `-TC` came. The fix now uses the
card's DMA selection as latched when `-CMD` fell, which holds for the whole
cycle. The testbench had been asserting `-TC` early, so it didn't show this.
It now asserts it as late as IBM allows, and the first version fails there.

## Finding 20: DMA requests while an interrupt is pending

OS/2 turned DMA on before it had handled "data transfer ready". As an extra
safeguard, the card can hold back its DMA request until the host has read
the interrupt status (register 15 bit 2). The fork's firmware turns it on,
and the `g` serial command switches it off.

It turned out not to be needed. With it switched off (`g`), OS/2 1.1 booted
to its desktop in the Model 70: the read of RBA 0x20 completed, followed by
hundreds more reads and FAT writes, with no stuck transfers. Finding 19 alone
fixes the hang.

It stays on by default anyway. IBM's spec doesn't say when a drive starts
its DMA requests, only that the "Interrupt Pending" BSR bit is set until the
interrupt is serviced, and holding back a request until then is consistent
with that. DOS, OS/2 and the simulation all work with it on.

## Also fixed: `-BURST` after a short `-TC`

With `-TC` asserted late in simulation, `-TC` could end before the 50 MHz
logic had latched "stop the burst", and `-BURST` came back on for about
20 ns. In use this would need `-TC` in the middle of a burst, which a normal
command doesn't produce, since the card ends each burst before its last word.
`-TC`'s falling edge now latches the release until the next arbitration.

## Simulation

[verilog/difnif72_t.v](../verilog/difnif72_t.v) gained:

- a test that the dropped status clears for the host and the Teensy;
- the first check of IRQ 14 itself at the edge connector, with the register
  15 diagnostics;
- `-TC` resetting DMA enable, both ways round (POS 3 bit 6 clear and set);
- the pending-interrupt hold on DMA requests;
- `-TC` asserted as late as T52 allows.

Each new test fails on the design before its fix. 36 tests pass, and the
quick matrix passes with POS enabled. The timing budget passes (T54, the
tightest, at 0.8 ns on stacked worst cases).

## Tested on hardware

With the development builds that became v2026.11.21-1 (FPGA v2026.11.20-6,
firmware v2026.11.20-8, which differ from the release only in their version
numbers):

| Test | 55SX | Model 70 |
|---|---|---|
| OS/2 1.1 | Installs and boots from the disk | Boots to the desktop (with finding 20 switched off) |
| DiskMeter (KB/s) | 1900 / 2111 / 2266 in DOS; 2139 / 2266 / 2305 in OS/2 | 2000 / 2078 / 2070 |
| 20-round copy test (DOS) | 120 of 120 compares identical | 120 of 120 compares identical |

DiskMeter is in line with release v2026.11.19-1 (55SX 2108 / 2266 / 2305,
Model 70 1956 / 2067 / 2102), so the new DMA handling costs nothing.

## Device 1

OS/2 also sends a seek to a second drive (device 1). The spec reserves
device numbers 1-6 (Figures 2 and 21), and has a command error for this,
13h, "invalid device number for the command" (Figure 52). Releases up to
v2026.11.21-1 rejected the seek as an unknown command (error 03) instead.
From firmware v2026.11.21-2 the card answers with a command block error,
error 13h, and a device status that is neither ready nor selected.

OS/2 does the same with either answer: it reads the status block, sends
end-of-interrupt, soft-resets the card and carries on. Booting OS/2 from the
disk, it resets twice and goes straight on to reads; in the earlier logs from
installing it in the 55SX, it reset once and then read the drive's
configuration. Either way the reset looks like how OS/2 handles a missing
second drive, rather than a sign that the answer is wrong. Whether a real IBM drive
answers this way hasn't been checked: DIFDIAG only addresses devices 0 and 7.

Eric's firmware never cleared the command error code, so after the device 1
rejection every later status block, including successful reads and writes,
still reported error 03. Each command now starts with it cleared.