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

    // ESDI registers (primary address)
    localparam [15:0] A_CIFR = 16'h3510;  // write: command interface, read: status
    localparam [15:0] A_BSR  = 16'h3512;  // write: basic control, read: basic status
    localparam [15:0] A_ATN  = 16'h3513;  // write: attention, read: interrupt status
    localparam [15:0] A_DREG = 16'h3514;  // data register

    // Basic status register bits
    localparam BSR_INTR = 0, BSR_TREQ = 1, BSR_CI_FULL = 2, BSR_SI_FULL = 3, BSR_BUSY = 4;

    // Teensy-side registers and flag bits (teensy.v, difnift.ino)
    localparam [3:0] TN_FLAGS = 1, TN_ATN = 2, TN_ISR = 3, TN_CIFR = 4, TN_SIFR = 5, TN_DREG = 6;
    localparam FL_ATN = 0, FL_ISR = 1, FL_CIFR = 2, FL_SIFR = 3, FL_TREQ_SET = 5, FL_TREQ = 8;

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
    assign h_sfdbk_l = (BOARD >= 2 && !b_out[9]) ? 1'b0 : 1'bz;  // Rev P2: spare 74VHCT125
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
            spec("data bus contention: host writing while the card drives");

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
    reg end_rd;
    integer end_id;

    always @(end_cycle) begin : cycle_end
        realtime rise;
        reg rd;
        integer id;
        rise = end_rise;
        rd = end_rd;
        id = end_id;
        wait_until(rise);
        h_cmd_l = 1'b1;
        if (!rd) begin
            wait_until(rise + T_WD_H);
            if (wd_owner == id) h_wdrive = 1'b0;
        end
    end

    // One I/O or setup cycle. For reads, rdata is the byte or word as the
    // planar would see it after data steering.
    task automatic mca_cycle(input rd, input setup, input [15:0] addr, input word,
                             input expect_ds16, input expect_sel, input [15:0] wdata,
                             output [15:0] rdata);
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

            wait_until(t0 - T_ADDR_SU);
            h_a = addr;
            h_mio_l = 1'b0;
            h_setup_l = ~setup;
            h_sbhe_l = word ? 1'b0 : ~addr[0];

            wait_until(t0 - T_STAT_SU);
            if (rd) h_s1_l = 1'b0; else h_s0_l = 1'b0;

            wait_until(t0 - T_ADDR_SU + T_DS16);
            ds16 = ~h_ds16_l;
            if (h_ds16_l === 1'bx || ds16 !== expect_ds16)
                spec($sformatf("-CD DS 16 = %b at %h, expected %0s", h_ds16_l, addr,
                               expect_ds16 ? "asserted" : "not asserted"));
            card16 = (ds16 === 1'b1);

            if (BOARD >= 2) begin
                wait_until(t0 - T_ADDR_SU + T_SFDBK);
                if (h_sfdbk_l === 1'bx || ~h_sfdbk_l !== expect_sel)
                    spec($sformatf("-CD SFDBK = %b at %h, expected %0s", h_sfdbk_l, addr,
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
            end_id = my_id;
            -> end_cycle;

            rdata = 16'hxxxx;
            if (rd) begin
                wait_until(t0 + T_RD);
                early = h_d;
                wait_until(t_rise);
                #0.05 raw = h_d;    // sampled as -CMD rises
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
    function selected(input [15:0] addr);
        selected = (addr[15:3] == {12'h351, alt_base});
    endfunction

    // ESDI register numbers 0, 1 and 4 are 16-bit (mcabus.v cd_ds16_l)
    function is16(input [15:0] addr);
        is16 = selected(addr) && (addr[2:1] == 2'b00 || addr[2:0] == 3'h4);
    endfunction

    task automatic host_in(input [15:0] addr, input word, output [15:0] d);
        mca_cycle(1, 0, addr, word, is16(addr), selected(addr), 16'h0, d);
    endtask

    task automatic host_out(input [15:0] addr, input word, input [15:0] d);
        reg [15:0] dummy;
        mca_cycle(0, 0, addr, word, is16(addr), selected(addr), d, dummy);
    endtask

    task automatic pos_in(input [2:0] r, output [7:0] d);
        reg [15:0] w;
        begin
            mca_cycle(1, 1, 16'h0100 + r, 0, 0, 0, 16'h0, w);
            d = w[7:0];
        end
    endtask

    task automatic pos_out(input [2:0] r, input [7:0] d);
        reg [15:0] dummy;
        mca_cycle(0, 1, 16'h0100 + r, 0, 0, 0, {8'h00, d}, dummy);
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

    task automatic tn_wait_flag(input integer bit_n, input value, output ok);
        reg [15:0] fl;
        integer i;
        begin
            ok = 1'b0;
            for (i = 0; i < MAX_POLL && !aborted && !ok; i = i + 1) begin
                tn_read(TN_FLAGS, fl);
                if (fl[bit_n] === value) ok = 1'b1;
            end
            if (!ok && !aborted) begin
                fail($sformatf("teensy: flag bit %0d never became %b (last flags %h)", bit_n, value, fl));
                aborted = 1'b1;
            end
        end
    endtask

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

        test_pos;
        test_reset_state;
        test_not_selected(16'h0080, "no response at 0080 (unrelated port)");
        test_not_selected(16'h3518, "no response at 3518 (alternate ESDI address)");
`ifdef MCA_USE_POS
        test_alt_address;
`endif
        test_cifr;
        test_sifr;
        test_atn;
        test_isr;
        test_dreg_write;
        test_dreg_read;

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
        #20_000_000;
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
