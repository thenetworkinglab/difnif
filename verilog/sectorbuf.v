// DifNif sector buffer
//
// Two 256-word (one sector) halves in block RAM between the Teensy and the
// host's DREG/DMA transfers, so the host doesn't wait on the Teensy for
// every word. Everything here runs on the 50 MHz clock: the Teensy's
// accesses (teensy.v) and the host's DREG transfers (mcabus.v, ev_treq)
// arrive as one-clock pulses.
//
// dir 0, disk read (Teensy to host):
//   The Teensy writes 256 words into a free half (t_wr), then t_go hands
//   that half to the host side. The host empties it one word per DREG
//   access, and the half becomes free again. The Teensy can fill the other
//   half meanwhile. t_ready: the Teensy's half is free to fill.
// dir 1, disk write (host to Teensy):
//   t_go arms a free half to take a sector from the host. The host fills it
//   one word per DREG access; when it's full it passes to the Teensy, which
//   reads it out (t_rdata, t_rd after each word) and frees it with t_done.
//   t_ready: a full half is waiting for the Teensy. t_can_arm: a half is
//   free to arm.
// h_idle: neither half belongs to the host side (nothing left for the host
// to read, or no armed half waiting for host data).
//
// Each half is FREE, HOST (being emptied, or armed and being filled, by the
// host) or TEENSY (dir 1: full, being read by the Teensy). A half's state
// only changes in one way at a time, so events for different halves in the
// same clock can't collide.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

