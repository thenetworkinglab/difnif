// DifNif
//
// Copyright (c) 2021 Eric Schlaepfer
// This work is licensed under the Creative Commons Attribution-ShareAlike 4.0
// International License. To view a copy of this license, visit
// http://creativecommons.org/licenses/by-sa/4.0/ or send a letter to Creative
// Commons, PO Box 1866, Mountain View, CA 94042, USA.
//

`default_nettype none
module teensy(
    // External connections to Teensy
    input tn_rd,
    input tn_wr,
    input [3:0]tn_addr,
    inout [15:0]tn_d,
    input tn29,
    input tn30,
    input tn35,

    // Connections to MCA interface
    input [7:0] t_atn,
    input t_atn_full,
    output t_atn_read,

    output [7:0] t_isr_out,
    input t_isr_full,
    output t_isr_write,

    input [15:0] t_cifr,
    input t_cifr_full,
    output t_cifr_read,

    output [15:0] t_sifr_out,
    input t_sifr_full,
    output t_sifr_write
    );

    localparam REG_TEST = 4'd0;
    localparam REG_FLAGS = 4'd1;
    localparam REG_ATN = 4'd2;
    localparam REG_ISR = 4'd3;
    localparam REG_CIFR = 4'd4;
    localparam REG_SIFR = 4'd5;

    wire [15:0] tn_d_out;

    wire [15:0] flags;

    reg [15:0] testreg = 16'HABCD;

    reg [7:0] t_isr;
    reg [15:0] t_sifr;

    assign t_isr_out = t_isr;
    assign t_sifr_out = t_sifr;

    // Flag register
    assign flags = {12'H0,
                    t_sifr_full, t_cifr_full,
                    t_isr_full, t_atn_full};

    // Data outputs
    assign tn_d = tn_rd ? tn_d_out : 16'bZ;
    always @ (*) begin
        case (tn_addr)
            REG_TEST   : tn_d_out <= testreg;
            REG_FLAGS  : tn_d_out <= flags;
            REG_ATN    : tn_d_out <= {8'H0, t_atn};
            REG_ISR    : tn_d_out <= {8'H0, t_isr};
            REG_SIFR   : tn_d_out <= t_sifr;
            REG_CIFR   : tn_d_out <= t_cifr;
            default    : tn_d_out <= 16'H0;
        endcase
    end

    // Capture data on rising edge of tn_wr
    always @ (posedge tn_wr) begin
        case (tn_addr)
            REG_TEST   : testreg <= tn_d;
            REG_ISR    : t_isr <= tn_d;
            REG_SIFR   : t_sifr <= tn_d;
        endcase
    end

    // Used to set/clear handshaking flags
    assign t_atn_read = tn_rd & (tn_addr == REG_ATN);
    assign t_isr_write = tn_wr & (tn_addr == REG_ISR);
    assign t_cifr_read = tn_rd & (tn_addr == REG_CIFR);
    assign t_sifr_write = tn_wr & (tn_addr == REG_SIFR);

endmodule

