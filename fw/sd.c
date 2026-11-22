// DifNif FPGA-only firmware: the SD card, through sdhost (verilog/sdhost.v)
//
// Start-up follows the SD specification's sequence for version 2.0 and
// later cards: 80 clocks, CMD0, CMD8, ACMD41 until ready, CMD2, CMD3,
// CMD7, ACMD6 for the 4-bit bus, then 25 MHz.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#include "fw.h"

uint32_t sd_status;
int sd_high_capacity;
static uint32_t rca;
// sample_late: see sdhost.v and docs/fpga-only.md
static const uint32_t ctrl_slow = SDC_DIV(62) | SDC_LATE;
static const uint32_t ctrl_fast = SDC_DIV(0) | SDC_BUS4 | SDC_LATE;

int sd_cmd(uint32_t idx, uint32_t arg, uint32_t flags)
{
    SD(SD_ARG) = arg;
    SD(SD_CMD) = flags | idx;
    do {
        uart_poll();                   // the log keeps going meanwhile
        sd_status = SD(SD_STATUS);
    } while (sd_status & SDS_CMD_BUSY);
    return sd_status & SDS_CMD_ERRS;
}

static int wait_data(void)
{
    do {
        uart_poll();
        sd_status = SD(SD_STATUS);
    } while (sd_status & (SDS_CMD_BUSY | SDS_DATA_BUSY));
    return sd_status & (SDS_CMD_ERRS | SDS_DATA_ERRS);
}

int sd_init(void)
{
    uint32_t t0;

    SD(SD_CTRL) = ctrl_slow;
    sd_cmd(0, 0, C_INITCLK);
    sd_cmd(0, 0, R_NONE);
    if (sd_cmd(8, 0x1AA, R_SHORT) || (SD(SD_RESP0) & 0xFFF) != 0x1AA)
        return 1;                      // no card, or a version 1 card
    t0 = MICROS;
    do {
        if (sd_cmd(55, 0, R_SHORT)) return 2;
        if (sd_cmd(41, 0x40300000, R_SHORT | R_NOCRC)) return 3;
        if (MICROS - t0 > 1000000) return 4;     // the spec allows 1 s
    } while (!(SD(SD_RESP0) & 0x80000000u));
    sd_high_capacity = (SD(SD_RESP0) >> 30) & 1;
    if (sd_cmd(2, 0, R_LONG)) return 5;
    if (sd_cmd(3, 0, R_SHORT)) return 6;
    rca = SD(SD_RESP0) & 0xFFFF0000u;
    if (sd_cmd(7, rca, R_SHORT | R_BUSY)) return 7;
    if (sd_cmd(55, rca, R_SHORT)) return 8;
    if (sd_cmd(6, 2, R_SHORT)) return 9;          // 4-bit bus
    if (!sd_high_capacity && sd_cmd(16, 512, R_SHORT)) return 10;
    SD(SD_CTRL) = ctrl_fast;
    if (sd_cmd(13, rca, R_SHORT)) return 11;
    if (((SD(SD_RESP0) >> 9) & 15) != 4) return 12;   // not in transfer state
    return 0;
}

int sd_read_cpu(uint32_t lba)
{
    int e;
    BR_CTRL = BRC_CPU | BRC_REWIND;
    SD(SD_BLKCNT) = 1;
    e = sd_cmd(17, sd_high_capacity ? lba : lba * 512, R_SHORT | D_READ);
    if (!e) e = wait_data();
    return e;
}

// Disk transfers through the bridge to the sector buffer: n blocks from
// card block lba. They run on their own; sd_data_busy() says when the
// blocks have all gone, and the bridge counts them (BR_STATUS).
int sd_start_read(uint32_t lba, uint32_t n)
{
    SD(SD_BLKCNT) = n;
    return sd_cmd(n > 1 ? 18 : 17, sd_high_capacity ? lba : lba * 512, R_SHORT | D_READ);
}

int sd_start_write(uint32_t lba, uint32_t n)
{
    SD(SD_BLKCNT) = n;
    return sd_cmd(n > 1 ? 25 : 24, sd_high_capacity ? lba : lba * 512, R_SHORT | D_WRITE);
}

int sd_data_busy(void)
{
    sd_status = SD(SD_STATUS);
    return (sd_status & SDS_DATA_BUSY) != 0;
}

// Stops sdhost's data engine, and the card's multiple-block transfer if
// one was running (CMD12 waits for a write to finish programming)
int sd_stop(int multi)
{
    SD(SD_CTRL) = ctrl_fast | SDC_ABORT;
    return multi ? sd_cmd(12, 0, R_SHORT | R_BUSY) : 0;
}

// The card answers CMD13 and is in the transfer state. A card that was
// taken out and put back has forgotten its address and doesn't answer.
int sd_check(void)
{
    if (sd_cmd(13, rca, R_SHORT)) return 1;
    return ((SD(SD_RESP0) >> 9) & 15) != 4;
}

uint8_t cbuf_byte(int i)
{
    uint32_t w = CBUF(i >> 1);
    return (uint8_t)((i & 1) ? (w >> 8) : w);
}

uint16_t cbuf_u16(int i)
{
    return (uint16_t)(cbuf_byte(i) | (cbuf_byte(i + 1) << 8));
}

uint32_t cbuf_u32(int i)
{
    return cbuf_u16(i) | ((uint32_t)cbuf_u16(i + 2) << 16);
}
