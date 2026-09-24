// DifNif
//
// Copyright (c) 2021 Eric Schlaepfer
// This work is licensed under CERN-OHL-S-2.0.
//

`default_nettype none

// POS bypass: card always enabled, POS registers not visible to the host.
// Build with -DMCA_USE_POS to enable the POS registers instead.
`ifndef MCA_USE_POS
`define MCA_NO_POS
`endif

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
    output cd_sfdbk_l,  // Card selected feedback

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
    output [3:0] tbus,  // test bus

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

    // Declared early: used before their definitions below
    reg flag_isr = 1'b0;
    reg [15:0] reg_dreg_write = 16'h0000; // Data register (MCA bus write direction only)
    wire control_int_enable;
    wire dma_selected;
    wire addressed;
    reg la_sbhe_l;
    reg la_cd_setup_l;
    reg [3:0] la_addr;
    reg la_addressed;
    reg la_write;
    reg la_read;
    reg la_dma_selected;

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

    // Interrupt request line
    assign irq14_l = !(flag_isr & control_int_enable);

    assign t_atn = reg_atn;
    assign t_cifr = reg_cifr;
    assign t_dreg_out = reg_dreg_write;

    // Flags
    reg flag_atn = 1'b0;
    reg flag_busy = 1'b0;
    reg flag_ci_full = 1'b0;
    reg flag_si_full = 1'b0;
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

    // Signal to clear flags -- sync it up.
    reg clear_all = 1'b0;
    always @ (posedge clk) begin
        clear_all <= t_clear_all | t_hard_reset;
    end

    // Host-side events. Each host cycle that writes a mailbox register, or
    // reads one the Teensy is waiting on, flips a toggle on the rising edge
    // of -CMD, after the write data has been stored (see "Data input
    // latches"). The 50 MHz domain sees each flip as exactly one event, so
    // back-to-back cycles can't merge, and the Teensy never sees a flag
    // before the data behind it.
    reg tg_atn = 1'b0;      // host wrote ATN
    reg tg_cifr = 1'b0;     // host wrote CIFR
    reg tg_isr = 1'b0;      // host read ISR
    reg tg_sifr = 1'b0;     // host read SIFR
    reg tg_treq = 1'b0;     // host or DMA accessed DREG

    wire la_io = la_addressed & la_cd_setup_l;

    always @ (posedge cmd_l) begin
        if (la_io & la_write & (la_addr == REG_ATN))    tg_atn  <= ~tg_atn;
        if (la_io & la_write & (la_addr == REG_CIFR_L)) tg_cifr <= ~tg_cifr;
        if (la_io & la_read  & (la_addr == REG_ISR))    tg_isr  <= ~tg_isr;
        if (la_io & la_read  & (la_addr == REG_SIFR_L)) tg_sifr <= ~tg_sifr;
        if ((la_io & (la_read | la_write) & (la_addr == REG_DREG)) | la_dma_selected)
            tg_treq <= ~tg_treq;
    end

    // Two synchronizer stages, then a third to detect each flip
    reg [2:0] s_atn = 3'b000;
    reg [2:0] s_cifr = 3'b000;
    reg [2:0] s_isr = 3'b000;
    reg [2:0] s_sifr = 3'b000;
    reg [2:0] s_treq = 3'b000;

    always @ (posedge clk) begin
        s_atn  <= {s_atn[1:0], tg_atn};
        s_cifr <= {s_cifr[1:0], tg_cifr};
        s_isr  <= {s_isr[1:0], tg_isr};
        s_sifr <= {s_sifr[1:0], tg_sifr};
        s_treq <= {s_treq[1:0], tg_treq};
    end

    wire ev_atn  = s_atn[2] ^ s_atn[1];
    wire ev_cifr = s_cifr[2] ^ s_cifr[1];
    wire ev_isr  = s_isr[2] ^ s_isr[1];
    wire ev_sifr = s_sifr[2] ^ s_sifr[1];
    wire ev_treq = s_treq[2] ^ s_treq[1];

    // Teensy-side strobes
    reg [1:0] reg_t_atn_read;
    reg [1:0] reg_t_busy_clear;
    reg [1:0] reg_t_cifr_read;
    reg [1:0] reg_t_isr_write;
    reg [1:0] reg_t_sifr_write;
    reg [1:0] reg_treq_set;

    always @ (posedge clk) begin
        reg_t_atn_read <= {reg_t_atn_read[0], t_atn_read};
        reg_t_busy_clear <= {reg_t_busy_clear[0], t_busy_clear};
        reg_t_cifr_read <= {reg_t_cifr_read[0], t_cifr_read};
        reg_t_isr_write <= {reg_t_isr_write[0], t_isr_write};
        reg_t_sifr_write <= {reg_t_sifr_write[0], t_sifr_write};
        reg_treq_set <= {reg_treq_set[0], t_treq_set};
    end

    // ATN register full: set when the host writes ATN, cleared when the
    // Teensy reads it
    always @ (posedge clk) begin
        if (clear_all || (reg_t_atn_read == 2'b10)) begin
            flag_atn <= 1'b0;
        end else if (ev_atn) begin
            flag_atn <= 1'b1;
        end
    end

    // Busy flag: Set when ATN written to. Cleared by Teensy
    always @ (posedge clk) begin
        if (clear_all || (reg_t_busy_clear == 2'b10)) begin
            flag_busy <= 1'b0;
        end else if (ev_atn) begin
            flag_busy <= 1'b1;
        end
    end

    // Command Interface Register Full
    always @ (posedge clk) begin
        if (clear_all || (reg_t_cifr_read == 2'b10)) begin
            flag_ci_full <= 1'b0;
        end else if (ev_cifr) begin
            flag_ci_full <= 1'b1;
        end
    end

    // ISR register full: set when the Teensy writes it, cleared once the
    // host's read of it has finished
    always @ (posedge clk) begin
        if (clear_all || ev_isr) begin
            flag_isr <= 1'b0;
        end else if (reg_t_isr_write == 2'b01) begin
            flag_isr <= 1'b1;
        end
    end

    // Status Interface Register Full
    // Clear register at end of MCA transaction
    // Set register when Teensy latches new value
    always @ (posedge clk) begin
        if (clear_all || ev_sifr) begin
            flag_si_full <= 1'b0;
        end else if (reg_t_sifr_write == 2'b01) begin
            flag_si_full <= 1'b1;
        end
    end

    // Data register transfer request: set by the Teensy, cleared at the end
    // of each host or DMA access to DREG
    // We can tell if it is an 8-bit or 16-bit transfer if la_sbhe_l is low
    always @ (posedge clk) begin
        if (clear_all || ev_treq) begin
            flag_treq <= 1'b0;
        end else if (reg_treq_set == 2'b10) begin
            flag_treq <= 1'b1;
        end

        if (clear_all) begin
            flag_treq_16 <= 1'b0;
        end else begin
            flag_treq_16 <= ~la_sbhe_l;
        end
    end

    // Test outputs
//    assign test1 = flag_treq;
//    assign test2 = t_treq_set;
//    assign tbus = {treq_clear1, 1'b0, 1'b0};
    assign tbus = 3'b0;
    assign test1 = 1'b0;
    assign test2 = 1'b0;
    // "fixed" when i probe treq_clear.
    // Signal treq_clear1 never asserts.


    /*
     ** Microchannel status registers **
    */

    wire [7:0] reg_bsr; // Assembled from assign statement
    reg [7:0] reg_bcr = 8'h00;

    // Control lines
    wire control_dma_enable;


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
`ifdef MCA_NO_POS
    reg [7:0] reg_pos2 = 8'b0_1_1110_0_1; // Default to card enabled, 3510, arb e, fairness on
`else
    reg [7:0] reg_pos2 = 8'b0_1_1110_0_0; // Default to card disabled, 3510, arb e, fairness on
`endif
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
    assign dma_selected = arb_won & ~m_io_l & ~arb_gnt_l;

    // Only support IO ports. Only respond when not in reset.
    // A disabled card answers only setup (POS) cycles.
`ifdef MCA_NO_POS
    assign addressed = (~addr_sel_l & card_enable) & ~m_io_l & ~chreset;
`else
    assign addressed = ((~addr_sel_l & card_enable) | ~cd_setup_l) & ~m_io_l & ~chreset;
`endif

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

    // Card selected feedback: required whenever the card is selected by the
    // processor or DMA controller, but not by -CD SETUP. Like -CD DS 16 it
    // comes from the unlatched decode (IBM Figure 2-34, notes 1 and 3).
    assign cd_sfdbk_l = ~(cd_setup_l & addressed | dma_selected);

    // Address, status and byte enables are latched on the falling edge of
    // -CMD. They are guaranteed valid for only 30 ns after it (T9, T10).
    reg la_data_read;

    always @ (negedge cmd_l) begin
        la_addr <= bus_a;
        la_cd_setup_l <= cd_setup_l;
        la_sbhe_l <= sbhe_l;
        la_addressed <= addressed;
        la_write <= ~s0_w_l;
        la_read <= ~s1_r_l;

        la_data_read <= ~s1_r_l & (addressed | dma_selected);
        //la_data_read <= ~s1_r_l & (addressed | dma_selected) & cd_setup_l; // Use this to disable POS
        la_dma_selected <= dma_selected;
    end

    // Data input latches
    // Write data is stored on the rising edge of -CMD. It is guaranteed
    // valid only 0 ns before -CMD falls (T17), but for 30 ns after -CMD
    // rises (T18).
    always @ (posedge cmd_l) begin
        // SBHE: useful really only when the host writes to us. Only write to the upper byte
        // when this is asserted low.
        if (la_write & (la_addressed | la_dma_selected)) begin
            if (la_cd_setup_l & card_enable) begin
                if (~la_dma_selected) begin
                    case (la_addr)
                        REG_CIFR_L  : reg_cifr <= la_sbhe_l ? {reg_cifr[15:8], bus_d[7:0]} : bus_d;
                        REG_CIFR_H  : reg_cifr <= la_sbhe_l ? reg_cifr : {bus_d[15:8], reg_cifr[7:0]};
                        REG_BCR     : reg_bcr  <= bus_d[7:0];
                        REG_ATN     : reg_atn  <= bus_d[7:0];
                        REG_DREG    : reg_dreg_write <= la_sbhe_l ? {reg_dreg_write[15:8], bus_d[7:0]} : bus_d;
                        // Doesn't make sense to access the high byte alone of REG_DREG
                    endcase
                end else begin
                    // DMA ignores address
                    reg_dreg_write <= la_sbhe_l ? {reg_dreg_write[15:8], bus_d[7:0]} : bus_d;
                end
            end else if (~la_cd_setup_l) begin
                case (la_addr)
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
