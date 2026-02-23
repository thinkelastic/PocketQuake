//
// io_sdram
//
// 2019-2022 Analogue
//

module io_sdram (

input   wire            controller_clk,
input   wire            chip_clk,
input   wire            clk_90,
input   wire            reset_n,

output  reg             phy_cke,
output  wire            phy_clk,
output  wire            phy_cas,
output  wire            phy_ras,
output  wire            phy_we,
output  reg     [1:0]   phy_ba,
output  reg     [12:0]  phy_a,
inout   wire    [15:0]  phy_dq,
output  reg     [1:0]   phy_dqm,

input   wire            burst_rd, // must be synchronous to clk_ram
input   wire    [24:0]  burst_addr,
input   wire    [10:0]  burst_len,
input   wire            burst_32bit,
output  reg     [31:0]  burst_data,
output  reg             burst_data_valid,
output  reg             burst_data_done,

input   wire            burstwr,
input   wire    [24:0]  burstwr_addr,
output  reg             burstwr_ready,
input   wire            burstwr_strobe,
input   wire    [15:0]  burstwr_data,
input   wire            burstwr_done,

input   wire            word_rd, // can be from other clock domain. we synchronize these
input   wire            word_wr,
input   wire    [23:0]  word_addr,
input   wire    [31:0]  word_data,
input   wire    [3:0]   word_wstrb, // byte enables: [0]=byte0, [1]=byte1, [2]=byte2, [3]=byte3
input   wire    [2:0]   word_burst_len, // 0=single word, N=N+1 words (for CPU cache line fills)
output  reg     [31:0]  word_q,
output  reg             word_busy,
output  reg             word_q_valid  // Pulses high for one cycle when word_q data is valid
);

    // tristate for DQ
    reg             phy_dq_oe;
    assign          phy_dq = phy_dq_oe ? phy_dq_out : 16'bZZZZZZZZZZZZZZZZ;
    reg     [15:0]  phy_dq_out;

    reg     [2:0]   cmd;
assign {phy_ras, phy_cas, phy_we} = cmd;

    localparam      CMD_NOP             = 3'b111;
    localparam      CMD_ACT             = 3'b011;
    localparam      CMD_READ            = 3'b101;
    localparam      CMD_WRITE           = 3'b100;
    localparam      CMD_PRECHG          = 3'b010;
    localparam      CMD_AUTOREF         = 3'b001;
    localparam      CMD_LMR             = 3'b000;
    localparam      CMD_SELFENTER       = 3'b001;
    localparam      CMD_SELFEXIT        = 3'b111;

    localparam      CAS                 =   4'd3;   // timings are for 110MHz (9.1ns)
    localparam      TIMING_LMR          =   4'd2;   // tLMR = 2ck
    localparam      TIMING_AUTOREFRESH  =   4'd9;   // tRFC = 80ns @ 110MHz = 9 cycles (81.8ns)
    localparam      TIMING_PRECHARGE    =   4'd2;   // tRP = 15ns @ 110MHz = 2 cycles (18.2ns)
    localparam      TIMING_ACT_ACT      =   4'd7;   // tRC = 60ns @ 110MHz = 7 cycles (63.6ns)
    localparam      TIMING_ACT_RW       =   4'd2;   // tRCD = 15ns @ 110MHz = 2 cycles (18.2ns)
    localparam      TIMING_ACT_PRECHG   =   4'd5;   // tRAS = 42ns @ 110MHz = 5 cycles (45.5ns)
    localparam      TIMING_WRITE        =   4'd2;   // tWR = 2ck

    reg     [5:0]   state;

    localparam      ST_RESET            = 'd0;
    localparam      ST_BOOT_0           = 'd1;
    localparam      ST_BOOT_1           = 'd2;
    localparam      ST_BOOT_2           = 'd3;
    localparam      ST_BOOT_3           = 'd4;
    localparam      ST_BOOT_4           = 'd5;
    localparam      ST_BOOT_5           = 'd6;
    localparam      ST_IDLE             = 'd7;

    // Open-page row-hit optimization states
    localparam      ST_PRECHG_WAIT      = 'd8;   // Wait tRP after precharge (then refresh or ACT)
    localparam      ST_WRITE_HIT        = 'd9;   // DQ setup for row-hit writes

    localparam      ST_WRITE_0          = 'd20;
    localparam      ST_WRITE_1          = 'd21;
    localparam      ST_WRITE_2          = 'd22;
    localparam      ST_WRITE_3          = 'd23;
    localparam      ST_WRITE_4          = 'd24;
    localparam      ST_WRITE_5          = 'd25;
    localparam      ST_WRITE_6          = 'd26;

    localparam      ST_READ_0           = 'd30;
    localparam      ST_READ_1           = 'd31;
    localparam      ST_READ_2           = 'd32;
    localparam      ST_READ_3           = 'd33;
    localparam      ST_READ_4           = 'd34;
    localparam      ST_READ_5           = 'd35;
    localparam      ST_READ_6           = 'd36;
    localparam      ST_READ_7           = 'd37;
    localparam      ST_READ_8           = 'd38;
    localparam      ST_READ_9           = 'd39;

    localparam      ST_BURSTWR_0        = 'd46;
    localparam      ST_BURSTWR_1        = 'd47;
    localparam      ST_BURSTWR_2        = 'd48;
    localparam      ST_BURSTWR_3        = 'd49;
    localparam      ST_BURSTWR_4        = 'd50;
    localparam      ST_BURSTWR_5        = 'd51;
    localparam      ST_BURSTWR_6        = 'd52;
    localparam      ST_BURSTWR_7        = 'd53;

    localparam      ST_REFRESH_0        = 'd60;
    localparam      ST_REFRESH_1        = 'd61;


    reg     [23:0]  delay_boot;
    reg     [15:0]  dc;
    // Refresh every ~5.69us at 90MHz (512 cycles) to satisfy 8K-row SDRAM timing.
    reg     [8:0]   refresh_count;
    reg             issue_autorefresh;

    wire reset_n_s;