`default_nettype none

module sectorbuf(
    input clk,
    input clear,            // empty both halves (buffer off, clear all, reset)
    input dir,              // 0: Teensy to host, 1: host to Teensy

    // Teensy side, one-clock pulses
    input t_wr,             // dir 0: store t_wdata at the Teensy's pointer
    input [15:0] t_wdata,
    input t_rd,             // dir 1: the Teensy has read t_rdata
    output reg [15:0] t_rdata = 16'h0000,
    input t_go,             // dir 0: the half just filled is loaded; dir 1: arm a half
    input t_done,           // dir 1: the Teensy has read the whole half
    output t_ready,
    output t_can_arm,
    output h_idle,

    // Host side
    input h_ev,             // one host or DMA access to DREG has completed
    input [15:0] h_wdata,   // dir 1: the word the host wrote
    output reg [15:0] h_rdata = 16'h0000,
    output h_ready,         // dir 0: a word is ready; dir 1: room for a word
    output h_more           // ...and there's another after the one at the pointer
    );

    localparam [1:0] FREE = 2'd0, HOST = 2'd1, TEENSY = 2'd2;

    reg [1:0] st0 = FREE, st1 = FREE;   // state of each half

    reg tp_half = 1'b0;                 // Teensy pointer
    reg [7:0] tp_idx = 8'h00;
    reg hp_half = 1'b0;                 // host pointer
    reg [7:0] hp_idx = 8'h00;
    reg ap_half = 1'b0;                 // dir 1: next half to arm

    wire [1:0] st_tp = tp_half ? st1 : st0;
    wire [1:0] st_hp = hp_half ? st1 : st0;
    wire [1:0] st_ap = ap_half ? st1 : st0;
    wire [1:0] st_ho = hp_half ? st0 : st1;     // the host's other half

    // Block RAM: one write port and one read port, shared by direction
    reg [15:0] mem [0:511];
    wire we = dir ? (h_ev & (st_hp == HOST)) : (t_wr & (st_tp == FREE));
    wire [8:0] waddr = dir ? {hp_half, hp_idx} : {tp_half, tp_idx};
    wire [15:0] wdata = dir ? h_wdata : t_wdata;
    wire [8:0] raddr = dir ? {tp_half, tp_idx} : {hp_half, hp_idx};
    reg [15:0] rq;

    always @ (posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rq <= mem[raddr];
    end

    // Prefetched words: the next one for the host (dir 0) or the Teensy (dir 1)
    reg h_valid = 1'b0, h_fetch = 1'b0;
    reg t_valid = 1'b0, t_fetch = 1'b0;

    wire h_take = ~dir & h_ev & h_valid;                // host took a word
    wire h_put = dir & h_ev & (st_hp == HOST);           // host wrote a word
    wire t_put = ~dir & t_wr & (st_tp == FREE);          // Teensy wrote a word
    wire t_take = dir & t_rd & t_valid;                  // Teensy took a word
    wire t_load = ~dir & t_go & (st_tp == FREE);         // dir 0: half loaded
    wire t_arm = dir & t_go & (st_ap == FREE);           // dir 1: arm a half
    wire t_free = dir & t_done & (st_tp == TEENSY);      // dir 1: half read out
    wire h_last = (hp_idx == 8'hFF);

    assign h_ready = dir ? (st_hp == HOST) : h_valid;
    assign t_ready = dir ? ((st_tp == TEENSY) & t_valid) : (st_tp == FREE);
    assign t_can_arm = dir & (st_ap == FREE);
    assign h_idle = (st0 != HOST) & (st1 != HOST);
    assign h_more = (st_hp == HOST) & (~h_last | (st_ho == HOST));

    // Changing direction empties the buffer too
    reg dir_q = 1'b0;
    always @ (posedge clk) dir_q <= dir;
    wire clr = clear | (dir != dir_q);

    always @ (posedge clk) begin
        if (clr) begin
            st0 <= FREE;
            st1 <= FREE;
            tp_half <= 1'b0;
            tp_idx <= 8'h00;
            hp_half <= 1'b0;
            hp_idx <= 8'h00;
            ap_half <= 1'b0;
            h_valid <= 1'b0;
            h_fetch <= 1'b0;
            t_valid <= 1'b0;
            t_fetch <= 1'b0;
            t_rdata <= 16'h0000;    // register 14 reads 0 while the buffer is off
            h_rdata <= 16'h0000;
        end else begin
            // Teensy pointer
            if (t_put | t_take)
                tp_idx <= tp_idx + 8'd1;
            if (t_load | t_free) begin
                tp_half <= ~tp_half;
                tp_idx <= 8'h00;
            end

            // Host pointer
            if (h_take | h_put) begin
                hp_idx <= hp_idx + 8'd1;
                if (h_last) hp_half <= ~hp_half;
            end

            if (t_arm) ap_half <= ~ap_half;

            // Half states. Each event needs its half in a different state,
            // so two events never hit the same half in one clock.
            if (t_load) begin
                if (tp_half) st1 <= HOST; else st0 <= HOST;
            end
            if (t_arm) begin
                if (ap_half) st1 <= HOST; else st0 <= HOST;
            end
            if ((h_take | h_put) & h_last) begin
                if (hp_half) st1 <= dir ? TEENSY : FREE;
                else         st0 <= dir ? TEENSY : FREE;
            end
            if (t_free) begin
                if (tp_half) st1 <= FREE; else st0 <= FREE;
            end

            // Host prefetch (dir 0): read the word at the host pointer, then
            // latch it a clock later. Not started in a clock that moves the
            // pointer, so the word read is the one latched.
            if (h_take) begin
                h_valid <= 1'b0;
            end else if (h_fetch) begin
                h_rdata <= rq;
                h_valid <= 1'b1;
            end
            h_fetch <= ~dir & ~h_valid & ~h_fetch & ~h_ev & (st_hp == HOST);

            // Teensy prefetch (dir 1), the same way
            if (t_take | t_free) begin
                t_valid <= 1'b0;
            end else if (t_fetch) begin
                t_rdata <= rq;
                t_valid <= 1'b1;
            end
            t_fetch <= dir & ~t_valid & ~t_fetch & ~t_rd & ~t_done & (st_tp == TEENSY);
        end
    end

endmodule
