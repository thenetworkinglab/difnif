// Self-checking testbench for sdhost.v against sdcard_model.v
//
// The testbench plays the part of the processor that will drive sdhost:
// the card's start-up sequence at 400 kHz, then 25 MHz 4-bit transfers.
//
// Defines (run_sdsim.sh sets them):
//   SAMPLE_LATE  1: sample CMD and DAT one 50 MHz clock after the SD clock
//                rises (sdhost's sample_late); 0: as it rises
//   ODLY         card output delay after the clock falls, ns
//   PAD_OUT      FPGA output delay (clock and data to the card), ns
//   PAD_IN       FPGA input delay (card to the sampling flip-flop), ns
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

module sd_t;

    reg clk = 0;
    always #10 clk = ~clk;       // 50 MHz
    reg rst = 1;

    // ---- sdhost ----
    reg  [3:0]  addr = 0;
    reg  [31:0] wdata = 0;
    reg         we = 0;
    wire [31:0] rdata;
    wire [15:0] rd_word;
    wire        rd_strobe, rd_blk_done, rd_blk_ok;
    reg         rd_ready = 1;
    wire [15:0] wr_word;
    wire        wr_next;
    reg         wr_ready = 1;
    wire        sd_clk_h, cmd_out, cmd_oe;
    wire [3:0]  dat_out, dat_oe;
    wire        cmd_in;
    wire [3:0]  dat_in;

    sdhost host (
        .clk(clk), .rst(rst),
        .addr(addr), .wdata(wdata), .we(we), .rdata(rdata),
        .rd_word(rd_word), .rd_strobe(rd_strobe), .rd_ready(rd_ready),
        .rd_blk_done(rd_blk_done), .rd_blk_ok(rd_blk_ok),
        .wr_word(wr_word), .wr_next(wr_next), .wr_ready(wr_ready),
        .wr_blk_done(), .wr_blk_ok(),
        .sd_clk(sd_clk_h), .cmd_in(cmd_in), .cmd_out(cmd_out), .cmd_oe(cmd_oe),
        .dat_in(dat_in), .dat_out(dat_out), .dat_oe(dat_oe),
        .card_detect(1'b0)
    );

    // ---- pins, with the FPGA's pad delays, and the card's pull-ups ----
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
    integer test_errors;

    task fail;
        input [8*100-1:0] msg;
        begin
            errors = errors + 1;
            test_errors = test_errors + 1;
            $display("%t   FAIL: %0s", $realtime, msg);
        end
    endtask

    task begin_test;
        input [8*60-1:0] name;
        begin
            tests = tests + 1;
            test_errors = 0;
            $display("%t %0s", $realtime, name);
        end
    endtask

    // Host and card driving a line at the same time
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

    // ---- data source (writes) and sink (reads) ----
    reg [15:0] src [0:4095];
    integer    src_i = 0;
    assign wr_word = src[src_i];
    integer    wr_throttle = 0;   // clocks without wr_ready after each block
    integer    wr_hold = 0;

    reg [15:0] snk [0:4095];
    integer    snk_i = 0;
    integer    blk_good = 0, blk_bad = 0;
    integer    rd_throttle = 0;   // clocks without rd_ready after each block
    integer    rd_hold = 0;
    integer    strobe_not_ready = 0;

    always @(posedge clk) begin
        if (wr_next) begin
            src_i <= src_i + 1;
            if ((src_i + 1) % 256 == 0 && wr_throttle > 0) begin
                wr_ready <= 0;
                wr_hold <= wr_throttle;
            end
        end else if (wr_hold > 0) begin
            wr_hold <= wr_hold - 1;
            if (wr_hold == 1) wr_ready <= 1;
        end

        if (rd_strobe) begin
            snk[snk_i] <= rd_word;
            snk_i <= snk_i + 1;
            if (!rd_ready) strobe_not_ready <= strobe_not_ready + 1;
        end
        if (rd_blk_done) begin
            if (rd_blk_ok) blk_good <= blk_good + 1;
            else blk_bad <= blk_bad + 1;
            if (rd_throttle > 0) begin
                rd_ready <= 0;
                rd_hold <= rd_throttle;
            end
        end else if (rd_hold > 0) begin
            rd_hold <= rd_hold - 1;
            if (rd_hold == 1) rd_ready <= 1;
        end
    end

    // ---- register access ----
    localparam R_NONE = 0, R_SHORT = 1 << 6, R_LONG = 2 << 6, BUSY = 1 << 8,
               NOCRC = 1 << 9, D_READ = 1 << 10, D_WRITE = 2 << 10, INITCLK = 1 << 12;

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

    reg [31:0] st, r0, r1, r2, r3;

    task wait_cmd;
        begin
            rreg(4'd4, st);
            while (st[0]) rreg(4'd4, st);
        end
    endtask

    task wait_data;
        begin
            rreg(4'd4, st);
            while (st[1:0] != 2'b00) rreg(4'd4, st);
            repeat (2) @(posedge clk);   // let the sink count the last block
        end
    endtask

    // Sends a command and waits for it (not for its data); st holds the
    // status, r0-r3 the response
    task sdcmd;
        input [5:0]  idx;
        input [31:0] a;
        input [31:0] flags;
        begin
            wreg(4'd1, a);
            wreg(4'd2, flags | idx);
            wait_cmd;
            rreg(4'd5, r0);
            rreg(4'd6, r1);
            rreg(4'd7, r2);
            rreg(4'd8, r3);
        end
    endtask

    task expect_ok;      // no command error bits in st
        input [8*60-1:0] what;
        begin
            if (st[4:2] != 0) begin
                fail({what, ": error bits in status"});
                $display("      status %h", st);
            end
        end
    endtask

    task expect_data_ok; // no command or data error bits in st
        input [8*60-1:0] what;
        begin
            if (st[8:2] != 0) begin
                fail({what, ": error bits in status"});
                $display("      status %h", st);
            end
        end
    endtask

    localparam CTRL_SLOW = 32'd62;  // 397 kHz, 1-bit

    reg [31:0] ctrl_fast;

    // ---- data helpers ----
    task fill_src;
        input integer nwords;
        integer i;
        begin
            for (i = 0; i < nwords; i = i + 1) src[i] = $random;
            src_i = 0;
        end
    endtask

    // Compares the card's memory with src, from block b, n blocks
    task check_card;
        input integer b;
        input integer n;
        input [8*60-1:0] what;
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < n * 256; i = i + 1)
                if (card.mem[b * 512 + 2 * i] !== src[i][7:0] ||
                    card.mem[b * 512 + 2 * i + 1] !== src[i][15:8]) bad = bad + 1;
            if (bad) begin
                fail({what, ": card memory differs from what was written"});
                $display("      %0d of %0d words differ", bad, n * 256);
            end
        end
    endtask

    // Compares snk with the card's memory, from block b, n blocks
    task check_snk;
        input integer b;
        input integer n;
        input [8*60-1:0] what;
        integer i, bad;
        begin
            bad = 0;
            if (snk_i != n * 256) begin
                fail({what, ": wrong number of words read"});
                $display("      %0d, expected %0d", snk_i, n * 256);
            end
            for (i = 0; i < n * 256; i = i + 1)
                if (snk[i] !== {card.mem[b * 512 + 2 * i + 1], card.mem[b * 512 + 2 * i]})
                    bad = bad + 1;
            if (bad) begin
                fail({what, ": data read differs from the card"});
                $display("      %0d of %0d words differ", bad, n * 256);
            end
        end
    endtask

    task start_read;
        begin
            snk_i = 0;
            blk_good = 0;
            blk_bad = 0;
            strobe_not_ready = 0;
        end
    endtask

    // ---- CRC self-checks against published values ----
    task crc_selftest;
        integer i;
        reg [15:0] c;
        begin
            begin_test("CRCs against the SD specification's examples");
            // CMD0: 40 00 00 00 00 95; CMD8 (1AA): 48 00 00 01 AA 87
            if ({host.crc7_40({2'b01, 6'd0, 32'h0}), 1'b1} !== 8'h95) fail("CRC7 of CMD0");
            if ({host.crc7_40({2'b01, 6'd8, 32'h1AA}), 1'b1} !== 8'h87) fail("CRC7 of CMD8");
            // CMD17 arg 0: 51 00 00 00 00 55
            if ({host.crc7_40({2'b01, 6'd17, 32'h0}), 1'b1} !== 8'h55) fail("CRC7 of CMD17");
            // 512 bytes of FF on one line: CRC16 7FA1
            c = 16'd0;
            for (i = 0; i < 4096; i = i + 1) c = host.crc16_bit(c, 1'b1);
            if (c !== 16'h7FA1) fail("CRC16 of 512 bytes of FF");
        end
    endtask

    // ---- the tests ----
    integer i;
    realtime t0, t1;

    initial begin
        $timeformat(-6, 2, " us", 12);
        for (i = 0; i < 1024 * 512; i = i + 1) card.mem[i] = $random;
        ctrl_fast = 32'h100 | (`SAMPLE_LATE << 10);   // 25 MHz, 4-bit

        repeat (5) @(posedge clk);
        rst = 0;

        crc_selftest;

        // -------- start-up --------
        begin_test("start-up at 400 kHz");
        wreg(4'd0, CTRL_SLOW | (`SAMPLE_LATE << 10));
        sdcmd(0, 0, INITCLK);
        sdcmd(0, 0, R_NONE);
        sdcmd(8, 32'h1AA, R_SHORT);
        expect_ok("CMD8");
        if (r0[11:0] !== 12'h1AA || r1[5:0] !== 6'd8) fail("CMD8 echo");
        i = 0;
        r0 = 0;
        while (!r0[31] && i < 10) begin
            sdcmd(55, 0, R_SHORT);
            expect_ok("CMD55");
            sdcmd(41, 32'h4030_0000, R_SHORT | NOCRC);
            expect_ok("ACMD41");
            i = i + 1;
        end
        if (!r0[31]) fail("card never became ready");
        if (!r0[30]) fail("card not reported as high capacity");
        if (i != card.ACMD41_TRIES) fail("ACMD41 count");
        sdcmd(2, 0, R_LONG);
        expect_ok("CMD2");
        if (r3[31:24] !== 8'h03) fail("CID manufacturer");
        sdcmd(3, 0, R_SHORT);
        expect_ok("CMD3");
        if (r0[31:16] !== card.rca) fail("RCA");
        sdcmd(9, {card.rca, 16'd0}, R_LONG);
        expect_ok("CMD9");
        if (r3[31:30] !== 2'b01) fail("CSD version");
        if ({r2[5:0], r1[31:16]} !== 22'd0) fail("CSD C_SIZE");
        sdcmd(7, {card.rca, 16'd0}, R_SHORT | BUSY);
        expect_ok("CMD7");
        sdcmd(55, {card.rca, 16'd0}, R_SHORT);
        sdcmd(6, 32'h2, R_SHORT);
        expect_ok("ACMD6");
        if (!card.bus4) fail("card not in 4-bit mode");
        wreg(4'd0, ctrl_fast);
        sdcmd(13, {card.rca, 16'd0}, R_SHORT);
        expect_ok("CMD13 at 25 MHz");
        if (r0[12:9] !== 4'd4) fail("card not in transfer state");

        // -------- single block --------
        begin_test("single-block write (CMD24), block 5");
        fill_src(256);
        wreg(4'd3, 1);
        sdcmd(24, 5, R_SHORT | D_WRITE);
        expect_ok("CMD24");
        wait_data;
        expect_data_ok("CMD24 data");
        check_card(5, 1, "CMD24");
        if (src_i != 256) fail("words taken from the source");

        begin_test("single-block read (CMD17), block 5");
        start_read;
        wreg(4'd3, 1);
        sdcmd(17, 5, R_SHORT | D_READ);
        expect_ok("CMD17");
        wait_data;
        expect_data_ok("CMD17 data");
        check_snk(5, 1, "CMD17");
        if (blk_good != 1 || blk_bad != 0) fail("block done/ok signals");

        // -------- multiple blocks --------
        begin_test("multiple-block write (CMD25 + CMD12), 8 blocks from 10");
        fill_src(8 * 256);
        wreg(4'd3, 8);
        sdcmd(25, 10, R_SHORT | D_WRITE);
        expect_ok("CMD25");
        wait_data;
        expect_data_ok("CMD25 data");
        sdcmd(12, 0, R_SHORT | BUSY);
        expect_ok("CMD12");
        check_card(10, 8, "CMD25");
        if (card.writes_done != 9) fail("card's count of blocks written");

        begin_test("multiple-block read (CMD18 + CMD12), 8 blocks from 10");
        start_read;
        wreg(4'd3, 8);
        t0 = $realtime;
        sdcmd(18, 10, R_SHORT | D_READ);
        expect_ok("CMD18");
        wait_data;
        t1 = $realtime;
        expect_data_ok("CMD18 data");
        sdcmd(12, 0, R_SHORT | BUSY);
        expect_ok("CMD12");
        check_snk(10, 8, "CMD18");
        if (blk_good != 8) fail("good blocks");
        $display("      8 blocks in %0.1f us: %0.2f MB/s", (t1 - t0) / 1000.0,
                 8 * 512 / ((t1 - t0) / 1000.0));
        sdcmd(13, {card.rca, 16'd0}, R_SHORT);
        if (r0[12:9] !== 4'd4) fail("card not back in transfer state");

        // -------- flow control --------
        begin_test("read with the consumer not ready for 5 us after each block");
        start_read;
        rd_throttle = 250;
        wreg(4'd3, 4);
        sdcmd(18, 40, R_SHORT | D_READ);
        wait_data;
        expect_data_ok("throttled read");
        sdcmd(12, 0, R_SHORT | BUSY);
        expect_ok("CMD12");
        rd_throttle = 0;
        check_snk(40, 4, "throttled read");
        if (strobe_not_ready) fail("data arrived while the consumer wasn't ready");

        begin_test("write with the source not ready for 5 us after each block");
        fill_src(4 * 256);
        wr_throttle = 250;
        wreg(4'd3, 4);
        sdcmd(25, 50, R_SHORT | D_WRITE);
        wait_data;
        expect_data_ok("throttled write");
        sdcmd(12, 0, R_SHORT | BUSY);
        expect_ok("CMD12");
        wr_throttle = 0;
        check_card(50, 4, "throttled write");

        begin_test("long write busy (20000 clocks, 0.8 ms)");
        card.busy_clks = 20000;
        fill_src(256);
        wreg(4'd3, 1);
        sdcmd(24, 60, R_SHORT | D_WRITE);
        wait_data;
        expect_data_ok("slow write");
        check_card(60, 1, "slow write");
        card.busy_clks = 200;

        // -------- errors --------
        begin_test("read block with a bad CRC");
        start_read;
        card.corrupt_read = 1;
        wreg(4'd3, 1);
        sdcmd(17, 5, R_SHORT | D_READ);
        wait_data;
        if (!st[5]) fail("CRC error not reported");
        if (blk_bad != 1) fail("rd_blk_ok not low");
        start_read;
        sdcmd(17, 5, R_SHORT | D_READ);
        wait_data;
        expect_data_ok("read after a CRC error");
        check_snk(5, 1, "read after a CRC error");

        begin_test("write rejected by the card (CRC status token)");
        fill_src(256);
        card.reject_write = 1;
        wreg(4'd3, 1);
        sdcmd(24, 70, R_SHORT | D_WRITE);
        wait_data;
        if (!st[7]) fail("rejected write not reported");
        sdcmd(13, {card.rca, 16'd0}, R_SHORT);
        expect_ok("CMD13 after a rejected write");
        if (r0[12:9] !== 4'd4) fail("card not in transfer state");

        begin_test("no response (unknown command)");
        sdcmd(5, 0, R_SHORT);
        if (!st[2]) fail("timeout not reported");
        sdcmd(13, {card.rca, 16'd0}, R_SHORT);
        expect_ok("CMD13 after a timeout");

        // -------- 1-bit bus --------
        begin_test("1-bit bus: write and read 2 blocks");
        sdcmd(55, {card.rca, 16'd0}, R_SHORT);
        sdcmd(6, 32'h0, R_SHORT);
        expect_ok("ACMD6 1-bit");
        wreg(4'd0, ctrl_fast & ~32'h100);
        fill_src(2 * 256);
        wreg(4'd3, 2);
        sdcmd(25, 80, R_SHORT | D_WRITE);
        wait_data;
        expect_data_ok("1-bit write");
        sdcmd(12, 0, R_SHORT | BUSY);
        check_card(80, 2, "1-bit write");
        start_read;
        sdcmd(18, 80, R_SHORT | D_READ);
        wait_data;
        expect_data_ok("1-bit read");
        sdcmd(12, 0, R_SHORT | BUSY);
        check_snk(80, 2, "1-bit read");
        sdcmd(55, {card.rca, 16'd0}, R_SHORT);
        sdcmd(6, 32'h2, R_SHORT);
        wreg(4'd0, ctrl_fast);

        begin_test("back in 4-bit: read 2 blocks");
        start_read;
        wreg(4'd3, 2);
        sdcmd(18, 80, R_SHORT | D_READ);
        wait_data;
        expect_data_ok("4-bit read");
        sdcmd(12, 0, R_SHORT | BUSY);
        check_snk(80, 2, "4-bit read");

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
