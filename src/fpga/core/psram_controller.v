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
    output wire         cram_lb_n
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

reg [3:0] state;
reg is_write;   // Distinguishes reads from writes in shared LO/HI states
reg [31:0] latched_data;
reg [21:0] latched_addr;
reg latched_chip_sel;
reg [3:0] latched_wstrb;

// Signals to psram module
reg psram_write_en;
reg psram_read_en;
reg [21:0] psram_addr;
reg [15:0] psram_data_in;
wire [15:0] psram_data_out;
wire psram_busy;
wire psram_read_avail;
reg psram_bank_sel;
reg psram_write_high_byte;
reg psram_write_low_byte;

// Instantiate the 16-bit PSRAM controller
psram #(
    .CLOCK_SPEED(CLOCK_SPEED)
) psram_inst (
    .clk(clk),

    .bank_sel(psram_bank_sel),
    .addr(psram_addr),

    .write_en(psram_write_en),
    .data_in(psram_data_in),
    .write_high_byte(psram_write_high_byte),
    .write_low_byte(psram_write_low_byte),

    .read_en(psram_read_en),

    .sync_burst_en(1'b0),
    .sync_burst_len(6'b0),

    .config_en(1'b0),
    .config_data(16'b0),

    .read_avail(psram_read_avail),
    .data_out(psram_data_out),

    .busy(psram_busy),

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
    .cram_lb_n(cram_lb_n)
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
    end else begin
        // Default: clear single-cycle signals
        psram_write_en <= 1'b0;
        psram_read_en <= 1'b0;
        word_q_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                word_busy <= 1'b0;

                if (word_wr || word_rd) begin
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

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
