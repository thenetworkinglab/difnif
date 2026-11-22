// DifNif: SD card host controller to sector buffer
//
// Takes the Teensy's place on the sector buffer's Teensy side (sectorbuf.v),
// so blocks go between the SD card (sdhost.v) and the PS/2's DREG and DMA
// accesses without passing through the Teensy. What to transfer, and the
// SD commands, are still up to whatever drives sdhost's registers.
//
// dir 0, disk read (card to host):
//   Each word from the card goes into the buffer's free half; a good block
//   is handed to the host side (t_go). sdhost only starts a block when a
//   half is free, so the SD clock stops while the host is behind. A block
//   with a bad CRC isn't handed over, and the bridge ignores the card from
//   then on (failed) until clear_fail. The half's pointer has wrapped back
//   to its start, so the retried block lands in the same half and the host
//   still gets the blocks in order.
// dir 1, disk write (host to card):
//   The bridge arms halves for the host to fill, arm_n of them in all (the
//   command's sectors), as halves come free. A full half goes to the card;
//   it's freed (t_done) only once the card has accepted the block and
//   finished programming it. A rejected block stays in its half, read out
//   again from the start when it's retried (the pointer has wrapped), and
//   the bridge stops (failed) until clear_fail.
//
// restart starts a transfer: set dir first (or in the same clock). It
// empties the sector buffer (sb_clear) and, for a write, sets how many
// halves to arm, so the arming can't run ahead of the buffer. For a read,
// arm_n is a limit (0: none): once that many blocks have gone to the host
// side, rd_ready stays low, so sdhost stops the SD clock before the next
// block and the card holds it. That's read-ahead: the card's multiple-block
// read stays open, and a restart for the next sequential sectors lets the
// held block through at once, without the card's access time.
//
// blocks_done counts the blocks passed to the host (dir 0) or accepted by
// the card (dir 1) since restart, which tells the controller where to
// resume after a failure.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

`default_nettype none

module sdbridge (
    input  wire        clk,
    input  wire        rst,

    input  wire        dir,         // the sector buffer's direction
    input  wire        restart,     // one clock: a new transfer
    output wire        sb_clear,    // to the sector buffer's clear
    input  wire [15:0] arm_n,       // with restart: sectors to transfer (dir 0: a limit, 0 none)
    input  wire        clear_fail,  // one clock: carry on after a failure
    output reg  [15:0] blocks_done,
    output reg         failed,

    // sdhost
    input  wire [15:0] rd_word,
    input  wire        rd_strobe,
    input  wire        rd_blk_done,
    input  wire        rd_blk_ok,
    output wire        rd_ready,
    output wire [15:0] wr_word,
    input  wire        wr_next,
    output wire        wr_ready,
    input  wire        wr_blk_done,
    input  wire        wr_blk_ok,

    // sector buffer, Teensy side
    output wire        t_wr,
    output wire [15:0] t_wdata,
    output wire        t_rd,
    input  wire [15:0] t_rdata,
    output wire        t_go,
    output reg         t_done,
    input  wire        t_ready,
    input  wire        t_can_arm
);

    reg [15:0] to_arm;
    reg [15:0] rd_limit = 16'd0;  // dir 0: blocks to pass before holding the card (0: no limit)
    reg [7:0]  wcount;    // dir 1: words of the current half sent
    reg        sent;      // dir 1: the whole half sent, waiting for the card

    // Read
    assign t_wdata  = rd_word;
    assign t_wr     = ~dir & rd_strobe & ~failed;
    wire   load     = ~dir & rd_blk_done & rd_blk_ok & ~failed;
    assign rd_ready = ~dir & t_ready & ~failed & (rd_limit == 16'd0 || blocks_done != rd_limit);

    // Write
    wire   arm      = dir & t_can_arm & (to_arm != 16'd0) & ~restart;
    assign wr_word  = t_rdata;
    assign t_rd     = dir & wr_next;
    assign wr_ready = dir & t_ready & ~sent & ~failed;

    assign t_go = load | arm;
    assign sb_clear = restart;

    always @(posedge clk) begin
        t_done <= 1'b0;
        if (rst || restart) begin
            to_arm      <= (rst || !dir) ? 16'd0 : arm_n;
            rd_limit    <= (rst || dir) ? 16'd0 : arm_n;
            wcount      <= 8'd0;
            sent        <= 1'b0;
            failed      <= 1'b0;
            blocks_done <= 16'd0;
        end else begin
            if (clear_fail) failed <= 1'b0;
            if (arm) to_arm <= to_arm - 16'd1;
            if (t_rd) begin
                wcount <= wcount + 8'd1;
                if (wcount == 8'd255) sent <= 1'b1;
            end
            if (dir && wr_blk_done) begin
                sent <= 1'b0;
                if (wr_blk_ok) begin
                    t_done      <= 1'b1;
                    blocks_done <= blocks_done + 16'd1;
                end else begin
                    failed <= 1'b1;
                end
            end
            if (load) blocks_done <= blocks_done + 16'd1;
            if (!dir && rd_blk_done && !rd_blk_ok && !failed) failed <= 1'b1;
        end
    end

endmodule

`default_nettype wire
