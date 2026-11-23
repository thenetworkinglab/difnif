// DifNif FPGA-only firmware: the DBA-ESDI drive
//
// A port of difnift.ino's command handling (Eric Schlaepfer's, with this
// fork's changes up to v2026.11.21-5) to the SoC's processor. The mailbox
// registers and their flags are the Teensy's (verilog/teensy.v, soc.v). The
// differences:
//   - Disk reads and writes go straight between the SD card and the sector
//     buffer (sdhost.v, sdbridge.v); the processor only starts them, watches
//     them, and retries a block the card reports bad, up to 3 times.
//   - A transfer past the end of the image gets "command failed" with
//     device error 07h (RBA out of range), where the Teensy firmware
//     answered with whatever was in its buffer.
//   - Writes are on the card before the host hears they're done: CMD12, or
//     the card's busy after a single block, waits for programming.
// Page numbers are the IBM DASD Storage Interface Specification, Micro
// Channel, Rev 2.2.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#include "fw.h"

// Flag register bits (difnift.ino)
#define F_ATN_FULL     (1u << 0)
#define F_ISR_FULL     (1u << 1)
#define F_CIFR_FULL    (1u << 2)
#define F_SIFR_FULL    (1u << 3)
#define F_HARD_RESET   (1u << 4)
#define F_TREQ_SET     (1u << 5)
#define F_CMD_PROG     (1u << 6)
#define F_BUSY         (1u << 7)
#define F_TREQ_STATE   (1u << 8)
#define F_CLEAR_ALL    (1u << 10)
#define F_BUF_MODE     (1u << 11)
#define F_BUF_READY    (1u << 13)   // read: a sector buffer half is free for the card
#define F_BUF_IDLE     (1u << 15)
#define F_STORED       (F_CMD_PROG | F_CLEAR_ALL | F_BUF_MODE)

#define DEV_CONTROLLER 0xE0
#define DEV_DRIVE      0x00
#define ATN_COMMAND    0x1
#define ATN_EOI        0x2
#define ATN_ABORT      0x3
#define ATN_RESET      0x4
#define ATN_DEV_MASK   0xE0
#define ATN_CMD_MASK   0x0F
#define ISR_RESET_OK   0xEA
#define ISR_FAILED     0x0C
#define ISR_CMD_ERROR  0x0E
#define ISR_ATN_ERROR  0x0F
#define ISR_DTR        0x0B
#define CMD_NO_OPT     0xC0FF
#define CMD_ERR_UNSUPP 0x03
#define CMD_ERR_INVDEV 0x13
#define DEV_ERR_RANGE  0x07
#define DEV_ERR_READ   0x05      // data ECC error (hard)
#define DEV_ERR_WRITE  0x0D      // write fault

#define PEND_INT       1
#define PEND_INT_RESET 2

enum { TS_IDLE, TS_READ, TS_WRITE, TS_PIO_READ, TS_PIO_WRITE };

static uint16_t status_block[8];
static int      status_count, status_max;
static uint16_t cmd_block[8];
static int      cmd_count;
static int      expect_cb;
static int      int_pending;
static uint8_t  sb_cmd_status, sb_cmd_error, sb_dev_status = 0x19, sb_dev_error;
static uint16_t flags_stored;
// MB_CTRL: bit 0 burst DMA, bit 2 DMA waits for the interrupt, bits 5:3 the
// bus release time after another device's -PREEMPT (mcabus.v): 000 as POS 4
// says, else 1 and the time: 00 at once, 01 3 us, 10 6 us.
// The default is 6 us whatever POS 4 says: PS/2 BIOSes write 00 there and
// their configuration utilities don't offer it, and on a Model 70 6 us gave
// 3.0 MB/s against 2.0 (sunbench raw 64 KB reads), faster at every size.
// 'p' cycles 6 us, POS 4's setting, at once, 3 us.
static uint16_t ctrl_bits = 0x0035;
static int      hold_mode = 3;        // 0 POS 4, 1 at once, 2 3 us, 3 6 us
static const uint16_t hold_ctrl[4] = { 0x0000, 0x0020, 0x0028, 0x0030 };

static void show_hold(void)
{
    static const char *const t[4] = { "at once", "3 us", "6 us", "6 us" };
    puts_("bus release after -PREEMPT: ");
    if (hold_mode == 0) {
        puts_(t[(MBOX(MB_POS4) >> 1) & 3]);
        puts_(" (POS 4)");
    } else {
        puts_(t[hold_mode - 1]);
        puts_(hold_mode == 3 ? " (default; 'p' changes it)" : " (set with 'p')");
    }
    putch('\n');
}

