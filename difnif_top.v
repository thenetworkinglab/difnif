// DifNif
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

    // Unknown, FIXME better name
    input chreset_l,

    // Bus reset
    input chreset,

    // Micro Channel bus
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
    output data_dir,    // Data bus buffer direction control

    output irq14_l,     // Interrupt line

    input arb_gnt_l,    // DMA arbitration/grant mode
    input tc_l,         // DMA terminate count
    input [3:0]arb,     // DMA arbitration bus inputs
    input burst_l,      // DMA burst request input
    input preempt_l,    // DMA preempt request input
    output [3:0]arb_o,  // DMA arbitration control line outputs
    output burst_o_l,   // DMA burst request output
    output preempt_o_l, // DMA preempt request output

    // SD card (temporarily used for testing)
    output sd_clk,
    output sd_cmd,
    input sd_d0,
    input sd_d1,
    input sd_d2,
    input sd_d3,
    input sd_switch,

    // LEDs
    output led0,
    output led1,

    // Teensy
    input tn_rd,
    input tn_wr,
    input [3:0]tn_addr,
    inout [15:0]tn_d,
    input tn29,
    input tn30,
    input tn35
    );

    reg[22:0] counter;
    wire pll_lock;
    wire clk;

    // Teensy registers and controls
    wire [7:0] t_atn;
    wire t_atn_full;
    wire t_atn_read;
    wire [7:0] t_isr_out;
    wire t_isr_full;
    wire t_isr_write;
    wire [15:0] t_cifr;
    wire t_cifr_full;
    wire t_cifr_read;
    wire [15:0] t_sifr_out;
    wire t_sifr_full;
    wire t_sifr_write;

    mcabus mca1 (
        .clk(clk),
        .chreset(chreset),
        .chreset_l(chreset_l),
        .cmd_l(cmd_l),
        .s0_w_l(s0_w_l),
        .s1_r_l(s1_r_l),
        .m_io_l(m_io_l),
        .cd_setup_l(cd_setup_l),
        .addr_sel_l(addr_sel_l),
        .bus_a(bus_a[3:0]),
        .sbhe_l(sbhe_l),
        .cd_ds16_l(cd_ds16_l),
        .cd_chrdy_l(cd_chrdy_l),

        .bus_d(bus_d),
        .data_dir(data_dir),

        .irq14_l(irq14_l),

        .arb_gnt_l(arb_gnt_l),
        .tc_l(tc_l),
        .arb(arb),
        .burst_l(burst_l),
        .preempt_l(preempt_l),
        .arb_o(arb_o),
        .burst_o_l(burst_o_l),
        .preempt_o_l(preempt_o_l),
        .test1(sd_clk), // FIXME testing
        .test2(sd_cmd),

        // Teensy connections
        .t_atn(t_atn),
        .t_atn_full(t_atn_full),
        .t_atn_read(t_atn_read),
        .t_isr_out(t_isr_out),
        .t_isr_full(t_isr_full),
        .t_isr_write(t_isr_write),
        .t_cifr(t_cifr),
        .t_cifr_full(t_cifr_full),
        .t_cifr_read(t_cifr_read),
        .t_sifr_out(t_sifr_out),
        .t_sifr_full(t_sifr_full),
        .t_sifr_write(t_sifr_write)
    );

    teensy tn1 (
        .tn_rd(tn_rd),
        .tn_wr(tn_wr),
        .tn_addr(tn_addr),
        .tn_d(tn_d),
        .tn29(tn29),
        .tn30(tn30),
        .tn35(tn35),

        // Register interface
        .t_atn(t_atn),
        .t_atn_full(t_atn_full),
        .t_atn_read(t_atn_read),
        .t_isr_out(t_isr_out),
        .t_isr_full(t_isr_full),
        .t_isr_write(t_isr_write),
        .t_cifr(t_cifr),
        .t_cifr_full(t_cifr_full),
        .t_cifr_read(t_cifr_read),
        .t_sifr_out(t_sifr_out),
        .t_sifr_full(t_sifr_full),
        .t_sifr_write(t_sifr_write)
    );

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
