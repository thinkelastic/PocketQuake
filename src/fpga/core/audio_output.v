//
// Audio output module for PocketQuake
// - Dual-clock FIFO bridges CPU clock to audio clock domain
// - I2S serializer outputs 48 kHz 16-bit stereo
// - Based on openfpga-litex audio.sv and sound_i2s.sv patterns
//

`default_nettype none

module audio_output (
    input  wire        clk_sys,       // CPU clock (FIFO write side)
    input  wire        clk_audio,     // 12.288 MHz (FIFO read side, audio master clock)
    input  wire        reset_n,

    // CPU write interface
    input  wire        sample_wr,     // Write strobe (one clk_sys cycle)
    input  wire [31:0] sample_data,   // {left[15:0], right[15:0]}
    output wire [11:0] fifo_level,    // Write-side fill level
    output wire        fifo_full,

    // I2S output
    output wire        audio_mclk,    // 12.288 MHz passthrough
    output wire        audio_lrck,    // Left/right clock (48 kHz)
    output wire        audio_dac      // Serial data
);

// ============================================
// MCLK passthrough
// ============================================
assign audio_mclk = clk_audio;

// ============================================
// Dual-clock FIFO (clk_sys -> clk_audio)
// ============================================
wire [15:0] fifo_l;
wire [15:0] fifo_r;
wire        fifo_empty;

dcfifo dcfifo_audio (
    .wrclk   (clk_sys),
    .rdclk   (clk_audio),

    .data    (sample_data),
    .wrreq   (sample_wr),

    .q       ({fifo_l, fifo_r}),
    .rdreq   (audio_pop && !fifo_empty),

    .rdempty (fifo_empty),
    .wrusedw (fifo_level),
    .wrfull  (fifo_full),

    .aclr    (~reset_n)
);
defparam dcfifo_audio.intended_device_family = "Cyclone V",
    dcfifo_audio.lpm_numwords  = 4096,
    dcfifo_audio.lpm_showahead = "OFF",
    dcfifo_audio.lpm_type      = "dcfifo",
    dcfifo_audio.lpm_width     = 32,
    dcfifo_audio.lpm_widthu    = 12,
    dcfifo_audio.overflow_checking  = "ON",
    dcfifo_audio.underflow_checking = "ON",
    dcfifo_audio.rdsync_delaypipe   = 5,
    dcfifo_audio.wrsync_delaypipe   = 5,
    dcfifo_audio.use_eab       = "ON";

// ============================================
// 48 kHz sample pop (12.288 MHz / 256 = 48 kHz)
// ============================================
reg [7:0] mclk_div = 8'hFF;
reg       audio_pop = 0;

always @(posedge clk_audio) begin
    audio_pop <= 0;
    if (mclk_div > 0) begin
        mclk_div <= mclk_div - 8'd1;
    end else begin
        mclk_div  <= 8'hFF;
        audio_pop <= 1;
    end
end

// ============================================
// SCLK generation (3.072 MHz = MCLK / 4)
// ============================================
reg [1:0] sclk_div;
wire      audgen_sclk = sclk_div[1] /* synthesis keep */;

always @(posedge clk_audio) begin
    sclk_div <= sclk_div + 2'd1;
end

// ============================================
// I2S serializer (16-bit signed stereo)
// ============================================
// Data format: 32 bits per channel (16 data + 16 dummy), MSB first
// LRCK toggles every 32 SCLK cycles

wire [15:0] active_l = fifo_empty ? 16'h0 : fifo_l;
wire [15:0] active_r = fifo_empty ? 16'h0 : fifo_r;

reg [31:0] audgen_sampshift;
reg [4:0]  audgen_lrck_cnt;
reg        audgen_lrck;
reg        audgen_dac;

always @(negedge audgen_sclk) begin
    // Output next bit
    audgen_dac <= audgen_sampshift[31];

    // 48 kHz * 64 bits = 3.072 MHz
    audgen_lrck_cnt <= audgen_lrck_cnt + 5'd1;
    if (audgen_lrck_cnt == 5'd31) begin
        // Switch channels
        audgen_lrck <= ~audgen_lrck;

        // Reload sample data at start of left channel
        if (~audgen_lrck) begin
            audgen_sampshift <= {active_l, active_r};
        end
    end else if (audgen_lrck_cnt < 5'd16) begin
        // Shift out 16 active bits per channel
        audgen_sampshift <= {audgen_sampshift[30:0], 1'b0};
    end
end

assign audio_lrck = audgen_lrck;
assign audio_dac  = audgen_dac;

endmodule