static uint32_t disk_size, psu_rba_max;

static void set_disk(uint32_t blocks)
{
    disk_size = (blocks / 2048) * 2048;           // whole megabytes
    if (disk_size > 0x1FF800) disk_size = 0x1FF800;   // 1023 MB
    psu_rba_max = disk_size ? disk_size - 1 : 0;
}

// Bring-up trace: each attention request and reset interrupt, with the time
// in microseconds, and the checksums after each disk transfer. Off at
// start-up: it's about 115 characters a command, 1.15 ms at 1 Mbaud, and the
// firmware waits for the log, listened to or not, so it slows small
// transfers by about half. 'v' in the serial monitor turns it on and off.
#ifndef TRACE_AT_START
#define TRACE_AT_START 0
#endif
static int trace = TRACE_AT_START;

static void show_trace(void)
{
    puts_(trace ? "trace on ('v' turns it off)\n" : "trace off ('v' turns it on)\n");
}
static uint32_t key_time;           // MICROS at the last key from the serial monitor
static int      keyed;              // ...if there has been one

static void stamp(void)
{
    puts_(" @");
    puthex(MICROS, 8);
    putch('\n');
}

static void delay_us(uint32_t us)
{
    uint32_t t0 = MICROS;
    while (MICROS - t0 < us) uart_poll();
}
static uint32_t current_rba;

// The disk transfer in progress
static int      state = TS_IDLE;
static uint32_t x_first, x_count;    // drive blocks
static int      x_stopped;           // the card's transfer ended (CMD12 sent)
static int      x_retries;
static uint32_t x_cmd_n;             // the card command's block count (to its run's end)
// A read's next card command (the next run of the image, or a retry) waits
// for a free sector buffer half: the SD clock has to run for the command
// and its response, and the card starts sending meanwhile. With both halves
// full that block was counted but dropped, and the host came up a sector
// short (found in simulation with a fragmented image).
static int      x_resume;

// Read-ahead. A read's card command (CMD18) runs on to the end of the image;
// the bridge holds the card after the command's blocks (its read limit), so
// the card has the next block ready. ra_held: that's the state of the
// current read once its blocks are through; ra_active: between commands,
// the card is held with image block ra_next ready. A read of exactly that
// block resumes it with a bridge restart and no card command, which saves
// the card's access time (about 180 us on the test card). Anything else
// (another read, a write, a reset) ends it first with CMD12.
static int      ra_held, ra_active;
static uint32_t ra_next;

static void ra_cancel(void)
{
    if (ra_active) {
        sd_stop(1);
        ra_active = 0;
    }
}
// Trace timing, microseconds from the command: the card's first block
// through the bridge, the host's first word, the card side finished
static uint32_t x_t0, x_t_card, x_t_host, x_t_done;
// Trace, reads of PROF_MIN blocks or more: the words the host took in each
// 100 us of the command, to see how steady the DMA is
#ifndef PROF_MIN
#define PROF_MIN  64
#endif
#define PROF_MAX  400
// Two slices to a word of cbuf (idle during disk transfers; the attachment
// buffer's contents don't survive a profiled read, which only matters with
// the trace on)
static int      prof_n;
static uint32_t prof_lo;
static void prof_put(int i, uint32_t v)
{
    if (i & 1) CBUF(i >> 1) = prof_lo | (v << 8);
    else prof_lo = v;
}
static uint32_t prof_get(int i)
{
    if ((i & 1) == 0 && i == prof_n - 1) return prof_lo;   // the last, unpaired
    return (CBUF(i >> 1) >> ((i & 1) * 8)) & 0xFF;
}
static uint32_t prof_t;
static uint16_t prof_words;

// Transfers through DREG a word at a time: the attachment buffer and the
// manufacturing header
// The data is in cbuf, the processor's own sector buffer in the SoC (idle
// except while the card is starting up), which saves 512 bytes of RAM. A
// card restart overwrites it; the attachment buffer is only for diagnostics.
#define PIO_WORD(i)  CBUF(i)
static int      pio_index, pio_blocks;

// ------------------------------------------------------------------
// Registers

