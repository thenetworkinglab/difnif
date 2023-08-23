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
    input tn_rd,
    input tn_wr,
    input [3:0]tn_addr,
    inout [15:0]tn_d,
    input tn29,
    input tn30,
    input tn35
    );

    wire [15:0] tn_d_out;

    // Data outputs
    assign tn_d = tn_rd ? tn_d_out : 16'bZ;

    assign tn_d_out = {12'b0, tn_addr[3:0]};

endmodule

