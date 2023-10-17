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
    input test3,

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

    output [15:0] t_dreg_out, // DREG data to Teensy
    input [15:0] t_dreg_in,   // DREG data from Teensy
    input t_treq_set,         // Set by Teensy (flag bit)
    output t_treq,            // So teensy can monitor flag status
    output t_treq_16,         // Set by MCA bus transfer to indicate 16-bit

    // Flags
    output t_hard_reset,
    input t_cmd_in_progress,
    input t_busy_clear,
    input t_clear_all,        // Clears all flag bits

    output [39:0] t_pos_regs
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
    assign burst_o_l = 1'b1;

    // Registers
    reg [15:0] reg_cifr = 16'h0000;
    reg [7:0] reg_atn = 8'h00;

    // Flag clear signal
    wire clear_all = t_clear_all | t_hard_reset;

    // Interrupt request line
    assign irq14_l = !(flag_isr & control_int_enable);

    assign t_atn = reg_atn;
    assign t_cifr = reg_cifr;
    assign t_dreg_out = reg_dreg_write;

    // Data register (MCA bus write direction only)
    reg [15:0] reg_dreg_write = 16'h0000;

    // Flags
    reg flag_atn = 1'b0;
    reg flag_busy = 1'b0;
    reg flag_ci_full = 1'b0;
    reg flag_si_full = 1'b0;
    reg flag_isr = 1'b0;
    reg flag_treq = 1'b0;
    reg flag_treq_16 = 1'b0;

    // Outputs to Teensy
    assign t_atn_full = flag_atn;
    assign t_isr_full = flag_isr;
    assign t_cifr_full = flag_ci_full;
    assign t_sifr_full = flag_si_full;
    assign t_treq_16 = flag_treq_16;
    assign t_treq = flag_treq;

    /*
     ** Registers and handshaking interface **
    */

    // ATN register full
    wire flag_atn_set = la_mca_op & ~la_s0_w_l & (la_addr == REG_ATN);
    reg [1:0] reg_atn_set;
    reg [1:0] reg_t_atn_read;
    reg [1:0] reg_t_busy_clear;

    always @ (posedge clk) begin
        reg_atn_set <= {reg_atn_set[0], flag_atn_set};
        reg_t_atn_read <= {reg_t_atn_read[0], t_atn_read};
        reg_t_busy_clear <= {reg_t_busy_clear[0], t_busy_clear};
    end

    always @ (posedge clk) begin
        if ((reg_atn_set == 2'b01) || (reg_t_atn_read == 2'b10) || clear_all) begin
            flag_atn <= clear_all ? 1'b0 : ((reg_t_atn_read == 2'b10) ? 1'b0 : 1'b1);
        end
    end

    assign test1 = flag_atn; //ES testing

    // Busy flag: Set when ATN written to. Cleared by Teensy
    always @ (posedge clk) begin
        if ((reg_atn_set == 2'b01) || (reg_t_busy_clear == 2'b10) || clear_all) begin
            flag_busy <= clear_all ? 1'b0 : ((reg_t_busy_clear == 2'b10) ? 1'b0 : 1'b1);
        end
    end

    // Command Interface Register Full
    wire flag_ci_full_set = la_mca_op & ~la_s0_w_l & (la_addr == REG_CIFR_L);
    reg [1:0] reg_ci_full_set;
    reg [1:0] reg_t_cifr_read;

    always @ (posedge clk) begin
        reg_ci_full_set <= {reg_ci_full_set[0], flag_ci_full_set};
        reg_t_cifr_read <= {reg_t_cifr_read[0], t_cifr_read};
    end

    always @ (posedge clk) begin
        if ((reg_ci_full_set == 2'b01) || (reg_t_cifr_read == 2'b10) || clear_all) begin
            flag_ci_full <= clear_all ? 1'b0 : ((reg_t_cifr_read == 2'b10) ? 1'b0 : 1'b1);
        end
    end

    // ISR register full
    wire flag_isr_clear = la_mca_op & ~la_s1_r_l & (la_addr == REG_ISR);
    reg [1:0] reg_isr_clear;
    reg [1:0] reg_t_isr_write;

    always @ (posedge clk) begin
        reg_isr_clear <= {reg_isr_clear[0], flag_isr_clear};
        reg_t_isr_write <= {reg_t_isr_write[0], t_isr_write};
    end

    always @ (posedge clk) begin
        if ((reg_isr_clear == 2'b10) || (reg_t_isr_write == 2'b01) || clear_all) begin
            flag_isr <= clear_all ? 1'b0 : ((reg_t_isr_write == 2'b01) ? 1'b1 : 1'b0);
        end
    end

    // Status Interface Register Full
    wire flag_sifr_clear = la_mca_op & ~la_s1_r_l & (la_addr == REG_SIFR_L);
    reg [1:0] reg_sifr_clear;
    reg [1:0] reg_t_sifr_write;

    always @ (posedge clk) begin
        reg_sifr_clear <= {reg_sifr_clear[0], flag_sifr_clear};
        reg_t_sifr_write <= {reg_t_sifr_write[0], t_sifr_write};
    end
    // Clear register at end of MCA transaction
    // Set register when Teensy latches new value
    always @ (posedge clk) begin
        if ((reg_sifr_clear == 2'b10) || (reg_t_sifr_write == 2'b01) || clear_all) begin
            flag_si_full <= clear_all ? 1'b0 : ((reg_t_sifr_write == 2'b01) ? 1'b1 : 1'b0);
        end
    end

    // Data register drequest
    wire treq_clear = (la_mca_op & (~la_s1_r_l || ~la_s0_w_l) & (la_addr == REG_DREG)) |
                      (la_dma_selected & ~cmd_l); // IO r/w of DREG *or* dma operation (qual'd by CMD)

    reg [1:0] reg_treq_clear;
    reg [1:0] reg_treq_set;
    // We can tell if it is an 8-bit or 16-bit transfer if la_sbhe_l is low
    always @ (posedge clk) begin
        reg_treq_clear <= {reg_treq_clear[0], treq_clear};
        reg_treq_set <= {reg_treq_set[0], t_treq_set};
    end
    always @ (posedge clk) begin
        if ((reg_treq_clear == 2'b10) || (reg_treq_set == 2'b10) || clear_all) begin
            flag_treq <= clear_all ? 1'b0 : ((reg_treq_set == 2'b10) ? 1'b1 : 1'b0);
        end
        if ((reg_treq_clear == 2'b01) || clear_all) begin
            flag_treq_16 <= clear_all ? 1'b0 : ~la_sbhe_l;
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
    assign reg_bsr = {control_dma_enable, flag_isr, t_cmd_in_progress, flag_busy,
                      flag_si_full, flag_ci_full, flag_treq, flag_isr};

    // Basic Control Register
    assign t_hard_reset = reg_bcr[7];      // Setting this bit resets the MCU
    // TODO: Make it so completing a DMA transfer
    // auto-clears the DMA enable
    assign control_dma_enable = reg_bcr[1]; // Set to allow DMA operation
    assign control_int_enable = reg_bcr[0]; // Set to en irq14 line to assert



    /*
     ** Microchannel Interface Implementation below **
    */

    // POS registers.
    wire [15:0] reg_pos01 = 16'hDF9F;
// LSB is card enable bit FIXME: add debug mode?
    reg [7:0] reg_pos2 = 8'b0_1_1110_0_0; // Default to card disabled, 3510, arb e, fairness on
    reg [7:0] reg_pos3 = 8'b0_0_00_0000;
    reg [7:0] reg_pos4 = 8'b00000_00_0;

    wire card_enable = reg_pos2[0];
    wire [3:0] arb_level = reg_pos2[5:2]; // DMA arbitration level

    assign t_pos_regs = {reg_pos4, reg_pos3, reg_pos2, reg_pos01};


    // DMA
    // arb_o = 4 outputs to drive arbitration bus
    // arb = 4 inputs to monitor status of arb bus
    // preempt_o_l = output to drive preempt signal
    // preempt_l = input to monitor preempt signal
    // burst_o_l = output to drive burst signal
    // burst_l = input to monitor burst signal
    // arb_gnt_l = input to monitor arbitration and grant cycle
    // tc_l = input to monitor for last cycle in burst

    wire dma_requested = control_dma_enable & flag_treq & card_enable;
    //wire dma_requested = test3; // & cmd_l? FIXME: & card_enable
    reg dma_cycle = 1'b0; // latch is set when we are in a dma cycle
    wire arb_won;

    wire [3:0] arb_comp;
    wire [3:0] arb_output;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin:m
            assign arb_o[i] = ~(arb_won | (dma_cycle & arb_gnt_l)) | arb_output[i];
            assign arb_comp[i] = ~arb_level[i] | arb[i];
        end
    endgenerate

    assign arb_output[3] = arb_level[3];
    assign arb_output[2] = arb_level[2] | ~arb_comp[3];
    assign arb_output[1] = arb_level[1] | ~arb_comp[3] | ~arb_comp[2];
    assign arb_output[0] = arb_level[0] | ~arb_comp[3] | ~arb_comp[2] | ~arb_comp[1];

    assign arb_won =  dma_cycle & arb_comp[3] & arb_comp[2] & arb_comp[1] & arb_comp[0];
    reg la_arb_won = 1'b0;

    //FIXME: may need to prevent DMA access during our own IO ops.

    always @ (negedge arb_gnt_l) begin
        la_arb_won <= arb_won;
    end

    // DMA cycle begins and ends when arb/gnt pulses high.
    always @ (posedge arb_gnt_l) begin
        dma_cycle <= dma_requested;
    end

    // Deassert preempt as soon as we win arbitration
    assign preempt_o_l = ~(dma_requested & ~la_arb_won);

    // dma_selected acts like another address select. This should enable access
    // by the bus to the DREG.
    wire dma_selected = la_arb_won & ~m_io_l & ~arb_gnt_l;

    // Only support IO ports. Only respond when not in reset.
    wire addressed;
//    assign addressed = (~addr_sel_l) & ~m_io_l & ~chreset;

    assign addressed = (~addr_sel_l | ~cd_setup_l) & ~m_io_l & ~chreset;

    // Data bus steering
    // MCA uses signals a0, cd_ds16_l, sbhe_l
    // Drive cd_ds16_l for register 0/1 (SIFR/CIFR). Also for register 4 (low byte of DREG).
    // Accessing the high byte of the DREG in 8-bit mode will not work (the Teensy transfers
    // data either 8 bits or 16 bits at a time depending on SBHE)
    // This is purely combinational.
    // Note that POS registers can be 8 bit only, so that's nice.
    assign cd_ds16_l = ~(cd_setup_l & addressed &
                         ((bus_a[3:1] == 3'b000) |
                          (bus_a[3:0] == 4'b0100)) | dma_selected);

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

    reg la_dma_selected;

    // Data input latches
    always @ (negedge cmd_l) begin
        la_addr <= bus_a;
        la_data_in <= bus_d; // Note that data out needs to be ready by rising edge of CMD
        la_cd_setup_l <= cd_setup_l;
        la_sbhe_l <= sbhe_l;
        la_s0_w_l <= s0_w_l;
        la_s1_r_l <= s1_r_l;

        la_mca_op <= addressed & cd_setup_l;

        la_data_read <= ~s1_r_l & (addressed | dma_selected);
        //la_data_read <= ~s1_r_l & (addressed | dma_selected) & cd_setup_l; // Use this to disable POS
        la_dma_selected <= dma_selected;

        // Data written to us on this edge
        // SBHE: useful really only when the host writes to us. Only write to the upper byte
        // when this is asserted low.
        if (~s0_w_l & (addressed | dma_selected)) begin
            if (cd_setup_l && card_enable) begin
                if (~dma_selected) begin
                    case (bus_a)
                        REG_CIFR_L  : reg_cifr <= sbhe_l ? {reg_cifr[15:8], bus_d[7:0]} : bus_d;
                        REG_CIFR_H  : reg_cifr <= sbhe_l ? reg_cifr : {bus_d[15:8], reg_cifr[7:0]};
                        REG_BCR     : reg_bcr  <= bus_d[7:0];
                        REG_ATN     : reg_atn  <= bus_d[7:0];
                        REG_DREG    : reg_dreg_write <= sbhe_l ? {reg_dreg_write[15:8], bus_d[7:0]} : bus_d;
                        // Doesn't make sense to access the high byte alone of REG_DREG
                    endcase
                end else begin
                    // DMA ignores address
                    reg_dreg_write <= sbhe_l ? {reg_dreg_write[15:8], bus_d[7:0]} : bus_d;
                end
            end else begin
                case (bus_a)
                    4'h2       : reg_pos2 <= bus_d[7:0];
                    4'h3       : reg_pos3 <= bus_d[7:0];
                    4'h4       : reg_pos4 <= bus_d[7:0];
                endcase
            end
        end
    end

    // Data output: present data at the data output depending on the address
    // This is qualified by the data output gate
    reg [15:0] data_out;
    assign bus_d = data_dir ? data_out : 16'bZ;
    assign data_dir = la_data_read & ~cmd_l & (card_enable | ~la_cd_setup_l); // Read mode; only when CMD is low.

    // Data output mux
    always @ (*) begin
        if (la_cd_setup_l == 1'b0) begin
            case (la_addr)
                4'h0    : data_out <= {8'hFF, reg_pos01[7:0]};
                4'h1    : data_out <= {8'hFF, reg_pos01[15:8]};
                4'h2    : data_out <= {8'hFF, reg_pos2};
                4'h3    : data_out <= {8'hFF, reg_pos3};
                4'h4    : data_out <= {8'hFF, reg_pos4};
                default     : data_out <= 16'hFFFF;
            endcase
        end else begin
            if (~la_dma_selected) begin
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
                    REG_DREG        : data_out <= la_sbhe_l ? {8'hFF, t_dreg_in[7:0]} : t_dreg_in;
                    default         : data_out <= 16'hFFFF;
                endcase
            end else begin
                data_out <= la_sbhe_l ? {8'hFF, t_dreg_in[7:0]} : t_dreg_in;
            end
        end
    end

endmodule