static uint16_t flags_read(void)
{
    return (uint16_t)MBOX(MB_FLAGS);
}

static void set_flag(uint16_t f)
{
    flags_stored |= f & F_STORED;
    MBOX(MB_FLAGS) = flags_stored | F_BUSY | (f & F_TREQ_SET);
}

static void clear_flag(uint16_t f)
{
    flags_stored &= ~(f & F_STORED);
    MBOX(MB_FLAGS) = flags_stored | (F_BUSY & ~f);
}

static void do_isr(uint8_t code)
{
    sb_cmd_status = code & 0x0F;
    MBOX(MB_ISR) = code;
}

static void start_status(int len, uint8_t code)
{
    status_block[0] = (uint16_t)((len << 8) | code);
    status_count = 0;
    status_max = len;
}

static void load_status(void)
{
    status_max--;
    MBOX(MB_SIFR) = status_block[status_count++];
}

static void default_status(void)     // page 49
{
    start_status(7, (uint8_t)cmd_block[0]);
    status_block[1] = (uint16_t)((sb_cmd_status << 8) | sb_cmd_error);
    status_block[2] = (uint16_t)((sb_dev_status << 8) | sb_dev_error);
    status_block[3] = 0;
    status_block[4] = (uint16_t)current_rba;
    status_block[5] = (uint16_t)(current_rba >> 16);
    status_block[6] = 0;
}

// Ends a command with an interrupt and its status block
static void finish(uint8_t isr)
{
    do_isr((uint8_t)((cmd_block[0] & ATN_DEV_MASK) | isr));
    default_status();
    load_status();
    clear_flag(F_CMD_PROG);
    int_pending = PEND_INT;
}

// The host skipped the rest of the status block (allowed, page 25): drop
// any word still waiting
static void drop_status(uint16_t f)
{
    status_max = 0;
    if (f & F_SIFR_FULL) MBOX(MB_CTRL) = ctrl_bits | 0x0002;
}

// ------------------------------------------------------------------
// Disk transfers

static void buf_begin(int write, uint32_t n)
{
    set_flag(F_BUF_MODE);              // first: the buffer is held empty while it's off
    BR_ARM = n;
    BR_CTRL = (write ? BRC_WRITE : 0) | BRC_RESTART;
}

static void buf_end(void)
{
    clear_flag(F_BUF_MODE);
    BR_CTRL = 0;
}

// Stops whatever transfer is running (reset)
static void abort_transfer(void)
{
    if (state == TS_READ) {
        sd_stop(1);                    // reads are always CMD18
        buf_end();
    } else if (state == TS_WRITE) {
        sd_stop(x_cmd_n > 1 && !x_stopped);
        buf_end();
    }
    ra_held = 0;
    x_resume = 0;
    if (state != TS_READ) ra_cancel();
    ra_active = 0;
    state = TS_IDLE;
}

static int out_of_range(uint32_t rba, uint32_t n)
{
    return n == 0 || rba >= disk_size || n > disk_size - rba;
}

// Starts the card's part of a transfer: n blocks from image block rba. If the
// card doesn't answer it has probably been taken out and put back: start it
// again (and find disk0.img again) and try once more. 0 when started.
// A read asks the card for everything to the end of the image (sdhost
// counts at most 0xFFFF): see read-ahead above
// Both stop at the end of the image's run (fat.c): disk_progress() then
// carries on from the next one.

static int card_cmd(int write, uint32_t rba, uint32_t n)
{
    uint32_t left, lba = img_map(rba, &left);
    if (write) {
        x_cmd_n = n < left ? n : left;
        return sd_start_write(lba, x_cmd_n);
    }
    x_cmd_n = left > 0xFFFF ? 0xFFFF : left;
    return sd_start_read(lba, x_cmd_n);
}

static int card_start(int write, uint32_t rba, uint32_t n)
{
    int e = card_cmd(write, rba, n);
    if (!e) return 0;
    logline(write ? "W card command failed, status " : "R card command failed, status ", sd_status);
    if (!sd_check()) return e;         // it answers: an ordinary error
    set_disk(card_restart());
    logline("drive blocks ", disk_size);
    // Finding disk0.img read blocks into cbuf, which routes the card there:
    // back to the sector buffer, keeping the bridge's count. (Before
    // read-ahead the misrouted block just ended in a retry.)
    BR_CTRL = (write ? BRC_WRITE : 0) | BRC_CLRFAIL;
    if (out_of_range(rba, n)) return 1;
    return card_cmd(write, rba, n);
}

