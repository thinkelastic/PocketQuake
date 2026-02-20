// Async SRAM controller wrapper for 32-bit CPU/video accesses.
// Targets Analogue Pocket external SRAM (128K x 16 = 256KB).
// Tristate data bus is handled EXTERNALLY (at top level) to avoid
// synthesis issues with inout ports through module hierarchy.

`default_nettype none

module sram_controller #(
    parameter WAIT_CYCLES = 5  // Wait cycles for SRAM access time (55ns chip, need ~6 cycles at 100MHz)
)(
    input  wire        clk,
    input  wire        reset_n,

    // 32-bit word interface (compatible with existing psram-style bus)
    input  wire        word_rd,
    input  wire        word_wr,
    input  wire [21:0] word_addr,
    input  wire [31:0] word_data,
    input  wire [3:0]  word_wstrb,
    output reg  [31:0] word_q,
    output reg         word_busy,
    output reg         word_q_valid,

    // Physical SRAM signals (active-low controls, active-high dq_oe)
    output reg  [16:0] sram_a,
    output reg  [15:0] sram_dq_out,
    input  wire [15:0] sram_dq_in,
    output reg         sram_dq_oe,     // 1 = FPGA drives bus, 0 = SRAM drives bus
    output reg         sram_oe_n,
    output reg         sram_we_n,
    output reg         sram_ub_n,
    output reg         sram_lb_n
);

    localparam [3:0] ST_IDLE          = 4'd0;
    localparam [3:0] ST_WR_LO_SETUP   = 4'd1;
    localparam [3:0] ST_WR_LO_PULSE   = 4'd2;
    localparam [3:0] ST_WR_LO_HOLD    = 4'd3;
    localparam [3:0] ST_WR_HI_SETUP   = 4'd4;
    localparam [3:0] ST_WR_HI_PULSE   = 4'd5;
    localparam [3:0] ST_WR_HI_HOLD    = 4'd6;
    localparam [3:0] ST_RD_LO_SETUP   = 4'd7;
    localparam [3:0] ST_RD_LO_WAIT    = 4'd8;
    localparam [3:0] ST_RD_LO_SAMPLE  = 4'd9;
    localparam [3:0] ST_RD_HI_SETUP   = 4'd10;
    localparam [3:0] ST_RD_HI_WAIT    = 4'd11;
    localparam [3:0] ST_RD_HI_SAMPLE  = 4'd12;
    localparam [3:0] ST_DONE          = 4'd13;

    reg [3:0] state;
    reg       is_write;
    reg [31:0] latched_data;
    reg [3:0]  latched_wstrb;
    reg [15:0] latched_addr;
    reg [3:0]  wait_cnt;

    wire [16:0] latched_addr_lo = {latched_addr, 1'b0};
    wire [16:0] latched_addr_hi = {latched_addr, 1'b1};

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= ST_IDLE;
            word_busy <= 1'b0;
            word_q <= 32'b0;
            word_q_valid <= 1'b0;
            is_write <= 1'b0;
            latched_data <= 32'b0;
            latched_wstrb <= 4'b0;
            latched_addr <= 16'b0;
            wait_cnt <= 4'b0;
            sram_a <= 17'b0;
            sram_oe_n <= 1'b1;
            sram_we_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
            sram_dq_oe <= 1'b0;
            sram_dq_out <= 16'b0;
        end else begin
            word_q_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    word_busy <= 1'b0;
                    sram_oe_n <= 1'b1;
                    sram_we_n <= 1'b1;
                    sram_ub_n <= 1'b1;
                    sram_lb_n <= 1'b1;
                    sram_dq_oe <= 1'b0;

                    if (word_wr || word_rd) begin
                        word_busy <= 1'b1;
                        is_write <= word_wr;
                        latched_data <= word_data;
                        latched_wstrb <= word_wstrb;
                        latched_addr <= word_addr[15:0];
                        state <= word_wr ? ST_WR_LO_SETUP : ST_RD_LO_SETUP;
                    end
                end

                // ---- Write Low Half ----
                ST_WR_LO_SETUP: begin
                    sram_a <= latched_addr_lo;
                    sram_dq_out <= latched_data[15:0];
                    sram_dq_oe <= 1'b1;
                    sram_oe_n <= 1'b1;
                    sram_we_n <= 1'b1;
                    sram_ub_n <= ~latched_wstrb[1];
                    sram_lb_n <= ~latched_wstrb[0];
                    state <= ST_WR_LO_PULSE;
                end

                ST_WR_LO_PULSE: begin
                    sram_we_n <= 1'b0;
                    wait_cnt <= WAIT_CYCLES[3:0] - 1'b1;
                    state <= ST_WR_LO_HOLD;
                end

                ST_WR_LO_HOLD: begin
                    if (wait_cnt == 0) begin
                        sram_we_n <= 1'b1;
                        sram_ub_n <= 1'b1;
                        sram_lb_n <= 1'b1;
                        state <= ST_WR_HI_SETUP;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                // ---- Write High Half ----
                ST_WR_HI_SETUP: begin
                    sram_a <= latched_addr_hi;
                    sram_dq_out <= latched_data[31:16];
                    sram_dq_oe <= 1'b1;
                    sram_oe_n <= 1'b1;
                    sram_we_n <= 1'b1;
                    sram_ub_n <= ~latched_wstrb[3];
                    sram_lb_n <= ~latched_wstrb[2];
                    state <= ST_WR_HI_PULSE;
                end

                ST_WR_HI_PULSE: begin
                    sram_we_n <= 1'b0;
                    wait_cnt <= WAIT_CYCLES[3:0] - 1'b1;
                    state <= ST_WR_HI_HOLD;
                end

                ST_WR_HI_HOLD: begin
                    if (wait_cnt == 0) begin
                        sram_we_n <= 1'b1;
                        sram_ub_n <= 1'b1;
                        sram_lb_n <= 1'b1;
                        sram_dq_oe <= 1'b0;
                        state <= ST_DONE;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                // ---- Read Low Half ----
                ST_RD_LO_SETUP: begin
                    sram_a <= latched_addr_lo;
                    sram_dq_oe <= 1'b0;
                    sram_we_n <= 1'b1;
                    sram_oe_n <= 1'b0;
                    sram_ub_n <= 1'b0;
                    sram_lb_n <= 1'b0;
                    wait_cnt <= WAIT_CYCLES[3:0];
                    state <= ST_RD_LO_WAIT;
                end

                ST_RD_LO_WAIT: begin
                    if (wait_cnt == 0) begin
                        state <= ST_RD_LO_SAMPLE;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                ST_RD_LO_SAMPLE: begin
                    word_q[15:0] <= sram_dq_in;
                    sram_oe_n <= 1'b1;
                    sram_ub_n <= 1'b1;
                    sram_lb_n <= 1'b1;
                    state <= ST_RD_HI_SETUP;
                end

                // ---- Read High Half ----
                ST_RD_HI_SETUP: begin
                    sram_a <= latched_addr_hi;
                    sram_dq_oe <= 1'b0;
                    sram_we_n <= 1'b1;
                    sram_oe_n <= 1'b0;
                    sram_ub_n <= 1'b0;
                    sram_lb_n <= 1'b0;
                    wait_cnt <= WAIT_CYCLES[3:0];
                    state <= ST_RD_HI_WAIT;
                end

                ST_RD_HI_WAIT: begin
                    if (wait_cnt == 0) begin
                        state <= ST_RD_HI_SAMPLE;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                ST_RD_HI_SAMPLE: begin
                    word_q[31:16] <= sram_dq_in;
                    sram_oe_n <= 1'b1;
                    sram_ub_n <= 1'b1;
                    sram_lb_n <= 1'b1;
                    state <= ST_DONE;
                end

                ST_DONE: begin
                    word_busy <= 1'b0;
                    if (!is_write) begin
                        word_q_valid <= 1'b1;
                    end
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
