// SD card model for simulating sdhost.v (not synthesizable)
//
// A version 2.0 high-capacity card in SD bus mode: start-up (CMD0, CMD8,
// ACMD41, CMD2, CMD3), CSD, select, ACMD6 bus width, CMD13, CMD16, single
// and multiple block reads and writes, and CMD12. Commands with a bad CRC,
// and commands it doesn't know or that don't belong in its state, get no
// response, as on a real card.
//
// It changes CMD and DAT after the clock falls: a line that changes is X
// from TOH to ODLY after the falling edge (default speed: tOH 0, tODLY at
// most 14 ns), so a host sampling inside that window gets X. It samples the
// host's CMD and DAT as the clock rises. It reports, as
// errors:
//   - the clock faster than 400 kHz before the card has an address (CMD3),
//     or than 25 MHz after;
//   - host changes on CMD or DAT within TISU before or TIH after a rising
//     clock edge (5 ns each at default speed);
//   - X or Z sampled from the host;
//   - commands with a bad CRC, end bit or transmission bit;
//   - fewer than 8 clocks between a command (with no response) or a
//     response and the next command's start bit (NCC).
// The testbench reads `errors`.
//
// Test hooks: corrupt_read (set it, and the next read block has a bad CRC
// on one lane), reject_write (the next written block gets "CRC error" in its
// CRC status token and isn't stored), busy_clks (write busy time in clocks).
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

