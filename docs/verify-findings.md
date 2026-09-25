# Checking the findings yourself

Each finding in [formfactor-review.md](formfactor-review.md) is listed below with
the evidence, where to look, and what you should see. Every check is against
**Eric's original files** and the manufacturers' or IBM's own documents, not the
modified files in this fork or the tools written for it.

Each finding is also labelled with the kind of claim it is:

- **File fact:** visible directly in Eric's schematic, board or Verilog.
- **Spec reading:** depends on reading a datasheet or IBM table correctly.
- **Simulation:** shown by this fork's testbench, which is only as good as its
  model (see "Reproducing the simulations").
- **Inference:** a reasonable conclusion, not proven.

## Setup

**Eric's untouched files.** `main` in this fork is still Eric's code
(commit `18a4d10`). A second checkout lets you open it in KiCad without touching
your working copy:

    git -C ~/Documents/networking/difnif worktree add ~/Documents/networking/difnif-original main

Open `~/Documents/networking/difnif-original/pcb_formfactor/DifNif.kicad_pro` in
KiCad. Close it without saving, so KiCad doesn't convert the files. You can also
view the files on GitHub at `schlae/difnif`.

**Following a net in KiCad.** In the schematic editor, click a wire or label and
press the backtick key (`` ` ``) to highlight everything on that net. In the PCB
editor, click a pad; the Properties panel shows its net.

**Documents:**

| Document | Where |
|---|---|
| IBM DBA-ESDI 72-pin connector pinout | https://ardent-tool.com/storage/DBA_ESDI.html |
| IBM PS/2 Hardware Interface Technical Reference, Micro Channel chapter (scanned) | https://ardent-tool.com/docs/pdf/ps2_50-60_techref_ch2_microchannel_architecture.pdf (PDF page *n* is book page 2-*n*) |
| Nexperia 74LVC4245A datasheet | https://assets.nexperia.com/documents/data-sheet/74LVC4245A.pdf |
| TI SN74LVC8T245 datasheet | https://www.ti.com/lit/ds/symlink/sn74lvc8t245.pdf |
| Eric's Micro Channel tutorial | https://github.com/schlae/mca-tutorial |

## The findings

### 1. The FPGA's `chreset` input is floating

- **Pinout (spec reading):** in the ardent-tool table, **B14 is `CHRESET`**, with
  no minus sign, so it's active high.
- **Schematic (file fact):** on the `DifNifBus` sheet, J1 pin b14 carries the label
  `~{CHRESET}_5V`, which goes to **U8 pin 14**. U8 pin 15 has the label
  `CHRESET_5V`. Highlight that net: **nothing else is on it**.
- **Board (file fact):** in the PCB editor, U8 pad 15 has no track.
- **Verilog (file fact):** `verilog/difnif.pcf` puts `chreset` on FPGA pin 76, which
  the schematic connects to U8 pin 9 (U8 pin 15's partner). `mcabus.v` line 385:
  `assign addressed = (~addr_sel_l) & ~m_io_l & ~chreset;`. Every register access
  depends on it.
- **"Explains the 50Z problem" is an inference.** A floating input fits "register
  communications don't work correctly", but only a board can prove it. The Rev P1
  check is: bridge U8 pins 14 and 15, and see whether register access becomes
  reliable.

### 2. The 74LVC4245A supplies are swapped (both boards)

- **Datasheet (spec reading), Nexperia:**
  - The features list says "3 V bus (VCC(B))" and "5 V bus (VCC(A))".
  - The pin table puts **VCC(A) on pin 1** and **VCC(B) on pins 23 and 24**.
  - Table 4 (limiting values): **VCC(B) absolute maximum 4.6 V**.
  - Table 5: VCC(B) recommended maximum 3.6 V, with VCC(A) ≥ VCC(B).
- **Schematic (file fact):** hover over U6's power pins, or U7-U10 and U14. **Pin 1
  is on +3V3, pins 23/24 are on +5V.** It's the same on `pcb_thinkpad`.
- **The replacement (spec reading), TI SN74LVC8T245:** same pin numbers (pin 1 VCCA,
  pins 23/24 VCCB), with **both supplies allowed from 1.65 to 5.5 V**, and the same
  function table (DIR low: B to A).

### 3. `-ADL` isn't connected (resolved, not a bug)

- **Pinout:** A20 is `-ADL`; in Eric's schematic J1 a20 has a no-connect flag.
- **Why it doesn't matter (spec reading):** IBM Figure 2-34 (book pages 2-62/2-63)
  gives address and status hold times of **30 ns after -CMD falls (T9, T10)**, and
  note 2 allows latching "with the leading edge of -CMD". My first write-up
  overstated this; the review now marks it resolved.

### 4. `-CD SFDBK` isn't driven

- **Pinout:** B08 is `-CD SFDBK`, direction I (driven by the card).
- **Schematic (file fact):** J1 b8 has a no-connect flag.
- **Requirement (spec reading):** Figure 2-34, note 1 (book page 2-63): "All slaves
  must drive -CD SFDBK whenever selected".
- **Inference:** whether a 55SX or Model 70 actually *checks* it for disk I/O is
  unknown.

### 5. The address decode also answers at 0x3518

- **Verilog (file fact):** `difnif_top.v` line 112:
  `addr_sel_l <= ~(bus_a[15:4] == 12'h351);`. That compares A15-A4 only, so it
  matches 0x3510-0x351F.
- **Context (spec reading):** the ESDI registers are 8 bytes wide. 0x3518 is the
  alternate ESDI address, selected by POS. `mcabus.v` line 316's comment marks POS 2
  bit 1 as the "3510" choice.

### 6. A `wire` is assigned in an `always` block

- **Verilog (file fact):** `difnif_top.v` line 95 declares `wire addr_sel_l;`, and
  lines 108-114 assign it inside `always @ (*)`. Icarus Verilog refuses the file.

### 8. There's no key slot in the board outline

- **Board (file fact):** in the PCB editor, turn on the `User.Drawings` layer: a
  line marks the slot between pins 2 and 3. On `Edge.Cuts` there's no slot.
- **Fab files (file fact):** open `pcb_formfactor/fab/DifNifFormFactor-RevP1.zip`'s
  `DifNif-Edge_Cuts.gbr` in KiCad's GerbView. It's a plain rectangle.
- **Physical:** your WD-3158 and the 55SX cable are both keyed.

### 9. Write data is captured when -CMD falls

- **Verilog (file fact):** `mcabus.v` lines 411-446. The `always @ (negedge cmd_l)`
  block stores `bus_d` into `reg_cifr`, `reg_atn`, `reg_bcr`, `reg_dreg_write` and
  the POS registers.
- **Timing (spec reading):** Figure 2-34 (book page 2-63): **T17, write data setup
  to -CMD active, minimum 0 ns**; T18, write data hold from -CMD inactive, minimum
  30 ns. So data is only guaranteed valid *at* the falling edge, and for 30 ns
  after the rising edge.
- **That it fails (simulation):** see "Reproducing the simulations". It depends on
  the real planar giving close to 0 ns of setup. Eric's 50Z measurements show
  about 50 ns, so real machines may never hit it.
- **The link to the "shifted by one byte" write bug is an inference**, and a weak
  one.

### 10. POS bypass hides the adapter ID

- **Verilog (file fact):** `mcabus.v` line 9 has `` `define MCA_NO_POS ``. Line 385
  (the bypass version of `addressed`) leaves out `~cd_setup_l`, so the card never
  answers POS setup cycles, and the `DF9F` ID at line 313 is never readable.
- **"The 50Z/55SX/70 BIOS needs it" is an inference.** A real DBA-ESDI drive answers
  POS on these machines, but I haven't confirmed the BIOS insists on it.

### 12. The DMA request drops too late

- **Verilog (file fact):**
  - Line 339: `dma_requested` depends on `flag_treq`.
  - Line 249 and the lines after it: `flag_treq` is cleared through a two-stage
    synchronizer on the 50 MHz clock, which takes 40-60 ns.
  - Line 370: the card decides whether to compete on the rising edge of
    `ARB/-GNT`.
- **Timing (spec reading):** Figure 2-46 (book page 2-85): **T41, ARB/-GNT high from
  end of transfer, minimum 30 ns.**
- **That it bites (simulation):** only if a planar really re-arbitrates within about
  40 ns of a transfer ending. Real planars may be slower.

### 13. The card relies on re-arbitration after DMA

- **Inference from Verilog:** `dma_cycle` (line 370) only changes when `ARB/-GNT`
  rises, so after winning, the card treats I/O cycles as DMA until the next
  arbitration. That's fine if the planar always re-arbitrates after a transfer.
  Eric's own testbench (`mcabus_t.v`, around line 408) notes seeing that on the real
  50Z. A logic analyzer on real hardware would confirm it.

## Reproducing the simulations

The testbench, `verilog/difnif72_t.v`, is this fork's code. Its assumptions are
worth reading before trusting its results:

- Host timing is either IBM's Figure 2-34 limits or Eric's typical 50Z
  measurements.
- Each level-shifter pin gets a random delay of 1-7 ns (the datasheet range).
- The FPGA itself is simulated with zero internal delay.
- A floating input is modelled as "unknown", so the as-built board fails
  consistently in simulation, where real hardware would probably fail
  intermittently.

**Findings 1, 5, 9 and 10 before any fixes.** Check out the commit that added the
testbench but not the fixes (`be66ed4`), and run the quick matrix. It needs
oss-cad-suite; takes about 20 seconds.

    git -C ~/Documents/networking/difnif worktree add ~/Documents/networking/difnif-be66ed4 be66ed4
    cd ~/Documents/networking/difnif-be66ed4/verilog
    PATH=/opt/oss-cad-suite/bin:$PATH ./run_sim72.sh quick

Expected:

- The **as-built** rows fail nearly every test (finding 1).
- The **bridged / bypass** rows fail the POS tests (finding 10) and "no response at
  3518" (finding 5).
- The **bridged / enabled / limit** rows fail the host-write tests (CIFR, ATN, DREG
  writes, POS write): finding 9.
- With POS enabled, typical timing passes everything except the 0x3518 test.

**Finding 12.** The DMA tests arrived in the same commit as the fix (`53ea7dd`), so
to see the failure, undo the fix by hand in a scratch checkout:

    git -C ~/Documents/networking/difnif worktree add ~/Documents/networking/difnif-53ea7dd 53ea7dd
    cd ~/Documents/networking/difnif-53ea7dd/verilog

In `mcabus.v`, change

    wire dma_requested = control_dma_enable & flag_treq & card_enable & ~treq_pending;

back to Eric's

    wire dma_requested = control_dma_enable & flag_treq & card_enable;

then run `PATH=/opt/oss-cad-suite/bin:$PATH ./run_sim72.sh quick`. At IBM limits the
DMA tests fail with "card re-entered arbitration with a stale request"; at typical
timing they pass.

**Cleaning up** afterwards (the worktrees are just extra folders):

    git -C ~/Documents/networking/difnif worktree remove ~/Documents/networking/difnif-be66ed4 --force
    git -C ~/Documents/networking/difnif worktree remove ~/Documents/networking/difnif-53ea7dd --force
    git -C ~/Documents/networking/difnif worktree remove ~/Documents/networking/difnif-original

## Mistakes made during this review

Knowing where the reasoning went wrong before helps judge the rest:

- I first called the missing `-ADL` a timing hazard (finding 3). IBM's tables
  showed latching on `-CMD` is allowed.
- Three times the testbench reported failures that were bugs in the testbench
  itself: a shared loop counter, an end-of-test handshake in the wrong order, and a
  missing arbitration cycle in the DMA controller model. Each was traced in the
  waveforms and fixed before any result was reported.
- An early photo estimate put the IBM drive's fingers at 1.3 mm wide. You measured
  1.5 mm, matching Eric's footprint.
- The first `-CD SFDBK` wiring cut part of the ground pour off and was changed
  during layout.
