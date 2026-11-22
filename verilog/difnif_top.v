// DifNif
//
// Copyright (c) 2021 Eric Schlaepfer
// This work is licensed under CERN-OHL-S-2.0.
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
    input addr_sel_in_l,// Card address selected
    input [15:0] bus_a, // Address bus (register select)
    input fulladdr_l,   // When high, only use 4 bits of address
    input sbhe_l,       // With bus_a0, selects 8 or 16 bit transfer
    output cd_ds16_l,   // Assert low to request 16-bit transfer
    output cd_chrdy_l,  // Channel ready (inserts wait states)
    output cd_sfdbk_l,  // Card selected feedback (72-pin only)

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

    // SD card (temporarily used for testing; the card itself in the
    // processor build, DIFNIF_CPU)
    output sd_clk,
`ifdef DIFNIF_CPU
    inout sd_cmd,
    inout [3:0]sd_d,
`else
    output sd_cmd,
    output [3:0]sd_d,
`endif
    input sd_switch,

    // LEDs
    output led0,
    output led1,

    // Teensy
    input tn_rd,
    input tn_wr,
    input [3:0]tn_addr,
    inout [15:0]tn_d,
    output tn_int,
    output tn_clk,
    input tn30
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

    wire [15:0] t_dreg_out;
    wire [15:0] t_dreg_in;
    wire t_treq_set;
    wire t_treq;
    wire t_treq_16;

    wire t_hard_reset;
    wire t_cmd_in_progress;
    wire t_busy_clear;
    wire t_clear_all;

    wire [39:0] t_pos_regs;
    wire [15:0] t_host_diag;

    // Sector buffer (fork)
    wire buf_mode, buf_dir;
    wire burst_en;
    wire isr_gate;
`ifdef DIFNIF_CPU
    wire [2:0] hold_ovr;        // bus release time override (soc.v to mcabus.v)
`endif
    wire t_sifr_clear;
    wire t_buf_wr, t_buf_rd, t_buf_go, t_buf_done;
    wire [15:0] t_buf_wdata, t_buf_rdata;
    wire t_buf_ready, t_buf_can_arm, t_buf_h_idle;
    wire buf_h_ev, buf_h_ready, buf_h_more;
    wire [15:0] buf_h_rdata;
    wire mca_clear_all;

    wire addr_sel_l;
    wire fulladdr2_l;
    wire pr_cmd, pr_gnt;        // processor build's probes (mcabus test outputs)
    wire [3:0] pr_bus;

    // Use pullup on fulladdr_l signal.
    SB_IO #(
        .PIN_TYPE(6'b0000_01),
        .PULLUP(1'b1)
    ) fulladdr_pad (
        .PACKAGE_PIN(fulladdr_l),
        .D_IN_0(fulladdr2_l)
    );

    // Address decoder for 72-pin version: 3510-3517, or 3518-351F when
    // POS 2 bit 1 selects the alternate address. The ThinkPad's system board
    // decodes the address itself and supplies addr_sel_in_l.
    wire alt_addr = t_pos_regs[17];
    assign addr_sel_l = fulladdr2_l ? addr_sel_in_l : ~(bus_a[15:3] == {12'h351, alt_addr});
    wire [3:0] reg_sel = fulladdr2_l ? bus_a[3:0] : {1'b0, bus_a[2:0]};

    // The processor build honours POS 4's bus release time (and the
    // firmware's override); the Teensy build is left exactly as released (a
    // parameter on the instance would rename its cells and move the placement)
`ifdef DIFNIF_CPU
    mcabus #(.PREEMPT_HOLD(1)) mca1 (
`else
    mcabus mca1 (
`endif
        .clk(clk),
        .chreset(chreset),
        .chreset_l(chreset_l),
        .cmd_l(cmd_l),
        .s0_w_l(s0_w_l),
        .s1_r_l(s1_r_l),
        .m_io_l(m_io_l),
        .cd_setup_l(cd_setup_l),
        .addr_sel_l(addr_sel_l),
        .bus_a(reg_sel),
        .sbhe_l(sbhe_l),
        .cd_ds16_l(cd_ds16_l),
        .cd_chrdy_l(cd_chrdy_l),
        .cd_sfdbk_l(cd_sfdbk_l),

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
`ifdef DIFNIF_CPU
        // make CPU=1 PROBES=1: to spare Teensy lines (below); otherwise unused
        .test1(pr_cmd),
        .test2(pr_gnt),
        .tbus(pr_bus),
`else
        .test1(sd_clk), // FIXME testing
        .test2(sd_cmd),
        .tbus(sd_d), // more testing