synch_3 s1(reset_n, reset_n_s, controller_clk);

    reg word_rd_queue;
    reg word_wr_queue;

    // Word interface - same clock domain as controller (no CDC needed)
    // word_rd/word_wr are 1-cycle pulses, use directly as triggers

    // Captured address and data registers
    // Sender must hold these stable until the operation completes (word_busy goes low)
    reg [23:0] word_addr_captured;
    reg [31:0] word_data_captured;
    reg [3:0]  word_wstrb_captured;
    reg [2:0]  word_burst_len_captured;

    reg burst_rd_queue;
    reg burstwr_queue;

    reg             word_op;
    reg             bram_op;
    reg     [24:0]  addr;
    wire    [9:0]   addr_col9_next_1 = addr[9:0] + 'h1;

    reg     [10:0]  length;
    wire    [10:0]  length_next = length - 'h1;
    reg             enable_dq_read, enable_dq_read_1, enable_dq_read_2, enable_dq_read_3, enable_dq_read_4, enable_dq_read_5;
    reg             enable_dq_read_toggle;

    reg             enable_data_done, enable_data_done_1, enable_data_done_2, enable_data_done_3, enable_data_done_4;

    reg             read_newrow;
    reg             read_cmd_issued;    // Full-page burst: track if READ issued for current row
    reg             burstwr_newrow;

    // Open-page: single-bank tracking (only one bank open at a time)
    reg     [1:0]   open_bank;          // Which bank is currently open
    reg     [12:0]  open_row;           // Which row is open in that bank
    reg             row_open;           // Whether any row is currently open
    reg     [3:0]   open_timer;         // Saturating tRAS counter
    reg     [1:0]   prechg_return;      // After precharge: 0=READ_0, 1=WRITE_0, 2=BURSTWR_0, 3=REFRESH_0

    // Open-page row-hit detection (combinational)
    wire    [24:0]  pending_addr      = word_addr_captured << 1;
    wire    [1:0]   pending_bank      = pending_addr[24:23];
    wire    [12:0]  pending_row       = pending_addr[22:10];
    wire            pending_row_hit   = row_open && (pending_bank == open_bank) &&
                                        (pending_row == open_row);
    wire            pending_need_prechg = row_open && ((pending_bank != open_bank) ||
                                          (pending_row != open_row));

    reg     [15:0]  phy_dq_latched;
always @(posedge controller_clk) begin
    phy_dq_latched <= phy_dq;
end


always @(*) begin
    burst_data_done <= enable_data_done_4;
