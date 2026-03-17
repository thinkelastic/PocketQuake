//
// HW CD Audio Resampler for PocketQuake
//
// Resamples raw CD audio (44100 Hz stereo) to 48000 Hz with linear
// interpolation, applies volume, and outputs {L16, R16} for hardware
// mixing with CPU SFX.
//
// The CPU feeds raw CD samples into an internal FIFO via MMIO writes.
// The resampler drains the FIFO at 44100 Hz, resamples to 48000 Hz,
// and advances on each mix_trigger pulse (48 kHz from CPU audio writes).
//
// FIFO: 512 stereo frames (2KB), written by CPU via MUSIC_DATA register.
//

`default_nettype none

module audio_cd_resampler (
    input  wire        clk,
    input  wire        reset_n,

    // Mix trigger: pulse when CPU writes an audio sample.
    // Advances the resampler by one 48 kHz step.
    input  wire        mix_trigger,

    // Current music output
    output reg  [15:0] music_l,
    output reg  [15:0] music_r,

    // Control register interface (active on clk)
    input  wire        reg_wr,
    input  wire [3:0]  reg_addr,    // Word address [5:2] of MMIO
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata
);

// ============================================
// Internal FIFO parameters
// ============================================
localparam FIFO_DEPTH_BITS = 9;                     // 512 entries
localparam FIFO_DEPTH      = (1 << FIFO_DEPTH_BITS);
localparam FIFO_MASK       = FIFO_DEPTH - 1;

// ============================================
// Resampling: 44100 -> 48000 Hz, Q15 fixed-point
// step = 30106, one = 32768 = 2^15
// ============================================
localparam [14:0] RESAMP_STEP = 15'd30106;

// ============================================
// Control registers (MMIO 0x4C0000xx)
//   0x08 (addr=2): CTRL      - bit0=enable, bit1=pause
//   0x0C (addr=3): VOLUME    - [8:0] = 0-256
//   0x10 (addr=4): (unused, was WRITE_POS)
//   0x14 (addr=5): FIFO_LEVEL - [9:0] = frames in FIFO (read-only)
//   0x18 (addr=6): STATUS    - bit0=active, bit1=starved
//   0x1C (addr=7): MUSIC_DATA - write raw stereo sample {R16,L16} into FIFO
// ============================================
reg        ctrl_enable;
reg        ctrl_pause;
reg [8:0]  ctrl_volume;        // 0-256
reg        starved;

// ============================================
// Internal FIFO (infers BRAM / M10K)
// ============================================
(* ramstyle = "no_rw_check" *) reg [31:0] fifo_mem [0:FIFO_DEPTH-1];
reg [FIFO_DEPTH_BITS-1:0] fifo_wr_ptr;
reg [FIFO_DEPTH_BITS-1:0] fifo_rd_ptr;
reg [FIFO_DEPTH_BITS:0]   fifo_count;    // 0..512

wire fifo_empty = (fifo_count == 0);
wire fifo_full  = (fifo_count == FIFO_DEPTH);
wire [FIFO_DEPTH_BITS:0] fifo_space = FIFO_DEPTH - fifo_count;

// FIFO write: from MUSIC_DATA register write
wire fifo_push = reg_wr && (reg_addr == 4'd7) && !fifo_full;

// FIFO read: when resampler needs next sample
reg  fifo_pop;
reg  [31:0] fifo_rd_data;

always @(posedge clk) begin
    if (fifo_pop && !fifo_empty)
        fifo_rd_data <= fifo_mem[fifo_rd_ptr];
    if (fifo_push)
        fifo_mem[fifo_wr_ptr] <= reg_wdata;
end

// Register read (combinational)
always @(*) begin
    case (reg_addr)
        4'd2:    reg_rdata = {30'b0, ctrl_pause, ctrl_enable};
        4'd3:    reg_rdata = {23'b0, ctrl_volume};
        4'd5:    reg_rdata = {22'b0, fifo_count};
        4'd6:    reg_rdata = {30'b0, starved, ctrl_enable & ~ctrl_pause};
        default: reg_rdata = 32'd0;
    endcase
end

// ============================================
// Sample buffers for interpolation
// ============================================
reg signed [15:0] s0_l, s0_r;  // Current sample
reg signed [15:0] s1_l, s1_r;  // Next sample
reg [14:0] resample_frac;

// ============================================
// FSM states
// ============================================
localparam S_IDLE       = 3'd0;
localparam S_FETCH_S0   = 3'd1;  // Pop first sample
localparam S_LATCH_S0   = 3'd2;  // Latch first sample
localparam S_FETCH_S1   = 3'd3;  // Pop second sample
localparam S_LATCH_S1   = 3'd4;  // Latch second sample
localparam S_RUNNING    = 3'd5;  // Interpolate and output
localparam S_FETCH_NEXT = 3'd6;  // Pop next sample after advance
localparam S_LATCH_NEXT = 3'd7;  // Latch next sample

reg [2:0] state;
reg need_advance;

// ============================================
// Interpolation (combinational, infers DSP)
// ============================================
wire signed [15:0] diff_l = s1_l - s0_l;
wire signed [15:0] diff_r = s1_r - s0_r;

wire signed [30:0] prod_l = diff_l * $signed({1'b0, resample_frac});
wire signed [30:0] prod_r = diff_r * $signed({1'b0, resample_frac});

wire signed [15:0] interp_l_comb = s0_l + prod_l[30:15];
wire signed [15:0] interp_r_comb = s0_r + prod_r[30:15];

// Registered interpolation output (pipeline stage 1)
reg signed [15:0] interp_l_r, interp_r_r;
always @(posedge clk) begin
    interp_l_r <= interp_l_comb;
    interp_r_r <= interp_r_comb;
end

// Volume scaling (pipeline stage 2)
wire signed [24:0] vol_l = interp_l_r * $signed({1'b0, ctrl_volume});
wire signed [24:0] vol_r = interp_r_r * $signed({1'b0, ctrl_volume});

wire signed [15:0] scaled_l = vol_l[23:8];
wire signed [15:0] scaled_r = vol_r[23:8];

// Resampling fraction accumulation
wire [15:0] frac_sum = {1'b0, resample_frac} + {1'b0, RESAMP_STEP};
wire        frac_overflow = frac_sum[15];

// ============================================
// Main FSM + register writes
// ============================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state         <= S_IDLE;
        s0_l <= 0; s0_r <= 0;
        s1_l <= 0; s1_r <= 0;
        resample_frac <= 0;
        need_advance  <= 0;
        starved       <= 0;
        music_l       <= 0;
        music_r       <= 0;
        ctrl_enable   <= 0;
        ctrl_pause    <= 0;
        ctrl_volume   <= 9'd256;
        fifo_wr_ptr   <= 0;
        fifo_rd_ptr   <= 0;
        fifo_count    <= 0;
        fifo_pop      <= 0;
    end else begin
        fifo_pop <= 0;  // Default: no pop

        // ============================================
        // FIFO write pointer management
        // ============================================
        if (fifo_push && !fifo_pop) begin
            fifo_wr_ptr <= fifo_wr_ptr + 1;
            fifo_count  <= fifo_count + 1;
        end else if (!fifo_push && fifo_pop && !fifo_empty) begin
            fifo_rd_ptr <= fifo_rd_ptr + 1;
            fifo_count  <= fifo_count - 1;
        end else if (fifo_push && fifo_pop && !fifo_empty) begin
            fifo_wr_ptr <= fifo_wr_ptr + 1;
            fifo_rd_ptr <= fifo_rd_ptr + 1;
            // count unchanged
        end

        // ============================================
        // Register writes from CPU
        // ============================================
        if (reg_wr) begin
            case (reg_addr)
                4'd2: begin // CTRL
                    ctrl_enable <= reg_wdata[0];
                    ctrl_pause  <= reg_wdata[1];
                    // Enable rising edge: reset state
                    if (reg_wdata[0] && !ctrl_enable) begin
                        resample_frac <= 0;
                        need_advance  <= 0;
                        state         <= S_IDLE;
                        music_l       <= 0;
                        music_r       <= 0;
                        fifo_rd_ptr   <= 0;
                        fifo_wr_ptr   <= 0;
                        fifo_count    <= 0;
                        starved       <= 0;
                    end
                    if (!reg_wdata[0]) begin
                        state   <= S_IDLE;
                        music_l <= 0;
                        music_r <= 0;
                    end
                end
                4'd3: ctrl_volume <= reg_wdata[8:0];
            endcase
        end

        // ============================================
        // FSM
        // ============================================
        if (!(reg_wr && reg_addr == 4'd2)) begin
            case (state)
            S_IDLE: begin
                music_l <= 0;
                music_r <= 0;
                if (ctrl_enable && !ctrl_pause && fifo_count >= 2) begin
                    fifo_pop <= 1;
                    state <= S_FETCH_S0;
                end
            end

            S_FETCH_S0: begin
                // fifo_rd_data available next cycle (BRAM read latency)
                state <= S_LATCH_S0;
            end

            S_LATCH_S0: begin
                s0_l <= $signed(fifo_rd_data[15:0]);
                s0_r <= $signed(fifo_rd_data[31:16]);
                if (fifo_count >= 1) begin
                    fifo_pop <= 1;
                    state <= S_FETCH_S1;
                end else begin
                    starved <= 1;
                    state <= S_IDLE;
                end
            end

            S_FETCH_S1: begin
                state <= S_LATCH_S1;
            end

            S_LATCH_S1: begin
                s1_l <= $signed(fifo_rd_data[15:0]);
                s1_r <= $signed(fifo_rd_data[31:16]);
                starved <= 0;
                state <= S_RUNNING;
            end

            S_RUNNING: begin
                if (!ctrl_enable) begin
                    state <= S_IDLE;
                    music_l <= 0;
                    music_r <= 0;
                end else if (ctrl_pause) begin
                    // Hold
                end else begin
                    music_l <= scaled_l;
                    music_r <= scaled_r;

                    if (mix_trigger) begin
                        if (need_advance) begin
                            s0_l <= s1_l;
                            s0_r <= s1_r;
                            need_advance <= 0;

                            if (fifo_empty) begin
                                starved <= 1;
                                // Hold last sample until FIFO refills
                            end else begin
                                fifo_pop <= 1;
                                state <= S_FETCH_NEXT;
                            end
                        end else begin
                            resample_frac <= frac_sum[14:0];
                            need_advance  <= frac_overflow;
                        end
                    end
                end
            end

            S_FETCH_NEXT: begin
                state <= S_LATCH_NEXT;
            end

            S_LATCH_NEXT: begin
                s1_l <= $signed(fifo_rd_data[15:0]);
                s1_r <= $signed(fifo_rd_data[31:16]);
                state <= S_RUNNING;
            end

            default: state <= S_IDLE;

            endcase
        end
    end
end

endmodule