`timescale 1ns / 1ps

module sdcard_model #(
    parameter MEM_BLOCKS   = 1024,   // blocks stored: 512 KB
    parameter CARD_BLOCKS  = MEM_BLOCKS,   // blocks the card reports (multiple of 1024);
                                     // those past MEM_BLOCKS read as 0
    parameter IMAGE        = "",     // $readmemh file for the stored blocks
    parameter real ODLY    = 14.0,   // outputs settled this long after the clock falls
    parameter real TOH     = 0.0,    // and unchanged until this long after
    parameter real TISU    = 5.0,
    parameter real TIH     = 5.0,
    parameter NCR          = 2,      // clocks from command end to response
    parameter NAC          = 8,      // clocks before a read block
    parameter ACMD41_TRIES = 3       // ACMD41 calls before the card is ready
) (
    input wire       sd_clk,
    inout wire       cmd,
    inout wire [3:0] dat
);

    integer errors = 0;
    reg     corrupt_read = 0;
    reg     reject_write = 0;
    integer busy_clks = 200;
    integer reads_done = 0;
    integer writes_done = 0;

    reg [7:0] mem [0:MEM_BLOCKS*512-1];
    initial if (IMAGE != "") $readmemh(IMAGE, mem);

    function [7:0] mem_rd;
        input integer a;
        mem_rd = (a < MEM_BLOCKS * 512) ? mem[a] : 8'h00;
    endfunction

    // ------------------------------------------------------------------
    // Pins

    // What the card means to drive, set as the clock falls...
    reg       cmd_drv = 0;
    reg       cmd_o = 1;
    reg [3:0] dat_drv = 4'h0;
    reg [3:0] dat_o = 4'hF;
    // ...and what's on the pins: {CMD, DAT3..0}
    reg [4:0] pin_v = 5'h1F;
    reg [4:0] pin_e = 5'h00;
    reg [4:0] pin_x = 5'h00;
    wire      cmd_drv_d = pin_e[4] | pin_x[4];
    wire [3:0] dat_drv_d = pin_e[3:0] | pin_x[3:0];

    always @(negedge sd_clk) begin : outputs
        reg [4:0] tv, te, chg;
        #0.001;   // after the card's own processes have set cmd_o etc.
        tv = {cmd_o, dat_o};
        te = {cmd_drv, dat_drv};
        chg = ((tv ^ pin_v) & (te | pin_e)) | (te ^ pin_e);
        if (chg != 5'h00) begin
            if (TOH > 0.0) #(TOH);
            pin_x = chg;
            #(ODLY - TOH);
            pin_v = tv;
            pin_e = te;
            pin_x = 5'h00;
        end
    end

    assign cmd = pin_x[4] ? 1'bx : pin_e[4] ? pin_v[4] : 1'bz;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : lane
            assign dat[g] = pin_x[g] ? 1'bx : pin_e[g] ? pin_v[g] : 1'bz;
        end
    endgenerate

    task fail;
        input [8*80-1:0] msg;
        begin
            errors = errors + 1;
            $display("%t SD card: %0s", $realtime, msg);
        end
    endtask

    // ------------------------------------------------------------------
    // Card state

    localparam S_IDLE = 0, S_READY = 1, S_IDENT = 2, S_STBY = 3, S_TRAN = 4,
               S_DATA = 5, S_RCV = 6, S_PRG = 7;

    integer   state = S_IDLE;
    reg       app = 0;
    integer   acmd41_count = 0;
    reg [15:0] rca = 16'h4D2A;
    reg       bus4 = 0;
    reg [31:0] errbits = 0;     // card status error bits, cleared when sent

    function [31:0] card_status;
        input dummy;
        card_status = errbits | (state << 9) | 32'h100 | (app ? 32'h20 : 32'h0);
    endfunction

    // ------------------------------------------------------------------
    // Clock and input timing checks

    realtime last_edge = -1.0e6;
    realtime last_rise = -1.0e6;
    realtime last_cmd_chg = -1.0e6;
    realtime last_dat_chg = -1.0e6;
    realtime last_card_act = -1.0e6;  // the card changed what it drives

    reg last_clk_val = 1'bx;
    always @(sd_clk) begin
        if (last_clk_val === 1'bx || sd_clk === 1'bx) begin
            // reset: not a real edge
        end else if (state < S_STBY) begin
            if ($realtime - last_edge < 1249.0)
                fail("clock faster than 400 kHz before CMD3");
        end else if ($realtime - last_edge < 19.9) begin
            fail("clock faster than 25 MHz");
        end
        if (last_clk_val !== 1'bx && sd_clk !== 1'bx) last_edge = $realtime;
        last_clk_val = sd_clk;
    end

    always @(cmd_drv or dat_drv) last_card_act = $realtime;

    function card_quiet;   // the card isn't driving and hasn't just stopped
        input dummy;
        card_quiet = cmd_drv == 0 && cmd_drv_d == 0 && dat_drv == 0 && dat_drv_d == 0 &&
                     $realtime - last_card_act > ODLY + 0.5;
    endfunction

    always @(posedge sd_clk) begin
        last_rise = $realtime;
        if (!cmd_drv_d && $realtime - last_cmd_chg < TISU && card_quiet(0))
            fail("CMD changed within setup time");
        if (dat_drv_d == 0 && $realtime - last_dat_chg < TISU && card_quiet(0))
            fail("DAT changed within setup time");
    end

    always @(cmd) begin
        last_cmd_chg = $realtime;
        if (card_quiet(0) && $realtime - last_rise < TIH)
            fail("CMD changed within hold time");
    end

    always @(dat) begin
        last_dat_chg = $realtime;
        if (card_quiet(0) && $realtime - last_rise < TIH)
            fail("DAT changed within hold time");
    end

    // ------------------------------------------------------------------
    // CRCs

    function [6:0] crc7_40;
        input [39:0] d;
        integer i;
        reg [6:0] c;
        reg fb;
        begin
            c = 7'd0;
            for (i = 39; i >= 0; i = i - 1) begin
                fb = c[6] ^ d[i];
                c = {c[5:0], 1'b0};
                if (fb) c = c ^ 7'h09;
            end
            crc7_40 = c;
        end
    endfunction

    function [15:0] crc16_bit;
        input [15:0] c;
        input b;
        crc16_bit = {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h1021 : 16'h0000);
    endfunction

    // ------------------------------------------------------------------
    // Commands and responses

    reg [47:0] cf;
    reg        cmd_ok;
    integer    clocks = 0;
    integer    last_end = -100;   // clock of the last command or response end bit
    always @(posedge sd_clk) clocks = clocks + 1;   // read it just after an edge

    task get_cmd;
        integer i;
        begin
            @(posedge sd_clk);
            while (cmd !== 1'b0) begin
                if (cmd !== 1'b1 && card_quiet(0)) fail("CMD is X or Z between commands");
                @(posedge sd_clk);
            end
            #0.002;   // after this edge is counted
            if (clocks - last_end < 9) fail("fewer than 8 clocks before a command (NCC)");
            cf[47] = 1'b0;
            for (i = 46; i >= 0; i = i - 1) begin
                @(posedge sd_clk);
                cf[i] = cmd;
            end
            #0.002;
            last_end = clocks;
            cmd_ok = 1;
            if (^cf === 1'bx) begin
                fail("X or Z in a command");
                cmd_ok = 0;
            end else if (cf[46] !== 1'b1 || cf[0] !== 1'b1) begin
                fail("bad transmission or end bit in a command");
                cmd_ok = 0;
            end else if (crc7_40(cf[47:8]) !== cf[7:1]) begin
                fail("bad CRC in a command");
                errbits = errbits | 32'h0080_0000;
                cmd_ok = 0;
            end
        end
    endtask

    task send_resp;
        input integer nbits;
        input [135:0] r;
        integer i;
        begin
            repeat (NCR) @(posedge sd_clk);
            for (i = nbits - 1; i >= 0; i = i - 1) begin
                @(negedge sd_clk);
                cmd_drv = 1;
                cmd_o = r[i];
            end
            @(posedge sd_clk);      // the host samples the end bit
            #0.002;
            last_end = clocks;
            @(negedge sd_clk);
            cmd_drv = 0;
            cmd_o = 1;
        end
    endtask

    task r1;
        input [5:0] idx;
        reg [39:0] f;
        begin
            f = {2'b00, idx, card_status(0)};
            errbits = 0;
            send_resp(48, {88'd0, f, crc7_40(f), 1'b1});
        end
    endtask

    task busy_dat0;   // R1b busy after the response
        input integer n;
        begin
            @(negedge sd_clk);
            dat_drv = 4'h1;
            dat_o = 4'hE;
            repeat (n) @(negedge sd_clk);
            dat_o = 4'hF;
            @(negedge sd_clk);
            dat_drv = 4'h0;
        end
    endtask

    // CID and CSD (version 2.0, C_SIZE 0: 512 KB). Bit 0 is the end bit
    // position, sent as part of the 136-bit response.
    wire [127:0] cid = {8'h03, "DN", "DIFNF", 8'h10, 32'h12345678, 4'h0, 12'h1A7, 7'h00, 1'b1};
    reg [127:0] csd;
    initial begin
        csd = 128'd0;
        csd[127:126] = 2'b01;        // CSD version 2.0
        csd[111:104] = 8'h0E;        // TAAC
        csd[103:96]  = 8'h32;        // TRAN_SPEED: 25 MHz
        csd[95:84]   = 12'h5B5;      // CCC
        csd[83:80]   = 4'h9;         // READ_BL_LEN: 512
        csd[69:48]   = CARD_BLOCKS / 1024 - 1;  // C_SIZE: (C_SIZE+1) x 512 KB
        csd[46]      = 1'b1;         // ERASE_BLK_EN
        csd[45:39]   = 7'h7F;        // SECTOR_SIZE
        csd[28:26]   = 3'b010;       // R2W_FACTOR
        csd[25:22]   = 4'h9;         // WRITE_BL_LEN: 512
        csd[0]       = 1'b1;
    end

    // ------------------------------------------------------------------
    // Data transfers

    event   rd_ev;
    event   wr_ev;
    integer rd_addr;
    reg     rd_multi;
    reg     rd_stop = 0;
    integer wr_addr;
    reg     wr_multi;
    reg     wr_stop = 0;
    reg     wr_busy_now = 0;

    task cmd_process;
        reg [5:0]  idx;
        reg [31:0] a;
        reg [39:0] f;
        begin
            get_cmd;
            idx = cf[45:40];
            a = cf[39:8];
            if (!cmd_ok) begin
                app = 0;
            end else if (app) begin
                app = 0;
                case (idx)
                    6'd41: if (state == S_IDLE || state == S_READY) begin
                        acmd41_count = acmd41_count + 1;
                        f = {2'b00, 6'h3F, (acmd41_count >= ACMD41_TRIES), 1'b1, 6'h00, 24'hFF8000};
                        send_resp(48, {88'd0, f, 7'h7F, 1'b1});
                        if (acmd41_count >= ACMD41_TRIES) state = S_READY;
                    end
                    6'd6: if (state == S_TRAN) begin
                        bus4 = (a[1:0] == 2'b10);
                        app = 1;    // R1 for an ACMD shows APP_CMD
                        r1(idx);
                        app = 0;
                    end
                    default: errbits = errbits | 32'h0040_0000;
                endcase
            end else begin
                case (idx)
                    6'd0: begin
                        state = S_IDLE;
                        acmd41_count = 0;
                        bus4 = 0;
                    end
                    6'd8: if (state == S_IDLE) begin
                        f = {2'b00, 6'd8, 20'd0, a[11:0]};
                        send_resp(48, {88'd0, f, crc7_40(f), 1'b1});
                    end
                    6'd55: begin
                        app = 1;
                        r1(idx);
                    end
                    6'd2: if (state == S_READY) begin
                        send_resp(136, {2'b00, 6'h3F, cid});
                        state = S_IDENT;
                    end
                    6'd3: if (state == S_IDENT || state == S_STBY) begin
                        f = {2'b00, 6'd3, rca, 16'h0500};
                        send_resp(48, {88'd0, f, crc7_40(f), 1'b1});
                        state = S_STBY;
                    end
                    6'd9: if (state == S_STBY && a[31:16] == rca) begin
                        send_resp(136, {2'b00, 6'h3F, csd});
                    end
                    6'd7: begin
                        if (a[31:16] == rca && state == S_STBY) begin
                            r1(idx);
                            state = S_TRAN;
                            busy_dat0(8);
                        end else if (a[31:16] != rca && state == S_TRAN) begin
                            state = S_STBY;   // deselected: no response
                        end
                    end
                    6'd13: if (state >= S_STBY && a[31:16] == rca) r1(idx);
                    6'd16: if (state == S_TRAN) r1(idx);
                    6'd17, 6'd18: if (state == S_TRAN) begin
                        if (a + (idx == 6'd18 ? 1 : 0) > CARD_BLOCKS - 1) begin
                            errbits = errbits | 32'h8000_0000;
                            r1(idx);
                        end else begin
                            r1(idx);
                            rd_addr = a;
                            rd_multi = (idx == 6'd18);
                            rd_stop = 0;
                            state = S_DATA;
                            -> rd_ev;
                        end
                    end
                    6'd24, 6'd25: if (state == S_TRAN) begin
                        if (a > CARD_BLOCKS - 1) begin
                            errbits = errbits | 32'h8000_0000;
                            r1(idx);
                        end else begin
                            r1(idx);
                            wr_addr = a;
                            wr_multi = (idx == 6'd25);
                            wr_stop = 0;
                            state = S_RCV;
                            -> wr_ev;
                        end
                    end
                    6'd12: if (state == S_DATA || state == S_RCV || state == S_PRG) begin
                        rd_stop = 1;
                        wr_stop = 1;
                        r1(idx);
                        // The write process holds DAT0 busy while it programs
                    end
                    default: errbits = errbits | 32'h0040_0000;
                endcase
            end
        end
    endtask

    initial begin
        #1;
        forever cmd_process;
    end

    // Read: start bit, data (byte 0 first, high nibble or bit first),
    // CRC16 per lane, end bit
    task send_block;
        input integer b;
        integer   i, k, nb, lanes;
        reg [15:0] c [0:3];
        reg [7:0] by;
        reg [3:0] v;
        reg       stop;
        begin
            stop = 0;
            lanes = bus4 ? 4 : 1;
            for (k = 0; k < 4; k = k + 1) c[k] = 16'd0;
            @(negedge sd_clk);
            if (rd_stop) stop = 1;
            if (!stop) begin
                dat_drv = bus4 ? 4'hF : 4'h1;
                dat_o = 4'h0;
            end
            nb = 0;
            for (i = 0; i < 512 && !stop; i = i + 1) begin
                by = mem_rd(b * 512 + i);
                for (k = (bus4 ? 1 : 7); k >= 0 && !stop; k = k - 1) begin
                    @(negedge sd_clk);
                    if (rd_stop) stop = 1;
                    else begin
                        v = bus4 ? (k ? by[7:4] : by[3:0]) : {3'b111, by[k]};
                        dat_o = v;
                        c[0] = crc16_bit(c[0], v[0]);
                        if (bus4) begin
                            c[1] = crc16_bit(c[1], v[1]);
                            c[2] = crc16_bit(c[2], v[2]);
                            c[3] = crc16_bit(c[3], v[3]);
                        end
                    end
                end
            end
            if (!stop && corrupt_read) begin
                c[lanes - 1] = c[lanes - 1] ^ 16'h0001;
                corrupt_read = 0;
            end
            for (i = 15; i >= 0 && !stop; i = i - 1) begin
                @(negedge sd_clk);
                if (rd_stop) stop = 1;
                else dat_o = {c[3][i], c[2][i], c[1][i], c[0][i]} | (bus4 ? 4'h0 : 4'hE);
            end
            if (!stop) begin
                @(negedge sd_clk);
                dat_o = 4'hF;
            end
            @(negedge sd_clk);
            dat_drv = 4'h0;
            dat_o = 4'hF;
            if (!stop) reads_done = reads_done + 1;
        end
    endtask

    initial begin : reader
        integer blk;
        forever begin
            @(rd_ev);
            blk = rd_addr;
            repeat (NAC) @(posedge sd_clk);
            while (!rd_stop) begin
                send_block(blk);
                blk = blk + 1;
                if (!rd_multi) rd_stop = 1;
                else if (blk >= CARD_BLOCKS) begin
                    rd_stop = 1;
                    errbits = errbits | 32'h8000_0000;
                end else if (!rd_stop) repeat (NAC) @(posedge sd_clk);
            end
            if (state == S_DATA) state = S_TRAN;
        end
    end

    // Write: start bit, data, CRC16 per lane, end bit; then the CRC status
    // token on DAT0 two clocks later, then busy while programming
    reg [7:0] wbuf [0:511];

    initial begin : writer
        integer blk, i, k, nlanes;
        reg [15:0] c [0:3];
        reg [3:0]  v;
        reg [7:0]  by;
        reg        good;
        reg        reject;
        forever begin
            @(wr_ev);
            blk = wr_addr;
            while (!wr_stop) begin
                // Wait for a start bit, or CMD12
                @(posedge sd_clk);
                while (dat[0] !== 1'b0 && !wr_stop) @(posedge sd_clk);
                if (!wr_stop) begin
                    nlanes = bus4 ? 4 : 1;
                    if (bus4 && dat !== 4'h0) fail("write start bit not on all four lanes");
                    for (k = 0; k < 4; k = k + 1) c[k] = 16'd0;
                    for (i = 0; i < 512; i = i + 1) begin
                        by = 8'd0;
                        for (k = 0; k < (bus4 ? 2 : 8); k = k + 1) begin
                            @(posedge sd_clk);
                            v = dat;
                            if ((bus4 ? ^v : v[0]) === 1'bx) fail("X or Z in write data");
                            if (bus4) by = {by[3:0], v};
                            else by = {by[6:0], v[0]};
                            c[0] = crc16_bit(c[0], v[0]);
                            if (bus4) begin
                                c[1] = crc16_bit(c[1], v[1]);
                                c[2] = crc16_bit(c[2], v[2]);
                                c[3] = crc16_bit(c[3], v[3]);
                            end
                        end
                        wbuf[i] = by;
                    end
                    for (i = 0; i < 16; i = i + 1) begin
                        @(posedge sd_clk);
                        v = dat;
                        c[0] = crc16_bit(c[0], v[0]);
                        if (bus4) begin
                            c[1] = crc16_bit(c[1], v[1]);
                            c[2] = crc16_bit(c[2], v[2]);
                            c[3] = crc16_bit(c[3], v[3]);
                        end
                    end
                    @(posedge sd_clk);
                    v = dat;
                    good = (c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 0) &&
                           (bus4 ? v === 4'hF : v[0] === 1'b1);
                    if (!good) fail("write block with a bad CRC or end bit");
                    reject = reject_write || !good;
                    reject_write = 0;
                    // CRC status token, two clocks after the end bit
                    @(negedge sd_clk);
                    @(negedge sd_clk);
                    dat_drv = 4'h1;
                    dat_o = 4'hE;                  // start bit
                    @(negedge sd_clk); dat_o = {3'b111, 1'b0};
                    @(negedge sd_clk); dat_o = {3'b111, reject ? 1'b0 : 1'b1};
                    @(negedge sd_clk); dat_o = {3'b111, reject ? 1'b1 : 1'b0};
                    @(negedge sd_clk); dat_o = 4'hF;   // end bit
                    if (!reject) begin
                        state = S_PRG;
                        if (blk < MEM_BLOCKS)
                            for (i = 0; i < 512; i = i + 1) mem[blk * 512 + i] = wbuf[i];
                        @(negedge sd_clk); dat_o = 4'hE;   // busy
                        repeat (busy_clks) @(negedge sd_clk);
                        dat_o = 4'hF;
                        writes_done = writes_done + 1;
                        blk = blk + 1;
                    end
                    @(negedge sd_clk);
                    dat_drv = 4'h0;
                    if (reject && wr_multi) begin
                        wait (wr_stop);     // ignore the host until CMD12
                    end else if (reject || !wr_multi) begin
                        wr_stop = 1;
                    end else begin
                        state = S_RCV;
                    end
                end
            end
            state = S_TRAN;
        end
    end

endmodule
