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
    input chreset,


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

    // Unused signals (for now)
    assign cd_chrdy_l = 1'b1;
    assign irq14_l = 1'b1;
    assign arb_o = 4'b1111;
    assign burst_o_l = 1'b1;
    assign preempt_o_l = 1'b1;

    // Registers
    reg [15:0] reg_first = 16'h1234;

    // Only support IO ports. Only respond when not in reset.
    wire addressed;
    assign addressed = ~addr_sel_l & ~m_io_l & ~chreset;

    // Data bus steering
    // MCA uses signals a0, cd_ds16_l, sbhe_l
    // Drive cd_ds16_l low only for register 0/1 (SIFR/CIFR). This is purely combinational.
    // Note that POS registers can be 8 bit only, so that's nice.
    assign cd_ds16_l = ~(cd_setup_l & addressed & bus_a[3:1] == 3'b000);

    // Logic latched on falling edge of CMD
    // Also includes data being written to us.
    reg la_cd_setup_l;
    reg [3:0] la_addr;
    reg [15:0] la_data_in;
    reg la_sbhe_l;
    reg la_data_read;

    // Data input latches
    always @ (negedge cmd_l) begin
        la_addr <= bus_a;
        la_data_in <= bus_d; // Note that data out needs to be ready by rising edge of CMD
        la_cd_setup_l <= cd_setup_l;
        la_sbhe_l <= sbhe_l;

        la_data_read <= ~s1_r_l & addressed & cd_setup_l; // FIXME: remove cd_setup_l

        // Data written to us on this edge
        // SBHE: useful really only when the host writes to us. Only write to the upper byte
        // when this is asserted low.
        if (~s0_w_l & addressed & cd_setup_l) begin
            case (bus_a)
                3'b000      : reg_first <= sbhe_l ? {reg_first[15:8], bus_d[7:0]} : bus_d;
                3'b001      : reg_first <= sbhe_l ? reg_first : {bus_d[15:8], reg_first[7:0]};
            endcase
        end
        // TODO: Implement writeable POS registers
    end

    // Data output: present data at the data output depending on the address
    // This is qualified by the data output gate
    reg [15:0] data_out;
    assign bus_d = data_dir ? data_out : 16'bZ;
    assign data_dir = la_data_read & ~cmd_l; // Read mode; only when CMD is low.

    // Data output mux
    always @ (*) begin
        if (la_cd_setup_l == 1'b0) begin
            case (la_addr)
                3'b000    : data_out <= 16'hDF9F;
                // TODO: Add remaining POS registers
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
                // TODO: Add remaining registers
                default     : data_out <= 16'hFFFF;
            endcase
        end
    end

endmodule
