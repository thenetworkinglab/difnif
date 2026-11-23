# Rev P3: design

The detailed design behind [rev-p3-spec.md](rev-p3-spec.md): which FPGA and
RP2040 pins do what, the new circuit blocks, and how the FPGA design and
firmware support them. Status: the FPGA side is done and simulated (`make
BOARD=p3`, `./run_sim72.sh p3`); the schematic is drawn and checked
against this document (`pcb_p3/`, see [Schematic](#schematic)); there's no
layout yet.

## Block diagram

```
 PS/2 72-pin edge ──transceivers/buffers (as Rev P2; U7 gets its own DIR)──┐
                                                                         │
 PS/2 +5V ─D3─┬─ +5VD ─ 3.3 V and 1.2 V regulators (as Rev P2)           │
 USB VBUS ─LM66100─┘                                                     │
                                                                  iCE40HX4K ── config flash (SPI)
                                                                   │  │  │        │
                                     QSPI PSRAM (APS6404L) ────────┘  │  │        │ SPI, CRESET, CDONE
                                     microSD ── bus switch ── SD ─────┘  │        │
                                                    │                    │ UART, SD handshake, power-fail
 USB-C ── ESD ── RP2040 ── its own QSPI flash        └── SD ── RP2040 ────┘────────┘
```

The bus side (edge connector, U6-U12, the oscillator, regulators and
reset supervisor) is Rev P2's, unchanged except U7's direction line.

## FPGA pins

Rev P2's pins (`verilog/difnif.pcf`) without the Teensy's 25, plus these
(`verilog/difnif_p3.pcf`). The new ones are on the FPGA's left side (bank
3), where the Teensy's were, next to the SD card's; `data_dir_hi` is beside
`data_dir` (130) at the top.

| Signal | FPGA pin | Direction | To |
|---|---|---|---|
| `data_dir_hi` | 135 | out | U7 DIR (pin 2), instead of `data_dir` |
| `uart_tx` | 25 | out | RP2040 GPIO1 (UART0 RX) |
| `uart_rx` | 26 | in (pull-up) | RP2040 GPIO0 (UART0 TX) |
| `sd_req` | 33 | in | RP2040 GPIO8: wants the SD card |
| `sd_rel` | 34 | out | RP2040 GPIO9: the FPGA has let it go |
| `pfail` | 31 | in | RP2040 GPIO10: the PS/2's 5 V is failing |
| `ps_clk` | 17 | out | PSRAM SCLK |
| `ps_cs_l` | 18 | out | PSRAM CE# (with a pull-up) |
| `ps_d[0..3]` | 21, 23, 28, 29 | in/out | PSRAM SIO0-SIO3 |
| `tp[0..3]` | 32, 11, 12, 16 | out | test points TP1-TP4 |
| `led0`, `led1` | 37, 38 | out | activity and status LEDs (as Rev P2) |
| SD card | 1-4, 7-9 | | the bus switch's FPGA side (was J3) |
| config SPI, CRESET, CDONE | 65-71 | | flash, J2 (unfitted) and the RP2040 |

Spare: 10, 15, 19, 20, 22, 24, 136-139, 141-144, and 63/64 (CBSEL, with
their pull-downs). `make BOARD=p3` uses 87 of the 107 I/O pins.

## RP2040 pins

| GPIO | Function | To |
|---|---|---|
| 0 | UART0 TX | FPGA `uart_rx` (26) |
| 1 | UART0 RX | FPGA `uart_tx` (25) |
| 2 | SPI0 SCK | config flash SCK, FPGA 70 (via 33 ohm) |
| 3 | SPI0 TX | config flash SI (COPI), FPGA 67 (via 33 ohm) |
| 4 | SPI0 RX | config flash SO (CIPO), FPGA 68 |
| 5 | flash CS (GPIO) | config flash CS#, FPGA 71 (via 33 ohm; R8 pull-up stays) |
| 6 | CRESET (open-drain) | FPGA CRESET_B (with U3, the supervisor, wire-ORed) |
| 7 | CDONE | FPGA CDONE |
| 8 | `sd_req` out | FPGA 33 |
| 9 | `sd_rel` in | FPGA 34 |
| 10 | `pfail` out | FPGA 31 |
| 11 | SD bus switch select | 74CBTLV3257 S (10k pull-down: FPGA side by default) |
| 12 | card detect | microSD switch (shared with the FPGA, pin 3) |
| 22 | USB VBUS detect | divider (10k / 15k) from VBUS: the USB controller's VBUS_DET |
| 16 | SD CLK | bus switch, RP2040 side |
| 17 | SD CMD | bus switch, RP2040 side |
| 18-21 | SD D0-D3 | bus switch, RP2040 side (consecutive, for PIO SDIO) |
| 25 | status LED | its own LED |
| 26 (ADC0) | PS/2 +5 V sense | divider (10k / 15k) from the edge's +5 V: about 3.0 V when on |
| QSPI | its own flash | W25Q16 (2 MB), BOOTSEL button on QSPI_SS |
| USB DP/DM | USB-C | via 27 ohm resistors and a USBLC6-2 |
| SWD | test pads | SWCLK, SWDIO, GND, 3V3 |

The RP2040 runs from the board's 3.3 V (its 1.1 V core from its own
regulator), with a 12 MHz crystal.

