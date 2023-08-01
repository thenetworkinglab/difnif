// DifNif
//
// Copyright (c) 2021 Eric Schlaepfer
// This work is licensed under the Creative Commons Attribution-ShareAlike 4.0
// International License. To view a copy of this license, visit
// http://creativecommons.org/licenses/by-sa/4.0/ or send a letter to Creative
// Commons, PO Box 1866, Mountain View, CA 94042, USA.
//

`default_nettype none
module mcabus(
    input clk,
    input chreset_l,

    input cmd_l,        // Command clock
    input s0_w_l,       // S0 aka write#
    input s1_r_l,       // S1 aka read#
    input m_io_l,       // memory / IO# transfer
    input cd_setup_l,   // Card setup mode
    input addr_sel_l,   // Card address selected
    input [3:0] bus_a,  // Truncated address bus (register select)
    input sbhe_l,       // With bus_a0, selects 8 or 16 bit transfer
    output cd_ds16_l,   // Assert low to request 16-bit transfer
    output cd_chrdy_l,  // Channel ready (inserts wait states)

    inout[15:0]bus_d,   // Bidirectional data bus
    output data_dir,    // Data bus buffer direction control. 0=in, 1=out

    output irq14_l,     // Interrupt line

    input arb_gnt_l,    // DMA arbitration/grant mode
    input tc_l,         // DMA terminate count
    input [3:0]arb,     // DMA arbitration bus inputs
    input burst_l,      // DMA burst request input
    input preempt_l,    // DMA preempt request input
    output [3:0]arb_o,  // DMA arbitration control line outputs
    output burst_o_l,   // DMA burst request output
    output preempt_o_l,  // DMA preempt request output

    output test1,
    output test2
    );

    wire test;

    assign cd_ds16_l = 1'b1; // FIXME
    assign cd_chrdy_l = 1'b1;
    assign data_dir = data_read; // Read mode
    assign irq14_l = 1'b1;
    assign arb_o = 4'b1111;
    assign burst_o_l = 1'b1;
    assign preempt_o_l = 1'b1;

    wire [15:0] data_out = 16'hABCD;

    assign bus_d = data_dir ? data_out : 16'bZ;

    wire data_read = ~la_rd_l; // FIXME, should only do this if addr decodes

    reg cmdh;
    wire cmd_rising;
    wire cmd_falling;

    reg sy_wr_l;
    reg sy_rd_l;
    reg sy_m_io_l;
    reg [3:0] sy_addr;

    reg la_wr_l;
    reg la_rd_l;
    reg la_m_io_l;
    reg [3:0] la_addr;

    reg [15:0] la_data_in;
    reg [15:0] sy_data_in;

    // Sync up CMD
    always @ (posedge clk)
    begin
        cmdh <= cmd_l;
    end

    assign cmd_rising = {cmdh, cmd_l} == 2'b01;
    assign cmd_falling = {cmdh, cmd_l} == 2'b10;

    assign test1 = cmd_rising;
    assign test2 = cmd_falling;

    // Handle latching control signals
    always @ (posedge clk)
    begin
            sy_wr_l <= s0_w_l;
            sy_rd_l <= s1_r_l;
            sy_m_io_l <= m_io_l;
            sy_addr <= bus_a;
            sy_data_in <= bus_d;
    end

    // Handle CMD rising and falling states
    always @ (posedge clk)
    begin
        if (cmd_falling) begin
            la_wr_l <= sy_wr_l;
            la_rd_l <= sy_rd_l;
            la_m_io_l <= sy_m_io_l;
            la_addr <= sy_addr;
        end
        if (cmd_rising) begin
            la_data_in <= sy_data_in;
        end
    end

endmodule
