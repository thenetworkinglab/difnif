// DifNif
//
// Copyright (c) 2021 Eric Schlaepfer
// This work is licensed under CERN-OHL-S-2.0.
//

`default_nettype none
`include "version.vh"

module teensy(
    // External connections to Teensy
    input tn_rd,
    input tn_wr,
    input [3:0]tn_addr,
    inout [15:0]tn_d,
    output tn_int,
    input clk,
    input tn30,

    // Connections to MCA interface
    // ATN register
    input [7:0] t_atn,
    input t_atn_full,
    output t_atn_read,

    // ISR register
    output [7:0] t_isr_out,
    input t_isr_full,
    output t_isr_write,

    // CIFR register
    input [15:0] t_cifr,
    input t_cifr_full,
    output t_cifr_read,

    // SIFR register
    output [15:0] t_sifr_out,
    input t_sifr_full,
    output t_sifr_write,

    // Flags
    input t_hard_reset,
    output t_cmd_in_progress,
    output t_busy_clear,
    output t_clear_all,

    // Data register
    input [15:0] t_dreg_out,
    output [15:0] t_dreg_in,
    output t_treq_set,
    input t_treq,
    input t_treq_16,

    input [39:0] t_pos_regs,
    input [15:0] t_host_diag,   // (fork) register 15 bits 15-3

    // Sector buffer (sectorbuf.v), all on clk
    output buf_mode,            // flag bit 11: buffer on
    output buf_dir,             // flag bit 12: 0 disk read, 1 disk write
    output burst_en,            // register 15 bit 0: burst DMA allowed (fork)
    output isr_gate,            // register 15 bit 2: no DMA requests while an interrupt is pending (fork)
    output t_sifr_clear,        // register 15 bit 1 written as 1: drop unread status (fork)
    output reg t_buf_wr = 1'b0,     // one-clock pulses
    output reg [15:0] t_buf_wdata = 16'h0000,
    output reg t_buf_rd = 1'b0,
    output reg t_buf_go = 1'b0,     // flag bit 13 written as 1
    output reg t_buf_done = 1'b0,   // flag bit 14 written as 1
    input [15:0] t_buf_rdata,
    input t_buf_ready,
    input t_buf_can_arm,
    input t_buf_h_idle
    );

    localparam REG_TEST = 4'd0;
    localparam REG_FLAGS = 4'd1;
    localparam REG_ATN = 4'd2;
    localparam REG_ISR = 4'd3;
    localparam REG_CIFR = 4'd4;
    localparam REG_SIFR = 4'd5;
    localparam REG_DREG = 4'd6;
    localparam REG_POS01 = 4'd7;
    localparam REG_POS23 = 4'd8;
    localparam REG_POS4 = 4'd9;
    // Read-only version registers (version.vh, BCD), and which build this is
    localparam REG_BUF = 4'd14;     // sector buffer data (fork)
    localparam REG_CTRL = 4'd15;    // bit 0: burst DMA allowed; bit 1 (write 1): drop unread status (fork)
    localparam REG_VER_YEAR = 4'd10;
    localparam REG_VER_DATE = 4'd11;
    localparam REG_VER_COUNT = 4'd12;
    localparam REG_VARIANT = 4'd13;
`ifdef MCA_USE_POS
    localparam [15:0] VARIANT = 16'h0001;   // make BOARD=ps2: POS registers on
`else
    localparam [15:0] VARIANT = 16'h0000;   // make (ThinkPad): POS bypassed
