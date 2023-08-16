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
    input made24,       // Memory address decode enable 24 bits
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

    // Test address latch
//    SB_IO #(
//        .PIN_TYPE(6'b0000_00), // No output, DDR style input
//        .PULLUP(1'b0)
//    ) s0_io_buf (
//        .PACKAGE_PIN(s0_w_l),
//        .INPUT_CLK(cmd_l),
//        .CLOCK_ENABLE(1'b1),
//        .OUTPUT_ENABLE(1'b0),
//        .D_IN_1(test2) // D_IN_1 is the falling edge latched, IN_0 is rising
//    );

    reg [15:0] reg_first = 16'h1234;

    assign cd_chrdy_l = 1'b1;
    assign irq14_l = 1'b1;
    assign arb_o = 4'b1111;
    assign burst_o_l = 1'b1;
    assign preempt_o_l = 1'b1;

    reg [15:0] data_out; //= 16'hABCD;

    wire data_read;
    reg addressed;
    wire addressed_unlatched;

    assign addressed_unlatched = ~addr_sel_l & ~m_io_l & made24;

    assign bus_d = data_dir ? data_out : 16'bZ;
    assign data_read = ~la_rd_l & addressed & la_cd_setup_l; // no card setup! FIXME
    assign data_dir = data_read & ~cmd_l; // Read mode; only when CMD is low.

    // Data bus steering
    // MCA uses signals a0, cd_ds16_l, sbhe_l
    // Drive cd_ds16_l low only for register 0 and 1. This is purely combinational.
    assign cd_ds16_l = ~(cd_setup_l & addressed_unlatched & bus_a[3:1] == 3'b000);


    // Note that POS registers can be 8 bit only, so that's nice.



    reg la_wr_l;
    reg la_rd_l;
    reg la_m_io_l;
    reg la_cd_setup_l;
    reg [3:0] la_addr;
    reg la_addr_sel_l;
    reg [15:0] la_data_in;
    reg la_made24;
    reg la_sbhe_l;

    // Latch a bunch of stuff
    always @ (negedge cmd_l) begin
        la_wr_l <= s0_w_l;
        la_rd_l <= s1_r_l;
        la_m_io_l <= m_io_l;
        la_addr <= bus_a;
        la_made24 <= made24;
        la_addr_sel_l <= addr_sel_l;
        la_data_in <= bus_d; // Note that data out needs to be ready by rising edge of CMD
        la_cd_setup_l <= cd_setup_l;
        la_sbhe_l <= sbhe_l;
        addressed <= addressed_unlatched;

        // Data written to us on this edge
        // SBHE: useful really only when the host writes to us. Only write to the upper byte
        // when this is asserted low.
        if (~s0_w_l & addressed_unlatched & cd_setup_l) begin
            case (bus_a)
                3'b000      : reg_first <= sbhe_l ? {reg_first[15:8], bus_d[7:0]} : bus_d;
                3'b001      : reg_first <= sbhe_l ? reg_first : {bus_d[15:8], reg_first[7:0]};
            endcase
        end
    end

    // Present data at the data output depending on the address
    // FIXME data steering
    always @ (*) begin
        if (la_cd_setup_l == 1'b0) begin
            case (la_addr)
                3'b000    : data_out <= 16'hDF9F;
                default     : data_out <= 16'hFFFF;
            endcase
        end else begin
            case (la_addr)
                // 16-bit read from location 0.
                // SBHE=0, A0=0: write bits 15:0 since upper 8 bits enabled.
                // SBHE=1, A0=0: only write bits 7:0
                3'b000      : data_out <= la_sbhe_l ? {8'hFF, reg_first[7:0]} : reg_first;
                // SBHE=0, A0=1: only write bits 15:8
                // SBHE=1, A0=1: invalid
                3'b001      : data_out <= la_sbhe_l ? 16'hFFFF : {reg_first[15:8], 8'hFF};
                default     : data_out <= 16'hFFFF;
            endcase
        end
    end

endmodule
