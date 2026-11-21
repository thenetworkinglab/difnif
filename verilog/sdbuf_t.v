// Self-checking testbench: SD card -> sdhost -> sdbridge -> sectorbuf -> host
//
// The host side stands in for mcabus.v's DREG and DMA accesses: one word
// per access, with a random gap between accesses, while the sector buffer
// says it's ready (h_ready). The testbench also plays the processor that
// drives sdhost and the bridge.
//
// Defines: SAMPLE_LATE, ODLY, PAD_OUT, PAD_IN as in sd_t.v.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

`timescale 1ns / 1ps

`ifndef SAMPLE_LATE
`define SAMPLE_LATE 1
`endif
`ifndef ODLY
`define ODLY 14.0
`endif
`ifndef PAD_OUT
`define PAD_OUT 0.0
`endif
`ifndef PAD_IN
`define PAD_IN 0.0
`endif

module sdbuf_t;

    reg clk = 0;
    always #10 clk = ~clk;
    reg rst = 1;

    // ---- sdhost ----
    reg  [3:0]  addr = 0;
    reg  [31:0] wdata = 0;
    reg         we = 0;
    wire [31:0] rdata;
    wire [15:0] rd_word, wr_word;
    wire        rd_strobe, rd_blk_done, rd_blk_ok, rd_ready;
    wire        wr_next, wr_ready, wr_blk_done, wr_blk_ok;
    wire        sd_clk_h, cmd_out, cmd_oe, cmd_in;
    wire [3:0]  dat_out, dat_oe, dat_in;

    sdhost host (
        .clk(clk), .rst(rst),
        .addr(addr), .wdata(wdata), .we(we), .rdata(rdata),
        .rd_word(rd_word), .rd_strobe(rd_strobe), .rd_ready(rd_ready),
        .rd_blk_done(rd_blk_done), .rd_blk_ok(rd_blk_ok),
        .wr_word(wr_word), .wr_next(wr_next), .wr_ready(wr_ready),
        .wr_blk_done(wr_blk_done), .wr_blk_ok(wr_blk_ok),
        .sd_clk(sd_clk_h), .cmd_in(cmd_in), .cmd_out(cmd_out), .cmd_oe(cmd_oe),
        .dat_in(dat_in), .dat_out(dat_out), .dat_oe(dat_oe),
        .card_detect(1'b0)
    );

    // ---- bridge and sector buffer ----
    reg         sb_dir = 0;
    reg         sb_clear = 0;
    reg         br_restart = 0;
    reg  [15:0] br_arm_n = 0;
    reg         br_clear_fail = 0;
    wire [15:0] blocks_done;
    wire        failed;
    wire        t_wr, t_rd, t_go, t_done, t_ready, t_can_arm, h_idle, br_sb_clear;
    wire [15:0] t_wdata, t_rdata;
    reg         h_ev = 0;
    reg  [15:0] h_wdata = 0;
    wire [15:0] h_rdata;
    wire        h_ready, h_more;

    sdbridge bridge (
        .clk(clk), .rst(rst),
        .dir(sb_dir), .restart(br_restart), .sb_clear(br_sb_clear), .arm_n(br_arm_n),
        .clear_fail(br_clear_fail), .blocks_done(blocks_done), .failed(failed),
        .rd_word(rd_word), .rd_strobe(rd_strobe), .rd_blk_done(rd_blk_done),
        .rd_blk_ok(rd_blk_ok), .rd_ready(rd_ready),
        .wr_word(wr_word), .wr_next(wr_next), .wr_ready(wr_ready),
        .wr_blk_done(wr_blk_done), .wr_blk_ok(wr_blk_ok),
        .t_wr(t_wr), .t_wdata(t_wdata), .t_rd(t_rd), .t_rdata(t_rdata),
        .t_go(t_go), .t_done(t_done), .t_ready(t_ready), .t_can_arm(t_can_arm)
    );

    sectorbuf sb (
        .clk(clk), .clear(br_sb_clear | sb_clear), .dir(sb_dir),
        .t_wr(t_wr), .t_wdata(t_wdata), .t_rd(t_rd), .t_rdata(t_rdata),
        .t_go(t_go), .t_done(t_done), .t_ready(t_ready), .t_can_arm(t_can_arm),
        .h_idle(h_idle),
        .h_ev(h_ev), .h_wdata(h_wdata), .h_rdata(h_rdata),
        .h_ready(h_ready), .h_more(h_more)
    );

    // ---- pins and card ----
    tri1        cmd;
    tri1 [3:0]  dat;
    wire        sd_clk_c, cmd_out_d, cmd_oe_d;
    wire [3:0]  dat_out_d, dat_oe_d;
    assign #(`PAD_OUT) sd_clk_c  = sd_clk_h;
    assign #(`PAD_OUT) cmd_out_d = cmd_out;
    assign #(`PAD_OUT) cmd_oe_d  = cmd_oe;
    assign #(`PAD_OUT) dat_out_d = dat_out;
    assign #(`PAD_OUT) dat_oe_d  = dat_oe;
    assign cmd = cmd_oe_d ? cmd_out_d : 1'bz;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : lane
            assign dat[g] = dat_oe_d[g] ? dat_out_d[g] : 1'bz;
        end
    endgenerate
    assign #(`PAD_IN) cmd_in = cmd;
    assign #(`PAD_IN) dat_in = dat;

    sdcard_model #(.ODLY(`ODLY)) card (.sd_clk(sd_clk_c), .cmd(cmd), .dat(dat));

    // ---- checks ----
    integer errors = 0;
    integer tests = 0;

    task fail;
        input [8*100-1:0] msg;
        begin
            errors = errors + 1;
            $display("%t   FAIL: %0s", $realtime, msg);
        end
    endtask

    task begin_test;
        input [8*70-1:0] name;
        begin
            tests = tests + 1;
            $display("%t %0s", $realtime, name);
        end
    endtask

    always @(cmd_oe_d or card.cmd_drv_d)
        if (cmd_oe_d && card.cmd_drv_d) begin
            #0.2;
            if (cmd_oe_d && card.cmd_drv_d) fail("host and card both drive CMD");
        end
    always @(dat_oe_d or card.dat_drv_d)
        if (dat_oe_d & card.dat_drv_d) begin
            #0.2;
            if (dat_oe_d & card.dat_drv_d) fail("host and card both drive DAT");
        end

    // Every word from the card must land in the buffer
    integer lost_words = 0;
    always @(posedge clk)
        if (rd_strobe && !failed && !sb.t_put) lost_words = lost_words + 1;

    // ---- host side: one DREG access at a time, with a random gap ----
    // A real DMA or I/O cycle takes at least 200 ns, and the first access
    // to a newly offered half comes at least 200 ns after the request (the
    // buffer relies on this to fetch the word: sectorbuf.v).
    reg [15:0] hq [0:8191];    // words the host read, or will write
    integer    hq_i = 0;
    integer    hq_n = 0;       // how many words to move
    integer    gap_min = 5, gap_max = 30;   // clocks between accesses
    integer    h_wait = 0;
    integer    not_valid = 0;
    reg        h_ready_q = 0;

    always @(posedge clk) begin
        h_ev <= 1'b0;
        h_ready_q <= h_ready;
        if (h_ready && !h_ready_q && h_wait < 10) h_wait <= 10;
        else if (hq_i < hq_n && h_ready && !h_ev) begin
            if (h_wait > 0) begin
                h_wait <= h_wait - 1;
            end else begin
                if (!sb_dir) begin
                    hq[hq_i] <= h_rdata;
                    if (!sb.h_valid) not_valid <= not_valid + 1;
                end else begin
                    h_wdata <= hq[hq_i];
                end
                h_ev <= 1'b1;
                hq_i <= hq_i + 1;
                h_wait <= gap_min + ({$random} % (gap_max - gap_min + 1));
            end
        end
    end

    // ---- register access (as in sd_t.v) ----
    localparam R_NONE = 0, R_SHORT = 1 << 6, R_LONG = 2 << 6, BUSY = 1 << 8,
               NOCRC = 1 << 9, D_READ = 1 << 10, D_WRITE = 2 << 10, INITCLK = 1 << 12;
    reg [31:0] st, r0;
    reg [31:0] ctrl_fast;

    task wreg;
        input [3:0]  a;
        input [31:0] d;
        begin
            @(negedge clk);
            addr = a;
            wdata = d;
            we = 1;
            @(negedge clk);
            we = 0;
        end
    endtask

    task rreg;
        input  [3:0]  a;
        output [31:0] d;
        begin
            @(negedge clk);
            addr = a;
            #1 d = rdata;
        end
    endtask

    task sdcmd;
        input [5:0]  idx;
        input [31:0] a;
        input [31:0] flags;
        begin
            wreg(4'd1, a);
            wreg(4'd2, flags | idx);
            rreg(4'd4, st);
            while (st[0]) rreg(4'd4, st);
            rreg(4'd5, r0);
            if (st[4:2] != 0) begin
                fail("command error");
                $display("      CMD%0d status %h", idx, st);
            end
        end
    endtask

    // One clock on a testbench-driven control line (a task can't pulse a
    // signal passed to it: an inout is only copied back when it returns)
    task pulse_clear;   begin @(negedge clk); sb_clear = 1;      @(negedge clk); sb_clear = 0;      end endtask
    task pulse_restart; begin @(negedge clk); br_restart = 1;    @(negedge clk); br_restart = 0;    end endtask
    task pulse_retry;   begin @(negedge clk); br_clear_fail = 1; @(negedge clk); br_clear_fail = 0; end endtask

    task card_startup;
        integer i;
        begin
            wreg(4'd0, 32'd62 | (`SAMPLE_LATE << 10));
            sdcmd(0, 0, INITCLK);
            sdcmd(0, 0, R_NONE);
            sdcmd(8, 32'h1AA, R_SHORT);
            r0 = 0;
            for (i = 0; i < 10 && !r0[31]; i = i + 1) begin
                sdcmd(55, 0, R_SHORT);
                sdcmd(41, 32'h4030_0000, R_SHORT | NOCRC);
            end
            sdcmd(2, 0, R_LONG);
            sdcmd(3, 0, R_SHORT);
            sdcmd(7, {card.rca, 16'd0}, R_SHORT | BUSY);
            sdcmd(55, {card.rca, 16'd0}, R_SHORT);
            sdcmd(6, 32'h2, R_SHORT);
            wreg(4'd0, ctrl_fast);
            if (card.state != 4 || !card.bus4) fail("card start-up");
        end
    endtask

    // Sets up the buffer and bridge for a transfer of n blocks
    task begin_transfer;
        input d;
        input integer n;
        integer i;
        begin
            @(negedge clk);
            sb_dir = d;
            hq_i = 0;
            hq_n = n * 256;
            if (d) for (i = 0; i < n * 256; i = i + 1) hq[i] = $random;
            br_arm_n = n;
            pulse_restart;    // the bridge clears the buffer
        end
    endtask

    task wait_host;   // the host has moved all its words
        begin
            while (hq_i < hq_n) @(posedge clk);
            repeat (10) @(posedge clk);
        end
    endtask

    task wait_written;   // the card has accepted n blocks
        input integer n;
        begin
            while (blocks_done < n) @(posedge clk);
        end
    endtask

    task check_read;     // hq against the card, n blocks from b
        input integer b;
        input integer n;
        input [8*60-1:0] what;
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < n * 256; i = i + 1)
                if (hq[i] !== {card.mem[b * 512 + 2 * i + 1], card.mem[b * 512 + 2 * i]})
                    bad = bad + 1;
            if (bad) begin
                fail({what, ": the host's data differs from the card"});
                $display("      %0d of %0d words", bad, n * 256);
                for (i = 0; i < 4; i = i + 1)
                    $display("      word %0d: host %h, card %h", i, hq[i],
                             {card.mem[b * 512 + 2 * i + 1], card.mem[b * 512 + 2 * i]});
            end
            if (lost_words) fail({what, ": words from the card not stored in the buffer"});
            if (not_valid) fail({what, ": host read a word before it was fetched"});
        end
    endtask

    task check_written;  // the card against hq, n blocks from b
        input integer b;
        input integer n;
        input [8*60-1:0] what;
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < n * 256; i = i + 1)
                if ({card.mem[b * 512 + 2 * i + 1], card.mem[b * 512 + 2 * i]} !== hq[i])
                    bad = bad + 1;
            if (bad) begin
                fail({what, ": the card's data differs from what the host wrote"});
                $display("      %0d of %0d words", bad, n * 256);
            end
            if (!h_idle) fail({what, ": a half is still offered to the host after the last sector"});
        end
    endtask

    integer i;
    realtime t0, t1;

    initial begin
        $timeformat(-6, 2, " us", 12);
        for (i = 0; i < 1024 * 512; i = i + 1) card.mem[i] = $random;
        ctrl_fast = 32'h100 | (`SAMPLE_LATE << 10);
        repeat (5) @(posedge clk);
        rst = 0;

        begin_test("card start-up");
        card_startup;

        // -------- reads --------
        begin_test("read 16 blocks, host 0.5-1 us per word (like the PS/2)");
        gap_min = 25; gap_max = 50;
        begin_transfer(0, 16);
        wreg(4'd3, 16);
        t0 = $realtime;
        sdcmd(18, 100, R_SHORT | D_READ);
        wait_host;
        t1 = $realtime;
        sdcmd(12, 0, R_SHORT | BUSY);
        check_read(100, 16, "slow host read");
        if (blocks_done != 16) fail("blocks_done");
        $display("      %0.2f MB/s (host-limited)", 16 * 512 / ((t1 - t0) / 1000.0));

        begin_test("read 16 blocks, host 200 ns per word");
        gap_min = 9; gap_max = 9;
        begin_transfer(0, 16);
        wreg(4'd3, 16);
        t0 = $realtime;
        sdcmd(18, 120, R_SHORT | D_READ);
        wait_host;
        t1 = $realtime;
        sdcmd(12, 0, R_SHORT | BUSY);
        check_read(120, 16, "fast host read");
        $display("      %0.2f MB/s (fast host)", 16 * 512 / ((t1 - t0) / 1000.0));

        // -------- writes --------
        begin_test("write 16 blocks, host 0.5-1 us per word");
        gap_min = 25; gap_max = 50;
        begin_transfer(1, 16);
        wreg(4'd3, 16);
        t0 = $realtime;
        sdcmd(25, 200, R_SHORT | D_WRITE);
        wait_written(16);
        t1 = $realtime;
        sdcmd(12, 0, R_SHORT | BUSY);
        check_written(200, 16, "slow host write");
        $display("      %0.2f MB/s (host-limited)", 16 * 512 / ((t1 - t0) / 1000.0));

        begin_test("write 16 blocks, host 200 ns per word");
        gap_min = 9; gap_max = 9;
        begin_transfer(1, 16);
        wreg(4'd3, 16);
        t0 = $realtime;
        sdcmd(25, 220, R_SHORT | D_WRITE);
        wait_written(16);
        t1 = $realtime;
        sdcmd(12, 0, R_SHORT | BUSY);
        check_written(220, 16, "fast host write");
        $display("      %0.2f MB/s (fast host, 200-clock card busy per block)",
                 16 * 512 / ((t1 - t0) / 1000.0));

        // -------- recovery --------
        begin_test("read 8 blocks, the 4th with a bad CRC, then retried");
        gap_min = 25; gap_max = 50;
        begin_transfer(0, 8);
        wreg(4'd3, 8);
        i = card.reads_done;
        sdcmd(18, 300, R_SHORT | D_READ);
        wait (card.reads_done == i + 3);
        card.corrupt_read = 1;
        wait (failed);
        if (blocks_done != 3) fail("blocks_done at the failure");
        wreg(4'd0, ctrl_fast | 32'h10000);     // stop sdhost's data engine
        sdcmd(12, 0, R_SHORT | BUSY);
        pulse_retry;
        wreg(4'd3, 8 - blocks_done);
        sdcmd(18, 300 + blocks_done, R_SHORT | D_READ);
        wait_host;
        sdcmd(12, 0, R_SHORT | BUSY);
        check_read(300, 8, "read after a retry");
        if (blocks_done != 8) fail("blocks_done after the retry");

        begin_test("write 6 blocks, the 3rd rejected, then retried");
        begin_transfer(1, 6);
        wreg(4'd3, 6);
        i = card.writes_done;
        sdcmd(25, 400, R_SHORT | D_WRITE);
        wait (card.writes_done == i + 2);
        card.reject_write = 1;
        wait (failed);
        if (blocks_done != 2) fail("blocks_done at the failure");
        sdcmd(12, 0, R_SHORT | BUSY);
        pulse_retry;
        wreg(4'd3, 6 - blocks_done);
        sdcmd(25, 400 + blocks_done, R_SHORT | D_WRITE);
        wait_written(6);
        sdcmd(12, 0, R_SHORT | BUSY);
        check_written(400, 6, "write after a retry");

        begin_test("read abandoned after 1 of 4 blocks, then a new read");
        begin_transfer(0, 1);          // the host takes only one block
        wreg(4'd3, 4);
        sdcmd(18, 500, R_SHORT | D_READ);
        wait_host;
        repeat (5000) @(posedge clk);  // the card fills the other half meanwhile
        wreg(4'd0, ctrl_fast | 32'h10000);
        sdcmd(12, 0, R_SHORT | BUSY);
        begin_transfer(0, 4);
        wreg(4'd3, 4);
        sdcmd(18, 520, R_SHORT | D_READ);
        wait_host;
        sdcmd(12, 0, R_SHORT | BUSY);
        check_read(520, 4, "read after an abandoned one");

        // -------- done --------
        repeat (100) @(posedge clk);
        if (card.errors) begin
            errors = errors + card.errors;
            $display("   FAIL: the card model reported %0d errors", card.errors);
        end
        if (errors == 0) $display("ALL PASS (%0d tests)", tests);
        else $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("FAILED: timeout");
        $finish;
    end

endmodule