`endif

    reg [15:0] tn_d_out;

    wire [15:0] flags_out;
    reg [15:0] flags_in = 16'H0000;

    reg [15:0] testreg = 16'HABCD;
    reg ctrl_in = 1'b0;             // register 15 bit 0 (fork)
    reg gate_in = 1'b0;             // register 15 bit 2 (fork)

    reg [7:0] t_isr;
    reg [15:0] t_sifr;
    reg [15:0] t_dreg;

    assign t_isr_out = t_isr;
    assign t_sifr_out = t_sifr;
    assign t_dreg_in = t_dreg;

    // Interrupt output
    assign tn_int = t_atn_full; // TODO: make this more complex

    wire t_busy_bit;

    // Flag register. Bits 11-15 are the sector buffer's (fork), and read 0
    // while it's off.
    wire [4:0] buf_flags = buf_mode ? {t_buf_h_idle, t_buf_can_arm, t_buf_ready, buf_dir, 1'b1}
                                    : 5'h00;
    assign flags_out = {buf_flags, t_clear_all,
                        t_treq_16, t_treq,
                        1'b1, t_cmd_in_progress, // Clear busy is active low
                        1'b0, t_hard_reset,
                        t_sifr_full, t_cifr_full,
                        t_isr_full, t_atn_full};

    // These bits in the flag reg are r/w
    assign t_cmd_in_progress = flags_in[6];
    assign t_clear_all = flags_in[10]; // ATN, BUSY, CI FULL, ISR, SI FULL, TREQ, TREQ_16
    // Note: Does not clear CmdInProgress

    // Clears the busy flag when bit is written to a '0'
    assign t_busy_clear = tn_wr & (tn_addr == REG_FLAGS) & ~tn_d[7];

    // Sets the transfer request flag when bit is written to a '1'
    assign t_treq_set = tn_wr & (tn_addr == REG_FLAGS) & tn_d[5];

    // (fork) Clears "status interface full" when register 15 is written with
    // bit 1 set: the host ended the command (EOI) without reading the rest
    // of the status block, which IBM allows, and the status mustn't still
    // show as waiting at the next command. Register 15 rather than a flag
    // bit, because Eric's firmware writes back the flag bits it reads.
    assign t_sifr_clear = tn_wr & (tn_addr == REG_CTRL) & tn_d[1];

    // Data outputs
    assign tn_d = tn_rd ? tn_d_out : 16'bZ;
    always @ (*) begin
        case (tn_addr)
            REG_TEST   : tn_d_out <= testreg;
            REG_FLAGS  : tn_d_out <= flags_out;
            REG_ATN    : tn_d_out <= {8'H0, t_atn};
            REG_ISR    : tn_d_out <= {8'H0, t_isr};
            REG_SIFR   : tn_d_out <= t_sifr;
            REG_CIFR   : tn_d_out <= t_cifr;
            REG_DREG   : tn_d_out <= t_dreg_out;
            REG_POS01  : tn_d_out <= t_pos_regs[15:0];
            REG_POS23  : tn_d_out <= t_pos_regs[31:16];
            REG_POS4   : tn_d_out <= t_pos_regs[39:32];
            REG_VER_YEAR  : tn_d_out <= `FPGA_VERSION_YEAR;
            REG_VER_DATE  : tn_d_out <= `FPGA_VERSION_DATE;
            REG_VER_COUNT : tn_d_out <= `FPGA_VERSION_COUNT;
            REG_VARIANT   : tn_d_out <= VARIANT;
            REG_BUF       : tn_d_out <= t_buf_rdata;
            REG_CTRL      : tn_d_out <= {t_host_diag[15:3], gate_in, t_host_diag[1], ctrl_in};
            default    : tn_d_out <= 16'H0;
        endcase
    end

    // Capture data on rising edge of tn_wr
    always @ (posedge tn_wr) begin
        case (tn_addr)
            REG_TEST   : testreg <= tn_d;
            REG_FLAGS  : flags_in <= tn_d;
            REG_ISR    : t_isr <= tn_d;
            REG_SIFR   : t_sifr <= tn_d;
            REG_DREG   : t_dreg <= tn_d;
            REG_CTRL   : begin
                ctrl_in <= tn_d[0];
                gate_in <= tn_d[2];
            end
        endcase
    end

    // Control register (fork): bit 0 allows burst DMA
    reg [1:0] burst_s = 2'b00;
    reg [1:0] gate_s = 2'b00;
    always @ (posedge clk) begin
        burst_s <= {burst_s[0], ctrl_in};
        gate_s <= {gate_s[0], gate_in};
    end
    assign burst_en = burst_s[1];
    assign isr_gate = gate_s[1];

    // Sector buffer access (fork). RD and WR are sampled on the 50 MHz
    // clock. A write is taken when WR is seen high, 20-60 ns after it rises,
    // while the Teensy still holds the address and data (its strobe is 80 ns
    // or more). A read moves the buffer on when RD falls; the next word is
    // ready about 100 ns later. WR and RD must stay low for 40 ns or more
    // between buffer accesses.
    reg [2:0] wr_s = 3'b000;
    reg [2:0] rd_s = 3'b000;
    reg [3:0] rd_addr = 4'h0;
    reg [1:0] mode_s = 2'b00;
    reg [1:0] dir_s = 2'b00;
    wire wr_rise = wr_s[1] & ~wr_s[2];
    wire rd_rise = rd_s[1] & ~rd_s[2];
    wire rd_fall = ~rd_s[1] & rd_s[2];

    always @ (posedge clk) begin
        wr_s <= {wr_s[1:0], tn_wr};
        rd_s <= {rd_s[1:0], tn_rd};
        mode_s <= {mode_s[0], flags_in[11]};
        dir_s <= {dir_s[0], flags_in[12]};

        t_buf_wr <= wr_rise & (tn_addr == REG_BUF);
        t_buf_go <= wr_rise & (tn_addr == REG_FLAGS) & tn_d[13];
        t_buf_done <= wr_rise & (tn_addr == REG_FLAGS) & tn_d[14];
        if (wr_rise) t_buf_wdata <= tn_d;
        if (rd_rise) rd_addr <= tn_addr;
        t_buf_rd <= rd_fall & (rd_addr == REG_BUF);
    end

    assign buf_mode = mode_s[1];
    assign buf_dir = dir_s[1];

    // Used to set/clear handshaking flags
    assign t_atn_read = tn_rd & (tn_addr == REG_ATN);
    assign t_isr_write = tn_wr & (tn_addr == REG_ISR);
    assign t_cifr_read = tn_rd & (tn_addr == REG_CIFR);
    assign t_sifr_write = tn_wr & (tn_addr == REG_SIFR);

endmodule