`endif

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
        .t_sifr_write(t_sifr_write),
        .t_hard_reset(t_hard_reset),
        .t_cmd_in_progress(t_cmd_in_progress),
        .t_busy_clear(t_busy_clear),
        .t_dreg_out(t_dreg_out),
        .t_dreg_in(t_dreg_in),
        .t_treq_set(t_treq_set),
        .t_treq(t_treq),
        .t_treq_16(t_treq_16),
        .t_clear_all(t_clear_all),

        .t_pos_regs(t_pos_regs),
        .t_host_diag(t_host_diag),

        .buf_mode(buf_mode),
        .buf_h_ready(buf_h_ready),
        .buf_h_more(buf_h_more),
        .buf_h_rdata(buf_h_rdata),
        .buf_h_ev(buf_h_ev),
        .clear_all_o(mca_clear_all),
        .burst_en(burst_en),
        .isr_gate(isr_gate),
        .t_sifr_clear(t_sifr_clear)
`ifdef DIFNIF_CPU
        , .hold_ovr(hold_ovr)
`endif
    );

`ifdef DIFNIF_CPU
    // (fork) FPGA-only build: a processor in the Teensy's place (soc.v).
    // Its log goes out on Teensy data line 7 (FPGA pin 25, Teensy pin 16,
    // the Teensy's Serial4 input) and comes in on line 6 (pin 26, Teensy pin
    // 17); the other Teensy lines are left alone.
    wire buf_clear;
    wire [1:0] soc_leds;
    wire sd_clk_w, sd_cmd_out, sd_cmd_oe;
    wire [3:0] sd_dat_out, sd_dat_oe;
    wire uart_tx;
    // The processor starts once the PLL has locked and the SD card's supply
    // has had 2.6 ms to settle (a few clocks in simulation)
`ifdef SYNTHESIS
    localparam POR_BITS = 17;
    wire clk_ok = pll_lock;
`else
    localparam POR_BITS = 4;
    wire clk_ok = 1'b1;
`endif
    reg [POR_BITS-1:0] por = 0;
    reg soc_rst = 1'b1;     // registered: it fans out across the processor
    always @ (posedge clk) begin
        if (!clk_ok) por <= 0;
        else if (~&por) por <= por + 1'b1;
        soc_rst <= ~&por;
    end

    assign sd_clk = sd_clk_w;
    assign sd_cmd = sd_cmd_oe ? sd_cmd_out : 1'bz;
    genvar sdi;
    generate
        for (sdi = 0; sdi < 4; sdi = sdi + 1) begin : sd_lane
            assign sd_d[sdi] = sd_dat_oe[sdi] ? sd_dat_out[sdi] : 1'bz;
        end
    endgenerate
    // The Teensy data lines: line 7 is the log's output, line 6 its input
    // (keys from the serial monitor), the rest inputs nobody reads. Explicit
    // pads, because yosys turns "assign tn_d = 1'bz" into a constant 0 and the
    // pins then drive low, against the Teensy's serial output on line 6.
    // Pull-ups keep line 6 idle (high) when nothing is plugged in.
    //
    // make CPU=1 PROBES=1 (debug only, not for releases) also puts bus
    // signals for a scope on lines the Teensy's teensy_log sketch leaves as
    // inputs, by Teensy pin number: 19 -CMD, 18 ARB/-GNT, 14 a DMA cycle to
    // the card, 15 -PREEMPT on the bus, 22 the card wants the bus or has the
    // next word, 23 the card drives -PREEMPT, 20 the card drives -BURST (high
    // = bursting). Don't run any other Teensy sketch with that image.
    wire [15:0] tn_din;
`ifdef DIFNIF_PROBES
    localparam [15:0] TN_OE = 16'h078F;
    wire [15:0] tn_out = {5'd0, ~burst_o_l, pr_bus[1], pr_bus[3], uart_tx, 3'd0,
                          pr_bus[0], pr_bus[2], pr_gnt, pr_cmd};
