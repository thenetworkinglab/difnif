// DifNif FPGA-only: a small processor in the Teensy's place
//
// Toward mcabus.v and the sector buffer this has the same ports as
// teensy.v, so the bus side doesn't change. Inside: a PicoRV32 (RV32IC)
// running firmware from block RAM, the mailbox registers the Teensy used,
// the SD card host controller (sdhost.v) and its bridge to the sector
// buffer (sdbridge.v), a sector buffer of the processor's own for blocks it
// reads itself (the card's partition table and FAT), a serial port for a
// log, a microsecond timer and the LEDs.
//
// Memory map (32-bit accesses unless noted):
//   0000_0000  RAM, RAM_WORDS x 32 bits, loaded from FIRMWARE at power-up
//   1000_0000  mailbox registers, 4 bytes apart, numbered as the Teensy's
//              (teensy.v): 0 test, 1 flags, 2 ATN, 3 ISR, 4 CIFR, 5 SIFR,
//              6 DREG, 7-9 POS, 10-13 versions and variant, 15 control.
//              Reading ATN or CIFR, and writing flags, ISR, SIFR or bit 1
//              of control, also signal mcabus as a Teensy access would.
//   1000_0100  sdhost registers 0-8, 4 bytes apart (see sdhost.v)
//   1000_0200  bridge: +0 control (write: bit 0 direction, which also sets
//              the sector buffer's; bit 1 restart; bit 2 clear failure;
//              bit 3 SD data to and from the processor's buffer instead of
//              the bridge; bit 4 rewind the processor's buffer), +4 sectors
//              to arm, +8 status (read: 15:0 blocks done, bit 16 failed,
//              bit 17 sector buffer h_idle)
//   1000_0300  +0 serial: write sends a byte; read bit 8 ready to send,
//              bit 9 a byte received, 7:0 that byte (reading takes it).
//              +4 LEDs (bits 1:0). +8 microseconds since power-up.
//   2000_0000  the processor's sector buffer: 256 words of 16 bits, 4 bytes
//              apart, byte 0 of the block in bits 7:0
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

