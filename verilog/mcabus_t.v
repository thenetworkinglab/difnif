`timescale 1ns / 1ps

// TODO:
// Unscramble bus cycles so I don't have to think about
// which address has to go with which transaction.
// Use logic analyzer to get more accurate values
// for bus delays. Do it for both the 50Z and the 95.

//
// SB MCA CPLD - Test bench for main module
// Copyright (c) 2020 Eric Schlaepfer
// This work is licensed under the Creative Commons Attribution-ShareAlike 4.0
// International License. To view a copy of this license, visit
// http://creativecommons.org/licenses/by-sa/4.0/ or send a letter to Creative
// Commons, PO Box 1866, Mountain View, CA 94042, USA.
//
module mcabus_t;

    // Inputs to module under test
    reg cd_setup_l;
    reg chreset;
    reg chreset_l;
    reg clk;
    reg cmd_l;
    reg m_io_l;
    reg s0_w_l;
    reg s1_r_l;
    reg [23:0] bus_a;
    wire addr_sel_l;
    reg sbhe_l;
    reg adl_l; // Not used for DBA-ESDI

    reg irq_in;

    reg arb_gnt_l;
    wire tc_l;

    // Outputs
    wire cd_chrdy_l;
    wire irq14_l;

    wire cden;
    wire bufen_l;
    wire bufdir;

    wire dack_l;

    // Bidirs
    wire [15:0] bus_d;
    wire [15:0] d_in; // Input sense
    reg [15:0] d_out; // Output drive
    reg d_valid;     // Direction control

    reg preempt_driver;
    reg burst_driver;
    wire preempt_l;
    wire burst_l;
    wire preempt_o_l;
    wire burst_o_l;
    wire [3:0] arb;
    wire [3:0] arb_o;

    reg [3:0] arbdriver;

    wire cd_ds16_l;
    wire data_dir; // FIXME use this to check for conflicts

    reg t_atn_read;
    reg t_isr_write;
    reg [7:0] t_isr_out;
    reg t_cifr_read;
    reg [15:0] t_sifr_out;
    reg t_sifr_write;

    reg t_cmd_in_progress;
    reg t_busy_clear;

    wire [15:0] t_dreg_out;
    reg [15:0] t_dreg_in;
    reg t_treq_set;
    wire t_treq;
    wire t_treq_16;

    reg t_clear_all;

    reg test3;

    // Instantiate the Unit Under Test (UUT)
    mcabus uut (
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

        .t_atn_read(t_atn_read),
        .t_isr_out(t_isr_out),
        .t_isr_write(t_isr_write),
        .t_cifr_read(t_cifr_read),
        .t_sifr_out(t_sifr_out),
        .t_sifr_write(t_sifr_write),
        .t_cmd_in_progress(t_cmd_in_progress),
        .t_busy_clear(t_busy_clear),

        .t_dreg_out(t_dreg_out),
        .t_dreg_in(t_dreg_in),
        .t_treq_set(t_treq_set),
        .t_treq(t_treq),
        .t_treq_16(t_treq_16),
        .t_clear_all(t_clear_all),

        .test3(test3)
    );

    // DBA-ESDI address decode
    assign addr_sel_l = ~((cd_setup_l & (bus_a[23:4] == 20'h00351)) |
                          (~cd_setup_l & (bus_a[23:4] == 20'h00010)));

    // Output data bus buffer
    // TODO: Add data steering ?
    assign d_in = bus_d;
    assign bus_d = (d_valid) ? d_out : 16'bZ;

    // DMA stuff
    assign tc_l = 1'b1;
    pullup (burst_l);
    pullup (preempt_l);

    // Either arbdriver (test bench signal) or arb_o (uut) can drive
    // the arbitration bus
    genvar i;
    generate
    for (i = 0; i < 4; i = i + 1) begin
        pullup (arb[i]);
        assign arb[i] = (arbdriver[i] & arb_o[i]) ? 1'bZ : 1'b0;
    end
    endgenerate

    assign burst_l = burst_driver & burst_o_l ? 1'bZ : 1'b0;
    assign preempt_l = preempt_driver & preempt_o_l ? 1'bZ : 1'b0;


    task read_cycle;
        input [15:0] next_addr;
        input next_mio;
        input onebyte;
        begin
            mca_cycle(next_mio, next_addr, 8'h00, 1, 0, onebyte);
        end
    endtask

    task write_cycle;
        input [15:0] next_addr;
        input [15:0] din;
        input next_mio;
        input onebyte;
        begin

            mca_cycle(next_mio, next_addr, din, 0, 0, onebyte);
        end
    endtask

    task pos_write_cycle;
        input [15:0] next_addr;
        input [7:0] din;
        begin
            mca_cycle(0, next_addr, din, 0, 1, 1);
        end
    endtask

    task pos_read_cycle;
        input [15:0] next_addr;
        begin
            mca_cycle(0, next_addr, 8'h00, 1, 1, 1);
        end
    endtask

    // TODO: Add sbhe_l and a0 for byte steering

    // Cycles start right after CMD goes low, when
    // m/io# and s0/s1 and address changes.
    task mca_cycle;
        input next_mio;
        input [15:0] next_addr;
        input [15:0] din;
        input read;
        input pos;
        input onebyte;
        begin
            #8 m_io_l = next_mio;
            bus_a = next_addr;
            wait(cd_chrdy_l);
            #8 s1_r_l = 1;
            s0_w_l = 1;
            #24
            if (pos) begin
                cd_setup_l = 0;
            end
            #120 cmd_l = 1;
            #8
            if (read) begin
                s1_r_l = 0; // Read or write
            end else begin
                s0_w_l = 0;
            end
            #8 d_valid = 0;
            #8 adl_l = 0;
            #24
// FIXME: sometimes data goes valid after cmd goes low
            if (~read) begin
                d_out = din;
                d_valid = 1;
            end
            #24
            cmd_l = 0;
            if (~cd_ds16_l) begin
                if (next_addr[0]) begin
                    sbhe_l = 0; //A0=1 means only high byte transferred
                end else begin
                    sbhe_l = onebyte;
                end
            end else begin
                sbhe_l = 1;
            end
            adl_l = 1;
            #8 s1_r_l = 1;
            s0_w_l = 1;
            #8 cd_setup_l = 1;
        end
    endtask

        // Clock FIXME
    always #10 clk = ~clk;

    initial begin
        $dumpfile("sim.vcd");
        $dumpvars(0,mcabus_t);
        // Initialize Inputs
        arbdriver = 4'b1111;
        burst_driver = 1'b1;
        preempt_driver = 1'b1;
        d_valid = 0;
        cd_setup_l = 1;
        chreset = 1;
        adl_l = 1;
        cmd_l = 1;
        m_io_l = 0;
        s0_w_l = 1;
        s1_r_l = 1;
        bus_a = 0;
        clk = 0;
        sbhe_l = 1;

        arb_gnt_l = 0;
        irq_in = 0;

        // Teensy signals
        t_atn_read = 0;
        t_isr_write = 0;
        t_isr_out = 8'H00;
        t_cifr_read = 0;
        t_sifr_out = 16'H00;
        t_sifr_write = 0;
        t_cmd_in_progress = 0;
        t_busy_clear = 0;
        t_dreg_in = 16'H00;
        t_treq_set = 0;
        t_clear_all = 0;

        test3 = 0;

        // Wait 100 ns for global reset to finish
        #100;
        chreset = 0;
        #16;
        write_cycle(16'h0000, 16'h0000, 0, 0); // fixme
        write_cycle(16'h3514, 16'hCCAA, 0, 0);
        write_cycle(16'h0000, 16'h0000, 0, 0);
        write_cycle(16'h3514, 16'hBBDD, 0, 1);
if (1) begin
        #100;
        read_cycle(16'h3512, 0, 1);
        write_cycle(16'h3513, 8'hCC, 0, 1); // Write to the ATN reg
        read_cycle(16'h3512, 0, 1);
        #100
        t_atn_read = 1'b1;
        #70                 // Toggle the read for the teensy
        t_atn_read = 1'b0;
        write_cycle(16'h3510, 16'hABCD, 0, 0);
        read_cycle(16'h3512, 0, 1);
        read_cycle(16'h3510, 0, 0);
        read_cycle(16'h3512, 0, 1);

        pos_read_cycle(16'h0100);
        read_cycle(16'h00aa, 1, 1);
        pos_read_cycle(16'h0101);
        read_cycle(16'h00bb, 1, 1);
        pos_write_cycle(16'h0003, 8'b10110010); // Value here goes to POS 03
        pos_write_cycle(16'h0002, 8'h01); // Value here goes to POS 02
end

        // Try a few back to back operations
        t_cifr_read = 1;
        #100
        t_cifr_read = 0;
        read_cycle(16'h0000, 0, 1);
        write_cycle(16'h3510, 16'h06E1, 0, 0);
        read_cycle(16'h3512, 0, 1);
        write_cycle(16'h3510, 16'h0006, 0, 0);

        // More dummy cycles so we don't accidentally clear transfer req
        read_cycle(16'h0000, 0, 1);
        read_cycle(16'h0000, 0, 1);

        // Set transfer request flag
        t_treq_set = 1;
        #75
        t_treq_set = 0;

        // Start DMA request
        write_cycle(16'h3512, 8'h2, 0, 1);
        write_cycle(16'h0000, 8'h0, 0, 0);

// Write DMA enable to teensy regs
        

        #25 test3 = 1;
        #25
        arb_gnt_l = 1;
        #25
        arbdriver = 4'b1111; // priority of some other device
        #175
        arb_gnt_l = 0;
        // DMA reads from memory, writes to IO
        #16 m_io_l = 1;
        bus_a = 16'h2000;
        #136
        read_cycle(16'h0000, 1, 0);
        write_cycle(16'h0000, 16'hAA55, 0, 0); // leave addr data alone. writes to IO (dma)
 //       test3 = 0;
// Delay for arb gnt
        #160
        cmd_l = 1;
        #130
        arb_gnt_l = 1;
        read_cycle(16'h0000, 1, 1); // dummy cycle
        arb_gnt_l = 1;
        #25
        arb_gnt_l = 0;
        read_cycle(16'h0000, 1, 0);
        #200

        // More dummy cycles so we don't accidentally clear transfer req
        read_cycle(16'h0000, 0, 1);
        read_cycle(16'h0000, 0, 1);

        // Set transfer request flag
        t_treq_set = 1;
        #75
        t_treq_set = 0;

        // Start DMA request
        write_cycle(16'h3512, 8'h2, 0, 1);
        write_cycle(16'h0000, 8'h0, 0, 0);


        write_cycle(16'h0123, 16'h9876, 1, 0);
        #25 test3 = 1;
        #25
        arb_gnt_l = 1;
        #25
        arbdriver = 4'b1111;
        // DMA reads from IO, writes to memory
t_dreg_in = 16'h4321;
        #175
        arb_gnt_l = 0;
        #16 m_io_l = 0;
        bus_a = 16'habcd; // should be ignored by card
        #136
        read_cycle(16'h0000, 0, 0); // Read from IO (dma)
        test3 = 0;
        write_cycle(16'h0000, 16'hAAAA, 1, 0);
        read_cycle(16'h0000, 1, 1); //dummy cycle
        arb_gnt_l = 1;
        #25
        arb_gnt_l = 0;
        read_cycle(16'h0000, 1, 1);
        #200

        #200

        #1 $finish ;
    end

endmodule

