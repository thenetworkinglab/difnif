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

    // Writable registers
    localparam REG_CIFR_L = 4'd0;
    localparam REG_CIFR_H = 4'd1;
    localparam REG_BCR = 4'd2;
    localparam REG_ATN = 4'd3;

    // Readable registers
    localparam REG_SIFR_L = 4'd0;
    localparam REG_SIFR_H = 4'd1;
    localparam REG_BSR = 4'd2;
    localparam REG_ISR = 4'd3;

    // Read/write register
    localparam REG_DREG = 4'd4;

    // Unused signals (for now)
    assign cd_chrdy_l = 1'b1;
    assign irq14_l = 1'b1;
    assign arb_o = 4'b1111;
    assign burst_o_l = 1'b1;
    assign preempt_o_l = 1'b1;

    // Registers
    reg [15:0] reg_cifr = 16'h0000;
    reg [7:0] reg_bcr = 8'h00;
    reg [7:0] reg_atn = 8'h00;
    reg [15:0] reg_sifr = 16'hA000;
    wire [7:0] reg_bsr; // Assembled from assign statement
    reg [7:0] reg_isr = 8'h00;
    reg [7:0] reg_dreg = 8'h00;

    // Flags
    reg flag_busy = 1'b0; // FIXME: Should be directly controlled by MCU
    reg flag_ci_full = 1'b0;
    reg flag_si_full = 1'b1; // FIXME: should be 0
    reg flag_int = 1'b0;

    // Control lines
    wire control_reset;
    wire control_dma_enable;
    wire control_int_enable;

    // Basic Status Register
    assign reg_bsr = {1'b0, 1'b0, 1'b0, flag_busy, flag_si_full, flag_ci_full, 1'b0, flag_int};

    // Basic Control Register
    assign control_reset = reg_bcr[7];      // Setting this bit resets the MCU
    assign control_dma_enable = reg_bcr[1]; // Set to allow DMA operation
    assign control_int_enable = reg_bcr[0]; // Set to allow the irq14 line to assert

    /*
     ** Microchannel Interface Implementation below **
    */

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
                REG_CIFR_L  : reg_cifr <= sbhe_l ? {reg_cifr[15:8], bus_d[7:0]} : bus_d;
                REG_CIFR_H  : reg_cifr <= sbhe_l ? reg_cifr : {bus_d[15:8], reg_cifr[7:0]};
                REG_BCR     : reg_bcr  <= bus_d[7:0];
                REG_ATN     : reg_atn  <= bus_d[7:0];
                REG_DREG    : reg_dreg <= bus_d[7:0];
            endcase
        end

        // Flag writes
        if (~s0_w_l & addressed & cd_setup_l) begin
            case (bus_a)
                REG_CIFR_L : flag_ci_full <= 1'b1;
                REG_CIFR_H : flag_ci_full <= 1'b1;
                REG_ATN    : flag_busy <= 1'b1;
            endcase
        end

        if (~s1_r_l & addressed & cd_setup_l) begin
            case (bus_a)
                REG_SIFR_L : flag_si_full <= 1'b0;
                REG_SIFR_H : flag_si_full <= 1'b0;
                REG_ISR    : flag_int <= 1'b0;
            endcase
        end

        // TODO: Implement writeable POS registers
        // TODO: Implement register read and write triggers (mailbox flags)
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
                REG_SIFR_L      : data_out <= la_sbhe_l ? {8'hFF, reg_sifr[7:0]} : reg_sifr;
                // SBHE=0, A0=1: only write bits 15:8
                // SBHE=1, A0=1: invalid
                REG_SIFR_H      : data_out <= la_sbhe_l ? 16'hFFFF : {reg_sifr[15:8], 8'hFF};
                REG_BSR         : data_out <= reg_bsr;
                REG_ISR         : data_out <= reg_isr;
                REG_DREG        : data_out <= reg_dreg;
                default         : data_out <= 16'hFFFF;
            endcase
        end
    end

endmodule