`default_nettype none

module soc #(
    parameter RAM_WORDS = 2048,          // 8 KB
    parameter FIRMWARE = "fw.hex",
    parameter BAUD_DIV = 50              // 50 MHz / 50 = 1 Mbaud
) (
    input  wire        clk,
    input  wire        rst,

    // Debug serial port (through the Teensy, or anything at 3.3 V)
    output reg         uart_tx = 1'b1,
    input  wire        uart_rx,
    output reg  [1:0]  leds = 2'b00,

    // SD card
    output wire        sd_clk,
    input  wire        sd_cmd_in,
    output wire        sd_cmd_out,
    output wire        sd_cmd_oe,
    input  wire [3:0]  sd_dat_in,
    output wire [3:0]  sd_dat_out,
    output wire [3:0]  sd_dat_oe,
    input  wire        sd_detect,

    // To mcabus, as teensy.v
    input  wire [7:0]  t_atn,
    input  wire        t_atn_full,
    output wire        t_atn_read,
    output wire [7:0]  t_isr_out,
    input  wire        t_isr_full,
    output wire        t_isr_write,
    input  wire [15:0] t_cifr,
    input  wire        t_cifr_full,
    output wire        t_cifr_read,
    output wire [15:0] t_sifr_out,
    input  wire        t_sifr_full,
    output wire        t_sifr_write,
    input  wire        t_hard_reset,
    output wire        t_cmd_in_progress,
    output wire        t_busy_clear,
    output wire        t_clear_all,
    input  wire [15:0] t_dreg_out,
    output wire [15:0] t_dreg_in,
    output wire        t_treq_set,
    input  wire        t_treq,
    input  wire        t_treq_16,
    input  wire [39:0] t_pos_regs,
    input  wire [15:0] t_host_diag,

    // Sector buffer, as teensy.v
    output wire        buf_mode,
    output wire        buf_dir,
    output wire        burst_en,
    output wire        isr_gate,
    output wire        t_sifr_clear,
    output wire        t_buf_wr,
    output wire [15:0] t_buf_wdata,
    output wire        t_buf_rd,
    output wire        t_buf_go,
    output wire        t_buf_done,
    input  wire [15:0] t_buf_rdata,
    input  wire        t_buf_ready,
    input  wire        t_buf_can_arm,
    input  wire        t_buf_h_idle,
    output wire        buf_clear        // the bridge empties the sector buffer
);

`include "version.vh"

    // ------------------------------------------------------------------
    // Processor

    wire        mem_valid, mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] per_rdata;              // peripheral data, registered
    wire [31:0] cpu_rdata;
    wire        trap;

    picorv32 #(
        .ENABLE_COUNTERS(0),
        .ENABLE_COUNTERS64(0),
        .ENABLE_REGS_16_31(1),
        .ENABLE_REGS_DUALPORT(1),
        .TWO_STAGE_SHIFT(1),
        .BARREL_SHIFTER(0),
        .COMPRESSED_ISA(1),
        .CATCH_MISALIGN(0),
        .CATCH_ILLINSN(0),
        .ENABLE_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_IRQ(0),
        .PROGADDR_RESET(32'h0000_0000),
        .STACKADDR(RAM_WORDS * 4)
    ) cpu (
        .clk(clk),
        .resetn(~rst),
        .trap(trap),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(cpu_rdata),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'd0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .irq(32'd0)
    );

    wire is_ram  = mem_addr[31:28] == 4'h0;
    wire is_mbox = mem_addr[31:8] == 24'h100000;
    wire is_sd   = mem_addr[31:8] == 24'h100001;
    wire is_br   = mem_addr[31:8] == 24'h100002;
    wire is_misc = mem_addr[31:8] == 24'h100003;
    wire is_cbuf = mem_addr[31:28] == 4'h2;
    wire [3:0] rn = mem_addr[5:2];               // register number
    wire       wr = mem_valid && !mem_ready && mem_wstrb != 4'd0;
    wire       rd = mem_valid && !mem_ready && mem_wstrb == 4'd0;

    // ------------------------------------------------------------------
    // RAM

    reg [31:0] ram [0:RAM_WORDS-1];
    initial $readmemh(FIRMWARE, ram);
    wire [13:0] ram_a = mem_addr[15:2];
    reg  [31:0] ram_q;
    always @(posedge clk) begin
        if (mem_valid && is_ram) begin
            if (mem_wstrb[0]) ram[ram_a][7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) ram[ram_a][15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) ram[ram_a][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) ram[ram_a][31:24] <= mem_wdata[31:24];
            ram_q <= ram[ram_a];
        end
    end

    // ------------------------------------------------------------------
    // Mailbox registers (teensy.v's, on the processor's bus)
    //
    // mcabus.v synchronises the Teensy's strobes and acts on an edge, so
    // each is a two-clock pulse here, and a write or read that makes one
    // completes only after two more clocks low, so the next can't merge
    // with it.

    reg [15:0] testreg = 16'hABCD;
    reg [15:0] flags_in = 16'h0000;
    reg [7:0]  t_isr = 8'h00;
    reg [15:0] t_sifr = 16'h0000;
    reg [15:0] t_dreg = 16'h0000;
    reg        ctrl_in = 1'b0;
    reg        gate_in = 1'b0;
    reg [3:0]  strobe = 4'd0;      // which strobes: atn_read, cifr_read, isr, sifr
    reg        s_busy_clear = 1'b0, s_treq_set = 1'b0, s_sifr_clear = 1'b0;
    reg [2:0]  scount = 3'd0;      // 4 clocks: two high, two low

    assign t_isr_out = t_isr;
    assign t_sifr_out = t_sifr;
    assign t_dreg_in = t_dreg;
    assign t_cmd_in_progress = flags_in[6];
    assign t_clear_all = flags_in[10];
    assign buf_mode = flags_in[11];
    wire   s_high = scount != 3'd0 && scount > 3'd2;
    assign t_atn_read   = s_high & strobe[0];
    assign t_cifr_read  = s_high & strobe[1];
    assign t_isr_write  = s_high & strobe[2];
    assign t_sifr_write = s_high & strobe[3];
    assign t_busy_clear = s_high & s_busy_clear;
    assign t_treq_set   = s_high & s_treq_set;
    assign t_sifr_clear = s_high & s_sifr_clear;
    assign burst_en = ctrl_in;
    assign isr_gate = gate_in;

    wire [4:0] buf_flags = buf_mode ? {t_buf_h_idle, t_buf_can_arm, t_buf_ready, buf_dir, 1'b1} : 5'h00;
    wire [15:0] flags_out = {buf_flags, t_clear_all, t_treq_16, t_treq,
                             1'b1, t_cmd_in_progress, 1'b0, t_hard_reset,
                             t_sifr_full, t_cifr_full, t_isr_full, t_atn_full};
`ifdef MCA_USE_POS
    localparam [15:0] VARIANT = 16'h0101;   // POS registers on, processor build
`else
    localparam [15:0] VARIANT = 16'h0100;
`endif

    reg [15:0] mbox_q;
    always @(*) begin
        case (rn)
            4'd0:  mbox_q = testreg;
            4'd1:  mbox_q = flags_out;
            4'd2:  mbox_q = {8'h00, t_atn};
            4'd3:  mbox_q = {8'h00, t_isr};
            4'd4:  mbox_q = t_cifr;
            4'd5:  mbox_q = t_sifr;
            4'd6:  mbox_q = t_dreg_out;
            4'd7:  mbox_q = t_pos_regs[15:0];
            4'd8:  mbox_q = t_pos_regs[31:16];
            4'd9:  mbox_q = {8'h00, t_pos_regs[39:32]};
            4'd10: mbox_q = `FPGA_VERSION_YEAR;
            4'd11: mbox_q = `FPGA_VERSION_DATE;
            4'd12: mbox_q = `FPGA_VERSION_COUNT;
            4'd13: mbox_q = VARIANT;
            4'd15: mbox_q = {t_host_diag[15:3], gate_in, t_host_diag[1], ctrl_in};
            default: mbox_q = 16'h0000;
        endcase
    end

    wire mbox_go = mem_valid && !mem_ready && is_mbox && scount == 3'd0;
    reg  mbox_done;
    always @(posedge clk) begin
        mbox_done <= 1'b0;
        if (rst) begin
            scount <= 3'd0;
            flags_in <= 16'h0000;
            ctrl_in <= 1'b0;
            gate_in <= 1'b0;
        end else if (scount != 3'd0) begin
            scount <= scount - 3'd1;
            if (scount == 3'd1) mbox_done <= 1'b1;
        end else if (mbox_go && !mbox_done) begin
            strobe <= 4'd0;
            s_busy_clear <= 1'b0;
            s_treq_set <= 1'b0;
            s_sifr_clear <= 1'b0;
            if (mem_wstrb != 4'd0) begin
                case (rn)
                    4'd0: testreg <= mem_wdata[15:0];
                    4'd1: begin
                        flags_in <= mem_wdata[15:0];
                        s_busy_clear <= ~mem_wdata[7];
                        s_treq_set <= mem_wdata[5];
                    end
                    4'd3: begin t_isr <= mem_wdata[7:0]; strobe[2] <= 1'b1; end
                    4'd5: begin t_sifr <= mem_wdata[15:0]; strobe[3] <= 1'b1; end
                    4'd6: t_dreg <= mem_wdata[15:0];
                    4'd15: begin
                        ctrl_in <= mem_wdata[0];
                        gate_in <= mem_wdata[2];
                        s_sifr_clear <= mem_wdata[1];
                    end
                    default: ;
                endcase
            end else begin
                if (rn == 4'd2) strobe[0] <= 1'b1;
                if (rn == 4'd4) strobe[1] <= 1'b1;
            end
            scount <= 3'd4;
        end
    end

    // ------------------------------------------------------------------
    // SD card, the bridge, and the processor's sector buffer

    wire [31:0] sd_rdata;
    wire [15:0] rd_word, wr_word_br;
    wire        rd_strobe, rd_blk_done, rd_blk_ok, wr_next, wr_blk_done, wr_blk_ok;
    wire        rd_ready_br, wr_ready_br;
    reg         route_cpu = 1'b0;          // SD data to and from cbuf
    reg  [7:0]  cbuf_idx = 8'd0;
    reg  [15:0] cbuf [0:255];
    reg  [15:0] cbuf_q;                    // the word at cbuf_idx, or the processor's

    sdhost sdh (
        .clk(clk), .rst(rst),
        .addr(rn), .wdata(mem_wdata), .we(wr && is_sd), .rdata(sd_rdata),
        .rd_word(rd_word), .rd_strobe(rd_strobe),
        .rd_ready(route_cpu ? 1'b1 : rd_ready_br),
        .rd_blk_done(rd_blk_done), .rd_blk_ok(rd_blk_ok),
        .wr_word(route_cpu ? cbuf_q : wr_word_br), .wr_next(wr_next),
        .wr_ready(route_cpu ? 1'b1 : wr_ready_br),
        .wr_blk_done(wr_blk_done), .wr_blk_ok(wr_blk_ok),
        .sd_clk(sd_clk), .cmd_in(sd_cmd_in), .cmd_out(sd_cmd_out), .cmd_oe(sd_cmd_oe),
        .dat_in(sd_dat_in), .dat_out(sd_dat_out), .dat_oe(sd_dat_oe),
        .card_detect(sd_detect)
    );

    reg        br_dir = 1'b0;
    reg        br_restart = 1'b0;
    reg        br_clear_fail = 1'b0;
    reg [15:0] br_arm_n = 16'd0;
    wire [15:0] br_blocks;
    wire       br_failed;
    assign buf_dir = br_dir;

    sdbridge bridge (
        .clk(clk), .rst(rst),
        .dir(br_dir), .restart(br_restart), .sb_clear(buf_clear),
        .arm_n(br_arm_n), .clear_fail(br_clear_fail),
        .blocks_done(br_blocks), .failed(br_failed),
        .rd_word(rd_word), .rd_strobe(rd_strobe & ~route_cpu),
        .rd_blk_done(rd_blk_done & ~route_cpu), .rd_blk_ok(rd_blk_ok),
        .rd_ready(rd_ready_br),
        .wr_word(wr_word_br), .wr_next(wr_next & ~route_cpu), .wr_ready(wr_ready_br),
        .wr_blk_done(wr_blk_done & ~route_cpu), .wr_blk_ok(wr_blk_ok),
        .t_wr(t_buf_wr), .t_wdata(t_buf_wdata), .t_rd(t_buf_rd), .t_rdata(t_buf_rdata),
        .t_go(t_buf_go), .t_done(t_buf_done), .t_ready(t_buf_ready),
        .t_can_arm(t_buf_can_arm)
    );

    // cbuf: one write port (SD reads, or the processor) and one read port
    // (the word for an SD write, or the processor's, which never overlap)
    wire       cbuf_sd_wr = route_cpu & rd_strobe;
    wire       cbuf_cpu_wr = wr && is_cbuf;
    wire [7:0] cbuf_raddr = (mem_valid && is_cbuf) ? mem_addr[9:2] : cbuf_idx;
    always @(posedge clk) begin
        if (cbuf_sd_wr) cbuf[cbuf_idx] <= rd_word;
        else if (cbuf_cpu_wr) cbuf[mem_addr[9:2]] <= mem_wdata[15:0];
        cbuf_q <= cbuf[cbuf_raddr];
    end

    always @(posedge clk) begin
        br_restart <= 1'b0;
        br_clear_fail <= 1'b0;
        if (rst) begin
            br_dir <= 1'b0;
            route_cpu <= 1'b0;
            cbuf_idx <= 8'd0;
        end else begin
            if (route_cpu && (rd_strobe || wr_next)) cbuf_idx <= cbuf_idx + 8'd1;
            if (wr && is_br) begin
                case (rn)
                    4'd0: begin
                        br_dir <= mem_wdata[0];
                        br_restart <= mem_wdata[1];
                        br_clear_fail <= mem_wdata[2];
                        route_cpu <= mem_wdata[3];
                        if (mem_wdata[4]) cbuf_idx <= 8'd0;
                    end
                    4'd1: br_arm_n <= mem_wdata[15:0];
                    default: ;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Serial port, 8N1

    reg [9:0]  tx_sh = 10'h3FF;
    reg [3:0]  tx_bits = 4'd0;
    reg [7:0]  tx_div = 8'd0;
    wire       tx_ready = tx_bits == 4'd0;

    reg [1:0]  rx_s = 2'b11;
    reg [7:0]  rx_div = 8'd0;
    reg [3:0]  rx_bits = 4'd0;
    reg [7:0]  rx_sh = 8'h00;
    reg [7:0]  rx_byte = 8'h00;
    reg        rx_have = 1'b0;

    always @(posedge clk) begin
        rx_s <= {rx_s[0], uart_rx};
        if (rst) begin
            tx_bits <= 4'd0;
            uart_tx <= 1'b1;
            rx_bits <= 4'd0;
            rx_have <= 1'b0;
        end else begin
            // Transmit
            if (wr && is_misc && rn == 4'd0 && tx_ready) begin
                tx_sh <= {1'b1, mem_wdata[7:0], 1'b0};
                tx_bits <= 4'd10;
                tx_div <= 8'd0;
            end else if (tx_bits != 4'd0) begin
                if (tx_div == 8'd0) begin
                    uart_tx <= tx_sh[0];
                    tx_sh <= {1'b1, tx_sh[9:1]};
                    tx_div <= BAUD_DIV - 1;
                end else begin
                    tx_div <= tx_div - 8'd1;
                    if (tx_div == 8'd1) tx_bits <= tx_bits - 4'd1;
                end
            end
            // Receive: start bit, then sample each bit in its middle
            if (rd && is_misc && rn == 4'd0) rx_have <= 1'b0;
            if (rx_bits == 4'd0) begin
                if (!rx_s[1]) begin
                    rx_bits <= 4'd10;
                    rx_div <= BAUD_DIV / 2;
                end
            end else if (rx_div != 8'd0) begin
                rx_div <= rx_div - 8'd1;
            end else begin
                rx_div <= BAUD_DIV - 1;
                rx_bits <= rx_bits - 4'd1;
                if (rx_bits == 4'd10 && rx_s[1]) rx_bits <= 4'd0;   // false start
                else if (rx_bits != 4'd10 && rx_bits != 4'd1) rx_sh <= {rx_s[1], rx_sh[7:1]};
                else if (rx_bits == 4'd1) begin
                    rx_byte <= rx_sh;
                    rx_have <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Microsecond timer

    reg [5:0]  us_div = 6'd0;
    reg [31:0] us = 32'd0;
    always @(posedge clk) begin
        if (us_div == 6'd49) begin
            us_div <= 6'd0;
            us <= us + 32'd1;
        end else begin
            us_div <= us_div + 6'd1;
        end
    end

    always @(posedge clk) begin
        if (rst) leds <= 2'b00;
        else if (wr && is_misc && rn == 4'd1) leds <= mem_wdata[1:0];
    end

    // ------------------------------------------------------------------
    // Bus: everything answers a clock after the request, except the
    // mailbox, which answers when its strobe has finished

    always @(posedge clk) begin
        mem_ready <= 1'b0;
        if (mem_valid && !mem_ready) begin
            if (is_mbox) begin
                if (mbox_done) begin
                    mem_ready <= 1'b1;
                    per_rdata <= {16'h0000, mbox_q};
                end
            end else if (is_ram) begin
                mem_ready <= 1'b1;   // ram_q is read below, a clock later
            end else begin
                mem_ready <= 1'b1;
                if (is_sd) per_rdata <= sd_rdata;
                else if (is_br) per_rdata <= {14'd0, t_buf_h_idle, br_failed, br_blocks};
                else if (is_misc) begin
                    case (rn)
                        4'd0: per_rdata <= {22'd0, rx_have, tx_ready, rx_byte};
                        4'd1: per_rdata <= {30'd0, leds};
                        4'd2: per_rdata <= us;
                        default: per_rdata <= 32'd0;
                    endcase
                end else per_rdata <= 32'd0;   // cbuf comes from block RAM below
            end
        end
    end

    // RAM and cbuf data come from block RAM, valid the clock after the
    // request, which is when mem_ready is high
    reg last_ram, last_cbuf;
    always @(posedge clk) begin
        last_ram <= mem_valid && is_ram;
        last_cbuf <= mem_valid && is_cbuf;
    end
    assign cpu_rdata = last_ram ? ram_q : last_cbuf ? {16'h0000, cbuf_q} : per_rdata;

endmodule

`default_nettype wire