// The card can't do the transfer: a device error, as after 3 retries
static void fail_card(int write)
{
    buf_end();
    state = TS_IDLE;
    sb_dev_error = write ? DEV_ERR_WRITE : DEV_ERR_READ;
    finish(ISR_FAILED);
    sb_dev_error = 0;
}

static void fail_range(void)
{
    sb_dev_error = DEV_ERR_RANGE;
    finish(ISR_FAILED);
    sb_dev_error = 0;
}

// Rev P3's SD card handover. The RP2040 asks for the card (to show it as a
// USB drive, which it only does while the PS/2 is off); once no transfer is
// running, the firmware lets go of it and says so. When the RP2040 gives it
// back, the card may have been changed in any way: start it again and find
// disk0.img again. While it's lent out, disk commands fail (not ready).
static int card_lent;

static void card_handover(void)
{
    uint32_t io = P3_IO;
    if (!card_lent && (io & P3_SD_REQ) && state == TS_IDLE) {
        ra_cancel();
        card_lent = 1;
        P3_IO = P3_SD_REL;
        puts_("SD card lent to USB\n");
    } else if (card_lent && !(io & P3_SD_REQ)) {
        P3_IO = 0;
        card_lent = 0;
        puts_("SD card back from USB\n");
        set_disk(card_restart());
        logline("drive blocks ", disk_size);
    }
}

static void start_disk(int write)
{
    x_t0 = MICROS;
    x_t_card = x_t_host = x_t_done = 0;
    prof_n = 0;
    prof_t = x_t0;
    prof_words = 0;
    current_rba = cmd_block[2] | ((uint32_t)cmd_block[3] << 16);
    x_first = current_rba;
    x_count = cmd_block[1];
    x_stopped = 0;
    x_retries = 0;
    x_resume = 0;
    ra_held = 0;
    if (out_of_range(x_first, x_count)) {
        logline(write ? "W out of range " : "R out of range ", x_first);
        fail_range();
        return;
    }
    if (card_lent) {                   // lent to USB: not ready
        logline(write ? "W while lent to USB " : "R while lent to USB ", x_first);
        current_rba = x_first;
        sb_dev_error = write ? DEV_ERR_WRITE : DEV_ERR_READ;
        finish(ISR_FAILED);
        sb_dev_error = 0;
        return;
    }
    // The next sequential read, with the card held there and enough left in
    // its count: let it go
    if (!write && ra_active && x_first == ra_next
        && (SD(SD_STATUS) >> 16) >= x_count) {
        ra_active = 0;
        buf_begin(0, x_count);
        do_isr(DEV_DRIVE | ISR_DTR);
        state = TS_READ;
        return;
    }
    ra_cancel();
    buf_begin(write, x_count);
    if (card_start(write, x_first, x_count)) {
        current_rba = x_first;
        fail_card(write);
        return;
    }
    do_isr(DEV_DRIVE | ISR_DTR);       // no EOI follows this
    state = write ? TS_WRITE : TS_READ;
}

// The card or the bridge gave up on a block: start again from it
static void retry(int write)
{
    uint32_t done = BR_STATUS & 0xFFFF;
    uint32_t left = x_count - done;
    sd_stop(write ? x_cmd_n > 1 : 1);
    logline(write ? "W retry at " : "R retry at ", x_first + done);
    current_rba = x_first + done;
    if (++x_retries > 3) {
        fail_card(write);
        return;
    }
    BR_CTRL = (write ? BRC_WRITE : 0) | BRC_CLRFAIL;
    if (!write) {
        x_resume = 1;
        return;
    }
    if (card_start(write, x_first + done, left)) fail_card(write);
}

// The image's run ended mid-transfer: end that card command and start one
// at the next run, from where the bridge has got to (not a retry)
static void next_run(int write)
{
    uint32_t done = BR_STATUS & 0xFFFF;
    sd_stop(write ? x_cmd_n > 1 : 1);
    if (!write) {
        x_resume = 1;                  // disk_progress() starts it when there's room
        return;
    }
    if (card_start(write, x_first + done, x_count - done)) {
        current_rba = x_first + done;
        fail_card(write);
    }
}