`else
    localparam [15:0] TN_OE = 16'h0080;
    wire [15:0] tn_out = {8'd0, uart_tx, 7'd0};
`endif
    genvar tni;
    generate
        for (tni = 0; tni < 16; tni = tni + 1) begin : tn_pad
            SB_IO #(
                .PIN_TYPE(6'b1010_01),          // tristate output, plain input
                .PULLUP(TN_OE[tni] ? 1'b0 : 1'b1)
            ) pad (
                .PACKAGE_PIN(tn_d[tni]),
                .OUTPUT_ENABLE(TN_OE[tni]),
                .D_OUT_0(tn_out[tni]),
                .D_IN_0(tn_din[tni])
            );
        end
    endgenerate
    assign tn_int = 1'b0;

    soc cpu1 (
        .clk(clk),
        .rst(soc_rst),
        .uart_tx(uart_tx),
        .uart_rx(tn_din[6]),
        .leds(soc_leds),
        .sd_clk(sd_clk_w),
        .sd_cmd_in(sd_cmd),
        .sd_cmd_out(sd_cmd_out),
        .sd_cmd_oe(sd_cmd_oe),
        .sd_dat_in(sd_d),
        .sd_dat_out(sd_dat_out),
        .sd_dat_oe(sd_dat_oe),
        .sd_detect(sd_switch),
        .buf_clear(buf_clear),
        .buf_h_ev(buf_h_ev),
        .buf_h_rdata(buf_h_rdata),
        .hold_ovr(hold_ovr),
`else
    wire buf_clear = 1'b0;

    teensy tn1 (
        .tn_rd(tn_rd),
        .tn_wr(tn_wr),
        .tn_addr(tn_addr),
        .tn_d(tn_d),
        .tn_int(tn_int),
        .clk(clk),
        .tn30(tn30),
`endif

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
        .t_sifr_write(t_sifr_write),
        .t_hard_reset(t_hard_reset),
        .t_cmd_in_progress(t_cmd_in_progress),
        .t_busy_clear(t_busy_clear),
        .t_dreg_out(t_dreg_out),
        .t_dreg_in(t_dreg_in),
        .t_treq_set(t_treq_set),
        .t_treq(t_treq),
        .t_treq_16(t_treq_16),
        .t_clear_all(t_clear_all),

        .t_pos_regs(t_pos_regs),
        .t_host_diag(t_host_diag),

        .buf_mode(buf_mode),
        .buf_dir(buf_dir),
        .burst_en(burst_en),
        .isr_gate(isr_gate),
        .t_sifr_clear(t_sifr_clear),
        .t_buf_wr(t_buf_wr),
        .t_buf_wdata(t_buf_wdata),
        .t_buf_rd(t_buf_rd),
        .t_buf_go(t_buf_go),
        .t_buf_done(t_buf_done),
        .t_buf_rdata(t_buf_rdata),
        .t_buf_ready(t_buf_ready),
        .t_buf_can_arm(t_buf_can_arm),
        .t_buf_h_idle(t_buf_h_idle)
    );

    sectorbuf sb1 (
        .clk(clk),
        .clear(mca_clear_all | ~buf_mode | buf_clear),
        .dir(buf_dir),
        .t_wr(t_buf_wr),
        .t_wdata(t_buf_wdata),
        .t_rd(t_buf_rd),
        .t_rdata(t_buf_rdata),
        .t_go(t_buf_go),
        .t_done(t_buf_done),
        .t_ready(t_buf_ready),
        .t_can_arm(t_buf_can_arm),
        .h_idle(t_buf_h_idle),
        .h_ev(buf_h_ev),
        .h_wdata(t_dreg_out),
        .h_rdata(buf_h_rdata),
        .h_ready(buf_h_ready),
        .h_more(buf_h_more)
    );
    // 50MHz
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

    assign tn_clk = 1'b0; // No clock for now
    //assign tn_clk = clk; // Clock to Teensy in case I want to make a synchronous interface

//    assign led0 = counter[22];
`ifdef DIFNIF_CPU
    assign led0 = soc_leds[0];
    assign led1 = soc_leds[1];
`else
    assign led0 = fulladdr2_l;
    assign led1 = counter[21];
`endif

    always @ (posedge clk)
    begin
        counter <= counter + 1;
    end

endmodule
