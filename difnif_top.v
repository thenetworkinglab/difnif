// icetest
//
// Copyright (c) 2021 Eric Schlaepfer
// This work is licensed under the Creative Commons Attribution-ShareAlike 4.0
// International License. To view a copy of this license, visit
// http://creativecommons.org/licenses/by-sa/4.0/ or send a letter to Creative
// Commons, PO Box 1866, Mountain View, CA 94042, USA.
//
`default_nettype none
module difnif_top(
    // Clocks
    input clk_10m,

    // Bus reset
    input chreset_l,

    // LEDs
    output led0,
    output led1
    );

    reg[22:0] counter;
    wire pll_lock;
    wire clk;

    `ifdef SYNTHESIS
    SB_PLL40_PAD #(
        .FEEDBACK_PATH("SIMPLE"),
        .DIVR(0),
        .DIVF(79),
        .DIVQ(4),
        .FILTER_RANGE(1)
    ) icetest_pll (
        .LOCK(pll_lock),
        .RESETB(1'b1),
        .BYPASS(1'b0),
        .PACKAGEPIN(clk_10m),
        .PLLOUTGLOBAL(clk)
    );
    `else
    assign clk = clk_10m;
    `endif

    assign led0 = counter[22];
    assign led1 = counter[21];

    always @ (posedge clk)
    begin
        counter <= counter + 1;
    end

endmodule
