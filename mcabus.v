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
    output preempt_o_l, // DMA preempt request output

    output test1,
    output test2,

    // Wiring from Teensy
    output [7:0] t_atn,   // Attention data to Teensy
    output t_atn_full,    // So Teensy can tell when host writes it
    input t_atn_read,     // So we can clear flag when Teensy reads it

    input [7:0] t_isr_out, // Interrupt byte from Teensy
    output t_isr_full,     // So Teensy can tell when host reads it
    input t_isr_write,     // So we can set flag when Teensy writes it

    output [15:0] t_cifr, // Command iface data to Teensy
    output t_cifr_full,   // So Teensy can tell when host writes it
    input t_cifr_read,    // So we can clear flag when Teensy reads it

    input [15:0] t_sifr_out, // Status iface data from Teensy
    output t_sifr_full,      // So Teensy can tell when host reads it
    input t_sifr_write,      // So we can set flag when Teensy writes it

    // Flags
    output t_hard_reset,
    input t_cmd_in_progress,
    input t_busy
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
    assign arb_o = 4'b1111;
    assign burst_o_l = 1'b1;
    assign preempt_o_l = 1'b1;

    // Registers
    reg [15:0] reg_cifr = 16'h0000;
    reg [7:0] reg_atn = 8'h00;

    // Interrupt request line
    assign irq14_l = !(flag_isr & control_int_enable);

    assign t_atn = reg_atn;
    assign t_cifr = reg_cifr;

    // FIXME: data register should be 16 bit (and do data steering)
    reg [7:0] reg_dreg = 8'h00;

    // Flags
    reg flag_atn = 1'b0;
    reg flag_ci_full = 1'b0;
    reg flag_si_full = 1'b0;
    reg flag_isr = 1'b0;

    // Outputs to Teensy
    assign t_atn_full = flag_atn;
    assign t_isr_full = flag_isr;
    assign t_cifr_full = flag_ci_full;
    assign t_sifr_full = flag_si_full;

    /*
     ** Registers and handshaking interface **
    */

    // ATN register full
// FIXME: which gets priority? Right now I have the ATN code written twice.
// This sort of implies that the MCA bus transaction is long enough that the bit gets set, cleared, then set again.
    wire flag_atn_set = la_mca_op & ~la_s0_w_l & (la_addr == REG_ATN);
    reg [1:0] reg_atn_set;

    always @ (posedge clk) begin
        reg_atn_set = {reg_atn_set[0], flag_atn_set};
    end

    always @ (posedge clk) begin
        if ((reg_atn_set == 2'b01) || t_atn_read) begin
            flag_atn = t_atn_read ? 1'b0 : 1'b1;
        end
    end

    // Command Interface Register Full
    wire flag_ci_full_set = la_mca_op & ~la_s0_w_l & (la_addr == REG_CIFR_L);
    reg [1:0] reg_ci_full_set;

    always @ (posedge clk) begin
        reg_ci_full_set = {reg_ci_full_set[0], flag_ci_full_set};
    end

    always @ (posedge clk) begin
        if ((reg_ci_full_set == 2'b01) || t_cifr_read) begin
            flag_ci_full <= t_cifr_read ? 1'b0 : 1'b1;
        end
    end

    // ISR register full
    wire flag_isr_clear = la_mca_op & ~la_s1_r_l & (la_addr == REG_ISR);
    reg [1:0] reg_isr_clear;

    always @ (posedge clk) begin
        reg_isr_clear = {reg_isr_clear[0], flag_isr_clear};
    end

    always @ (posedge clk) begin
        if ((reg_isr_clear == 2'b10) || t_isr_write) begin
            flag_isr <= t_isr_write ? 1'b1 : 1'b0;
        end
    end

    // Status Interface Register Full
    wire flag_sifr_clear = la_mca_op & ~la_s1_r_l & (la_addr == REG_SIFR_L);
    reg [1:0] reg_sifr_clear;
    reg [1:0] reg_t_sifr_write;

    always @ (posedge clk) begin
        reg_sifr_clear = {reg_sifr_clear[0], flag_sifr_clear};
        reg_t_sifr_write = {reg_t_sifr_write[0], t_sifr_write};
    end
    // Clear register at end of MCA transaction
    // Set register when Teensy latches new value
    always @ (posedge clk) begin
        if ((reg_sifr_clear == 2'b10) || (reg_t_sifr_write == 2'b01)) begin
            flag_si_full <= (reg_t_sifr_write == 2'b01) ? 1'b1 : 1'b0;
        end
    end

    /*
     ** Microchannel status registers **
    */

    wire [7:0] reg_bsr; // Assembled from assign statement
    reg [7:0] reg_bcr = 8'h00;

    // Control lines
    wire control_dma_enable;
    wire control_int_enable;


    // Basic Status Register
    assign reg_bsr = {control_dma_enable, flag_isr, t_cmd_in_progress, t_busy,
                      flag_si_full, flag_ci_full, 1'b0, flag_isr & control_int_enable};

    // Basic Control Register
    assign t_hard_reset = reg_bcr[7];      // Setting this bit resets the MCU
    // TODO: Make it so completing a DMA transfer
    // auto-clears the DMA enable
    assign control_dma_enable = reg_bcr[1]; // Set to allow DMA operation
    assign control_int_enable = reg_bcr[0]; // Set to en irq14 line to assert



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

    reg la_mca_op;
    reg la_s0_w_l;
    reg la_s1_r_l;

    // Data input latches
    always @ (negedge cmd_l) begin
        la_addr <= bus_a;
        la_data_in <= bus_d; // Note that data out needs to be ready by rising edge of CMD
        la_cd_setup_l <= cd_setup_l;
        la_sbhe_l <= sbhe_l;
        la_s0_w_l <= s0_w_l;
        la_s1_r_l <= s1_r_l;

        la_mca_op <= addressed & cd_setup_l;
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
                REG_SIFR_L      : data_out <= la_sbhe_l ? {8'hFF, t_sifr_out[7:0]} : t_sifr_out;
                // SBHE=0, A0=1: only write bits 15:8
                // SBHE=1, A0=1: invalid
                REG_SIFR_H      : data_out <= la_sbhe_l ? 16'hFFFF : {t_sifr_out[15:8], 8'hFF};
                REG_BSR         : data_out <= reg_bsr;
                REG_ISR         : data_out <= t_isr_out;
                REG_DREG        : data_out <= reg_dreg;
                default         : data_out <= 16'hFFFF;
            endcase
        end
    end

endmodule
