// PSRAM Controller wrapper for VexRiscv CPU
// Provides 32-bit word interface using two 16-bit async PSRAM accesses
// Uses the psram.sv module from analogue-pocket-utils

`default_nettype none

module psram_controller #(
    parameter CLOCK_SPEED = 48.0  // MHz - same as CPU/SDRAM for simple integration
) (
    input wire clk,
    input wire reset_n,

    // CPU 32-bit word interface
    input wire         word_rd,
    input wire         word_wr,
    input wire  [21:0] word_addr,   // 22-bit word address (4MB word = 16MB byte addressable)
    input wire  [31:0] word_data,
    input wire  [3:0]  word_wstrb,  // Byte enables: [0]=byte0, [1]=byte1, [2]=byte2, [3]=byte3
    output reg  [31:0] word_q,
    output reg         word_busy,
    output reg         word_q_valid,  // Pulses when read data is valid

    // PSRAM physical signals
    output wire [21:16] cram_a,
    inout  wire [15:0]  cram_dq,
    input  wire         cram_wait,
    output wire         cram_clk,
    output wire         cram_adv_n,
    output wire         cram_cre,
    output wire         cram_ce0_n,
    output wire         cram_ce1_n,
    output wire         cram_oe_n,
    output wire         cram_we_n,
    output wire         cram_ub_n,
    output wire         cram_lb_n,

    // BCR configuration pass-through (directly to psram.sv)
    input wire          config_en,
    input wire  [15:0]  config_data,
    input wire          config_bank_sel,

    // Sync burst read interface
    input wire          burst_rd,           // Start sync burst read (single-cycle pulse)
    input wire  [5:0]   burst_len,          // 32-bit words minus 1 (max 31, i.e. 32 words = 64 halfwords)
    output reg          burst_rdata_valid,  // Pulses for each assembled 32-bit word
    output reg  [31:0]  burst_rdata,

    // Raw psram.sv busy (for BCR init FSM — bypasses word_busy)
    output wire         raw_busy,

    // Debug pass-through from psram.sv
    output wire         dbg_wait_seen,
    output wire [15:0]  dbg_wait_cycles,
    output wire [15:0]  dbg_burst_count,
    output wire [15:0]  dbg_stale_count
);

// State machine
localparam [3:0] ST_IDLE        = 4'd0;
// Async write states (unchanged)
localparam [3:0] ST_WR_LO_START = 4'd1;
localparam [3:0] ST_WR_LO_BUSY  = 4'd2;
localparam [3:0] ST_WR_LO_WAIT  = 4'd3;
localparam [3:0] ST_WR_HI_START = 4'd4;
localparam [3:0] ST_WR_HI_BUSY  = 4'd5;
localparam [3:0] ST_WR_HI_WAIT  = 4'd6;
localparam [3:0] ST_DONE        = 4'd7;
// Sync burst read states
localparam [3:0] ST_BURST_START = 4'd8;
localparam [3:0] ST_BURST_WAIT  = 4'd9;
localparam [3:0] ST_BURST_LO    = 4'd10;
localparam [3:0] ST_BURST_HI    = 4'd11;
localparam [3:0] ST_BURST_DONE  = 4'd12;

reg [3:0] state;
reg is_write;   // Distinguishes reads from writes in shared LO/HI states
reg [31:0] latched_data;
reg [21:0] latched_addr;
reg latched_chip_sel;
reg [3:0] latched_wstrb;
reg [5:0] burst_words_remaining;  // 32-bit words left in burst
reg burst_lo_captured;            // Low halfword captured flag

// Signals to psram module
reg psram_write_en;
reg psram_read_en;
reg [21:0] psram_addr;
reg [15:0] psram_data_in;
wire [15:0] psram_data_out;
wire psram_busy;
assign raw_busy = psram_busy;
wire psram_read_avail;
reg psram_bank_sel;
reg psram_write_high_byte;
reg psram_write_low_byte;

// Sync burst signals
reg psram_sync_burst_en;
reg [5:0] psram_sync_burst_len;

// Latched config bank_sel — must persist for the full config transaction.
// psram.sv doesn't use bank_sel until STATE_CONFIG_CRE_SETUP, several
// cycles after config_en goes low, so we latch the value and hold it
// until psram.sv completes the config write (busy falls after rising).
reg config_bank_sel_latched;
reg config_in_progress;
reg config_saw_busy;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        config_bank_sel_latched <= 1'b0;
        config_in_progress <= 1'b0;
        config_saw_busy <= 1'b0;
    end else if (config_en) begin
        config_bank_sel_latched <= config_bank_sel;
        config_in_progress <= 1'b1;
        config_saw_busy <= 1'b0;
    end else if (config_in_progress) begin
        if (psram_busy)
            config_saw_busy <= 1'b1;
        else if (config_saw_busy)
            config_in_progress <= 1'b0;  // busy rose then fell → config done
    end
end

// Instantiate the 16-bit PSRAM controller
psram #(
    .CLOCK_SPEED(CLOCK_SPEED)
) psram_inst (
    .clk(clk),

    .bank_sel(config_in_progress ? config_bank_sel_latched : psram_bank_sel),
    .addr(psram_addr),

    .write_en(psram_write_en),
    .data_in(psram_data_in),
    .write_high_byte(psram_write_high_byte),
    .write_low_byte(psram_write_low_byte),

    .read_en(psram_read_en),

    .sync_burst_en(psram_sync_burst_en),
    .sync_burst_len(psram_sync_burst_len),

    .config_en(config_en),
    .config_data(config_data),

    .read_avail(psram_read_avail),
    .data_out(psram_data_out),

    .busy(psram_busy),  // raw psram.sv busy

    // Physical signals
    .cram_a(cram_a),
    .cram_dq(cram_dq),
    .cram_wait(cram_wait),
    .cram_clk(cram_clk),
    .cram_adv_n(cram_adv_n),
    .cram_cre(cram_cre),
    .cram_ce0_n(cram_ce0_n),
    .cram_ce1_n(cram_ce1_n),
    .cram_oe_n(cram_oe_n),
    .cram_we_n(cram_we_n),
    .cram_ub_n(cram_ub_n),
    .cram_lb_n(cram_lb_n),

    .dbg_wait_seen(dbg_wait_seen),
    .dbg_wait_cycles(dbg_wait_cycles),
    .dbg_burst_count(dbg_burst_count),
    .dbg_stale_count(dbg_stale_count)
);

// Convert 22-bit word address to two 22-bit halfword addresses (for writes)
wire [21:0] latched_addr_lo = {latched_addr[20:0], 1'b0};
wire [21:0] latched_addr_hi = {latched_addr[20:0], 1'b1};

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= ST_IDLE;
        is_write <= 1'b0;
        word_busy <= 1'b0;
        word_q <= 32'b0;
        word_q_valid <= 1'b0;
        latched_data <= 32'b0;
        latched_addr <= 22'b0;
        latched_chip_sel <= 1'b0;
        latched_wstrb <= 4'b1111;
        psram_write_en <= 1'b0;
        psram_read_en <= 1'b0;
        psram_addr <= 22'b0;
        psram_data_in <= 16'b0;
        psram_bank_sel <= 1'b0;
        psram_write_high_byte <= 1'b1;
        psram_write_low_byte <= 1'b1;
        psram_sync_burst_en <= 1'b0;
        psram_sync_burst_len <= 6'b0;
        burst_words_remaining <= 6'b0;
        burst_lo_captured <= 1'b0;
        burst_rdata_valid <= 1'b0;
        burst_rdata <= 32'b0;
    end else begin
        // Default: clear single-cycle signals
        psram_write_en <= 1'b0;
        psram_read_en <= 1'b0;
        psram_sync_burst_en <= 1'b0;
        word_q_valid <= 1'b0;
        burst_rdata_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                word_busy <= 1'b0;

                if (burst_rd) begin
                    // Sync burst read: issue one sync burst for N words
                    // Each 32-bit word = 2 halfwords, so burst_len of N words = 2*(N+1)-1 halfwords
                    word_busy <= 1'b1;
                    latched_addr <= word_addr;
                    latched_chip_sel <= word_addr[21];
                    burst_words_remaining <= burst_len;
                    burst_lo_captured <= 1'b0;
                    state <= ST_BURST_START;
                end else if (word_wr || word_rd) begin
                    word_busy <= 1'b1;
                    is_write <= word_wr;
                    latched_data <= word_data;
                    latched_addr <= word_addr;
                    latched_chip_sel <= word_addr[21];
                    latched_wstrb <= word_wr ? word_wstrb : 4'b1111;
                    // Skip low half if writing with no bytes enabled there
                    if (word_wr && word_wstrb[1:0] == 2'b00)
                        state <= ST_WR_HI_START;
                    else
                        state <= ST_WR_LO_START;
                end
            end

            ST_DONE: begin
                word_busy <= 1'b0;
                state <= ST_IDLE;
            end

            // ============================================
            // Async write / async read path
            // ============================================
            ST_WR_LO_START: begin
                psram_bank_sel <= latched_chip_sel;
                psram_addr <= latched_addr_lo;
                psram_data_in <= latched_data[15:0];
                psram_write_low_byte <= latched_wstrb[0];
                psram_write_high_byte <= latched_wstrb[1];

                if (is_write)
                    psram_write_en <= 1'b1;
                else
                    psram_read_en <= 1'b1;

                state <= ST_WR_LO_BUSY;
            end

            ST_WR_LO_BUSY: begin
                if (psram_busy) begin
                    state <= ST_WR_LO_WAIT;
                end
            end

            ST_WR_LO_WAIT: begin
                if (!psram_busy) begin
                    if (!is_write)
                        word_q[15:0] <= psram_data_out;
                    if (is_write && latched_wstrb[3:2] == 2'b00) begin
                        state <= ST_DONE;
                    end else begin
                        state <= ST_WR_HI_START;
                    end
                end
            end

            ST_WR_HI_START: begin
                psram_bank_sel <= latched_chip_sel;
                psram_addr <= latched_addr_hi;
                psram_data_in <= latched_data[31:16];
                psram_write_low_byte <= latched_wstrb[2];
                psram_write_high_byte <= latched_wstrb[3];

                if (is_write)
                    psram_write_en <= 1'b1;
                else
                    psram_read_en <= 1'b1;

                state <= ST_WR_HI_BUSY;
            end

            ST_WR_HI_BUSY: begin
                if (psram_busy) begin
                    state <= ST_WR_HI_WAIT;
                end
            end

            ST_WR_HI_WAIT: begin
                if (!psram_busy) begin
                    if (!is_write) begin
                        word_q[31:16] <= psram_data_out;
                        word_q_valid <= 1'b1;
                    end
                    state <= ST_DONE;
                end
            end

            // ============================================
            // Sync burst read path
            // Issues one psram.sv sync burst for 2*(N+1) halfwords,
            // assembles consecutive pairs into 32-bit words.
            // ============================================
            ST_BURST_START: begin
                // Convert word address to halfword address (word_addr * 2)
                // and request 2*(burst_len+1) halfwords
                psram_bank_sel <= latched_chip_sel;
                psram_addr <= {latched_addr[20:0], 1'b0};  // halfword address (low half first)
                psram_sync_burst_en <= 1'b1;
                psram_sync_burst_len <= {burst_words_remaining[4:0], 1'b1};  // 2*(N+1)-1 halfwords
                state <= ST_BURST_WAIT;
            end

            ST_BURST_WAIT: begin
                // Wait for psram.sv to start delivering data (read_avail pulses)
                if (psram_read_avail) begin
                    // First halfword is low 16 bits
                    burst_rdata[15:0] <= psram_data_out;
                    burst_lo_captured <= 1'b1;
                    state <= ST_BURST_HI;
                end
            end

            ST_BURST_LO: begin
                // Capture low halfword of next 32-bit word
                if (psram_read_avail) begin
                    burst_rdata[15:0] <= psram_data_out;
                    state <= ST_BURST_HI;
                end
            end

            ST_BURST_HI: begin
                // Capture high halfword, emit completed 32-bit word
                if (psram_read_avail) begin
                    burst_rdata[31:16] <= psram_data_out;
                    burst_rdata_valid <= 1'b1;
                    if (burst_words_remaining == 6'd0) begin
                        state <= ST_BURST_DONE;
                    end else begin
                        burst_words_remaining <= burst_words_remaining - 6'd1;
                        state <= ST_BURST_LO;
                    end
                end
            end

            ST_BURST_DONE: begin
                // Wait for psram.sv to finish (busy goes low)
                if (!psram_busy) begin
                    word_busy <= 1'b0;
                    state <= ST_IDLE;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