### Sharing the configuration flash and CRESET

At power-up the RP2040's GPIOs are inputs with weak pull-downs (about
50 kohm). The FPGA must still boot from its flash whether the RP2040 is
running, starting or held in reset:

- CRESET_B keeps Rev P2's 10k pull-up and the supervisor (U3); the RP2040
  only ever pulls it low (open-drain: output low or input), to hold the
  FPGA while it writes the flash.
- The flash's CS# keeps its 10k pull-up (R8), which beats the RP2040's
  pull-down; SCK keeps R11. The RP2040's SPI pins stay inputs except while
  programming, and series resistors limit any overlap with the FPGA's own
  reads at configuration.
- The firmware sequence for programming: pull CRESET low, wait, drive the
  SPI pins, write the flash, release the SPI pins, release CRESET, and
  watch CDONE.
- U3 (APX803) has an open-drain output, so it and the RP2040 can both pull
  CRESET low.
- The configuration flash (U2, SST26VF080A) powers up with every block
  write-protected: send ULBPR (0x98, after a write enable) before erasing.

## Power

- **+5VD** (the regulators' input, as on Rev P2) from the edge's +5 V
  through D3 (the Schottky Rev P2 has), and from USB VBUS through an LM66100
  ideal diode. Neither source can feed the other.
- The bus-side transceivers and buffers (VCCB) stay on the edge's +5 V only,
  so on USB power the board doesn't drive the PS/2's bus.
- **The PS/2's power** is sensed by the RP2040 on ADC0 through a divider
  from the edge's +5 V: it shows the USB drive only when that's off, and
  tells the FPGA (`pfail`) when it's falling.
- USB-C: 5.1k pull-downs on CC1 and CC2. VBUS also goes, through a
  divider, to GPIO22 (VBUS_DET), so the RP2040 only connects to USB when a
  host is there, as a self-powered device must.
- On USB power alone, the FPGA and RP2040 run but the bus side doesn't: the
  74LVC8T245s turn their outputs off when either supply is off, and the
  74VHCT125 and 74LCX07 tolerate inputs with their supply off.

## SD card

The microSD socket's six lines go through two 74CBTLV3257 (quad 1-of-2 FET
bus switches) to either the FPGA (S low, the default, with a pull-down) or
the RP2040 (S high). Card-side pull-ups on CMD and D0-D3 as on Rev P2;
card detect goes to both chips.

Handover (`fw/esdi.c`, `card_handover()`):

1. The RP2040, only with the PS/2's +5 V off, raises `sd_req`.
2. The FPGA's firmware, once no transfer is running, ends any held read
   and raises `sd_rel`.
3. The RP2040 switches the card to itself and presents it as a USB drive.
4. When done, it switches the card back and lowers `sd_req`.
5. The FPGA lowers `sd_rel`, starts the card again and finds disk0.img
   again (it may have been replaced or moved).

While the card is lent, the drive answers commands with a device error
rather than hanging. Simulated in `difnif72_t.v`'s `test_p3_handover`.

## U7's direction