static void disk_progress(uint16_t f)
{
    int write = (state == TS_WRITE);
    uint32_t br = BR_STATUS;

    if (x_resume) {
        uint32_t done;
        if (!(flags_read() & F_BUF_READY)) return;
        x_resume = 0;
        done = BR_STATUS & 0xFFFF;
        if (card_start(0, x_first + done, x_count - done)) {
            current_rba = x_first + done;
            fail_card(0);
        }
        return;
    }
    if (trace) {
        if (!x_t_card && (br & 0xFFFF)) x_t_card = MICROS - x_t0;
        if (!x_t_host && (BR_CK_COUNT >> 16)) x_t_host = MICROS - x_t0;
        if (!write && x_count >= PROF_MIN && prof_n < PROF_MAX && MICROS - prof_t >= 100) {
            uint16_t w = (uint16_t)(BR_CK_COUNT >> 16);
            uint16_t d = (uint16_t)(w - prof_words);
            prof_put(prof_n++, d > 255 ? 255 : d);
            prof_words = w;
            prof_t += 100;
        }
    }
    if (br & (1u << 16)) {                  // bridge failed
        retry(write);
        return;
    }
    // The card's transfer ended before all its blocks came through: it
    // stopped answering (sdhost gives up after about 0.67 s with no data, or
    // after a write's busy time-out). The count is read again after busy,
    // so a last block finishing just then isn't taken for a short one.
    if (!x_stopped && (br & 0xFFFF) < x_count && !sd_data_busy()
        && (BR_STATUS & 0xFFFF) < x_count) {
        // The card command's count ran out at the end of a run of the image,
        // with no error: carry on from the next run. Otherwise it failed.
        if ((sd_status >> 16) == 0 && !(sd_status & (SDS_CMD_ERRS | SDS_DATA_ERRS)))
            next_run(write);
        else
            retry(write);
        return;
    }
    if (!x_stopped && (br & 0xFFFF) == x_count) {
        if (write) {
            // Every block is through: end the card's transfer. CMD12's busy
            // (or a single block's) means it's programmed.
            if (!sd_data_busy()) {
                if (x_cmd_n > 1) sd_stop(1);
                x_stopped = 1;
            }
        } else {
            // The card is held before the next block if its count goes on;
            // if the count ran out (the end of the image), stop it
            uint32_t st = SD(SD_STATUS);
            if ((st >> 16) && (st & SDS_DATA_BUSY)) {
                ra_held = 1;
                x_stopped = 1;
            } else if (!(st & SDS_DATA_BUSY)) {
                sd_stop(1);
                x_stopped = 1;
            }
        }
        if (x_stopped) x_t_done = MICROS - x_t0;
    }
    // For a read, the host has had every word once the buffer's host side is
    // idle. That has to come from the same read of BR_STATUS as the block
    // count: f is from the top of the loop, and when the last block reached
    // the buffer in between, f still said idle and the command ended with
    // the host 3-6 words into its last sector (seen on a Model 70).
    (void)f;
    if (x_stopped && (write || (br & (1u << 17)))) {
        if (trace) {
            // What went through the sector buffer on each side; reset by the
            // bridge's restart at the start of the command
            uint32_t cs = BR_CK_SD, ch = BR_CK_HOST, cn = BR_CK_COUNT;
            puts_(" D card ");
            puthex(cs, 8);
            puts_(" host ");
            puthex(ch, 8);
            puts_(" words ");
            puthex(cn & 0xFFFF, 4);
            putch('/');
            puthex(cn >> 16, 4);
            puts_(cs != ch || (cn & 0xFFFF) != (cn >> 16) ? " MISMATCH" : "");
            // us from the command: card's first block, host's first word,
            // card side done, command done
            puts_("\n T card ");
            putdec(x_t_card);
            puts_(" host ");
            putdec(x_t_host);
            puts_(" card done ");
            putdec(x_t_done);
            puts_(" end ");
            putdec(MICROS - x_t0);
            putch('\n');
            if (prof_n) {
                // words per 100 us through the command, 20 to a line
                int i;
                for (i = 0; i < prof_n; i++) {
                    puts_(i % 20 ? " " : (i ? "\n P " : " P "));
                    putdec(prof_get(i));
                }
                putch('\n');
            }
        }
        buf_end();                     // the bridge still holds the card
        state = TS_IDLE;
        current_rba = x_first + x_count - 1;
        if (ra_held) {
            ra_held = 0;
            ra_active = 1;
            ra_next = x_first + x_count;
        }
        finish(0x01);
    }
}

