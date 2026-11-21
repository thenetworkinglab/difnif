`timescale 1ns / 100ps

//
// Self-checking testbench for the 72-pin (form factor) DifNif.
//
// Models three things around the unmodified FPGA design (difnif_top):
//   * the host: a PS/2 planar driving the DBA-ESDI edge connector with
//     Micro Channel timing from the IBM PS/2 Hardware Interface Technical
//     Reference, Figure 2-34 (I/O and memory default cycle), either at the
//     minimum/maximum limits or at typical values measured on a Model 50Z
//     (github.com/schlae/mca-tutorial)
//   * the Rev P1 board: level shifters with per-pin delays inside the
//     74LVC4245A datasheet range (1.0-7.0 ns), and the board's actual wiring,
//     including the floating FPGA chreset input (docs/formfactor-review.md,
//     finding 1)
//   * the Teensy: register accesses timed like difnift.ino's portRead and
//     portWrite, running the same mailbox handshakes as DIFDIAG
//   * the planar's central arbiter and DMA controller (Figures 2-40, 2-41,
//     2-46), optionally with a second DMA device competing for the bus.
//     The DMA controller keeps the bus while the card holds -BURST (Figures
//     2-28, 2-29, 2-42, 2-43), and in the burst tests memory refresh takes
//     place in arbitration every 15 us, so bursts get preempted. The burst
//     rules checked are T40, T43, T54 and T56; IBM PS/2 Model 50/60
//     Technical Reference, section 2.
//
// Parameters (override with iverilog -P difnif72_t.NAME=value):
//   CYCLE        default I/O cycle in ns: 300 = 50Z, 250 = 55SX, 200 = Model 70
//   WORST        0 = typical 50Z timing, 1 = Figure 2-34 limits
//   BOARD        0 = Rev P1 as built, 1 = Rev P1 with U8 pins 14/15 bridged,
//                2 = Rev P2 (bridged, plus -CD SFDBK wired to J1 B08)
//   SEED         selects the per-pin level-shifter delays and clock phase
//   N_ITER       values sent through each mailbox
//
// Build with -DMCA_USE_POS to test with the POS registers enabled.
// Pass +vcd to write difnif72_t.vcd.
//
// Prints one "RESULT:" line at the end for run_sim72.sh.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.
//

`default_nettype none
`include "version.vh"

// One level-shifter or buffer channel: a plain delay.
module lvl #(parameter integer D10 = 10) (input wire a, output wire y);
    assign #(D10 / 10.0) y = a;
endmodule

module difnif72_t;

    parameter integer CYCLE = 300;
    parameter integer WORST = 0;
    parameter integer BOARD = 0;
    parameter integer SEED = 1;
    parameter integer N_ITER = 16;

    // Level-shifter delay for one pin, in tenths of a ns: 1.0 to 7.0 ns
    function integer pin_delay(input integer seed, input integer pin);
        integer h;
        begin
            h = (seed * 7919 + pin * 104729 + seed * pin * 31) % 61;
            if (h < 0) h = -h;
            pin_delay = 10 + h;
        end
    endfunction

    // ------------------------------------------------------------------
    // Host timing, relative to the falling edge of -CMD (Figure 2-34)
    // ------------------------------------------------------------------
    localparam real T_ADDR_SU = WORST ? 85 : 150;   // T15 address, M/-IO valid to -CMD
    localparam real T_STAT_SU = WORST ? 55 : 105;   // T2  status active to -CMD
    localparam real T_ADL_ON  = WORST ? 40 : 55;    // T4  -ADL active to -CMD
    localparam real T_WD_SU   = WORST ? 0 : 50;     // T17 write data setup to -CMD
    localparam real T_ADL_OFF = WORST ? 0 : 5;      // T6  -ADL pulse >= 40 ns
    localparam real T_ADDR_H  = WORST ? 30 : 50;    // T9  address hold from -CMD
    localparam real T_STAT_H  = WORST ? 30 : 55;    // T10 status hold from -CMD
    localparam real T_WD_H    = WORST ? 30 : 55;    // T18 write data hold from -CMD rising
    localparam real T_CMD_LOW = WORST ? CYCLE - 110 : CYCLE - 100;  // T16 >= 90
    localparam real T_DS16    = 55;                 // T13 -CD DS 16 valid from address
    localparam real T_RD      = 60;                 // T20 read data valid from -CMD
    localparam real T_RD_OFF  = 40;                 // T22 read data off from -CMD rising
    localparam real T_SFDBK   = 60;                 // T14 -CD SFDBK valid from address
    localparam real T_EOT_ARB = WORST ? 30 : 100;   // T41 ARB/-GNT high after end of transfer
    localparam real T_ARB     = 300;                // T44 ARB/-GNT high (arbitration) time
    localparam real T_GNT_CMD = 115;                // T43B -CMD after ARB/-GNT low
    localparam real T_PRE_OFF = 50;                 // T42 winner releases -PREEMPT
    localparam real T_TC_SU     = 30;               // T52 -TC setup to -CMD inactive (asserted that late)
    localparam real T_BURST_ON  = 50;               // T43 -BURST active from ARB/-GNT low
    localparam real T_BURST_TC  = 30;               // T54 -BURST released from -TC active
    localparam real T_BURST_SU  = 35;               // T56 -BURST high before the last I/O -CMD rises
    localparam real T_BURST_MAX = 7800;             // T40 bus released after -PREEMPT
    localparam real T_REFRESH   = 15000;            // memory refresh interval (burst tests)

    // ESDI registers (primary address)
    localparam [15:0] A_CIFR = 16'h3510;  // write: command interface, read: status
    localparam [15:0] A_BSR  = 16'h3512;  // write: basic control, read: basic status
    localparam [15:0] A_ATN  = 16'h3513;  // write: attention, read: interrupt status
    localparam [15:0] A_DREG = 16'h3514;  // data register

    // Basic status register bits
    localparam BSR_INTR = 0, BSR_TREQ = 1, BSR_CI_FULL = 2, BSR_SI_FULL = 3, BSR_BUSY = 4;

    // Teensy-side registers and flag bits (teensy.v, difnift.ino)
    localparam [3:0] TN_FLAGS = 1, TN_ATN = 2, TN_ISR = 3, TN_CIFR = 4, TN_SIFR = 5, TN_DREG = 6;
    localparam FL_ATN = 0, FL_ISR = 1, FL_CIFR = 2, FL_SIFR = 3, FL_HARD_RESET = 4, FL_TREQ_SET = 5,
               FL_TREQ = 8;
    // Sector buffer (sectorbuf.v): register 14, flag bits 11-15
    localparam [3:0] TN_BUF = 14;
    localparam [3:0] TN_CTRL = 15;      // bit 0: burst DMA allowed; bit 1 (write 1): drop unread status;
                                        // bit 2: no DMA requests while an interrupt is pending
    localparam FL_BUF_MODE = 11, FL_BUF_DIR = 12,
               FL_BUF_GO = 13, FL_BUF_DONE = 14,                        // written as 1
               FL_BUF_READY = 13, FL_BUF_CAN_ARM = 14, FL_BUF_IDLE = 15; // read
    localparam integer N_SECT = 3;      // sectors per buffer test

    localparam integer MAX_POLL = 400;

    // ------------------------------------------------------------------
    // Edge connector (host side, 5 V)
    // ------------------------------------------------------------------
    reg [15:0] h_a;
    reg h_mio_l, h_s0_l, h_s1_l, h_cmd_l, h_adl_l, h_sbhe_l, h_setup_l, h_chreset;
    reg h_arb_gnt_l, h_tc_l;
    reg [15:0] h_wdata;
    reg h_wdrive;
    integer wd_owner;

    tri1 [15:0] h_d;          // undriven data bus reads as FFFF
    assign h_d = h_wdrive ? h_wdata : 16'bz;
    tri1 h_ds16_l, h_irq14_l, h_chrdy, h_sfdbk_l;
    tri1 [3:0] h_arb;
    tri1 h_burst_l, h_preempt_l;

    // ------------------------------------------------------------------
    // Board: connector to FPGA through the level shifters
    // ------------------------------------------------------------------
    localparam integer N_IN = 31;
    wire [N_IN-1:0] b_in = {h_a, h_mio_l, h_s0_l, h_s1_l, h_cmd_l, h_sbhe_l, h_setup_l,
                            h_arb_gnt_l, h_tc_l, h_arb, h_burst_l, h_preempt_l, h_chreset};
    wire [N_IN-1:0] f_in;
    genvar gi;
    generate
        for (gi = 0; gi < N_IN; gi = gi + 1) begin : in_path
            lvl #(.D10(pin_delay(SEED, gi))) u (.a(b_in[gi]), .y(f_in[gi]));
        end
    endgenerate

    wire f_chreset_pin = f_in[0];
    wire f_preempt_l = f_in[1], f_burst_l = f_in[2];
    wire [3:0] f_arb = f_in[6:3];
    wire f_tc_l = f_in[7], f_arb_gnt_l = f_in[8], f_setup_l = f_in[9], f_sbhe_l = f_in[10];
    wire f_cmd_l = f_in[11], f_s1_l = f_in[12], f_s0_l = f_in[13], f_mio_l = f_in[14];
    wire [15:0] f_a = f_in[30:15];

    // Rev P1: B14 (CHRESET) reaches FPGA pin 52 (chreset_l, unused) and the
    // FPGA's chreset input (pin 76) comes from the unconnected U8 pin 15.
    wire f_chreset   = BOARD >= 1 ? f_chreset_pin : 1'bx;
    wire f_chreset_l = f_chreset_pin;

    // FPGA outputs back to the connector
    wire f_ds16_l, f_irq14_l, f_chrdy_l, f_burst_o_l, f_preempt_o_l, f_data_dir, f_sfdbk_l;
    wire [3:0] f_arb_o;
    wire [9:0] b_out, f_out = {f_sfdbk_l, f_ds16_l, f_irq14_l, f_chrdy_l, f_burst_o_l, f_preempt_o_l, f_arb_o};
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : out_path
            lvl #(.D10(pin_delay(SEED, 100 + gi))) u (.a(f_out[gi]), .y(b_out[gi]));
        end
    endgenerate
    assign h_sfdbk_l = (BOARD >= 2) ? b_out[9] : 1'bz;           // Rev P2: spare 74VHCT125, push-pull
    assign h_ds16_l = b_out[8];                     // 74VHCT125, push-pull
    assign h_irq14_l = b_out[7] ? 1'bz : 1'b0;      // 74VHCT125 used as open drain
    assign h_chrdy = b_out[6] ? 1'bz : 1'b0;
    assign h_burst_l = b_out[5] ? 1'bz : 1'b0;      // 74LCX07 open drain
    assign h_preempt_l = b_out[4] ? 1'bz : 1'b0;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : arb_od
            assign h_arb[gi] = b_out[gi] ? 1'bz : 1'b0;
        end
    endgenerate

    // A second DMA device on the channel: a local arbiter as in Figure 2-27
    reg comp_want = 1'b0;       // wants a transfer (drives -PREEMPT)
    reg comp_in = 1'b0;         // taking part in the current arbitration
    reg [3:0] comp_level = 4'h2;
    wire [3:0] comp_lost;
    assign comp_lost[3] = 1'b0;
    assign comp_lost[2] = comp_lost[3] | (comp_level[3] & ~h_arb[3]);
    assign comp_lost[1] = comp_lost[2] | (comp_level[2] & ~h_arb[2]);
    assign comp_lost[0] = comp_lost[1] | (comp_level[1] & ~h_arb[1]);
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : comp_od
            assign h_arb[gi] = (comp_in && !comp_level[gi] && !comp_lost[gi]) ? 1'b0 : 1'bz;
        end
    endgenerate
    assign h_preempt_l = comp_want ? 1'b0 : 1'bz;

    // Data bus: U6/U7, DIR driven by the FPGA (high = FPGA to connector)
    wire [15:0] f_d;
    wire [15:0] d_to_f, d_to_h;
    wire b_dir;
    lvl #(.D10(pin_delay(SEED, 200))) u_dir (.a(f_data_dir), .y(b_dir));
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : data_path
            lvl #(.D10(pin_delay(SEED, 300 + gi))) u_hf (.a(h_d[gi]), .y(d_to_f[gi]));
            lvl #(.D10(pin_delay(SEED, 400 + gi))) u_fh (.a(f_d[gi]), .y(d_to_h[gi]));
        end
    endgenerate
    assign f_d = (b_dir === 1'b0) ? d_to_f : 16'bz;
    assign h_d = (b_dir === 1'b1) ? d_to_h : 16'bz;

    // ------------------------------------------------------------------
    // Teensy side
    // ------------------------------------------------------------------
    reg tn_rd, tn_wr, tn_drive;
    reg [3:0] tn_addr;
    reg [15:0] tn_dout;
    wire [15:0] tn_d = tn_drive ? tn_dout : 16'bz;
    wire tn_int, tn_clk;

    // ------------------------------------------------------------------
    // FPGA
    // ------------------------------------------------------------------
    reg clk;
    wire sd_clk, sd_cmd, led0, led1;
    wire [3:0] sd_d;

    difnif_top dut (
        .clk_10m(clk),              // simulation bypasses the PLL: this is the 50 MHz clock
        .chreset_l(f_chreset_l),
        .chreset(f_chreset),
        .cmd_l(f_cmd_l),
        .s0_w_l(f_s0_l),
        .s1_r_l(f_s1_l),
        .m_io_l(f_mio_l),
        .cd_setup_l(f_setup_l),
        .addr_sel_in_l(1'bz),       // FPGA pin 107: no connection on the 72-pin board
        .bus_a(f_a),
        .fulladdr_l(1'b0),          // R22 to ground: full address decode
        .sbhe_l(f_sbhe_l),
        .cd_ds16_l(f_ds16_l),
        .cd_chrdy_l(f_chrdy_l),
        .cd_sfdbk_l(f_sfdbk_l),
        .bus_d(f_d),
        .data_dir(f_data_dir),
        .irq14_l(f_irq14_l),
        .arb_gnt_l(f_arb_gnt_l),
        .tc_l(f_tc_l),
        .arb(f_arb),
        .burst_l(f_burst_l),
        .preempt_l(f_preempt_l),
        .arb_o(f_arb_o),
        .burst_o_l(f_burst_o_l),
        .preempt_o_l(f_preempt_o_l),
        .sd_clk(sd_clk),
        .sd_cmd(sd_cmd),
        .sd_d(sd_d),
        .sd_switch(1'b0),
        .led0(led0),
        .led1(led1),
        .tn_rd(tn_rd),
        .tn_wr(tn_wr),
        .tn_addr(tn_addr),
        .tn_d(tn_d),
        .tn_int(tn_int),
        .tn_clk(tn_clk),
        .tn30(1'b0)
    );

`ifdef DIFNIF_CPU
    // ------------------------------------------------------------------
    // Processor build (make CPU=1): the SD card in J3, with its pull-ups,
    // and the firmware's log on Teensy data line 7 (1 Mbaud)
    // ------------------------------------------------------------------
    pullup (sd_cmd);
    pullup (sd_d[0]);
    pullup (sd_d[1]);
    pullup (sd_d[2]);
    pullup (sd_d[3]);
    sdcard_model #(.MEM_BLOCKS(`MEM_BLOCKS), .CARD_BLOCKS(`CARD_BLOCKS), .IMAGE(`SDIMG))
        card (.sd_clk(sd_clk), .cmd(sd_cmd), .dat(sd_d));

    reg [8*120-1:0] log_line = 0;
    initial begin : fw_log
        integer i;
        reg [7:0] c;
        forever begin
            @(negedge tn_d[7]);
            #500;
            for (i = 0; i < 8; i = i + 1) begin
                #1000;
                c[i] = tn_d[7];
            end
            #1000;
            if (c == 8'h0A) begin
                if ($test$plusargs("fwlog")) $display("%t   fw: %0s", $realtime, log_line);
                log_line = 0;
            end else if (c != 8'h0D) begin
                log_line = {log_line[8*119-1:0], c};
            end
        end
    end
`endif

    // 50 MHz, with a seed-dependent phase against the bus
    initial begin
        clk = 1'b0;
        #((SEED * 37 % 200) / 10.0);
        forever #10 clk = ~clk;
    end

    // ------------------------------------------------------------------
    // Error bookkeeping
    // ------------------------------------------------------------------
    integer errors = 0, test_errors = 0, spec_errors = 0, tests_failed = 0;
    integer tests_run = 0;
    reg aborted;
    string test_name;

    task automatic fail(input string msg);
        begin
            test_errors = test_errors + 1;
            errors = errors + 1;
            if (test_errors <= 4)
                $display("  %t  FAIL  %0s", $realtime, msg);
        end
    endtask

    task automatic spec(input string msg);
        begin
            spec_errors = spec_errors + 1;
            if (spec_errors <= 6)
                $display("  %t  SPEC  %0s", $realtime, msg);
        end
    endtask

    task automatic begin_test(input string name);
        begin
            test_name = name;
            test_errors = 0;
            aborted = 1'b0;
            tests_run = tests_run + 1;
        end
    endtask

    task automatic end_test;
        begin
            if (test_errors) tests_failed = tests_failed + 1;
            $display("%-4s %0s", test_errors ? "FAIL" : "ok", test_name);
        end
    endtask

    // Bus contention on the connector data lines
    always @(h_wdrive or b_dir)
        if (h_wdrive && b_dir !== 1'b0)
            fail("data bus contention: host writing while the card drives");

    // ------------------------------------------------------------------
    // Host bus cycle
    // ------------------------------------------------------------------
    realtime t_next_cmd;
    integer cyc_id = 0;

    task automatic wait_until(input realtime t);
        if (t > $realtime) #(t - $realtime);
    endtask

    // End of a host cycle: -CMD rises, then write data is released
    event end_cycle;
    realtime end_rise;
    realtime t_last_rise;
    reg end_rd, end_tc, end_mem;
    integer end_id;

    // -BURST as the DMA controller sees it at the end of each I/O cycle, and
    // how long it had been steady (T56)
    realtime t_burst_chg = 0;
    reg io_burst_l = 1'b1;
    realtime io_burst_age = 0;
    always @(h_burst_l) t_burst_chg = $realtime;

    always @(end_cycle) begin : cycle_end
        realtime rise;
        reg rd, tc, mem;
        integer id;
        rise = end_rise;
        rd = end_rd;
        tc = end_tc;
        mem = end_mem;
        id = end_id;
        if (tc) begin
            // -TC as late as T52 allows, after the cycle's address and
            // status have gone invalid
            wait_until(rise - T_TC_SU);
            h_tc_l = 1'b0;
        end
        wait_until(rise);
        if (!mem) begin
            io_burst_l = h_burst_l;
            io_burst_age = rise - t_burst_chg;
        end
        h_cmd_l = 1'b1;
        if (tc) begin
            wait_until(rise + 10);  // T53
            h_tc_l = 1'b1;
        end
        if (!rd) begin
            wait_until(rise + T_WD_H);
            if (wd_owner == id) h_wdrive = 1'b0;
        end
    end

    // One I/O or setup cycle. For reads, rdata is the byte or word as the
    // planar would see it after data steering.
    task automatic mca_cycle(input rd, input mem, input setup, input tc, input [15:0] addr,
                             input word, input expect_ds16, input expect_sel,
                             input [15:0] wdata, output [15:0] rdata);
        realtime t0, t_rise;
        reg ds16, card16;
        reg [15:0] raw, early;
        integer my_id;
        begin
            cyc_id = cyc_id + 1;
            my_id = cyc_id;
            t0 = t_next_cmd;
            if (t0 < $realtime + T_ADDR_SU) t0 = $realtime + T_ADDR_SU;
            t_rise = t0 + T_CMD_LOW;
            t_next_cmd = t0 + CYCLE;
            t_last_rise = t_rise;

            wait_until(t0 - T_ADDR_SU);
            h_a = addr;
            h_mio_l = mem;
            h_setup_l = ~setup;
            h_sbhe_l = word ? 1'b0 : ~addr[0];

            wait_until(t0 - T_STAT_SU);
            if (rd) h_s1_l = 1'b0; else h_s0_l = 1'b0;

            wait_until(t0 - T_ADDR_SU + T_DS16);
            ds16 = ~h_ds16_l;
            if (h_ds16_l === 1'bx || ds16 !== expect_ds16)
                fail($sformatf("-CD DS 16 = %b in %0s cycle at %h, expected %0s", h_ds16_l,
                               mem ? "memory" : "I/O", addr,
                               expect_ds16 ? "asserted" : "not asserted"));
            card16 = (ds16 === 1'b1);

            if (BOARD >= 2) begin
                wait_until(t0 - T_ADDR_SU + T_SFDBK);
                if (h_sfdbk_l === 1'bx || ~h_sfdbk_l !== expect_sel)
                    fail($sformatf("-CD SFDBK = %b in %0s cycle at %h, expected %0s", h_sfdbk_l,
                                   mem ? "memory" : "I/O", addr,
                                   expect_sel ? "asserted" : "not asserted"));
            end

            wait_until(t0 - T_ADL_ON);
            h_adl_l = 1'b0;

            if (!rd) begin
                wait_until(t0 - T_WD_SU);
                // Unused byte lanes carry garbage
                if (card16 && word) h_wdata = wdata;
                else if (card16 && addr[0]) h_wdata = {wdata[7:0], 8'hxx};
                else h_wdata = {8'hxx, wdata[7:0]};
                h_wdrive = 1'b1;
                wd_owner = my_id;
            end

            wait_until(t0 - T_ADL_OFF);
            h_adl_l = 1'b1;


            wait_until(t0);
            h_cmd_l = 1'b0;

            // Address and status stop being valid: the next address may appear
            fork
                begin
                    wait_until(t0 + T_ADDR_H);
                    h_a = 16'hxxxx;
                    h_mio_l = 1'bx;
                    h_sbhe_l = 1'bx;
                    h_setup_l = 1'bx;
                end
                begin
                    wait_until(t0 + T_STAT_H);
                    h_s0_l = 1'b1;
                    h_s1_l = 1'b1;
                end
            join

            // End of cycle runs in cycle_end so the next cycle can overlap it
            end_rise = t_rise;
            end_rd = rd;
            end_tc = tc;
            end_mem = mem;
            end_id = my_id;
            -> end_cycle;

            rdata = 16'hxxxx;
            if (rd) begin
                wait_until(t0 + T_RD);
                early = h_d;
                wait_until(t_rise);
                #0.05 raw = h_d;    // sampled as -CMD rises
                // On an 8-bit read the data belongs on D0-D7. A 32-bit planar
                // (Model 70) copies it onto D8-D15 itself for odd addresses,
                // so anything else the card drives there fights that copy.
                // (Status that changes during the read, finding 11, is
                // reported by the T20 check below instead.)
                if (!card16 && b_dir === 1'b1 && early === raw && raw[15:8] !== raw[7:0])
                    fail($sformatf("8-bit read of %h: card drives %h on D8-D15, not a copy of D0-D7 (%h)",
                                   addr, raw[15:8], raw[7:0]));
                if (card16 && word) rdata = raw;
                else if (card16 && addr[0]) rdata = {8'h00, raw[15:8]};
                else rdata = {8'h00, raw[7:0]};
                if (early !== raw)
                    spec($sformatf("read of %h not valid %0.0f ns after -CMD (T20): %h then %h",
                                   addr, T_RD, early, raw));
                wait_until(t_rise + T_RD_OFF);
                if (b_dir === 1'b1)
                    spec($sformatf("card still driving data %0.0f ns after -CMD rose (T22)", T_RD_OFF));
            end
        end
    endtask

    // Where the card should answer: 3510-3517, or 3518-351F with the
    // alternate address selected in POS 2
    reg alt_base = 1'b0;
    reg card_on = 1'b1;     // cleared while the POS build's card is disabled
    reg [3:0] card_level = 4'hE;    // arbitration level set in POS 2
    function selected(input [15:0] addr);
        selected = card_on && (addr[15:3] == {12'h351, alt_base});
    endfunction

    // ESDI register numbers 0, 1 and 4 are 16-bit (mcabus.v cd_ds16_l)
    function is16(input [15:0] addr);
        is16 = selected(addr) && (addr[2:1] == 2'b00 || addr[2:0] == 3'h4);
    endfunction

    task automatic host_in(input [15:0] addr, input word, output [15:0] d);
        mca_cycle(1, 0, 0, 0, addr, word, is16(addr), selected(addr), 16'h0, d);
    endtask

    task automatic host_out(input [15:0] addr, input word, input [15:0] d);
        reg [15:0] dummy;
        mca_cycle(0, 0, 0, 0, addr, word, is16(addr), selected(addr), d, dummy);
    endtask

    task automatic pos_in(input [2:0] r, output [7:0] d);
        reg [15:0] w;
        begin
            mca_cycle(1, 0, 1, 0, 16'h0100 + r, 0, 0, 0, 16'h0, w);
            d = w[7:0];
        end
    endtask

    task automatic pos_out(input [2:0] r, input [7:0] d);
        reg [15:0] dummy;
        mca_cycle(0, 0, 1, 0, 16'h0100 + r, 0, 0, 0, {8'h00, d}, dummy);
    endtask

    // Poll the basic status register until a bit has the wanted value
    task automatic host_wait_bsr(input integer bit_n, input value, output ok);
        reg [15:0] bsr;
        integer i;
        begin
            ok = 1'b0;
            for (i = 0; i < MAX_POLL && !aborted && !ok; i = i + 1) begin
                host_in(A_BSR, 0, bsr);
                if (bsr[bit_n] === value) ok = 1'b1;
            end
            if (!ok && !aborted) begin
                fail($sformatf("host: BSR bit %0d never became %b (last BSR %h)", bit_n, value, bsr[7:0]));
                aborted = 1'b1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Teensy register access, timed like difnift.ino portRead/portWrite
    // ------------------------------------------------------------------
    task automatic tn_read(input [3:0] a, output [15:0] d);
        begin
            tn_addr = a;
            #20 tn_rd = 1'b1;
            #200 d = tn_d;
            tn_rd = 1'b0;
            #40;
        end
    endtask

    task automatic tn_write(input [3:0] a, input [15:0] d);
        begin
            tn_addr = a;
            tn_dout = d;
            tn_drive = 1'b1;
            #20 tn_wr = 1'b1;
            #200 tn_wr = 1'b0;
            #20 tn_drive = 1'b0;
            #20;
        end
    endtask

    // The Teensy's sector buffer accesses, at difnift.ino's timing: 80 ns
    // strobes, and a wait after each read for the next word
    task automatic tn_buf_write(input [15:0] d);
        begin
            tn_addr = TN_BUF;
            tn_dout = d;
            tn_drive = 1'b1;
            #5 tn_wr = 1'b1;
            #80 tn_wr = 1'b0;
            #5 tn_drive = 1'b0;
            #60;
        end
    endtask

    task automatic tn_buf_read(output [15:0] d);
        begin
            tn_addr = TN_BUF;
            #5 tn_rd = 1'b1;
            #80 d = tn_d;
            tn_rd = 1'b0;
            #120;
        end
    endtask

    task automatic tn_wait_flag(input integer bit_n, input value, output ok);
        tn_wait_flag_n(bit_n, value, MAX_POLL, ok);
    endtask

    task automatic tn_wait_flag_n(input integer bit_n, input value, input integer polls, output ok);
        reg [15:0] fl;
        integer i;
        begin
            ok = 1'b0;
            for (i = 0; i < polls && !aborted && !ok; i = i + 1) begin
                tn_read(TN_FLAGS, fl);
                if (fl[bit_n] === value) ok = 1'b1;
            end
            if (!ok && !aborted) begin
                fail($sformatf("teensy: flag bit %0d never became %b (last flags %h)", bit_n, value, fl));
                aborted = 1'b1;
            end
        end
    endtask

    function [15:0] bpat(input integer i, input [15:0] salt);
        reg [31:0] p;
        begin
            p = i * 32'h9E37 + 32'h1234;
            bpat = p[15:0] ^ salt;
        end
    endfunction

    function [15:0] pattern(input integer i, input [15:0] salt);
        pattern = {i[7:0] ^ 8'hA5, i[7:0] ^ 8'h3C} ^ salt;
    endfunction

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    task automatic test_reset_state;
        reg [15:0] d;
        begin
            begin_test("BSR reads 00 after reset");
            host_in(A_BSR, 0, d);
            if (d[7:0] !== 8'h00) fail($sformatf("BSR = %h", d[7:0]));
            end_test;
        end
    endtask

    task automatic test_version;
        reg [15:0] d;
        reg [15:0] want [0:5];
        integer i;
        begin
            want[0] = `FPGA_VERSION_YEAR;
            want[1] = `FPGA_VERSION_DATE;
            want[2] = `FPGA_VERSION_COUNT;
`ifdef MCA_USE_POS
            want[3] = 16'h0001;
`else
            want[3] = 16'h0000;
`endif
            want[4] = 16'h0000;
            want[5] = 16'h0000;
            begin_test("Teensy reads version registers 10-13, and 0 at 14-15");
            for (i = 0; i < 6; i = i + 1) begin
                tn_read(10 + i, d);
                if (i == 5) d = d & 16'h0007;   // 15: bits 15-3 report host activity
                if (d !== want[i])
                    fail($sformatf("register %0d = %h, expected %h", 10 + i, d, want[i]));
            end
            end_test;
        end
    endtask

    task automatic test_pos;
        reg [7:0] lo, hi, p2;
        begin
            begin_test("POS adapter ID reads DF9F");
            pos_in(0, lo);
            pos_in(1, hi);
            if ({hi, lo} !== 16'hDF9F) fail($sformatf("adapter ID = %h%h", hi, lo));
            end_test;

            // Enable the card the way the BIOS does: POS 2 = card enable,
            // arbitration level E, fairness, primary address
            begin_test("POS 2 write and read back");
            pos_out(2, 8'b0_1_1110_0_1);
            pos_in(2, p2);
            if (p2 !== 8'b0_1_1110_0_1) fail($sformatf("POS 2 = %h", p2));
            end_test;
        end
    endtask

    reg watch_en = 1'b0, drove = 1'b0;
    always @(b_dir) if (watch_en && b_dir !== 1'b0) drove = 1'b1;

    task automatic test_not_selected(input [15:0] addr, input string name);
        reg [15:0] d;
        begin
            begin_test(name);
            drove = 1'b0;
            watch_en = 1'b1;
            host_in(addr, 0, d);
            watch_en = 1'b0;
            if (drove) fail($sformatf("card drove the data bus for a read of %h", addr));
            end_test;
        end
    endtask

    // POS 2 bit 1 moves the card to the alternate address
    task automatic test_alt_address;
        reg [15:0] d;
        begin
            begin_test("POS 2 alternate address moves card to 3518");
            // POS registers are stored as -CMD rises, so the new address takes
            // effect only after the POS write ends. Let it finish before the
            // next cycle starts rather than overlapping it.
            pos_out(2, 8'b0_1_1110_1_1);
            wait_until(t_next_cmd);
            alt_base = 1'b1;
            drove = 1'b0;
            watch_en = 1'b1;
            host_in(16'h3512, 0, d);
            watch_en = 1'b0;
            if (drove) fail("card still answers at 3512");
            host_in(16'h351A, 0, d);
            if (d[7:0] !== 8'h00) fail($sformatf("BSR at 351A = %h", d[7:0]));
            pos_out(2, 8'b0_1_1110_0_1);
            wait_until(t_next_cmd);
            alt_base = 1'b0;
            host_in(A_BSR, 0, d);
            if (d[7:0] !== 8'h00) fail($sformatf("BSR back at 3512 = %h", d[7:0]));
            end_test;
        end
    endtask

    // Channel reset: leave the card in use (DMA and interrupts enabled in the
    // BCR, a transfer requested so it's bidding for the bus), pulse CHRESET,
    // and check it's back in its power-on state with the Teensy told
    task automatic test_channel_reset;
        reg [15:0] d, fl;
        reg [7:0] p2;
        begin
            begin_test("channel reset returns the card to its power-on state");
            host_out(A_BSR, 0, 16'h0003);
            tn_write(TN_FLAGS, 16'h0001 << FL_TREQ_SET);
            #1000;
            if (h_preempt_l !== 1'b0) fail("set-up: card isn't requesting the bus before the reset");
            wait_until(t_next_cmd);

            h_chreset = 1'b1;
            #2000;
            tn_read(TN_FLAGS, fl);
            if (fl[FL_HARD_RESET] !== 1'b1) fail("Teensy isn't told about the reset (hard-reset flag clear)");
            if (h_preempt_l !== 1'b1) fail("card still requesting the bus during the reset");
            h_chreset = 1'b0;
            #2000;
            if (t_next_cmd < $realtime) t_next_cmd = $realtime;

            tn_read(TN_FLAGS, fl);
            if (fl[FL_HARD_RESET] !== 1'b0) fail("hard-reset flag still set after the reset");
            if (fl[FL_TREQ] !== 1'b0) fail("transfer request survived the reset");
            if (h_preempt_l !== 1'b1) fail("card requesting the bus after the reset");
`ifdef MCA_USE_POS
            pos_in(2, p2);
            if (p2 !== 8'b0_1_1110_0_0) fail($sformatf("POS 2 = %h after the reset, expected 78 (card disabled)", p2));
            card_on = 1'b0;
            drove = 1'b0;
            watch_en = 1'b1;
            host_in(A_BSR, 0, d);
            watch_en = 1'b0;
            if (drove) fail("disabled card answered at 3512 after the reset");
            // Configure it again, as the BIOS would
            pos_out(2, {2'b01, card_level, 2'b01});
            wait_until(t_next_cmd);
            card_on = 1'b1;
`endif
            host_in(A_BSR, 0, d);
            if (d[7:0] !== 8'h00) fail($sformatf("BSR = %h after the reset, expected 00 (BCR and flags cleared)", d[7:0]));
            end_test;
        end
    endtask

    // Host to Teensy: command interface register (16-bit)
    task automatic test_cifr;
        integer ia, ib;
        reg ok;
        reg [15:0] d;
        begin
            begin_test("CIFR mailbox, host to Teensy");
            fork
                for (ia = 0; ia < N_ITER && !aborted; ia = ia + 1) begin
                    host_wait_bsr(BSR_CI_FULL, 1'b0, ok);
                    if (ok) host_out(A_CIFR, 1, pattern(ia, 16'h0000));
                end
                for (ib = 0; ib < N_ITER && !aborted; ib = ib + 1) begin
                    tn_wait_flag(FL_CIFR, 1'b1, ok);
                    if (ok) begin
                        tn_read(TN_CIFR, d);
                        if (d !== pattern(ib, 16'h0000))
                            fail($sformatf("CIFR #%0d: Teensy read %h, host wrote %h", ib, d, pattern(ib, 16'h0000)));
                    end
                end
            join
            end_test;
        end
    endtask

    // Teensy to host: status interface register (16-bit)
    // The host may end a command (EOI) without reading all of the status
    // block (IBM DASD spec 3.3). The Teensy then drops the unread word, so
    // "status interface full" doesn't still show at the next command
    // (OS/2 1.1 hung on that).
    task automatic test_sifr_clear;
        reg ok;
        reg [15:0] d, fl;
        begin
            begin_test("unread status word dropped by the Teensy (register 15 bit 1)");
            tn_write(TN_SIFR, 16'h5A5A);
            host_wait_bsr(BSR_SI_FULL, 1'b1, ok);
            if (!ok) fail("status interface full not shown after the Teensy wrote SIFR");
            tn_write(TN_CTRL, 16'h0001);    // bit 1 clear: nothing to drop
            #300;
            host_in(A_BSR, 0, d);
            if (d[BSR_SI_FULL] !== 1'b1) fail("writing register 15 without bit 1 cleared status interface full");
            tn_write(TN_CTRL, 16'h0002);
            #300;
            host_in(A_BSR, 0, d);
            if (d[BSR_SI_FULL] !== 1'b0) fail($sformatf("status interface full still set after the Teensy dropped it: BSR %h", d));
            tn_read(TN_FLAGS, fl);
            if (fl[FL_SIFR] !== 1'b0) fail($sformatf("Teensy still sees SIFR full: flags %h", fl));
            tn_read(TN_CTRL, d);
            if (d[2:0] !== 3'b000) fail($sformatf("register 15 reads %h after the strobe, expected bits 2-0 clear", d));
            end_test;
        end
    endtask

    task automatic test_sifr;
        integer ia, ib;
        reg ok;
        reg [15:0] d;
        begin
            begin_test("SIFR mailbox, Teensy to host");
            fork
                for (ia = 0; ia < N_ITER && !aborted; ia = ia + 1) begin
                    tn_wait_flag(FL_SIFR, 1'b0, ok);
                    if (ok) tn_write(TN_SIFR, pattern(ia, 16'h1111));
                end
                for (ib = 0; ib < N_ITER && !aborted; ib = ib + 1) begin
                    host_wait_bsr(BSR_SI_FULL, 1'b1, ok);
                    if (ok) begin
                        host_in(A_CIFR, 1, d);
                        if (d !== pattern(ib, 16'h1111))
                            fail($sformatf("SIFR #%0d: host read %h, Teensy wrote %h", ib, d, pattern(ib, 16'h1111)));
                    end
                end
            join
            end_test;
        end
    endtask

    // Host to Teensy: attention register (8-bit), with the busy handshake
    task automatic test_atn;
        integer ia, ib;
        reg ok;
        reg [15:0] d;
        begin
            begin_test("ATN mailbox, host to Teensy");
            fork
                for (ia = 0; ia < N_ITER && !aborted; ia = ia + 1) begin
                    host_wait_bsr(BSR_BUSY, 1'b0, ok);
                    if (ok) host_out(A_ATN, 0, {8'h00, pattern(ia, 16'h0000) >> 8});
                end
                for (ib = 0; ib < N_ITER && !aborted; ib = ib + 1) begin
                    tn_wait_flag(FL_ATN, 1'b1, ok);
                    if (ok) begin
                        tn_read(TN_ATN, d);
                        if (d[7:0] !== pattern(ib, 16'h0000) >> 8)
                            fail($sformatf("ATN #%0d: Teensy read %h, host wrote %h", ib, d[7:0],
                                           pattern(ib, 16'h0000) >> 8));
                        tn_write(TN_FLAGS, 16'h0000);   // clear busy
                    end
                end
            join
            end_test;
        end
    endtask

    // Teensy to host: interrupt status register (8-bit)
    // Register 15 bits 15-3 (fork): the host's BSR reads, counted; BCR's
    // interrupt and DMA enables; and IRQ 14 as the card drives it. Also the
    // first check of the IRQ 14 line itself at the connector.
    task automatic test_host_diag;
        reg [15:0] d0, d1, d;
        integer i;
        begin
            begin_test("register 15 reports BSR reads, BCR and IRQ 14; IRQ 14 at the connector");
            host_out(A_BSR, 0, 16'h0000);           // BCR: interrupts and DMA off
            tn_read(TN_CTRL, d0);
            for (i = 0; i < 3; i = i + 1) host_in(A_BSR, 0, d);
            #300;
            tn_read(TN_CTRL, d1);
            if (d1[15:9] !== d0[15:9] + 7'd3)
                fail($sformatf("BSR read count went from %0d to %0d after 3 reads", d0[15:9], d1[15:9]));
            if (d1[8:3] !== 6'b000000) fail($sformatf("register 15 = %h with BCR 00 and no interrupt", d1));
            tn_write(TN_ISR, 16'h0001);             // interrupt, but not enabled
            #300;
            tn_read(TN_CTRL, d);
            if (d[5] !== 1'b0 || h_irq14_l !== 1'b1) fail("IRQ 14 asserted with BCR interrupt enable off");
            host_out(A_BSR, 0, 16'h0003);           // interrupts and DMA on
            #300;
            tn_read(TN_CTRL, d);
            if (d[5:3] !== 3'b111) fail($sformatf("register 15 = %h, expected IRQ, interrupt enable, DMA enable", d));
            if (h_irq14_l !== 1'b0) fail("IRQ 14 not low at the connector with an interrupt enabled");
            host_in(A_ATN, 0, d);                   // the host reads ISR
            #300;
            if (h_irq14_l !== 1'b1) fail("IRQ 14 still low after the host read ISR");
            tn_read(TN_CTRL, d);
            if (d[5] !== 1'b0) fail("register 15 still shows IRQ 14 after the host read ISR");
            host_out(A_BSR, 0, 16'h0000);
            end_test;
        end
    endtask

    task automatic test_isr;
        integer ia, ib;
        reg ok;
        reg [15:0] d;
        begin
            begin_test("ISR mailbox, Teensy to host");
            fork
                for (ia = 0; ia < N_ITER && !aborted; ia = ia + 1) begin
                    tn_wait_flag(FL_ISR, 1'b0, ok);
                    if (ok) tn_write(TN_ISR, {8'h00, pattern(ia, 16'h2222) >> 8});
                end
                for (ib = 0; ib < N_ITER && !aborted; ib = ib + 1) begin
                    host_wait_bsr(BSR_INTR, 1'b1, ok);
                    if (ok) begin
                        host_in(A_ATN, 0, d);
                        if (d[7:0] !== pattern(ib, 16'h2222) >> 8)
                            fail($sformatf("ISR #%0d: host read %h, Teensy wrote %h", ib, d[7:0],
                                           pattern(ib, 16'h2222) >> 8));
                    end
                end
            join
            end_test;
        end
    endtask

    // Host to Teensy: data register, as in a sector write
    task automatic test_dreg_write;
        integer ia, ib;
        reg ok;
        reg [15:0] d;
        begin
            begin_test("DREG host writes (sector write path)");
            fork
                for (ia = 0; ia < N_ITER && !aborted; ia = ia + 1) begin
                    host_wait_bsr(BSR_TREQ, 1'b1, ok);
                    if (ok) host_out(A_DREG, 1, pattern(ia, 16'h5A5A));
                end
                for (ib = 0; ib < N_ITER && !aborted; ib = ib + 1) begin
                    tn_wait_flag(FL_TREQ, 1'b0, ok);
                    if (ok && ib > 0) begin
                        tn_read(TN_DREG, d);
                        if (d !== pattern(ib - 1, 16'h5A5A))
                            fail($sformatf("DREG #%0d: Teensy read %h, host wrote %h", ib - 1, d,
                                           pattern(ib - 1, 16'h5A5A)));
                    end
                    if (ok) tn_write(TN_FLAGS, 16'h0001 << FL_TREQ_SET);   // request next word
                end
            join
            if (!aborted) begin
                // The request flag clears on the host's next bus cycle
                host_in(A_BSR, 0, d);
                tn_wait_flag(FL_TREQ, 1'b0, ok);
                tn_read(TN_DREG, d);
                if (d !== pattern(N_ITER - 1, 16'h5A5A))
                    fail($sformatf("DREG #%0d: Teensy read %h, host wrote %h", N_ITER - 1, d,
                                   pattern(N_ITER - 1, 16'h5A5A)));
            end
            end_test;
        end
    endtask

    // Teensy to host: data register, as in a sector read
    task automatic test_dreg_read;
        integer ia, ib;
        reg ok;
        reg [15:0] d;
        begin
            begin_test("DREG host reads (sector read path)");
            fork
                for (ia = 0; ia < N_ITER && !aborted; ia = ia + 1) begin
                    tn_wait_flag(FL_TREQ, 1'b0, ok);
                    if (ok) begin
                        tn_write(TN_DREG, pattern(ia, 16'hC3C3));
                        tn_write(TN_FLAGS, 16'h0001 << FL_TREQ_SET);
                    end
                end
                for (ib = 0; ib < N_ITER && !aborted; ib = ib + 1) begin
                    host_wait_bsr(BSR_TREQ, 1'b1, ok);
                    if (ok) begin
                        host_in(A_DREG, 1, d);
                        if (d !== pattern(ib, 16'hC3C3))
                            fail($sformatf("DREG #%0d: host read %h, Teensy wrote %h", ib, d, pattern(ib, 16'hC3C3)));
                    end
                end
            join
            end_test;
        end
    endtask

    // ------------------------------------------------------------------
    // Central arbiter and DMA controller
    // ------------------------------------------------------------------
    integer dma_done;               // transfers completed for the card
    reg dma_hold_at_n = 1'b0;       // stop after n transfers without arbitrating again
    realtime t_dma_start;
    integer dma_extra;              // transfers the card won with nothing to send
    reg [15:0] dma_buf [0:4095];    // "system memory"

    // Burst mode. The card may only burst in the burst tests, and only
    // while it holds the grant: -BURST goes low within T43 of ARB/-GNT going
    // low, is released within T54 of -TC, and is high by the next
    // arbitration.
    reg burst_allowed = 1'b0;       // this test lets the card burst
    reg card_granted = 1'b0;        // the card won the current grant
    reg burst_seen = 1'b0;          // ...and asserted -BURST in it
    realtime t_grant = 0;
    integer n_bursts, burst_words, burst_max;   // statistics for the burst tests

    always @(negedge h_burst_l) if (h_burst_l === 1'b0) begin
        if (!burst_allowed)
            fail("card asserted -BURST (burst DMA not allowed in this test)");
        else if (!card_granted || h_arb_gnt_l !== 1'b0)
            fail("card asserted -BURST without holding the grant");
        else begin
            burst_seen = 1'b1;
            if ($realtime - t_grant > T_BURST_ON)
                fail($sformatf("-BURST asserted %0.1f ns after ARB/-GNT went low (T43, max %0.0f)",
                               $realtime - t_grant, T_BURST_ON));
        end
    end
    always @(posedge h_arb_gnt_l)
        if (h_burst_l === 1'b0) fail("-BURST still low when arbitration started");
    reg tc_in_burst = 1'b0;         // -TC came while the card held -BURST
    always @(negedge h_tc_l) begin : tc_burst
        if (h_burst_l === 1'b0) tc_in_burst = 1'b1;
        #(T_BURST_TC);
        if (h_burst_l === 1'b0)
            fail($sformatf("-BURST still low %0.0f ns after -TC (T54)", T_BURST_TC));
    end

    // Memory refresh: the planar asks for the channel every T_REFRESH and
    // refreshes while ARB/-GNT is in the arbitrate state (level -2, page 2-55)
    // When another requester (not the card) last raised -PREEMPT. Set in
    // the same step as the request, so the T40 check never sees a new
    // request with an old time.
    realtime t_pre_other = 0;

    reg refresh_on = 1'b0, refresh_want = 1'b0;
    initial forever begin
        #(T_REFRESH);
        if (refresh_on && !refresh_want) begin
            t_pre_other = $realtime;
            refresh_want = 1'b1;
        end
    end
    assign h_preempt_l = refresh_want ? 1'b0 : 1'bz;

    task automatic comp_ask;
        if (!comp_want) begin
            t_pre_other = $realtime;
            comp_want = 1'b1;
        end
    endtask

    // One arbitration cycle, starting T41 after the last transfer ended
    task automatic arbitrate(output [3:0] winner);
        reg [15:0] d;
        begin
            wait_until(t_last_rise + T_EOT_ARB);
            h_arb_gnt_l = 1'b1;
            card_granted = 1'b0;
            burst_seen = 1'b0;
            comp_in = comp_want;
            if (refresh_want) begin
                // A refresh cycle: the card must ignore it
                mca_cycle(1, 1, 0, 0, 16'h0000, 1, 0, 0, 16'h0, d);
                refresh_want = 1'b0;
            end
            #(T_ARB);
            winner = h_arb;
            if (^winner === 1'bx) fail($sformatf("arbitration bus unresolved: %b", winner));
            h_arb_gnt_l = 1'b0;
            t_grant = $realtime;
            card_granted = (winner == card_level);
            t_next_cmd = $realtime + T_GNT_CMD;
            if (winner != comp_level) comp_in = 1'b0;
            if (winner == card_level) begin
                #(T_PRE_OFF);
                if (b_out[4] !== 1'b1)
                    fail($sformatf("card still driving -PREEMPT %0.0f ns after winning (T42)", T_PRE_OFF));
            end
        end
    endtask

    // The planar's DMA controller moving one word. Its I/O cycles carry an
    // address the card must ignore: alternate between DREG and garbage.
    // Returns once the I/O cycle has ended, with io_burst_l set.
    task automatic dma_transfer(input to_card, input integer k, input last);
        reg [15:0] d, io_addr;
        begin
            io_addr = k[0] ? A_DREG : 16'hxxxx;
            if (to_card) begin
                // DMA read: memory read, then I/O write to the card
                mca_cycle(1, 1, 0, 0, 16'h2000 + 2 * k, 1, 0, 0, 16'h0, d);
                mca_cycle(0, 0, 0, last, io_addr, 1, 1, 1, dma_buf[k], d);
                wait_until(t_last_rise + 0.1);
            end else begin
                // DMA write: I/O read from the card, then memory write
                mca_cycle(1, 0, 0, last, io_addr, 1, 1, 1, 16'h0, d);
                dma_buf[k] = d;
                mca_cycle(0, 1, 0, 0, 16'h2000 + 2 * k, 1, 0, 0, d, d);
            end
        end
    endtask

    // A transfer for the competing device: the card must stay out of it
    task automatic dma_other;
        reg [15:0] d;
        begin
            mca_cycle(1, 1, 0, 0, 16'h4000, 1, 0, 0, 16'h0, d);
            mca_cycle(0, 0, 0, 0, 16'h0000, 1, 0, 0, 16'h1234, d);  // its own port
        end
    endtask

    // Run the bus until n transfers for the card have completed. The CPU
    // does unrelated I/O between arbitrations; the competitor asks for the
    // bus now and then.
    task automatic dma_run(input to_card, input integer n, input compete);
        reg [3:0] winner;
        reg [15:0] d;
        reg after_card, more;
        integer loops, blen;
        realtime t_ref;
        begin
            dma_done = 0;
            dma_extra = 0;
            n_bursts = 0;
            burst_words = 0;
            burst_max = 0;
            t_dma_start = $realtime;
            for (loops = 0; dma_done < n && loops < 40 * n && !aborted; loops = loops + 1) begin
                // CPU cycles to an unrelated port while nobody is asking
                watch_en = 1'b1;
                if (loops[0]) host_out(16'h0080, 0, loops);
                else host_in(16'h0080, 0, d);
                watch_en = 1'b0;
                if (drove) begin
                    fail("card drove the data bus during a CPU cycle to 0080");
                    drove = 1'b0;
                end
                if (compete && (loops % 3 == 1)) comp_ask;

                // Arbitrate when anyone wants the bus. Every transfer is
                // followed by another arbitration cycle (T41); the bus goes
                // back to the CPU when nobody wins it.
                // When nobody wins, the CPU gets at least one cycle before the
                // next arbitration.
                if (h_preempt_l === 1'b0 && dma_done < n && !aborted) begin
                    arbitrate(winner);
                    after_card = 1'b0;
                    while (winner != 4'hF && !aborted) begin
                        if (winner == card_level) begin
                            // The Teensy can't re-arm this quickly, so a win
                            // straight after the card's own transfer means it
                            // bid with a request that was already serviced.
                            if (after_card) dma_extra = dma_extra + 1;
                            // Transfers until -BURST is high at the end of an
                            // I/O cycle (one transfer when the card doesn't
                            // burst), -TC, or a channel time-out (T40)
                            blen = 0;
                            more = 1'b1;
                            while (more && !aborted) begin
                                if (dma_done >= n) begin
                                    fail("card won arbitration after its last transfer");
                                    aborted = 1'b1;
                                end else begin
                                    dma_transfer(to_card, dma_done, dma_done == n - 1);
                                    dma_done = dma_done + 1;
                                    blen = blen + 1;
                                end
                                if (io_burst_l === 1'bx) fail("-BURST unknown at the end of an I/O cycle");
                                if (burst_seen && io_burst_age < T_BURST_SU && dma_done < n)
                                    fail($sformatf("-BURST changed %0.1f ns before -CMD rose (T56, min %0.0f)",
                                                   io_burst_age, T_BURST_SU));
                                more = io_burst_l === 1'b0 && dma_done < n;
                                // Another requester waiting: the card must let go within T40
                                if (more && (comp_want || refresh_want)) begin
                                    t_ref = t_pre_other > t_grant ? t_pre_other : t_grant;
                                    if ($realtime - t_ref > T_BURST_MAX) begin
                                        fail($sformatf("card kept the bus %0.1f us after -PREEMPT (T40, max 7.8)",
                                                       ($realtime - t_ref) / 1000.0));
                                        more = 1'b0;
                                    end
                                end
                                // The competitor asks for the bus in the middle of a burst
                                if (more && compete && dma_done % 97 == 50) comp_ask;
                            end
                            if (blen > 1) begin
                                n_bursts = n_bursts + 1;
                                burst_words = burst_words + blen;
                                if (blen > burst_max) burst_max = blen;
                            end
                            after_card = 1'b1;
                        end else if (winner == comp_level) begin
                            dma_other;
                            comp_want = 1'b0;
                            after_card = 1'b0;
                        end else begin
                            fail($sformatf("arbitration won by unknown level %h", winner));
                            aborted = 1'b1;
                        end
                        if (!aborted && dma_hold_at_n && dma_done >= n)
                            winner = 4'hF;      // leave the bus as it is
                        else if (!aborted)
                            arbitrate(winner);
                    end
                end
            end
            if (dma_done < n && !aborted) begin
                fail($sformatf("only %0d of %0d DMA transfers happened", dma_done, n));
                aborted = 1'b1;
            end
            comp_want = 1'b0;
            if ($test$plusargs("rate"))
                $display("      %0d transfers in %0.1f us: %0.2f us per word", dma_done,
                         ($realtime - t_dma_start) / 1000.0, ($realtime - t_dma_start) / 1000.0 / dma_done);
        end
    endtask

    // Sector write: DMA from memory into DREG, read out by the Teensy
    task automatic test_dma_to_card(input compete, input string name);
        integer k, ib;
        reg ok;
        reg [15:0] d;
        begin
            begin_test(name);
            for (k = 0; k < N_ITER; k = k + 1) dma_buf[k] = pattern(k, 16'h6969);
            host_out(A_BSR, 0, 16'h0002);       // BCR: DMA enable
            fork
                dma_run(1, N_ITER, compete);
                for (ib = 0; ib <= N_ITER && !aborted; ib = ib + 1) begin
                    tn_wait_flag(FL_TREQ, 1'b0, ok);
                    if (ok && ib > 0) begin
                        tn_read(TN_DREG, d);
                        if (d !== pattern(ib - 1, 16'h6969))
                            fail($sformatf("DMA word %0d: Teensy read %h, memory held %h", ib - 1, d,
                                           pattern(ib - 1, 16'h6969)));
                    end
                    if (ok && ib < N_ITER) tn_write(TN_FLAGS, 16'h0001 << FL_TREQ_SET);
                end
            join
            if (dma_extra) fail($sformatf("card re-entered arbitration with a stale request %0d times", dma_extra));
            host_out(A_BSR, 0, 16'h0000);
            end_test;
        end
    endtask

    // Sector read: Teensy fills DREG, DMA moves it into memory
    task automatic test_dma_from_card(input compete, input string name);
        integer k, ib;
        reg ok;
        begin
            begin_test(name);
            for (k = 0; k < N_ITER; k = k + 1) dma_buf[k] = 16'hxxxx;
            host_out(A_BSR, 0, 16'h0002);
            fork
                dma_run(0, N_ITER, compete);
                for (ib = 0; ib < N_ITER && !aborted; ib = ib + 1) begin
                    tn_wait_flag(FL_TREQ, 1'b0, ok);
                    if (ok) begin
                        tn_write(TN_DREG, pattern(ib, 16'h9696));
                        tn_write(TN_FLAGS, 16'h0001 << FL_TREQ_SET);
                    end
                end
            join
            for (k = 0; k < N_ITER && !aborted; k = k + 1)
                if (dma_buf[k] !== pattern(k, 16'h9696))
                    fail($sformatf("DMA word %0d: memory got %h, Teensy wrote %h", k, dma_buf[k],
                                   pattern(k, 16'h9696)));
            if (dma_extra) fail($sformatf("card re-entered arbitration with a stale request %0d times", dma_extra));
            host_out(A_BSR, 0, 16'h0000);
            end_test;
        end
    endtask

    // Burst tests: allow burst DMA in the FPGA, and turn on memory refresh so
    // that bursts get preempted
    task automatic burst_begin(input burst);
        begin
            if (burst) begin
                tn_write(TN_CTRL, 16'h0001);
                burst_allowed = 1'b1;
                refresh_on = 1'b1;
            end
        end
    endtask

    task automatic burst_end(input burst);
        begin
            if (burst) begin
                if (!aborted && n_bursts == 0) fail("the card never burst");
                $display("      %0d bursts, %0.1f words on average, longest %0d; %0.2f us per word",
                         n_bursts, n_bursts ? 1.0 * burst_words / n_bursts : 0.0, burst_max,
                         ($realtime - t_dma_start) / 1000.0 / (dma_done ? dma_done : 1));
                tn_write(TN_CTRL, 16'h0000);
                refresh_on = 1'b0;
                refresh_want = 1'b0;
                burst_allowed = 1'b0;
            end
        end
    endtask

    // Burst ended by the DMA controller: its count runs out (-TC) in the
    // middle of a burst, with more words still in the buffer. The card must
    // let go of -BURST within T54, and the words up to the count must arrive.
    task automatic test_burst_tc;
        integer k, w, n;
        reg ok;
        reg [3:0] winner;
        reg [15:0] base;
        begin
            begin_test("burst: -TC in the middle of a burst");
            burst_begin(1);
            refresh_on = 1'b0;          // so the burst is still going at -TC
            n = 256 + 37;
            tc_in_burst = 1'b0;
            for (k = 0; k < 512; k = k + 1) dma_buf[k] = 16'hxxxx;
            base = 16'h0080 | (16'h1 << FL_BUF_MODE);
            tn_write(TN_FLAGS, base);
            for (k = 0; k < 2; k = k + 1) begin
                tn_wait_flag_n(FL_BUF_READY, 1'b1, 4000, ok);
                for (w = 0; w < 256 && ok; w = w + 1)
                    tn_buf_write(bpat(k * 256 + w, 16'h7C7C));
                if (ok) tn_write(TN_FLAGS, base | (16'h1 << FL_BUF_GO));
            end
            host_out(A_BSR, 0, 16'h0002);
            // The card still has words after the count runs out and would bid
            // for the bus again, so stop there, turn the buffer off, and only
            // then let the bus go back to the CPU.
            dma_hold_at_n = 1'b1;
            dma_run(0, n, 0);
            dma_hold_at_n = 1'b0;
            if (!aborted && !tc_in_burst) fail("-TC didn't come during a burst (test needs another count)");
            #2000;
            if (h_burst_l !== 1'b1) fail("-BURST low after the DMA count ran out");
            tn_write(TN_FLAGS, 16'h0080);   // buffer off: the rest is thrown away
            #1000;
            if (!aborted) begin
                arbitrate(winner);
                if (winner != 4'hF) fail($sformatf("level %h won arbitration with the buffer off", winner));
            end
            for (k = 0; k < n && !aborted; k = k + 1)
                if (dma_buf[k] !== bpat(k, 16'h7C7C))
                    fail($sformatf("DMA word %0d: memory got %h, Teensy wrote %h", k, dma_buf[k],
                                   bpat(k, 16'h7C7C)));
            host_out(A_BSR, 0, 16'h0000);
            burst_end(1);
            end_test;
        end
    endtask

    // n words from the Teensy to memory by DMA, the old way (DREG + TREQ),
    // with -TC on the last
    task automatic dma_words_from_card(input integer n);
        integer ib;
        reg ok;
        begin
            fork
                dma_run(0, n, 0);
                for (ib = 0; ib < n && !aborted; ib = ib + 1) begin
                    tn_wait_flag(FL_TREQ, 1'b0, ok);
                    if (ok) begin
                        tn_write(TN_DREG, 16'hC0DE + ib);
                        tn_write(TN_FLAGS, 16'h0001 << FL_TREQ_SET);
                    end
                end
            join
        end
    endtask

    // Terminal count resets DMA enable when POS 3 bit 6 is 0, as on IBM's
    // drives: the card mustn't ask for DMA again until the host re-enables
    // it (OS/2 1.1 hung without this). With bit 6 set, DMA stays enabled.
    task automatic test_tc_dma_reset;
        reg [15:0] d;
        integer i;
        reg asked;
        begin
            begin_test("-TC resets DMA enable (POS 3 bit 6 = 0); not with bit 6 set");
            host_out(A_BSR, 0, 16'h0002);
            dma_words_from_card(2);
            #300;
            host_in(A_BSR, 0, d);
            if (d[7] !== 1'b0) fail($sformatf("BSR %h after -TC: DMA still enabled", d));
            // More data ready, DMA not re-enabled: the card must not ask
            tn_write(TN_DREG, 16'hBEEF);
            tn_write(TN_FLAGS, 16'h0001 << FL_TREQ_SET);
            asked = 1'b0;
            for (i = 0; i < 50; i = i + 1) begin
                #100;
                if (b_out[4] === 1'b0) asked = 1'b1;
            end
            if (asked) fail("card asked for the bus (-PREEMPT) after -TC, before the host re-enabled DMA");
            // The host re-enables DMA: now it asks, and the word goes across
            host_out(A_BSR, 0, 16'h0002);
            #300;
            if (b_out[4] !== 1'b0) fail("card didn't ask for the bus after the host re-enabled DMA");
            dma_run(0, 1, 0);
            if (!aborted && dma_buf[0] !== 16'hBEEF) fail($sformatf("word after re-enabling: %h", dma_buf[0]));
            // POS 3 bit 6 set: DMA stays enabled after -TC
            pos_out(3, 8'h40);
            host_out(A_BSR, 0, 16'h0002);
            dma_words_from_card(1);
            #300;
            host_in(A_BSR, 0, d);
            if (d[7] !== 1'b1) fail($sformatf("BSR %h after -TC with POS 3 bit 6 set: DMA should stay enabled", d));
            pos_out(3, 8'h00);
            host_out(A_BSR, 0, 16'h0000);
            end_test;
        end
    endtask

    // With register 15 bit 2, the card asks for DMA only once the host has
    // read the interrupt status: OS/2 1.1 enables DMA before it handles
    // "data transfer ready" and programs the DMA controller.
    task automatic test_isr_gate;
        reg [15:0] d;
        integer i;
        reg asked;
        begin
            begin_test("register 15 bit 2: no DMA request until the host reads the interrupt status");
            tn_write(TN_CTRL, 16'h0004);
            tn_write(TN_ISR, 16'h000B);             // data transfer ready
            tn_write(TN_DREG, 16'hFACE);
            tn_write(TN_FLAGS, 16'h0001 << FL_TREQ_SET);
            host_out(A_BSR, 0, 16'h0003);           // DMA and interrupts on
            asked = 1'b0;
            for (i = 0; i < 30; i = i + 1) begin
                #100;
                if (b_out[4] === 1'b0) asked = 1'b1;
            end
            if (asked) fail("card asked for the bus with the interrupt still pending");
            host_in(A_ATN, 0, d);                   // the host reads ISR
            if (d[7:0] !== 8'h0B) fail($sformatf("ISR read %h, expected 0B", d[7:0]));
            #300;
            if (b_out[4] !== 1'b0) fail("card didn't ask for the bus after the host read the interrupt status");
            dma_run(0, 1, 0);
            if (!aborted && dma_buf[0] !== 16'hFACE) fail($sformatf("DMA word %h, expected FACE", dma_buf[0]));
            tn_write(TN_CTRL, 16'h0000);
            host_out(A_BSR, 0, 16'h0000);
            end_test;
        end
    endtask

    // Sector buffer, disk read: the Teensy loads sectors into the buffer,
    // DMA moves them to memory. slow: the Teensy takes 400 us over each
    // sector, so the host has to wait for it.
    task automatic test_buf_from_card(input compete, input slow, input burst, input string name);
        integer k, sct, w;
        reg ok;
        reg [15:0] fl;
        reg [15:0] base;
        begin
            begin_test(name);
            burst_begin(burst);
            for (k = 0; k < N_SECT * 256; k = k + 1) dma_buf[k] = 16'hxxxx;
            base = 16'h0080 | (16'h1 << FL_BUF_MODE);   // busy bit left alone
            tn_write(TN_FLAGS, base);
            tn_read(TN_FLAGS, fl);
            if (fl[15:11] !== 5'b10101)
                fail($sformatf("buffer on for a disk read: flags %h, expected idle, ready, mode", fl));
            host_out(A_BSR, 0, 16'h0002);
            fork
                dma_run(0, N_SECT * 256, compete);
                begin
                    for (sct = 0; sct < N_SECT && !aborted; sct = sct + 1) begin
                        if (slow) #400000;
                        tn_wait_flag_n(FL_BUF_READY, 1'b1, 4000, ok);
                        for (w = 0; w < 256 && ok; w = w + 1)
                            tn_buf_write(bpat(sct * 256 + w, 16'hB00F));
                        if (ok) tn_write(TN_FLAGS, base | (16'h1 << FL_BUF_GO));
                    end
                    tn_wait_flag_n(FL_BUF_IDLE, 1'b1, 8000, ok);
                end
            join
            for (k = 0; k < N_SECT * 256 && !aborted; k = k + 1)
                if (dma_buf[k] !== bpat(k, 16'hB00F))
                    fail($sformatf("DMA word %0d (sector %0d): memory got %h, Teensy wrote %h", k, k / 256,
                                   dma_buf[k], bpat(k, 16'hB00F)));
            tn_write(TN_FLAGS, 16'h0080);
            tn_read(TN_FLAGS, fl);
            if (fl[15:11] !== 5'b00000) fail($sformatf("buffer off: flags %h, bits 11-15 should be 0", fl));
            host_out(A_BSR, 0, 16'h0000);
            burst_end(burst);
            end_test;
        end
    endtask

    // Sector buffer, disk write: the Teensy arms halves, DMA fills them from
    // memory, the Teensy reads each full one out. slow: 400 us before reading
    // each sector, so the host has to wait for room.
    task automatic test_buf_to_card(input compete, input slow, input burst, input string name);
        integer k, sct, w, armed;
        reg ok;
        reg [15:0] fl, d;
        reg [15:0] base;
        begin
            begin_test(name);
            burst_begin(burst);
            for (k = 0; k < N_SECT * 256; k = k + 1) dma_buf[k] = bpat(k, 16'h0DD5);
            base = 16'h0080 | (16'h1 << FL_BUF_MODE) | (16'h1 << FL_BUF_DIR);
            tn_write(TN_FLAGS, base);
            tn_read(TN_FLAGS, fl);
            if (fl[15:11] !== 5'b11011)
                fail($sformatf("buffer on for a disk write: flags %h, expected idle, can arm, dir, mode", fl));
            armed = 0;
            for (k = 0; k < 2 && armed < N_SECT; k = k + 1) begin
                tn_write(TN_FLAGS, base | (16'h1 << FL_BUF_GO));
                armed = armed + 1;
            end
            host_out(A_BSR, 0, 16'h0002);
            fork
                dma_run(1, N_SECT * 256, compete);
                for (sct = 0; sct < N_SECT && !aborted; sct = sct + 1) begin
                    tn_wait_flag_n(FL_BUF_READY, 1'b1, 4000, ok);
                    if (slow) #400000;
                    for (w = 0; w < 256 && ok; w = w + 1) begin
                        tn_buf_read(d);
                        if (d !== bpat(sct * 256 + w, 16'h0DD5))
                            fail($sformatf("sector %0d word %0d: Teensy read %h, memory held %h", sct, w,
                                           d, bpat(sct * 256 + w, 16'h0DD5)));
                    end
                    if (ok) tn_write(TN_FLAGS, base | (16'h1 << FL_BUF_DONE));
                    if (ok && armed < N_SECT) begin
                        tn_wait_flag(FL_BUF_CAN_ARM, 1'b1, ok);
                        if (ok) tn_write(TN_FLAGS, base | (16'h1 << FL_BUF_GO));
                        armed = armed + 1;
                    end
                end
            join
            tn_read(TN_FLAGS, fl);
            if (!aborted && fl[FL_BUF_IDLE] !== 1'b1) fail($sformatf("buffer not idle after the transfer: flags %h", fl));
            tn_write(TN_FLAGS, 16'h0080);
            host_out(A_BSR, 0, 16'h0000);
            burst_end(burst);
            end_test;
        end
    endtask

`ifdef DIFNIF_CPU
    // ------------------------------------------------------------------
    // Processor build: the PS/2's side of ESDI commands (DASD spec section
    // 3), against the firmware in ../fw and the SD card model
    // ------------------------------------------------------------------

    // Polls a BSR bit for up to t_us microseconds
    task automatic esdi_wait(input integer bit_n, input value, input integer t_us, output ok);
        reg [15:0] bsr;
        realtime t_end;
        begin
            ok = 1'b0;
            bsr = 16'hxxxx;
            t_end = $realtime + t_us * 1000.0;
            while (!ok && $realtime < t_end && !aborted) begin
                host_in(A_BSR, 0, bsr);
                if (bsr[bit_n] === value) ok = 1'b1;
                else #1000;
            end
            if (!ok && !aborted) begin
                fail($sformatf("host: BSR bit %0d not %b after %0d us (BSR %h)", bit_n, value, t_us, bsr[7:0]));
                aborted = 1'b1;
            end
        end
    endtask

    // Waits for an interrupt and reads the interrupt status
    task automatic esdi_intr(input integer t_us, output [7:0] isr);
        reg ok;
        reg [15:0] d;
        begin
            isr = 8'hxx;
            esdi_wait(BSR_INTR, 1'b1, t_us, ok);
            if (ok) begin
                host_in(A_ATN, 0, d);
                isr = d[7:0];
            end
        end
    endtask

    task automatic esdi_expect_intr(input integer t_us, input [7:0] want, input string what);
        reg [7:0] isr;
        begin
            esdi_intr(t_us, isr);
            if (!aborted && isr !== want) begin
                fail($sformatf("%0s: interrupt status %h, expected %h", what, isr, want));
                aborted = 1'b1;
            end
        end
    endtask

    reg [15:0] sblk [0:7];      // status block
    task automatic esdi_status(input integer n);
        integer i;
        reg ok;
        reg [15:0] w;     // (an output straight into sblk[i] isn't written back)
        begin
            for (i = 0; i < 8; i = i + 1) sblk[i] = 16'hxxxx;
            for (i = 0; i < n && !aborted; i = i + 1) begin
                esdi_wait(BSR_SI_FULL, 1'b1, 2000, ok);
                if (ok) begin
                    host_in(A_CIFR, 1, w);
                    sblk[i] = w;
                end
            end
        end
    endtask

    task automatic esdi_eoi(input [7:0] dev);
        host_out(A_ATN, 0, {8'h00, dev | 8'h02});
    endtask

    reg [15:0] cblk [0:3];      // command block
    task automatic esdi_command(input [7:0] dev, input integer n);
        integer i;
        reg ok;
        begin
            esdi_wait(BSR_BUSY, 1'b0, 2000, ok);
            if (ok) host_out(A_ATN, 0, {8'h00, dev | 8'h01});
            for (i = 0; i < n && !aborted; i = i + 1) begin
                esdi_wait(BSR_CI_FULL, 1'b0, 2000, ok);
                if (ok) host_out(A_CIFR, 1, cblk[i]);
            end
        end
    endtask

    // Interrupt, status block and EOI that end a command
    task automatic esdi_complete(input [7:0] dev, input [7:0] isr, input integer n, input string what);
        begin
            esdi_expect_intr(50000, isr, what);
            esdi_status(n);
            if (!aborted && sblk[0][15:8] !== n[7:0])
                fail($sformatf("%0s: status block length %h, expected %0d", what, sblk[0][15:8], n));
            esdi_eoi(dev);
        end
    endtask

    function [15:0] img_word(input integer rba, input integer w);
        img_word = {card.mem[(`IMG_LBA + rba) * 512 + 2 * w + 1], card.mem[(`IMG_LBA + rba) * 512 + 2 * w]};
    endfunction

    task automatic test_cpu_reset(input string name, input is_soft);
        begin
            begin_test(name);
            if (is_soft) host_out(A_ATN, 0, 16'h00E4);
            esdi_complete(8'hE0, 8'hEA, 1, "reset");
            if (!aborted && sblk[0] !== 16'h01E0) fail($sformatf("reset status block %h", sblk[0]));
            end_test;
        end
    endtask

    task automatic test_cpu_config;
        begin
            begin_test("get device configuration: the image's size");
            cblk[0] = 16'h0609;
            cblk[1] = 16'h0000;
            esdi_command(8'h00, 2);
            esdi_complete(8'h00, 8'h01, 6, "get configuration");
            if (!aborted && {sblk[3], sblk[2]} !== `IMG_BLOCKS)
                fail($sformatf("configuration: %0d blocks, expected %0d", {sblk[3], sblk[2]}, `IMG_BLOCKS));
            end_test;
        end
    endtask

    // Read or write n sectors from rba by burst DMA, and check the data
    task automatic test_cpu_rw(input write, input integer rba, input integer n, input string name);
        integer k, bad;
        begin
            begin_test(name);
            if (write) for (k = 0; k < n * 256; k = k + 1) dma_buf[k] = pattern(k, 16'h5EC7) ^ (rba << 4);
            cblk[0] = write ? 16'h4602 : 16'h4601;
            cblk[1] = n;
            cblk[2] = rba;
            cblk[3] = 16'h0000;
            esdi_command(8'h00, 4);
            esdi_expect_intr(20000, 8'h0B, "data transfer ready");
            host_out(A_BSR, 0, 16'h0002);       // BCR: DMA enable
            if (!aborted) dma_run(write, n * 256, 0);
            esdi_complete(8'h00, 8'h01, 7, write ? "write" : "read");
            if (!aborted && {sblk[5], sblk[4]} !== rba + n - 1)
                fail($sformatf("status block: last RBA %0d, expected %0d", {sblk[5], sblk[4]}, rba + n - 1));
            bad = 0;
            for (k = 0; k < n * 256 && !aborted; k = k + 1)
                if (dma_buf[k] !== img_word(rba + k / 256, k % 256)) bad = bad + 1;
            if (bad) fail($sformatf("%0d of %0d words differ between memory and the card", bad, n * 256));
            host_out(A_BSR, 0, 16'h0000);
            end_test;
        end
    endtask

    task automatic test_cpu_range;
        begin
            begin_test("read past the end of the image: command failed, RBA out of range");
            cblk[0] = 16'h4601;
            cblk[1] = 2;
            cblk[2] = `IMG_BLOCKS - 1;
            cblk[3] = 16'h0000;
            esdi_command(8'h00, 4);
            esdi_complete(8'h00, 8'h0C, 7, "read past the end");
            if (!aborted && sblk[2][7:0] !== 8'h07) fail($sformatf("device error %h, expected 07", sblk[2][7:0]));
            end_test;
        end
    endtask

    task automatic test_cpu_device1;
        begin
            begin_test("seek to device 1: command error 13h");
            cblk[0] = 16'h4625;
            cblk[1] = 0;
            cblk[2] = 0;
            cblk[3] = 0;
            esdi_command(8'h20, 4);
            esdi_complete(8'h20, 8'h2E, 7, "device 1");
            if (!aborted && sblk[1][7:0] !== 8'h13) fail($sformatf("command error %h, expected 13", sblk[1][7:0]));
            end_test;
        end
    endtask

    // Write and read back the attachment buffer, a word at a time through DREG
    task automatic test_cpu_attach;
        integer k, bad;
        reg ok;
        reg [15:0] d;
        begin
            begin_test("attachment buffer write and read, through DREG");
            cblk[0] = 16'h06F0;
            cblk[1] = 1;
            esdi_command(8'hE0, 2);
            esdi_expect_intr(20000, 8'hEB, "write attachment buffer");
            for (k = 0; k < 256 && !aborted; k = k + 1) begin
                esdi_wait(BSR_TREQ, 1'b1, 1000, ok);
                if (ok) host_out(A_DREG, 1, pattern(k, 16'hA77A));
            end
            esdi_complete(8'hE0, 8'hE1, 7, "write attachment buffer");
            cblk[0] = 16'h06F1;
            esdi_command(8'hE0, 2);
            esdi_expect_intr(20000, 8'hEB, "read attachment buffer");
            bad = 0;
            for (k = 0; k < 256 && !aborted; k = k + 1) begin
                esdi_wait(BSR_TREQ, 1'b1, 1000, ok);
                if (ok) host_in(A_DREG, 1, d);
                if (ok && d !== pattern(k, 16'hA77A)) bad = bad + 1;
            end
            esdi_complete(8'hE0, 8'hE1, 7, "read attachment buffer");
            if (bad) fail($sformatf("%0d of 256 words read back wrong", bad));
            end_test;
        end
    endtask
`endif

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    initial begin
        $timeformat(-9, 1, " ns", 12);
        if ($test$plusargs("vcd")) begin
            $dumpfile("difnif72_t.vcd");
            $dumpvars(0, difnif72_t);
        end

        h_a = 16'h0000;
        h_mio_l = 1'b1;
        h_s0_l = 1'b1;
        h_s1_l = 1'b1;
        h_cmd_l = 1'b1;
        h_adl_l = 1'b1;
        h_sbhe_l = 1'b1;
        h_setup_l = 1'b1;
        h_chreset = 1'b1;
        h_arb_gnt_l = 1'b0;     // bus granted to the CPU
        h_tc_l = 1'b1;
        h_wdrive = 1'b0;
        h_wdata = 16'h0000;
        wd_owner = 0;
        tn_rd = 1'b0;
        tn_wr = 1'b0;
        tn_drive = 1'b0;
        tn_addr = 4'h0;
        tn_dout = 16'h0000;

        $display("difnif72_t: CYCLE=%0d ns, %0s timing, board %0s, POS %0s, seed %0d",
                 CYCLE, WORST ? "Figure 2-34 limit" : "typical 50Z",
                 BOARD == 2 ? "Rev P2" : BOARD == 1 ? "Rev P1 with U8 14/15 bridged" : "Rev P1 as built",
`ifdef MCA_USE_POS
                 "enabled",
`else
                 "bypassed (Eric's default)",
`endif
                 SEED);

        #2000 h_chreset = 1'b0;
        #1000 t_next_cmd = $realtime;

`ifdef DIFNIF_CPU
        test_pos;
        pos_out(2, 8'b0_1_0011_0_1);    // arbitration level 3
        card_level = 4'h3;
        burst_allowed = 1'b1;           // the firmware allows burst DMA
        refresh_on = 1'b1;
        test_cpu_reset("reset complete after power-on", 0);
        test_cpu_config;
        test_cpu_rw(0, 16, 8, "read 8 sectors");
        test_cpu_rw(0, 0, 1, "read 1 sector");
        test_cpu_rw(1, 40, 8, "write 8 sectors");
        test_cpu_rw(0, 40, 8, "read back the 8 written");
        test_cpu_rw(1, 100, 1, "write 1 sector");
        test_cpu_rw(0, 100, 1, "read back the 1 written");
        test_cpu_range;
        test_cpu_device1;
        test_cpu_attach;
        test_cpu_reset("soft reset", 1);
        test_cpu_rw(0, 2040, 8, "read the last 8 sectors after the reset");
        begin_test("SD card model reports no errors");
        if (card.errors) fail($sformatf("%0d errors from the card model", card.errors));
        end_test;
`else
        test_pos;
        test_reset_state;
        test_version;
        test_not_selected(16'h0080, "no response at 0080 (unrelated port)");
        test_not_selected(16'h3518, "no response at 3518 (alternate ESDI address)");
`ifdef MCA_USE_POS
        test_alt_address;
`endif
        test_cifr;
        test_sifr;
        test_sifr_clear;
        test_atn;
        test_isr;
        test_host_diag;
        test_dreg_write;
        test_dreg_read;

`ifdef MCA_USE_POS
        // Arbitration level 3, the fixed disk's usual level
        pos_out(2, 8'b0_1_0011_0_1);
        card_level = 4'h3;
`endif
        comp_level = 4'h2;
        test_dma_to_card(0, "DMA sector write");
        test_dma_from_card(0, "DMA sector read");
        test_dma_to_card(1, "DMA sector write, higher-priority device competing");
        test_dma_from_card(1, "DMA sector read, higher-priority device competing");
`ifdef MCA_USE_POS
        comp_level = 4'h5;
        test_dma_to_card(1, "DMA sector write, lower-priority device competing");
        test_dma_from_card(1, "DMA sector read, lower-priority device competing");
`endif
        comp_level = 4'h2;
        test_buf_from_card(0, 0, 0, "buffer: DMA sector read, 3 sectors");
        test_buf_to_card(0, 0, 0, "buffer: DMA sector write, 3 sectors");
        test_buf_from_card(1, 1, 0, "buffer: DMA sector read, slow Teensy, device competing");
        test_buf_to_card(1, 1, 0, "buffer: DMA sector write, slow Teensy, device competing");
        test_buf_from_card(0, 0, 1, "burst: DMA sector read, 3 sectors");
        test_buf_to_card(0, 0, 1, "burst: DMA sector write, 3 sectors");
        test_buf_from_card(1, 1, 1, "burst: DMA sector read, slow Teensy, device competing");
        test_buf_to_card(1, 1, 1, "burst: DMA sector write, slow Teensy, device competing");
        test_burst_tc;
        test_dma_from_card(0, "DMA sector read without the buffer, after it");
`ifdef MCA_USE_POS
        test_tc_dma_reset;
`endif
        // Burst allowed but the buffer off: the old path must not burst
        tn_write(TN_CTRL, 16'h0001);
        test_dma_from_card(0, "DMA sector read without the buffer, burst allowed");
        tn_write(TN_CTRL, 16'h0000);
        test_isr_gate;
        test_channel_reset;
        test_not_selected(16'h0080, "no response at 0080 after DMA");
`endif

        $display("RESULT: cycle=%0d worst=%0d board=%0d pos=%0d seed=%0d tests=%0d failed=%0d spec=%0d",
                 CYCLE, WORST, BOARD,
`ifdef MCA_USE_POS
                 1,
`else
                 0,
`endif
                 SEED, tests_run, tests_failed, spec_errors);
        $finish;
    end

    // Safety net
    initial begin
`ifdef DIFNIF_CPU
        #400_000_000;
`else
        #80_000_000;
`endif
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