`mcabus.v` (`DIFNIF_P3`): `data_dir_hi` is `data_dir` during 16-bit cycles
only (-CD DS 16 asserted and -SBHE low, latched with the address). On 8-bit
reads (POS, BSR, ISR) U7 stays off and the planar's own copy of D0-D7 onto
D8-D15 is undisturbed (finding 16). The bus testbench models it
(`BOARD=3`) and checks both cases; a mutation that drives U7 as U6 fails 32
of its tests.

## QSPI PSRAM

APS6404L-3SQR-SN (8 MB, SOP-8), on six FPGA pins with a pull-up on CE#.
Until there's a controller, the FPGA holds it deselected and its data lines
are inputs with pull-ups. A controller (QSPI, quad mode) in `soc.v`, for
data first (buffers, a FAT cache) and code later through a small cache, is
the next FPGA job.

## Schematic

`pcb_p3/` is generated from Rev P2's schematic (`pcb_formfactor/`) by
`tools/p3_schematic.py`, so the bus side is Rev P2's, unchanged:

- **Top sheet:** the Teensy (U13) and R23 are gone. Its FPGA pins carry
  the new signals as global labels (`FPGA_TX`, `FPGA_RX`, `SD_REQ`,
  `SD_REL`, `PFAIL`, `PS_CLK`, `PS_~{CS}`, `PS_D0`-`PS_D3`, `TP1`-`TP4`)
  or are marked unused. Pin 135 is `DATA_DIR_HI`. The config SPI, CDONE and
  CRESET labels are global, for the RP2040.
- **DifNifBus:** U7's DIR is on `DATA_DIR_HI`; U6's stays on `DATA_DIR`.
- **SDCard:** the card's lines (`CARD_*`) go through U15/U16
  (74CBTLV3257): B1 to the FPGA (the sheet's pins, as before), B2 to the
  RP2040 (`RP_SD_*`), selected by `SD_SEL`. Card detect also goes to the
  RP2040 (`SD_CD`).
- **USB** (new): USB-C, ESD, the LM66100, the RP2040 with its flash,
  crystal, BOOTSEL button, LED, SWD header (not fitted) and decoupling,
  the series resistors to the config flash, and the two dividers.
- **PSRAM** (new): the APS6404L and the test points.

New parts are wired with short stubs and labels, in rows; move them as
you like in KiCad (it keeps the connections). The files are in Rev P2's
format (KiCad 6); KiCad 9 opens them and saves in its own. Regenerating
gives the same UUIDs, so only real changes show in a diff.

53 parts are added: the RP2040, W25Q16JVSS, 12 MHz crystal, USB-C
(HRO TYPE-C-31-M-12), USBLC6-2SC6, LM66100, 2× 74CBTLV3257, APS6404L,
BOOTSEL button, LED, 4 test pads, a 5-pin SWD header (not fitted), and
32 resistors and capacitors (0603; one 4.7 µF 0805). New parts use KiCad's
own footprint libraries.

`DifNif.kicad_pcb` is Rev P2's board, copied as a starting point for the
layout: the outline, card edge, holes and bus-side parts. Update it from
the schematic (Tools > Update PCB from Schematic) to drop the Teensy and
bring in the new parts.

ERC: the same findings as Rev P2 (its footprint libraries `Passive` and
`Active` aren't in the repo, its library symbols differ from KiCad 9's,
the `~{ADDR_SEL}` sheet pin, and power nets with no PWR_FLAG), less the
Teensy's dangling labels and the unflagged FPGA pins, plus one warning:
card detect has two names, `SD_SWITCH` (the SDCard sheet's pin) and
`SD_CD`.

## Checking

- `make BOARD=p3`: builds (4956 logic cells, 31 block RAMs, 87 I/O pins).
- `tools/timing_budget.py --p3`: all IBM timing rows pass; T54 6.6 ns,
  T22 7.8 ns.
- `./run_sim72.sh p3`: the bus model at typical and limit timing for the
  50Z, 55SX and Model 70, with U7 on its own line and the SD handover.
- `tools/p3_check.py`: exports both boards' netlists with KiCad and checks
  that Rev P2's nets are unchanged (155 of them), that every connection
  in this document is there, and that every pin in `verilog/difnif_p3.pcf`
  is wired (except `addr_sel_in_l`, unconnected on the 72-pin boards by
  design) while the Teensy's other pins are not. Swapping two labels makes
  it fail.