// Word-at-a-time transfers through DREG (difnift.ino's unbuffered path)
static void start_pio(int write, int blocks)
{
    pio_index = 0;
    pio_blocks = blocks > 0 ? blocks : 1;
    do_isr((uint8_t)((cmd_block[0] & ATN_DEV_MASK) | ISR_DTR));
    if (write) set_flag(F_TREQ_SET);   // ask for the first word
    state = write ? TS_PIO_WRITE : TS_PIO_READ;
}

static void pio_progress(uint16_t f)
{
    if (f & F_TREQ_STATE) return;      // the host hasn't taken (or sent) a word yet
    if (state == TS_PIO_READ) {
        if (pio_index < 512) {
            MBOX(MB_DREG) = (uint16_t)PIO_WORD(pio_index >> 1);
            pio_index += 2;
            set_flag(F_TREQ_SET);
            return;
        }
    } else {
        uint16_t d = (uint16_t)MBOX(MB_DREG);
        PIO_WORD(pio_index >> 1) = d;
        pio_index += 2;
        if (pio_index < 512) {
            set_flag(F_TREQ_SET);
            return;
        }
    }
    if (--pio_blocks > 0) {            // the same 512 bytes again
        pio_index = 0;
        if (state == TS_PIO_WRITE) set_flag(F_TREQ_SET);
        return;
    }
    state = TS_IDLE;
    finish(0x01);
}

// ------------------------------------------------------------------
// Commands (page 24)

static void esdi_reset(void)          // page 22
{
    abort_transfer();
    flags_stored &= ~F_BUF_MODE;
    // difnift.ino holds the clear for 10 us, and its two log lines then put
    // the reset's interrupt some tens of microseconds after the request.
    // The processor would answer in about one, and on a Model 70 the BIOS
    // then sent a second soft reset and never asked for the drive's
    // configuration, as if it had missed the first interrupt. So the same
    // timing as the Teensy's.
    set_flag(F_CLEAR_ALL);
    delay_us(10);
    clear_flag(F_CLEAR_ALL);
    delay_us(30);
    clear_flag(F_CMD_PROG);
    expect_cb = 0;
    start_status(1, DEV_CONTROLLER);
    load_status();
    do_isr(ISR_RESET_OK);
    int_pending = PEND_INT_RESET;
    if (trace) { puts_("I EA reset complete"); stamp(); }
}

static int cmd_len(void)
{
    return (cmd_block[0] >> 14) == 1 ? 4 : 2;
}

