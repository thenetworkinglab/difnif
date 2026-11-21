// DifNif SD card host controller (SD bus mode, 1-bit or 4-bit)
//
// The low-level half of an FPGA-only DifNif: it sends commands and moves
// 512-byte blocks, and leaves the card's start-up sequence, error recovery
// and which commands to send to whatever drives the registers (a small
// processor later, the testbench for now).
//
// Everything runs on the 50 MHz clock. The SD clock is a divided copy:
// each half period is clkdiv+1 clocks, so clkdiv 0 gives 25 MHz (the
// default-speed maximum) and 62 gives 397 kHz (start-up must be at 400 kHz
// or less). The SD clock only runs while something needs it, and stops low.
// The host drives CMD and DAT as the SD clock falls. It samples them as
// the clock rises or, with sample_late, one 50 MHz clock later: at 25 MHz
// that's as the clock falls, which leaves room for the card's output delay
// (up to 14 ns) plus the FPGA's own pin and trace delays.
//
// Registers (addr):
//   0 CTRL    [7:0] clkdiv, [8] 4-bit bus, [9] clock runs all the time,
//             [10] sample_late. Writing bit 16 stops a data transfer.
//   1 ARG     the next command's argument
//   2 CMD     write: starts a command. [5:0] index, [7:6] response (0 none,
//             1 48-bit, 2 136-bit), [8] wait for busy after the response
//             (R1b), [9] don't check the response's CRC (R3), [11:10] data
//             (0 none, 1 read, 2 write), [12] send 80 clocks and no command
//             (power-up). Read: same as STATUS.
//   3 BLKCNT  [15:0] blocks in the next data command
//   4 STATUS  [0] command busy, [1] data busy, [2] response timeout,
//             [3] response CRC or format error, [4] busy timeout after R1b,
//             [5] read data CRC error, [6] read data timeout, [7] write
//             rejected by the card (CRC status not "accepted"), [8] write
//             busy timeout, [9] card detect switch, [10] DAT0,
//             [31:16] blocks still to transfer. The command and data error
//             bits clear when a new command (or data command) starts.
//   5-8 RESP  the last response: 48-bit responses give the 32-bit
//             argument or card status in RESP (5) and the command index in
//             RESP1 (6) bits 5:0; 136-bit responses (CID, CSD) give bits
//             127:0 in 5-8, so CSD bit n is bit n of {8,7,6,5}.
//
// Data streams, 16 bits at a time, byte 0 of the block in bits 7:0 (as the
// sector buffer and the Teensy firmware hold them):
//   read:  rd_word with a one-clock rd_strobe per word, then rd_blk_done
//          with rd_blk_ok (CRC and end bits good). rd_ready: there's room
//          for a whole block. Between blocks the SD clock stops until it
//          is; within a block, words come at the bus rate (one per four SD
//          clocks in 4-bit mode). Have room for the first block before
//          starting a read.
//   write: wr_word is the next word to send, and wr_next takes it (the next
//          word must follow within two clocks). wr_ready: a whole block is
//          there to send; between blocks the SD clock stops until it is.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

