// Testbench: the FPGA-only SoC (soc.v) running its firmware (fw.hex, from
// ../fw) against an SD card model holding a FAT32 card built by mksdimg.py.
// Prints the firmware's serial log, and checks that start-up gets as far as
// running the drive, without the processor trapping. (The drive itself is
// tested by difnif72_t.v's processor mode, run_sim72.sh cpu.)
//
// Run by run_socsim.sh, which supplies IMG_LBA, IMG_BLOCKS, MEM_BLOCKS,
// CARD_BLOCKS and SDIMG.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

`timescale 1ns / 1ps

module soc_t;

    reg clk = 0;
    always #10 clk = ~clk;
    reg rst = 1;

    wire        uart_tx;
    reg         uart_rx = 1'b1;

    task send_byte;   // 1 Mbaud, 8N1
        input [7:0] b;
        integer i;
        begin
            uart_rx = 1'b0;
            #1000;
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = b[i];
                #1000;
            end
            uart_rx = 1'b1;
            #1000;
        end
    endtask
    wire [1:0]  leds;
    wire        sd_clk, sd_cmd_out, sd_cmd_oe;
    wire [3:0]  sd_dat_out, sd_dat_oe;
    tri1        cmd;
    tri1 [3:0]  dat;
    assign cmd = sd_cmd_oe ? sd_cmd_out : 1'bz;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : lane
            assign dat[g] = sd_dat_oe[g] ? sd_dat_out[g] : 1'bz;
        end
    endgenerate

    // Sector buffer, as in difnif_top.v (its host side idle here)
    wire        buf_mode, buf_dir, buf_clear;
    wire        t_buf_wr, t_buf_rd, t_buf_go, t_buf_done, t_buf_ready, t_buf_can_arm, t_buf_h_idle;
    wire [15:0] t_buf_wdata, t_buf_rdata, h_rdata;
    wire        h_ready, h_more;

    soc #(.FIRMWARE("fw.hex")) soc (
        .clk(clk), .rst(rst),
        .uart_tx(uart_tx), .uart_rx(uart_rx), .leds(leds),
        .sd_clk(sd_clk), .sd_cmd_in(cmd), .sd_cmd_out(sd_cmd_out), .sd_cmd_oe(sd_cmd_oe),
        .sd_dat_in(dat), .sd_dat_out(sd_dat_out), .sd_dat_oe(sd_dat_oe), .sd_detect(1'b0),
        .t_atn(8'h00), .t_atn_full(1'b0), .t_atn_read(),
        .t_isr_out(), .t_isr_full(1'b0), .t_isr_write(),
        .t_cifr(16'h0000), .t_cifr_full(1'b0), .t_cifr_read(),
        .t_sifr_out(), .t_sifr_full(1'b0), .t_sifr_write(),
        .t_hard_reset(1'b0), .t_cmd_in_progress(), .t_busy_clear(), .t_clear_all(),
        .t_dreg_out(16'h0000), .t_dreg_in(), .t_treq_set(), .t_treq(1'b0), .t_treq_16(1'b0),
        .t_pos_regs(40'h00_0000_DF9F), .t_host_diag(16'h0000),
        .buf_mode(buf_mode), .buf_dir(buf_dir), .burst_en(), .isr_gate(), .t_sifr_clear(),
        .t_buf_wr(t_buf_wr), .t_buf_wdata(t_buf_wdata), .t_buf_rd(t_buf_rd),
        .t_buf_go(t_buf_go), .t_buf_done(t_buf_done), .t_buf_rdata(t_buf_rdata),
        .t_buf_ready(t_buf_ready), .t_buf_can_arm(t_buf_can_arm), .t_buf_h_idle(t_buf_h_idle),
        .buf_clear(buf_clear),
        .buf_h_ev(1'b0), .buf_h_rdata(16'h0000), .hold_ovr(),
        .sd_req(1'b0), .pfail(1'b0), .sd_rel()
    );

    sectorbuf sb (
        .clk(clk), .clear(~buf_mode | buf_clear), .dir(buf_dir),
        .t_wr(t_buf_wr), .t_wdata(t_buf_wdata), .t_rd(t_buf_rd), .t_rdata(t_buf_rdata),
        .t_go(t_buf_go), .t_done(t_buf_done), .t_ready(t_buf_ready), .t_can_arm(t_buf_can_arm),
        .h_idle(t_buf_h_idle), .h_ev(1'b0), .h_wdata(16'h0000), .h_rdata(h_rdata),
        .h_ready(h_ready), .h_more(h_more)
    );

    sdcard_model #(.MEM_BLOCKS(`MEM_BLOCKS), .CARD_BLOCKS(`CARD_BLOCKS), .IMAGE(`SDIMG))
        card (.sd_clk(sd_clk), .cmd(cmd), .dat(dat));

    // ---- the serial log, 1 Mbaud ----
    reg [8*200-1:0] line = 0;
    integer         nlines = 0;
    reg             done = 0, failed = 0;
    integer         n_running = 0;     // "drive blocks" lines seen
    integer         errors = 0;

    initial begin : rx
        integer i;
        reg [7:0] c;
        forever begin
            @(negedge uart_tx);
            #500;                          // middle of the start bit
            for (i = 0; i < 8; i = i + 1) begin
                #1000;
                c[i] = uart_tx;
            end
            #1000;
            if (c == 8'h0A) begin
                $display("%t  log: %0s", $realtime, line);
                // "drive blocks " and 8 hex digits: the drive is running
                if (line[8*21-1:8*9] == "drive blocks") begin
                    done = 1;
                    n_running = n_running + 1;
                end
                if (line[8*6-1:0] == "failed" || line[8*6-1:0] == "usable") failed = 1;
                line = 0;
                nlines = nlines + 1;
            end else if (c != 8'h0D) begin
                line = {line[8*199-1:0], c};
            end
        end
    end

    integer k;
    initial begin
        $timeformat(-3, 3, " ms", 10);
        repeat (20) @(posedge clk);
        rst = 0;
        wait (done || failed || soc.trap);
        repeat (1000) @(posedge clk);
        // A key on the serial port prints the summary again
        send_byte(8'h0D);
        // (the summary is a few ms of log at 1 Mbaud: wait for it, up to 20 ms)
        for (k = 0; k < 200 && n_running < 2; k = k + 1) #100_000;
        if (n_running != 2) begin
            $display("FAIL: no summary after a key on the serial port");
            errors = errors + 1;
        end
        // "x" and Enter, as the Arduino serial monitor sends it: one summary
        send_byte("x");
        send_byte(8'h0A);
        for (k = 0; k < 200 && n_running < 3; k = k + 1) #100_000;
        #10_000_000;                    // and no second one for the line ending
        if (n_running != 3) begin
            $display("FAIL: \"x\" and a line ending gave %0d summaries, expected 1", n_running - 2);
            errors = errors + 1;
        end
        if (soc.trap) begin
            $display("FAIL: the processor trapped");
            errors = errors + 1;
        end
        if (!done) begin
            $display("FAIL: start-up didn't finish");
            errors = errors + 1;
        end
        if (card.errors) begin
            $display("FAIL: the card model reported %0d errors", card.errors);
            errors = errors + card.errors;
        end
        if (errors == 0) $display("ALL PASS");
        else $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAILED: timeout");
        $finish;
    end

endmodule