static void process_cmd(void)
{
    uint16_t c = cmd_block[0] & CMD_NO_OPT;
    uint8_t dev = cmd_block[0] & ATN_DEV_MASK;
    int i;

    sb_cmd_error = 0;
    putch('C');
    puthex(cmd_block[0], 4);
    if (cmd_count > 2) {
        putch(' ');
        puthex(cmd_block[1], 4);
        putch(' ');
        puthex(cmd_block[3], 4);
        puthex(cmd_block[2], 4);
    }
    if (trace) stamp();
    else putch('\n');

    // Devices 1-6 are reserved (Figures 2 and 21): command error 13h
    if (dev != DEV_DRIVE && dev != DEV_CONTROLLER) {
        do_isr(dev | ISR_CMD_ERROR);
        sb_cmd_error = CMD_ERR_INVDEV;
        default_status();
        status_block[2] = 0;
        status_block[4] = 0;
        status_block[5] = 0;
        load_status();
        clear_flag(F_CMD_PROG);
        int_pending = PEND_INT;
        return;
    }

    switch (c) {
    case 0x4001:                       // read data (page 41)
        start_disk(0);
        return;
    case 0x4002:                       // write data (page 48)
    case 0x4004:                       // write with verify (page 49)
        start_disk(1);
        return;
    case 0x4003:                       // read verify (page 42)
    case 0x4005:                       // seek (page 44)
    case 0x0006:                       // park head
    case 0x0012:                       // run diagnostic test (page 43)
    case DEV_CONTROLLER | 0x0012:
    case 0x401A:                       // set max RBA (page 44)
    case 0x401B:                       // set power saving mode (page 40)
    case 0x001C:                       // power conservation (page 39)
    case DEV_CONTROLLER | 0x001C:
        if (c == 0x401A) psu_rba_max = cmd_block[2] | ((uint32_t)cmd_block[3] << 16);
        do_isr(0x01);
        default_status();
        break;
    case 0x0014:                       // get diagnostic status block (page 37)
        do_isr(0x01);
        default_status();
        status_block[3] = status_block[4] = status_block[5] = status_block[6] = 0;
        break;
    case 0x0007:                       // get command complete status: send it again
    case DEV_CONTROLLER | 0x0007:
        MBOX(MB_ISR) = 0x01;
        status_count = 0;
        status_max = (status_block[0] >> 8) ? (status_block[0] >> 8) : 1;
        break;
    case 0x0008:                       // get device status
    case DEV_CONTROLLER | 0x0008:
        start_status(3, (uint8_t)cmd_block[0]);
        status_block[1] = 0;
        status_block[2] = (uint16_t)((sb_dev_status << 8) | sb_dev_error);
        do_isr(0x01);
        break;
    case 0x0009:                       // get device configuration (pages 37, 55)
        start_status(6, (uint8_t)cmd_block[0]);
        status_block[1] = 0x0200;
        if (cmd_block[0] & (1u << 11)) {   // pseudo RBAs
            status_block[2] = (uint16_t)(psu_rba_max + 1);
            status_block[3] = (uint16_t)((psu_rba_max + 1) >> 16);
        } else {
            status_block[2] = (uint16_t)disk_size;
            status_block[3] = (uint16_t)(disk_size >> 16);
        }
        status_block[4] = (uint16_t)(disk_size / 2048);    // cylinders
        status_block[5] = (0x20 << 8) | 0x3F;             // 32 sectors, 64 heads
        do_isr(0x01);
        break;
    case DEV_CONTROLLER | 0x0009:      // get configuration, controller (page 56)
        do_isr(DEV_CONTROLLER | 0x01);
        start_status(6, (uint8_t)cmd_block[0]);
        status_block[1] = 0;
        status_block[2] = 0x0001;
        status_block[3] = 0x3101;
        status_block[4] = 0;
        status_block[5] = 0;
        break;
    case DEV_CONTROLLER | 0x000A:      // get POS information (page 39)
        do_isr(DEV_CONTROLLER | 0x01);
        start_status(5, (uint8_t)cmd_block[0]);
        i = MBOX(MB_POS01);
        status_block[1] = (uint16_t)(((i >> 8) & 0xFF) | ((i & 0xFF) << 8));
        i = MBOX(MB_POS23);
        status_block[2] = (uint16_t)(((i >> 8) & 0xFF) | ((i & 0xFF) << 8));
        status_block[3] = (uint16_t)((MBOX(MB_POS4) << 8) | 0xFF);
        status_block[4] = 0xFFFF;
        break;
    case DEV_CONTROLLER | 0x0010:      // write attachment buffer (page 48)
        start_pio(1, cmd_block[1]);
        return;
    case DEV_CONTROLLER | 0x0011:      // read attachment buffer (page 41)
        start_pio(0, cmd_block[1]);
        return;
    case 0x0015:                       // get manufacturing header (pages 38, 72)
        for (i = 0; i < 256; i++) PIO_WORD(i) = 0;
        PIO_WORD(0) = 'D' | ('E' << 8);
        PIO_WORD(1) = 'F' | ('E' << 8);
        PIO_WORD(2) = 'C' | ('T' << 8);
        PIO_WORD(4) = 0xFF << 8;           // byte 9
        start_pio(0, cmd_block[1]);
        return;
    default:
        logline("unknown command ", c);
        do_isr(dev | ISR_CMD_ERROR);
        sb_cmd_error = CMD_ERR_UNSUPP;
        default_status();
        break;
    }
    load_status();
    clear_flag(F_CMD_PROG);
    int_pending = PEND_INT;
}

static void eoi(uint16_t f)
{
    // Empty the command interface first, then clear busy. difnift.ino does
    // it the other way round, and a host that starts its next command as
    // soon as busy clears can get its first command word in before that
    // read, which throws it away (seen in simulation at the Model 70's
    // limit timing).
    (void)MBOX(MB_CIFR);
    int_pending = 0;
    drop_status(f);
    clear_flag(F_CMD_PROG);
    clear_flag(F_BUSY);
}

// ------------------------------------------------------------------
// Main loop (difnift.ino mainLoop)