`default_nettype none

module sdhost (
    input  wire        clk,
    input  wire        rst,

    input  wire [3:0]  addr,
    input  wire [31:0] wdata,
    input  wire        we,
    output reg  [31:0] rdata,

    output reg  [15:0] rd_word,
    output reg         rd_strobe,
    input  wire        rd_ready,
    output reg         rd_blk_done,
    output reg         rd_blk_ok,

    input  wire [15:0] wr_word,
    output reg         wr_next,
    input  wire        wr_ready,

    output reg         sd_clk,
    input  wire        cmd_in,
    output reg         cmd_out,
    output reg         cmd_oe,
    input  wire [3:0]  dat_in,
    output reg  [3:0]  dat_out,
    output reg  [3:0]  dat_oe,
    input  wire        card_detect
);

    // ------------------------------------------------------------------
    // CRCs

    // CRC7 (x^7 + x^3 + 1) over the first 40 bits of a command or response
    function [6:0] crc7_40;
        input [39:0] d;
        integer i;
        reg [6:0] c;
        reg fb;
        begin
            c = 7'd0;
            for (i = 39; i >= 0; i = i - 1) begin
                fb = c[6] ^ d[i];
                c = {c[5:0], 1'b0};
                if (fb) c = c ^ 7'h09;
            end
            crc7_40 = c;
        end
    endfunction

    // CRC16 (x^16 + x^12 + x^5 + 1), one bit
    function [15:0] crc16_bit;
        input [15:0] c;
        input b;
        begin
            crc16_bit = {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h1021 : 16'h0000);
        end
    endfunction

    // ------------------------------------------------------------------
    // Registers

    reg [7:0]   clkdiv;
    reg         bus4;
    reg         clk_free;
    reg         sample_late;
    reg [31:0]  arg;
    reg [15:0]  blkcnt;
    reg [127:0] resp;

    wire cmd_write  = we && addr == 4'd2;
    wire data_abort = we && addr == 4'd0 && wdata[16];

    always @(posedge clk) begin
        if (rst) begin
            clkdiv      <= 8'd62;
            bus4        <= 1'b0;
            clk_free    <= 1'b0;
            sample_late <= 1'b0;
            arg         <= 32'd0;
            blkcnt      <= 16'd1;
        end else if (we) begin
            case (addr)
                4'd0: begin
                    clkdiv      <= wdata[7:0];
                    bus4        <= wdata[8];
                    clk_free    <= wdata[9];
                    sample_late <= wdata[10];
                end
                4'd1: arg    <= wdata;
                4'd3: blkcnt <= wdata[15:0];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // SD clock

    reg  [7:0] divcnt;
    wire       tick = (divcnt == 8'd0);
    wire       clk_run;
    wire       do_fall = tick && sd_clk;             // SD clock falls now
    wire       do_rise = tick && !sd_clk && clk_run; // SD clock rises now
    reg        rise_d;
    wire       samp = sample_late ? rise_d : do_rise; // sample CMD and DAT now

    always @(posedge clk) begin
        rise_d <= do_rise;
        if (rst) begin
            sd_clk <= 1'b0;
            divcnt <= 8'd0;
        end else if (!tick) begin
            divcnt <= divcnt - 8'd1;
        end else if (sd_clk) begin
            sd_clk <= 1'b0;
            divcnt <= clkdiv;
        end else if (clk_run) begin
            sd_clk <= 1'b1;
            divcnt <= clkdiv;
        end
    end

    // ------------------------------------------------------------------
    // Command engine

    localparam C_IDLE  = 4'd0;
    localparam C_INIT  = 4'd1;  // power-up clocks
    localparam C_SEND  = 4'd2;  // 48 command bits
    localparam C_REL   = 4'd3;  // let go of CMD
    localparam C_WAIT  = 4'd4;  // wait for the response's start bit
    localparam C_RESP  = 4'd5;  // the rest of the response
    localparam C_CHECK = 4'd6;
    localparam C_BUSYW = 4'd7;  // two clocks before looking at busy
    localparam C_BUSY  = 4'd8;  // wait for DAT0 high
    localparam C_NCC   = 4'd9;  // 8 clocks before the next command (NCC)

    reg [3:0]   cst;
    reg [47:0]  csr;
    reg [5:0]   cbits;
    reg [135:0] rsr;
    reg [7:0]   rcount;
    reg [1:0]   rtype;
    reg         rbusy;
    reg         rnocrc;
    reg [23:0]  ctimer;
    reg         err_rto;
    reg         err_rcrc;
    reg         err_bto;
    reg         resp_ok;    // one clock: a good response came (starts a write)

    wire [39:0] frame = {2'b01, wdata[5:0], arg};

    wire short_bad = !rsr[0] || rsr[46] ||
                     (!rnocrc && crc7_40(rsr[47:8]) != rsr[7:1]);
    wire long_bad  = !rsr[0] || rsr[134];
    wire resp_bad  = (rtype == 2'd2) ? long_bad : short_bad;

    always @(posedge clk) begin
        resp_ok <= 1'b0;
        if (rst) begin
            cst      <= C_IDLE;
            cmd_oe   <= 1'b0;
            cmd_out  <= 1'b1;
            err_rto  <= 1'b0;
            err_rcrc <= 1'b0;
            err_bto  <= 1'b0;
            resp     <= 128'd0;
        end else begin
            case (cst)
                C_IDLE: if (cmd_write) begin
                    err_rto  <= 1'b0;
                    err_rcrc <= 1'b0;
                    err_bto  <= 1'b0;
                    rtype    <= wdata[7:6];
                    rbusy    <= wdata[8];
                    rnocrc   <= wdata[9];
                    if (wdata[12]) begin
                        rcount <= 8'd80;
                        cst    <= C_INIT;
                    end else begin
                        csr   <= {frame, crc7_40(frame), 1'b1};
                        cbits <= 6'd0;
                        cst   <= C_SEND;
                    end
                end

                C_INIT: if (do_rise) begin
                    rcount <= rcount - 8'd1;
                    if (rcount == 8'd1) cst <= C_IDLE;
                end

                C_SEND: if (do_fall) begin
                    cmd_oe  <= 1'b1;
                    cmd_out <= csr[47];
                    csr     <= {csr[46:0], 1'b1};
                    cbits   <= cbits + 6'd1;
                    if (cbits == 6'd47) cst <= C_REL;
                end

                // The end bit has had a full clock; let go of CMD
                C_REL: if (do_fall) begin
                    cmd_oe  <= 1'b0;
                    cmd_out <= 1'b1;
                    rcount  <= 8'd0;
                    cst     <= (rtype == 2'd0) ? C_NCC : C_WAIT;
                end

                // The response starts within 64 clocks (NCR)
                C_WAIT: if (samp) begin
                    if (!cmd_in) begin
                        rsr    <= 136'd0;
                        rcount <= 8'd1;
                        cst    <= C_RESP;
                    end else if (rcount == 8'd80) begin
                        err_rto <= 1'b1;
                        rcount  <= 8'd0;
                        cst     <= C_NCC;
                    end else begin
                        rcount <= rcount + 8'd1;
                    end
                end

                C_RESP: if (samp) begin
                    rsr    <= {rsr[134:0], cmd_in};
                    rcount <= rcount + 8'd1;
                    if (rcount == ((rtype == 2'd2) ? 8'd135 : 8'd47)) cst <= C_CHECK;
                end

                C_CHECK: begin
                    if (rtype == 2'd2)
                        resp <= rsr[127:0];
                    else
                        resp <= {90'd0, rsr[45:40], rsr[39:8]};
                    rcount <= 8'd0;
                    if (resp_bad) begin
                        err_rcrc <= 1'b1;
                        cst      <= C_NCC;
                    end else begin
                        resp_ok <= 1'b1;
                        ctimer  <= 24'd0;
                        cst     <= rbusy ? C_BUSYW : C_NCC;
                    end
                end

                // Busy (DAT0 low) starts within two clocks of the response
                C_BUSYW: if (samp) begin
                    rcount <= rcount + 8'd1;
                    if (rcount == 8'd1) cst <= C_BUSY;
                end

                C_BUSY: if (samp) begin
                    ctimer <= ctimer + 24'd1;
                    rcount <= 8'd0;
                    if (dat_in[0]) begin
                        cst <= C_NCC;
                    end else if (&ctimer) begin
                        err_bto <= 1'b1;
                        cst     <= C_NCC;
                    end
                end

                // The card may still be driving CMD as the next clock
                // falls, and needs eight clocks after a command or response
                C_NCC: if (do_rise) begin
                    rcount <= rcount + 8'd1;
                    if (rcount == 8'd7) cst <= C_IDLE;
                end

                default: cst <= C_IDLE;
            endcase
        end
    end

    wire cmd_clk = (cst != C_IDLE);

    // ------------------------------------------------------------------
    // Data engine

    localparam D_IDLE   = 4'd0;
    localparam D_RWAIT  = 4'd1;   // read: wait for a block's start bit
    localparam D_RDATA  = 4'd2;   // read: data, CRC, end bit
    localparam D_RGAP   = 4'd3;   // read: clock stopped while rd_ready settles
    localparam D_WARM   = 4'd4;   // write: wait for the command's response
    localparam D_WGAP   = 4'd5;   // write: two clocks before a block (NWR)
    localparam D_WWAIT  = 4'd6;   // write: wait for wr_ready
    localparam D_WDATA  = 4'd7;   // write: start bit, data, CRC, end bit
    localparam D_WREL   = 4'd8;   // write: let go of DAT
    localparam D_WTOK   = 4'd9;   // write: wait for the CRC status token
    localparam D_WTOKB  = 4'd10;  // write: its three bits and end bit
    localparam D_WBUSYW = 4'd11;  // write: two clocks before looking at busy
    localparam D_WBUSY  = 4'd12;  // write: wait for programming to finish

    reg [3:0]  dst;
    reg [15:0] blocks_left;
    reg [12:0] dcount;
    reg [15:0] dsh;
    reg [15:0] crc0, crc1, crc2, crc3;
    reg [23:0] dtimer;
    reg [2:0]  tok;
    reg        err_dcrc;
    reg        err_dto;
    reg        err_wcrc;
    reg        err_dbto;

    wire [12:0] data_n = bus4 ? 13'd1024 : 13'd4096;  // data samples per block
    wire [15:0] rd_next_sh = bus4 ? {dsh[11:0], dat_in} : {dsh[14:0], dat_in[0]};
    wire        rd_word_end = bus4 ? (dcount[1:0] == 2'd3) : (dcount[3:0] == 4'd15);
    wire        wr_word_start = bus4 ? (dcount[1:0] == 2'd0) : (dcount[3:0] == 4'd0);
    wire [15:0] wr_cur = wr_word_start ? {wr_word[7:0], wr_word[15:8]} : dsh;
    wire        crc_zero = (crc0 == 16'd0) && (crc1 == 16'd0) &&
                           (crc2 == 16'd0) && (crc3 == 16'd0);
    wire        data_cmd = cmd_write && cst == C_IDLE && !wdata[12] &&
                           wdata[11:10] != 2'd0;

    always @(posedge clk) begin
        rd_strobe   <= 1'b0;
        rd_blk_done <= 1'b0;
        wr_next     <= 1'b0;
        if (rst || data_abort) begin
            dst     <= D_IDLE;
            dat_oe  <= 4'h0;
            dat_out <= 4'hF;
            if (rst) begin
                blocks_left <= 16'd0;
                err_dcrc    <= 1'b0;
                err_dto     <= 1'b0;
                err_wcrc    <= 1'b0;
                err_dbto    <= 1'b0;
                rd_blk_ok   <= 1'b0;
                rd_word     <= 16'd0;
            end
        end else if (data_cmd) begin
            err_dcrc    <= 1'b0;
            err_dto     <= 1'b0;
            err_wcrc    <= 1'b0;
            err_dbto    <= 1'b0;
            blocks_left <= blkcnt;
            dtimer      <= 24'd0;
            dst         <= (wdata[11:10] == 2'd1) ? D_RWAIT : D_WARM;
        end else begin
            case (dst)
                // ---- read ----
                D_RWAIT: if (samp) begin
                    dtimer <= dtimer + 24'd1;
                    if (!dat_in[0]) begin
                        dcount <= 13'd0;
                        crc0   <= 16'd0;
                        crc1   <= 16'd0;
                        crc2   <= 16'd0;
                        crc3   <= 16'd0;
                        dst    <= D_RDATA;
                    end else if (&dtimer) begin
                        err_dto <= 1'b1;
                        dst     <= D_IDLE;
                    end
                end

                D_RDATA: if (samp) begin
                    dcount <= dcount + 13'd1;
                    if (dcount < data_n + 13'd16) begin
                        // Data and then CRC bits both go through the CRC;
                        // a good block leaves it at zero
                        crc0 <= crc16_bit(crc0, dat_in[0]);
                        if (bus4) begin
                            crc1 <= crc16_bit(crc1, dat_in[1]);
                            crc2 <= crc16_bit(crc2, dat_in[2]);
                            crc3 <= crc16_bit(crc3, dat_in[3]);
                        end
                        if (dcount < data_n) begin
                            dsh <= rd_next_sh;
                            if (rd_word_end) begin
                                rd_word   <= {rd_next_sh[7:0], rd_next_sh[15:8]};
                                rd_strobe <= 1'b1;
                            end
                        end
                    end else begin
                        // End bit
                        rd_blk_done <= 1'b1;
                        rd_blk_ok   <= crc_zero && (bus4 ? dat_in == 4'hF : dat_in[0]);
                        if (!(crc_zero && (bus4 ? dat_in == 4'hF : dat_in[0])))
                            err_dcrc <= 1'b1;
                        blocks_left <= blocks_left - 16'd1;
                        dtimer      <= 24'd0;
                        dcount      <= 13'd0;
                        dst         <= (blocks_left == 16'd1) ? D_IDLE : D_RGAP;
                    end
                end

                // Four clocks with the SD clock stopped, so rd_ready can
                // reflect the block just finished
                D_RGAP: begin
                    dcount <= dcount + 13'd1;
                    if (dcount == 13'd3) dst <= D_RWAIT;
                end

                // ---- write ----
                D_WARM: begin
                    if (resp_ok) begin
                        dcount <= 13'd0;
                        dst    <= D_WGAP;
                    end else if (cst == C_IDLE) begin
                        dst <= D_IDLE;   // no response, or a bad one
                    end
                end

                D_WGAP: if (samp) begin
                    dcount <= dcount + 13'd1;
                    if (dcount == 13'd1) dst <= D_WWAIT;
                end

                D_WWAIT: if (do_fall && wr_ready) begin
                    dat_oe  <= bus4 ? 4'hF : 4'h1;
                    dat_out <= 4'h0;            // start bit
                    dcount  <= 13'd0;
                    crc0    <= 16'd0;
                    crc1    <= 16'd0;
                    crc2    <= 16'd0;
                    crc3    <= 16'd0;
                    dst     <= D_WDATA;
                end

                D_WDATA: if (do_fall) begin
                    dcount <= dcount + 13'd1;
                    if (dcount < data_n) begin
                        if (wr_word_start) wr_next <= 1'b1;
                        if (bus4) begin
                            dat_out <= wr_cur[15:12];
                            dsh     <= {wr_cur[11:0], 4'h0};
                            crc0    <= crc16_bit(crc0, wr_cur[12]);
                            crc1    <= crc16_bit(crc1, wr_cur[13]);
                            crc2    <= crc16_bit(crc2, wr_cur[14]);
                            crc3    <= crc16_bit(crc3, wr_cur[15]);
                        end else begin
                            dat_out <= {3'b111, wr_cur[15]};
                            dsh     <= {wr_cur[14:0], 1'b0};
                            crc0    <= crc16_bit(crc0, wr_cur[15]);
                        end
                    end else if (dcount < data_n + 13'd16) begin
                        dat_out <= {crc3[15], crc2[15], crc1[15], crc0[15]};
                        crc0    <= {crc0[14:0], 1'b0};
                        crc1    <= {crc1[14:0], 1'b0};
                        crc2    <= {crc2[14:0], 1'b0};
                        crc3    <= {crc3[14:0], 1'b0};
                    end else begin
                        dat_out <= 4'hF;            // end bit
                        dst     <= D_WREL;
                    end
                end

                D_WREL: if (do_fall) begin
                    dat_oe  <= 4'h0;
                    dcount  <= 13'd0;
                    dst     <= D_WTOK;
                end

                // The CRC status token starts two clocks after the end bit
                D_WTOK: if (samp) begin
                    dcount <= dcount + 13'd1;
                    if (!dat_in[0]) begin
                        dcount <= 13'd0;
                        dst    <= D_WTOKB;
                    end else if (dcount == 13'd16) begin
                        err_wcrc <= 1'b1;
                        dst      <= D_IDLE;
                    end
                end

                D_WTOKB: if (samp) begin
                    dcount <= dcount + 13'd1;
                    if (dcount < 13'd3) begin
                        tok <= {tok[1:0], dat_in[0]};
                    end else begin
                        dcount <= 13'd0;
                        dtimer <= 24'd0;
                        if (tok != 3'b010 || !dat_in[0]) begin
                            err_wcrc <= 1'b1;
                            dst      <= D_IDLE;
                        end else begin
                            dst <= D_WBUSYW;
                        end
                    end
                end

                D_WBUSYW: if (samp) begin
                    dcount <= dcount + 13'd1;
                    if (dcount == 13'd1) dst <= D_WBUSY;
                end

                D_WBUSY: if (samp) begin
                    dtimer <= dtimer + 24'd1;
                    if (dat_in[0]) begin
                        blocks_left <= blocks_left - 16'd1;
                        dcount      <= 13'd0;
                        dst         <= (blocks_left == 16'd1) ? D_IDLE : D_WGAP;
                    end else if (&dtimer) begin
                        err_dbto <= 1'b1;
                        dst      <= D_IDLE;
                    end
                end

                default: dst <= D_IDLE;
            endcase
        end
    end

    wire data_clk = (dst == D_RDATA) || (dst == D_RWAIT && rd_ready) ||
                    (dst == D_WGAP) || (dst == D_WWAIT && wr_ready) ||
                    (dst == D_WDATA) || (dst == D_WREL) || (dst == D_WTOK) ||
                    (dst == D_WTOKB) || (dst == D_WBUSYW) || (dst == D_WBUSY);

    assign clk_run = cmd_clk || data_clk || clk_free;

    // ------------------------------------------------------------------
    // Register reads

    wire [31:0] status = {blocks_left, 5'd0, dat_in[0], card_detect,
                          err_dbto, err_wcrc, err_dto, err_dcrc,
                          err_bto, err_rcrc, err_rto,
                          dst != D_IDLE, cst != C_IDLE};

    always @(*) begin
        case (addr)
            4'd0: rdata = {21'd0, sample_late, clk_free, bus4, clkdiv};
            4'd1: rdata = arg;
            4'd2: rdata = status;
            4'd3: rdata = {16'd0, blkcnt};
            4'd4: rdata = status;
            4'd5: rdata = resp[31:0];
            4'd6: rdata = resp[63:32];
            4'd7: rdata = resp[95:64];
            4'd8: rdata = resp[127:96];
            default: rdata = 32'd0;
        endcase
    end

endmodule

`default_nettype wire