end
initial begin
    state <= ST_RESET;
    phy_cke <= 0;
end
always @(posedge controller_clk) begin
    phy_dq_oe <= 0;
    cmd <= CMD_NOP;
    dc <= dc + 1'b1;

    // (word_rd/word_wr are same clock domain - no edge detection needed)

    burst_data_valid <= 0;
    burstwr_ready <= 0;
    word_q_valid <= 0;  // Clear each cycle, set when read data is captured

    enable_dq_read_5 <= enable_dq_read_4;
    enable_dq_read_4 <= enable_dq_read_3;
    enable_dq_read_3 <= enable_dq_read_2;
    enable_dq_read_2 <= enable_dq_read_1;
    enable_dq_read_1 <= enable_dq_read;
    enable_dq_read <= 0;

    enable_data_done_4 <= enable_data_done_3;
    enable_data_done_3 <= enable_data_done_2;
    enable_data_done_2 <= enable_data_done_1;
    enable_data_done_1 <= enable_data_done;
    enable_data_done <= 0;

    // Open-page tRAS timer: saturating increment each cycle
    if (row_open && open_timer < TIMING_ACT_PRECHG)
        open_timer <= open_timer + 4'd1;

    // delayed by CAS latency for reads
    // CAS=3 means data appears 3 cycles after READ command
    // enable_dq_read_4 = CAS + 1 (for input register latency)
    if(enable_dq_read_4) begin
        enable_dq_read_toggle <= ~enable_dq_read_toggle;

        if(word_op) begin
            if(~enable_dq_read_toggle) begin
                // First read from low address: contains low 16 bits (little-endian)
                word_q[15:0] <= phy_dq_latched;
            end else begin
                // Second read from high address: contains high 16 bits, word complete
                word_q[31:16] <= phy_dq_latched;
                word_q_valid <= 1;  // Signal that word_q is valid
            end

        end else begin
            if(burst_32bit) begin
                // accumulate 32-bit word from BL=2 burst
                if(~enable_dq_read_toggle) begin
                    // First beat: low 16 bits
                    burst_data[15:0] <= phy_dq_latched;
                end else begin
                    // Second beat: high 16 bits
                    burst_data[31:16] <= phy_dq_latched;
                    burst_data_valid <= 1;
                end
            end else begin
                // 16-bit
                burst_data[15:0] <= phy_dq_latched;
                burst_data_valid <= 1;
            end
        end
    end


    case(state)
    ST_RESET: begin
        phy_cke <= 0;
        cmd <= CMD_NOP;
        delay_boot <= 0;
        issue_autorefresh <= 0;
        phy_dqm <= 2'b00;
        read_cmd_issued <= 0;

        state <= ST_BOOT_0;
    end
    ST_BOOT_0: begin
        delay_boot <= delay_boot + 1'b1;

        if(delay_boot == 30000-16) phy_cke <= 1;
        if(delay_boot == 30000) begin
            // >=200us power-up delay (30000 cycles @90MHz ~= 333us)
            dc <= 0;

            // precharge all
            cmd <= CMD_PRECHG;
            phy_a[10] = 1'b1;

            state <= ST_BOOT_1;
        end
    end
    ST_BOOT_1: begin
        if(dc == TIMING_PRECHARGE-1) begin
            dc <= 0;
            cmd <= CMD_AUTOREF;

            state <= ST_BOOT_2;
        end
    end
    ST_BOOT_2: begin
        if(dc == TIMING_AUTOREFRESH-1) begin
            dc <= 0;
            cmd <= CMD_AUTOREF;

            state <= ST_BOOT_3;
        end
    end
    ST_BOOT_3: begin
        if(dc == TIMING_AUTOREFRESH-1) begin
            dc <= 0;
            cmd <= CMD_LMR;
            phy_ba <= 'b00;
            phy_a <= 13'b000000_011_0_001; // CAS 3, burst length 2, sequential

            state <= ST_BOOT_4;
        end
    end
    ST_BOOT_4: begin
        if(dc == TIMING_LMR-1) begin
            dc <= 0;
            cmd <= CMD_LMR;
            phy_ba <= 'b10; // Extended mode register
            phy_a <= 13'b00000_010_00_000; // Self refresh coverage: All banks,
            // drive strength = 3'b010 (alliance, 50%)
            state <= ST_BOOT_5;
        end
    end
    ST_BOOT_5: begin
        if(dc == TIMING_LMR-1) begin
            phy_dqm <= 2'b00;

            state <= ST_IDLE;
        end
    end


    ST_IDLE: begin

        read_newrow <= 0;
        word_busy <= 0;
        word_op <= 0;

        if(issue_autorefresh) begin
            word_busy <= 1;
            if(row_open) begin
                // Precharge open bank before refresh
                dc <= 0;
                cmd <= CMD_PRECHG;
                phy_ba <= open_bank;
                phy_a[10] <= 1'b0;
                row_open <= 0;
                prechg_return <= 2'd3;  // 3 = refresh
                state <= ST_PRECHG_WAIT;
            end else begin
                state <= ST_REFRESH_0;
            end
        end else
        if(word_rd_queue) begin
            word_rd_queue <= 0;
            word_op <= 1;
            addr <= pending_addr;
            word_busy <= 1;
            length <= {8'd0, word_burst_len_captured} + 11'd1;

            if(pending_row_hit) begin
                // ROW HIT: skip ACT+tRCD, go directly to READ
                phy_ba <= pending_bank;
                enable_dq_read_toggle <= 0;
                state <= ST_READ_2;
            end else if(pending_need_prechg) begin
                // ROW MISS or DIFFERENT BANK: precharge, then ACT
                dc <= 0;
                cmd <= CMD_PRECHG;
                phy_ba <= open_bank;
                phy_a[10] <= 1'b0;
                row_open <= 0;
                prechg_return <= 2'd0;
                state <= ST_PRECHG_WAIT;
            end else begin
                // NO ROW OPEN: normal ACT path
                state <= ST_READ_0;
            end
        end else
        if(word_wr_queue) begin
            word_wr_queue <= 0;
            word_op <= 1;
            addr <= pending_addr;
            word_busy <= 1;

            if(pending_row_hit) begin
                // ROW HIT: 1-cycle DQ setup, then WRITE
                phy_ba <= pending_bank;
                state <= ST_WRITE_HIT;
            end else if(pending_need_prechg) begin
                // ROW MISS or DIFFERENT BANK: precharge, then ACT
                dc <= 0;
                cmd <= CMD_PRECHG;
                phy_ba <= open_bank;
                phy_a[10] <= 1'b0;
                row_open <= 0;
                prechg_return <= 2'd1;
                state <= ST_PRECHG_WAIT;
            end else begin
                // NO ROW OPEN: normal ACT path
                state <= ST_WRITE_0;
            end
        end else
        if(burst_rd_queue) begin
            burst_rd_queue <= 0;
            addr <= burst_addr;
            length <= burst_len;
            word_busy <= 1;
            if(row_open) begin
                // Precharge open bank before burst ACT
                dc <= 0;
                cmd <= CMD_PRECHG;
                phy_ba <= open_bank;
                phy_a[10] <= 1'b0;
                row_open <= 0;
                prechg_return <= 2'd0;
                state <= ST_PRECHG_WAIT;
            end else begin
                state <= ST_READ_0;
            end
        end else
        if(burstwr_queue) begin
            burstwr_queue <= 0;
            addr <= burstwr_addr;
            word_busy <= 1;
            if(row_open) begin
                // Precharge open bank before burst ACT
                dc <= 0;
                cmd <= CMD_PRECHG;
                phy_ba <= open_bank;
                phy_a[10] <= 1'b0;
                row_open <= 0;
                prechg_return <= 2'd2;
                state <= ST_PRECHG_WAIT;
            end else begin
                state <= ST_BURSTWR_0;
            end
        end

    end


    // Open-page: wait tRP after precharge, then dispatch
    ST_PRECHG_WAIT: begin
        if(dc == TIMING_PRECHARGE-1) begin
            case(prechg_return)
                2'd0: state <= ST_READ_0;
                2'd1: state <= ST_WRITE_0;
                2'd2: state <= ST_BURSTWR_0;
                2'd3: state <= ST_REFRESH_0;
            endcase
        end
    end

    // Open-page: row-hit write DQ setup (1 cycle for tristate turn-on)
    ST_WRITE_HIT: begin
        phy_a[10] <= 1'b0;
        phy_dq_oe <= 1;
        state <= ST_WRITE_2;
    end


    ST_WRITE_0: begin
        dc <= 0;

        phy_ba <= addr[24:23];
        phy_a <= addr[22:10]; // A0-A12 row address
        cmd <= CMD_ACT;

        // Track open row
        row_open <= 1;
        open_bank <= addr[24:23];
        open_row <= addr[22:10];
        open_timer <= 4'd0;

        state <= ST_WRITE_1;
    end
    ST_WRITE_1: begin
        phy_a[10] <= 1'b0; // no auto precharge
        if(dc == TIMING_ACT_RW-1) begin
            dc <= 0;
            phy_dq_oe <= 1;
            state <= ST_WRITE_2;
        end
    end
    ST_WRITE_2: begin
        dc <= 0;

        phy_a <= addr[9:0]; // A0-A9 column address
        cmd <= CMD_WRITE;
        phy_dq_oe <= 1;
        phy_dq_out <= word_data_captured[15:0];  // First BL=2 beat: low half (little-endian)
        phy_dqm <= ~word_wstrb_captured[1:0];    // Byte enables for bytes 0,1

        state <= ST_WRITE_3;
    end
    ST_WRITE_3: begin
        dc <= 0;

        // Second BL=2 beat - SDRAM auto-accepts, no WRITE command needed
        phy_dq_oe <= 1;
        phy_dq_out <= word_data_captured[31:16]; // Second BL=2 beat: high half (little-endian)
        phy_dqm <= ~word_wstrb_captured[3:2];    // Byte enables for bytes 2,3

        state <= ST_WRITE_4;
    end
    ST_WRITE_4: begin
        phy_dqm <= 2'b00;  // Clear byte masks
        if(dc == TIMING_WRITE-1+1) begin
            // Leave row open: skip precharge, return to IDLE
            state <= ST_IDLE;
        end
    end


    ST_READ_0: begin
        dc <= 0;

        phy_ba <= addr[24:23];
        phy_a <= addr[22:10]; // A0-A12 row address
        cmd <= CMD_ACT;

        // Track open row
        row_open <= 1;
        open_bank <= addr[24:23];
        open_row <= addr[22:10];
        open_timer <= 4'd0;

        state <= ST_READ_1;
    end
    ST_READ_1: begin
        phy_a[10] <= 1'b0; // no auto precharge
        enable_dq_read_toggle <= 0;
        if(dc == TIMING_ACT_RW-1) begin
            dc <= 0;
            state <= ST_READ_2;
        end
    end
    ST_READ_2: begin
        phy_a <= addr[9:0]; // A0-A9 column address
        cmd <= CMD_READ;

        enable_dq_read <= 1;  // First BL=2 data beat

        length <= length - 1'b1;
        addr <= addr + 2'd2;  // BL=2: skip 2 half-word addresses per READ

        // Always go to ST_READ_3 for second BL=2 data beat
        state <= ST_READ_3;
    end
    ST_READ_3: begin
        // Second BL=2 data beat
        enable_dq_read <= 1;

        if(length == 0) begin
            // All READs issued, drain pipeline
            read_newrow <= 0;
            state <= ST_READ_5;
        end else if(addr[9:0] <= 10'd1) begin
            // Near end of row, need to activate next row
            read_newrow <= 1;
            state <= ST_READ_5;
        end else begin
            // More READs needed (burst mode)
            state <= ST_READ_2;
        end
    end
    ST_READ_5: begin
        state <= ST_READ_8;
    end
    ST_READ_8: begin
        state <= ST_READ_9;
    end
    ST_READ_9: begin
        state <= ST_READ_6;// hmm do we need this
    end
    ST_READ_6: begin
        if(!read_newrow && !word_op) enable_data_done <= 1;
        dc <= 0;

        if(word_op && !read_newrow) begin
            // Word operation complete: leave row open, return to IDLE
            state <= ST_IDLE;
        end else begin
            // Burst read or row-crossing: precharge as before
            cmd <= CMD_PRECHG;
            phy_a[10] <= 0; // only precharge current bank
            row_open <= 0;
            state <= ST_READ_7;
        end
    end
    ST_READ_7: begin
        if(dc == TIMING_PRECHARGE-1) begin
            if(read_newrow)
                state <= ST_READ_0;
            else
                state <= ST_IDLE;
        end
    end

    ST_BURSTWR_0: begin
        phy_ba <= addr[24:23];
        phy_a <= addr[22:10]; // A0-A12 column address
        cmd <= CMD_ACT;
        state <= ST_BURSTWR_1;
    end
    ST_BURSTWR_1: begin
        cmd <= CMD_NOP;
        state <= ST_BURSTWR_2;
    end
    ST_BURSTWR_2: begin
        cmd <= CMD_NOP;
        state <= ST_BURSTWR_3;
    end
    ST_BURSTWR_3: begin
        burstwr_ready <= 1;
        burstwr_newrow <= 0;

        if(burstwr_strobe) begin

            phy_a <= addr[9:0]; // A0-A9 row address
            cmd <= CMD_WRITE;
            phy_dq_oe <= 1;
            phy_dq_out <= burstwr_data;

            addr <= addr + 1'b1;
            /*if(addr_col9_next_1 == 9'h0) begin
                burstwr_ready <= 0;
                burstwr_newrow <= 1;
                state <= ST_BURSTWR_4;
            end */
        end
        if(burstwr_strobe | burstwr_done) begin
            burstwr_newrow <= 0;
            state <= ST_BURSTWR_4;
        end
    end
    ST_BURSTWR_4: begin
        cmd <= CMD_NOP;
        phy_dqm <= 2'b11;  // Mask unwanted second BL=2 data beat
        state <= ST_BURSTWR_5;
    end
    ST_BURSTWR_5: begin
        cmd <= CMD_PRECHG;
        phy_a[10] <= 0; // only precharge current bank
        phy_dqm <= 2'b00;  // Restore DQM for future operations
        row_open <= 0;  // Track bank close
        state <= ST_BURSTWR_6;
    end
    ST_BURSTWR_6: begin
        cmd <= CMD_NOP;
        state <= ST_BURSTWR_7;
    end
    ST_BURSTWR_7: begin
        cmd <= CMD_NOP;
        state <= ST_IDLE;
        if(burstwr_newrow) begin
            state <= ST_BURSTWR_0;
            if(issue_autorefresh) begin
                state <= ST_REFRESH_0;
            end
        end
    end


    ST_REFRESH_0: begin
        // autorefresh
        issue_autorefresh <= 0;

        cmd <= CMD_AUTOREF;
        dc <= 0;
        state <= ST_REFRESH_1;
    end
    ST_REFRESH_1: begin
        if(dc == TIMING_AUTOREFRESH-1)  begin
            state <= ST_IDLE;
            if(burstwr_newrow) begin
                state <= ST_BURSTWR_0;
            end
        end
    end

    endcase


    // catch incoming events if fsm is busy
    // Same clock domain - capture directly on pulse
    if(word_wr) begin
        word_wr_queue <= 1;
        word_addr_captured <= word_addr;
        word_data_captured <= word_data;
        word_wstrb_captured <= word_wstrb;
    end else if(word_rd) begin
        word_rd_queue <= 1;
        word_addr_captured <= word_addr;
        word_burst_len_captured <= word_burst_len;
    end
    if(burst_rd) begin
        burst_rd_queue <= 1;
    end
    if(burstwr) begin
        burstwr_queue <= 1;
    end

    // autorefresh generator
    refresh_count <= refresh_count + 1'b1;
    if(&refresh_count) begin
        // every 5.689us @90MHz (512 cycles)
        // 8192 refreshes / 64ms requires <=7.8125us average interval
        refresh_count <= 0;
        issue_autorefresh <= 1;

    end

    if(~reset_n_s) begin
        // reset
        state <= ST_RESET;
        refresh_count <= 0;
        word_rd_queue <= 0;
        word_wr_queue <= 0;
        burst_rd_queue <= 0;
        burstwr_queue <= 0;
        word_addr_captured <= 0;
        word_data_captured <= 0;
        word_wstrb_captured <= 0;
        word_burst_len_captured <= 0;
        word_q <= 0;
        word_busy <= 0;
        word_q_valid <= 0;
        enable_dq_read_toggle <= 0;
        row_open <= 0;
        prechg_return <= 2'd0;
    end
end

assign phy_clk = chip_clk;

endmodule