void esdi_run(uint32_t blocks)
{
    int pfail_seen = 0;
    int hard_reset = 0, reset_pending = 0;
    uint16_t f;
    uint8_t atn;

    set_disk(blocks);
    logline("drive blocks ", disk_size);
    show_trace();
    show_hold();

    MBOX(MB_CTRL) = ctrl_bits;
    esdi_reset();

    for (;;) {
        uart_poll();
        card_handover();
        if ((P3_IO & P3_PFAIL) && !pfail_seen) {
            pfail_seen = 1;
            puts_("PS/2 power failing\n");
        } else if (!(P3_IO & P3_PFAIL)) {
            pfail_seen = 0;
        }
        if (UART_STAT & UART_RXHAVE) {     // a key from the serial monitor
            uint8_t k = (uint8_t)UART;
            // The Arduino serial monitor sends a line with its line ending:
            // "x" and Enter is 'x', '\n'. A line ending within 50 ms of
            // another key is part of the same line; on its own (just Enter)
            // it still prints the summary.
            int eol = (k == '\r' || k == '\n');
            if (eol && keyed && MICROS - key_time < 50000) {
                ;
            } else if (k == 'v') {
                trace = !trace;
                show_trace();
            } else if (k == 'p') {
                // 6 us, then POS 4's setting, at once, 3 us, and round again
                hold_mode = (hold_mode + 1) & 3;
                ctrl_bits = (uint16_t)((ctrl_bits & ~0x0038) | hold_ctrl[hold_mode]);
                MBOX(MB_CTRL) = ctrl_bits;
                show_hold();
            } else {
                show_status();
                logline("drive blocks ", disk_size);
                show_trace();
                show_hold();
            }
            key_time = MICROS;
            keyed = 1;
        }
        f = flags_read();

        // While the PS/2 holds the channel reset, do nothing; after it, reset
        if (f & F_HARD_RESET) {
            hard_reset = 1;
            continue;
        } else if (hard_reset) {
            hard_reset = 0;
            reset_pending = 0;
            puts_("hard reset\n");
            abort_transfer();          // so the card is back in its transfer state
            if (sd_check()) {          // swapped, or missing at power-on
                set_disk(card_restart());
                logline("drive blocks ", disk_size);
            }
            esdi_reset();
            continue;
        }

        // A soft reset waits for a write to finish
        if (reset_pending && state != TS_WRITE) {
            reset_pending = 0;
            esdi_reset();
            continue;
        }

        // The host has taken a status word, and there's another
        if (status_max > 0 && !(f & F_SIFR_FULL)) load_status();

        if (state == TS_READ || state == TS_WRITE) disk_progress(f);
        else if (state == TS_PIO_READ || state == TS_PIO_WRITE) pio_progress(f);

        // Command block words (page 24)
        if (expect_cb && (f & F_CIFR_FULL)) {
            cmd_block[cmd_count++] = (uint16_t)MBOX(MB_CIFR);
            if (cmd_count > 1 && cmd_count == cmd_len()) {
                clear_flag(F_BUSY);    // page 14: busy clears when the block is in
                set_flag(F_CMD_PROG);
                expect_cb = 0;
                process_cmd();
            } else if (cmd_count >= 8) {
                expect_cb = 0;
            }
        }

        // Attention requests
        if (f & F_ATN_FULL) {
            atn = (uint8_t)MBOX(MB_ATN);
            if (trace) {
                putch('A');
                puthex(atn, 2);
                if ((atn & ATN_CMD_MASK) == ATN_EOI) {
                    puts_(" EOI, pending ");
                    puthex((uint32_t)int_pending, 1);
                }
                stamp();
            }
            switch (atn & ATN_CMD_MASK) {
            case ATN_EOI:
                eoi(f);
                break;
            case ATN_RESET:
                if ((atn & ATN_DEV_MASK) == 0xE0) {
                    set_flag(F_BUSY);
                    puts_("soft reset\n");
                    reset_pending = 1;
                } else {
                    do_isr(ISR_ATN_ERROR | (atn & ATN_DEV_MASK));
                    int_pending = PEND_INT_RESET;
                }
                break;
            case ATN_COMMAND:
                expect_cb = 1;
                cmd_count = 0;
                break;
            case ATN_ABORT:
                break;                 // not supported, as before
            default:
                do_isr(ISR_ATN_ERROR | (atn & ATN_DEV_MASK));
                int_pending = PEND_INT_RESET;
                break;
            }
        }
    }
}
