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
    output t_atn_read
    );

    localparam REG_TEST = 4'd0;
    localparam REG_FLAGS = 4'd1;
    localparam REG_ATN = 4'd2;

    wire [15:0] tn_d_out;

    wire [15:0] flags;

    reg [15:0] testreg = 16'HABCD;

    // Flag register
    assign flags = {15'H0, t_atn_full};

    // Data outputs
    assign tn_d = tn_rd ? tn_d_out : 16'bZ;
    always @ (*) begin
        case (tn_addr)
            REG_TEST   : tn_d_out <= testreg;
            REG_FLAGS  : tn_d_out <= flags;
            REG_ATN    : tn_d_out <= {8'H0, t_atn};
            default    : tn_d_out <= 16'H0;
        endcase
    end
    //assign tn_d_out = (tn_addr == 4'H0) ? testreg : {12'b0, tn_addr[3:0]};

    // Capture data on rising edge of tn_wr. Figure out clock sync later :blobsweat:
    always @ (posedge tn_wr) begin
        case (tn_addr)
            REG_TEST   : testreg <= tn_d;
        endcase
    end

    // Used to set/clear handshaking flags
    assign t_atn_read = tn_rd & (tn_addr == REG_ATN);

endmodule

