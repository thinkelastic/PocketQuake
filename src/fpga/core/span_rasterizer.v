//
// Span Rasterizer - Hardware textured span + z-span drawing engine
// Offloads D_DrawSpans8 and D_DrawZSpans inner loops from CPU to FPGA.
//
// Register map (reg_addr = byte_offset[6:2]):
//   0x00: SPAN_FB_ADDR    (RW) - Framebuffer dest CPU byte address
//   0x04: SPAN_TEX_ADDR   (RW) - Texture base CPU byte address
//   0x08: SPAN_TEX_WIDTH  (RW) - [15:0]=width, [31:16]=height in pixels
//   0x0C: SPAN_S          (RW) - Initial S (16.16 fixed-point)
//   0x10: SPAN_T          (RW) - Initial T (16.16 fixed-point)
//   0x14: SPAN_SSTEP      (RW) - S step per pixel (16.16 fixed-point)
//   0x18: SPAN_TSTEP      (RW) - T step per pixel (16.16 fixed-point)
//   0x1C: SPAN_CONTROL    (W)  - Write to enqueue: [15:0]=count, [16]=colormap enable, [17]=turb enable
//   0x20: SPAN_STATUS     (R)  - bit0=busy, bit1=queue_full, bit2=can_accept, bit3=overflow
//   0x24: ZSPAN_ADDR      (RW) - Z-buffer dest CPU byte address (short*)
//   0x28: ZSPAN_IZI       (RW) - Initial izi fixed-point value (high 16 written)
//   0x2C: ZSPAN_IZISTEP   (RW) - IZI step per pixel
//   0x30: ZSPAN_CONTROL   (W)  - Write pixel count to enqueue z-span
//   0x34: SPAN_LIGHT      (RW) - Light level for colormap (bits [13:8] = light index)
//   0x38: SPAN_LIGHTSTEP  (RW) - Light step per pixel (signed, for surface cache building)
//   0x3C: SPAN_TURB_PHASE (RW) - Turbulence sine LUT phase offset (7-bit, 0-127)
//   0x40: SURF_LIGHT_TL   (RW) - Surface block: top-left light corner
//   0x44: SURF_LIGHT_TR   (RW) - Surface block: top-right light corner
//   0x48: SURF_LIGHT_BL   (RW) - Surface block: bottom-left light corner
//   0x4C: SURF_LIGHT_BR   (RW) - Surface block: bottom-right light corner
//   0x50: SURF_TEX_STEP   (RW) - Surface block: texture row stride (bytes)
//   0x54: SURF_DEST_STEP  (RW) - Surface block: dest row stride (bytes)
//   0x58: SURF_CONTROL    (W)  - Write blockdivshift to enqueue surface block
//
// Queueing:
//   - One active command + 2-entry FIFO (depth=3 total).
//   - CPU should check can_accept before enqueueing to avoid overflow.
//

`default_nettype none

module span_rasterizer (
    input wire        clk,
    input wire        reset_n,

    // CPU register interface
    input wire        reg_wr,
    input wire [4:0]  reg_addr,     // byte_offset[6:2]
    input wire [31:0] reg_wdata,
    output reg [31:0] reg_rdata,

    // SDRAM word interface
    output reg        sdram_rd,
    output reg        sdram_wr,
    output reg [23:0] sdram_addr,
    output reg [31:0] sdram_wdata,
    output reg [3:0]  sdram_wstrb,
    output reg [2:0]  sdram_burst_len,  // 0=1 word, N=N+1 words (for cache line fills)
    input wire [31:0] sdram_rdata,
    input wire        sdram_busy,
    input wire        sdram_rdata_valid,

    // SRAM write interface (for z-span writes to external SRAM z-buffer)
    output reg        sram_wr,
    output reg [21:0] sram_addr,
    output reg [31:0] sram_wdata,
    output reg [3:0]  sram_wstrb,
    input wire        sram_busy,

    // Status
    output wire       active,

    // Colormap BRAM interface (port B, read-only)
    output wire [11:0] cmap_addr,
    input wire [31:0]  cmap_rdata
);

// Configuration registers (staging for new commands)
reg [31:0] fb_addr_reg;
reg [31:0] tex_addr_reg;
reg [15:0] tex_width_reg;
reg [15:0] tex_height_reg;
reg [31:0] s_reg;
reg [31:0] t_reg;
reg [31:0] sstep_reg;
reg [31:0] tstep_reg;
reg [31:0] light_reg;
reg [31:0] lightstep_reg;
reg [6:0]  turb_phase_reg;
reg [31:0] z_addr_reg;
reg [31:0] zi_reg;
reg [31:0] zistep_reg;

// Surface block staging registers
reg [31:0] surf_light_tl_reg;
reg [31:0] surf_light_tr_reg;
reg [31:0] surf_light_bl_reg;
reg [31:0] surf_light_br_reg;
reg [31:0] surf_tex_step_reg;
reg [31:0] surf_dest_step_reg;

// Active textured command state
reg [31:0] cur_fb;
reg [31:0] cur_tex_addr;
reg [15:0] cur_tex_width;
reg [15:0] cur_tex_height;
reg [31:0] cur_s;
reg [31:0] cur_t;
reg [31:0] cur_sstep;
reg [31:0] cur_tstep;
reg [15:0] remaining;
reg [31:0] cur_light;
reg [31:0] cur_lightstep;
reg        cur_cmap_en;
reg        cur_turb_en;

// Turbulence distortion state (set in ST_TURB_CALC, used in ST_TURB_FETCH+)
reg [5:0]  turb_s_r;
reg [5:0]  turb_t_r;

// Active z command state
reg [31:0] cur_zaddr;
reg [31:0] cur_izi;
reg [31:0] cur_zistep;
reg [15:0] z_remaining;
reg        z_issue_pair;

// Surface block active state
reg        surf_block_active;
reg [31:0] surf_ll, surf_lr;
reg signed [31:0] surf_lls, surf_lrs;
reg [31:0] surf_tex_step, surf_dest_step;
reg [4:0]  surf_rows_remaining;
reg [2:0]  surf_blockshift;
reg [31:0] surf_fb_base, surf_tex_base;

// Command FIFO (2-entry circular buffer, total depth = 3 with active command)
reg        fifo_wr_ptr;
reg        fifo_rd_ptr;
reg [1:0]  fifo_count;    // 0-2

reg        fifo_is_z      [0:1];
reg        fifo_is_surf   [0:1];
reg [31:0] fifo_fb        [0:1];
reg [31:0] fifo_tex_addr  [0:1];
(* ramstyle = "logic" *) reg [31:0] fifo_tex_wh    [0:1]; // packed: {height[31:16], width[15:0]}
reg [31:0] fifo_s         [0:1];
reg [31:0] fifo_t         [0:1];
reg [31:0] fifo_sstep     [0:1];
reg [31:0] fifo_tstep     [0:1];
reg [15:0] fifo_count_f   [0:1];
reg [31:0] fifo_light     [0:1];
reg [31:0] fifo_lightstep [0:1];
reg        fifo_cmap_en   [0:1];
reg        fifo_turb_en   [0:1];
reg [31:0] fifo_zaddr     [0:1];
reg [31:0] fifo_izi       [0:1];
reg [31:0] fifo_zistep    [0:1];
reg [15:0] fifo_zcount    [0:1];

reg        fifo_overflow;

// Surface block FIFO fields
reg [31:0] fifo_surf_light_tl [0:1];
reg [31:0] fifo_surf_light_tr [0:1];
reg [31:0] fifo_surf_light_bl [0:1];
reg [31:0] fifo_surf_light_br [0:1];
reg [31:0] fifo_surf_tex_step [0:1];
reg [31:0] fifo_surf_dest_step[0:1];
reg [2:0]  fifo_surf_blockshift[0:1];

// Texture cache (16-entry direct-mapped, 4-word lines = 16 texels per line)
// Index = tex_word_addr[5:2], Line offset = tex_word_addr[1:0], Tag = tex_word_addr[23:6]
// Data arrays use M10K block RAM with synchronous reads to eliminate 16:1 mux critical path.
reg [17:0] tex_cache_tag   [0:15];
(* ramstyle = "M10K" *) reg [31:0] tex_cache_data0 [0:15];
(* ramstyle = "M10K" *) reg [31:0] tex_cache_data1 [0:15];
(* ramstyle = "M10K" *) reg [31:0] tex_cache_data2 [0:15];
(* ramstyle = "M10K" *) reg [31:0] tex_cache_data3 [0:15];
reg [15:0] tex_cache_valid;
reg [1:0]  fill_count;  // Tracks which word during 4-word cache line fill

// Texture cache prefetch (non-blocking background fill for next sequential line)
reg        pf_pending;      // Prefetch address ready to issue
reg        pf_filling;      // Prefetch read in-flight
reg [23:0] pf_addr;         // Prefetch word address (4-word aligned)
reg [3:0]  pf_idx;          // Target cache index
reg [17:0] pf_tag;          // Target cache tag
reg [1:0]  pf_fill_count;   // Words received (0-3)
reg        pf_just_finished; // Set when pf_filling clears during ST_TEX_READ

// Framebuffer write accumulator (batches up to 4 bytes into one SDRAM word write)
reg [31:0] acc_data;
reg [3:0]  acc_strb;
reg [23:0] acc_addr;

// Colormap byte select (registered for ST_CMAP_WAIT extraction)
reg [1:0] cmap_byte_sel_r;

// Turbulence sine LUT (128 entries x 32-bit, initialized at synthesis)
// Values: AMP + round(sin(i * 2*pi / 128) * AMP), AMP = 0x80000
// Dual-port read for simultaneous s-indexed and t-indexed lookups
(* ramstyle = "M10K" *) reg [31:0] turb_lut [0:127];
reg [6:0] turb_lut_addr_a, turb_lut_addr_b;
reg [31:0] turb_lut_rd_a, turb_lut_rd_b;

always @(posedge clk) turb_lut_rd_a <= turb_lut[turb_lut_addr_a];
always @(posedge clk) turb_lut_rd_b <= turb_lut[turb_lut_addr_b];

initial begin
    turb_lut[  0] = 32'h00080000; turb_lut[  1] = 32'h0008647e;
    turb_lut[  2] = 32'h0008c8bd; turb_lut[  3] = 32'h00092c81;
    turb_lut[  4] = 32'h00098f8c; turb_lut[  5] = 32'h0009f1a0;
    turb_lut[  6] = 32'h000a5281; turb_lut[  7] = 32'h000ab1f3;
    turb_lut[  8] = 32'h000b0fbc; turb_lut[  9] = 32'h000b6ba2;
    turb_lut[ 10] = 32'h000bc56c; turb_lut[ 11] = 32'h000c1ce2;
    turb_lut[ 12] = 32'h000c71cf; turb_lut[ 13] = 32'h000cc3fe;
    turb_lut[ 14] = 32'h000d133d; turb_lut[ 15] = 32'h000d5f5a;
    turb_lut[ 16] = 32'h000da828; turb_lut[ 17] = 32'h000ded78;
    turb_lut[ 18] = 32'h000e2f20; turb_lut[ 19] = 32'h000e6cf8;
    turb_lut[ 20] = 32'h000ea6da; turb_lut[ 21] = 32'h000edca1;
    turb_lut[ 22] = 32'h000f0e2d; turb_lut[ 23] = 32'h000f3b5f;
    turb_lut[ 24] = 32'h000f641b; turb_lut[ 25] = 32'h000f8848;
    turb_lut[ 26] = 32'h000fa7d0; turb_lut[ 27] = 32'h000fc2a0;
    turb_lut[ 28] = 32'h000fd8a6; turb_lut[ 29] = 32'h000fe9d5;
    turb_lut[ 30] = 32'h000ff623; turb_lut[ 31] = 32'h000ffd88;
    turb_lut[ 32] = 32'h00100000; turb_lut[ 33] = 32'h000ffd88;
    turb_lut[ 34] = 32'h000ff623; turb_lut[ 35] = 32'h000fe9d5;
    turb_lut[ 36] = 32'h000fd8a6; turb_lut[ 37] = 32'h000fc2a0;
    turb_lut[ 38] = 32'h000fa7d0; turb_lut[ 39] = 32'h000f8848;
    turb_lut[ 40] = 32'h000f641b; turb_lut[ 41] = 32'h000f3b5f;
    turb_lut[ 42] = 32'h000f0e2d; turb_lut[ 43] = 32'h000edca1;
    turb_lut[ 44] = 32'h000ea6da; turb_lut[ 45] = 32'h000e6cf8;
    turb_lut[ 46] = 32'h000e2f20; turb_lut[ 47] = 32'h000ded78;
    turb_lut[ 48] = 32'h000da828; turb_lut[ 49] = 32'h000d5f5a;
    turb_lut[ 50] = 32'h000d133d; turb_lut[ 51] = 32'h000cc3fe;
    turb_lut[ 52] = 32'h000c71cf; turb_lut[ 53] = 32'h000c1ce2;
    turb_lut[ 54] = 32'h000bc56c; turb_lut[ 55] = 32'h000b6ba2;
    turb_lut[ 56] = 32'h000b0fbc; turb_lut[ 57] = 32'h000ab1f3;
    turb_lut[ 58] = 32'h000a5281; turb_lut[ 59] = 32'h0009f1a0;
    turb_lut[ 60] = 32'h00098f8c; turb_lut[ 61] = 32'h00092c81;
    turb_lut[ 62] = 32'h0008c8bd; turb_lut[ 63] = 32'h0008647e;
    turb_lut[ 64] = 32'h00080000; turb_lut[ 65] = 32'h00079b82;
    turb_lut[ 66] = 32'h00073743; turb_lut[ 67] = 32'h0006d37f;
    turb_lut[ 68] = 32'h00067074; turb_lut[ 69] = 32'h00060e60;
    turb_lut[ 70] = 32'h0005ad7f; turb_lut[ 71] = 32'h00054e0d;
    turb_lut[ 72] = 32'h0004f044; turb_lut[ 73] = 32'h0004945e;
    turb_lut[ 74] = 32'h00043a94; turb_lut[ 75] = 32'h0003e31e;
    turb_lut[ 76] = 32'h00038e31; turb_lut[ 77] = 32'h00033c02;
    turb_lut[ 78] = 32'h0002ecc3; turb_lut[ 79] = 32'h0002a0a6;
    turb_lut[ 80] = 32'h000257d8; turb_lut[ 81] = 32'h00021288;
    turb_lut[ 82] = 32'h0001d0e0; turb_lut[ 83] = 32'h00019308;
    turb_lut[ 84] = 32'h00015926; turb_lut[ 85] = 32'h0001235f;
    turb_lut[ 86] = 32'h0000f1d3; turb_lut[ 87] = 32'h0000c4a1;
    turb_lut[ 88] = 32'h00009be5; turb_lut[ 89] = 32'h000077b8;
    turb_lut[ 90] = 32'h00005830; turb_lut[ 91] = 32'h00003d60;
    turb_lut[ 92] = 32'h0000275a; turb_lut[ 93] = 32'h0000162b;
    turb_lut[ 94] = 32'h000009dd; turb_lut[ 95] = 32'h00000278;
    turb_lut[ 96] = 32'h00000000; turb_lut[ 97] = 32'h00000278;
    turb_lut[ 98] = 32'h000009dd; turb_lut[ 99] = 32'h0000162b;
    turb_lut[100] = 32'h0000275a; turb_lut[101] = 32'h00003d60;
    turb_lut[102] = 32'h00005830; turb_lut[103] = 32'h000077b8;
    turb_lut[104] = 32'h00009be5; turb_lut[105] = 32'h0000c4a1;
    turb_lut[106] = 32'h0000f1d3; turb_lut[107] = 32'h0001235f;
    turb_lut[108] = 32'h00015926; turb_lut[109] = 32'h00019308;
    turb_lut[110] = 32'h0001d0e0; turb_lut[111] = 32'h00021288;
    turb_lut[112] = 32'h000257d8; turb_lut[113] = 32'h0002a0a6;
    turb_lut[114] = 32'h0002ecc3; turb_lut[115] = 32'h00033c02;
    turb_lut[116] = 32'h00038e31; turb_lut[117] = 32'h0003e31e;
    turb_lut[118] = 32'h00043a94; turb_lut[119] = 32'h0004945e;
    turb_lut[120] = 32'h0004f044; turb_lut[121] = 32'h00054e0d;
    turb_lut[122] = 32'h0005ad7f; turb_lut[123] = 32'h00060e60;
    turb_lut[124] = 32'h00067074; turb_lut[125] = 32'h0006d37f;
    turb_lut[126] = 32'h00073743; turb_lut[127] = 32'h00079b82;
end

// Texture cache M10K write control (combinational, drives M10K always blocks)
// Normal fill (ST_TEX_WAIT) and prefetch fill are mutually exclusive.
wire        tc_fill_wr = (state == ST_TEX_WAIT) && sdram_rdata_valid;
wire        tc_pf_wr   = pf_filling && sdram_rdata_valid && (state != ST_TEX_WAIT);
wire        tc_wr_en   = tc_fill_wr || tc_pf_wr;
wire [3:0]  tc_wr_addr = tc_fill_wr ? cache_idx : pf_idx;
wire [1:0]  tc_wr_slot = tc_fill_wr ? fill_count : pf_fill_count;

// Texture cache M10K synchronous read outputs
reg [31:0] cache_rd_data0, cache_rd_data1, cache_rd_data2, cache_rd_data3;

always @(posedge clk) begin
    if (tc_wr_en && tc_wr_slot == 2'd0) tex_cache_data0[tc_wr_addr] <= sdram_rdata;
    cache_rd_data0 <= tex_cache_data0[cache_idx];
end
always @(posedge clk) begin
    if (tc_wr_en && tc_wr_slot == 2'd1) tex_cache_data1[tc_wr_addr] <= sdram_rdata;
    cache_rd_data1 <= tex_cache_data1[cache_idx];
end
always @(posedge clk) begin
    if (tc_wr_en && tc_wr_slot == 2'd2) tex_cache_data2[tc_wr_addr] <= sdram_rdata;
    cache_rd_data2 <= tex_cache_data2[cache_idx];
end
always @(posedge clk) begin
    if (tc_wr_en && tc_wr_slot == 2'd3) tex_cache_data3[tc_wr_addr] <= sdram_rdata;
    cache_rd_data3 <= tex_cache_data3[cache_idx];
end

// FSM
localparam ST_IDLE       = 4'd0;
localparam ST_PIXEL      = 4'd1;
localparam ST_TEX_READ   = 4'd2;
localparam ST_TEX_WAIT   = 4'd3;
localparam ST_FB_WRITE   = 4'd4;
localparam ST_FB_WAIT    = 4'd5;
localparam ST_Z_WRITE    = 4'd6;
localparam ST_Z_WAIT     = 4'd7;
localparam ST_CMAP_WAIT  = 4'd8;
localparam ST_TURB_CALC  = 4'd9;
localparam ST_TURB_FETCH = 4'd10;
localparam ST_TEX_ADDR   = 4'd11;
localparam ST_TEX_CACHE      = 4'd12;
localparam ST_SURF_INIT      = 4'd13;
localparam ST_SURF_ROW_SETUP = 4'd14;
localparam ST_TEX_M10K       = 4'd15;  // M10K read latency wait (1 cycle for synchronous read)
reg [3:0] state;
reg       cmd_issued;
reg       seen_busy;

wire busy_status = (state != ST_IDLE) || (fifo_count > 2'd0);
wire queue_full  = (fifo_count == 2'd2);
wire can_accept  = (fifo_count < 2'd2);
assign active = busy_status;

// Textured address computation
// Treat S/T as signed fixed-point high words and clamp negative values to 0.
// This avoids catastrophic address wrap if S/T briefly go slightly negative.
// Upper-bound clamping is handled at step time (when cur_s/cur_t are updated)
// to avoid adding logic to the critical tex_byte_addr → cache_hit path.
wire signed [15:0] s_int_signed = cur_s[31:16];
wire signed [15:0] t_int_signed = cur_t[31:16];
wire [15:0] s_int = s_int_signed[15] ? 16'd0 : s_int_signed[15:0];
wire [15:0] t_int = t_int_signed[15] ? 16'd0 : t_int_signed[15:0];
// Mux: turb mode uses distorted coords (6-bit, always positive)
wire [15:0] s_int_eff = cur_turb_en ? {10'd0, turb_s_r} : s_int;
wire [15:0] t_int_eff = cur_turb_en ? {10'd0, turb_t_r} : t_int;
// Registered texture byte address: combines multiply (t * width), s offset,
// and tex base address into a single pipeline register. This moves the
// cur_tex_addr adder from the critical output path (tex_offset_r → adder →
// cache lookup → cache_hit_r) to the non-critical input path, saving ~3.7 ns.
wire [31:0] t_times_w = t_int_eff * cur_tex_width;
wire [31:0] tex_byte_addr_comb = t_times_w + {16'd0, s_int_eff} + cur_tex_addr;
reg  [31:0] tex_byte_addr_r;
wire [23:0] tex_word_addr = tex_byte_addr_r[25:2];
wire [1:0]  tex_byte_sel  = tex_byte_addr_r[1:0];

wire [23:0] fb_word_addr = cur_fb[25:2];
wire [1:0]  fb_byte_sel  = cur_fb[1:0];

// Step-time S/T clamping: prevent linear stepping within a chunk from
// overshooting texture bounds (close surfaces with strong perspective).
// Clamping at step time avoids adding logic to the critical
// tex_byte_addr → cache_hit path. Only upper bound is checked here;
// the address computation above already handles negative clamping.
wire [31:0] next_s = cur_s + cur_sstep;
wire [31:0] next_t = cur_t + cur_tstep;
wire next_s_over = !next_s[31] && (next_s[31:16] >= cur_tex_width);
wire next_t_over = !next_t[31] && (next_t[31:16] >= cur_tex_height);
wire [31:0] next_s_clamped = next_s_over ? {cur_tex_width  - 16'd1, 16'hFFFF} : next_s;
wire [31:0] next_t_clamped = next_t_over ? {cur_tex_height - 16'd1, 16'hFFFF} : next_t;

// ST_TEX_ADDR routing flag: 0->ST_PIXEL, 1->ST_TURB_FETCH
reg tex_addr_for_turb;

// Direct-mapped texture cache: 4-word lines, index by aligned address bits.
wire [3:0]  cache_idx = tex_word_addr[5:2];          // 4-word aligned index
wire [1:0]  cache_line_offset = tex_word_addr[1:0];   // Word within cache line
wire [17:0] cache_tag = tex_word_addr[23:6];           // 18-bit tag
wire cache_hit_comb = tex_cache_valid[cache_idx] && (tex_cache_tag[cache_idx] == cache_tag);

// Prefetch: next sequential cache line address (computed from current miss address)
wire [23:0] pf_next_addr = {tex_word_addr[23:2], 2'b00} + 24'd4;
// M10K synchronous read outputs → 4:1 mux (no 16:1 mux, critical path eliminated)
wire [31:0] cache_hit_data =
    (cache_line_offset == 2'd0) ? cache_rd_data0 :
    (cache_line_offset == 2'd1) ? cache_rd_data1 :
    (cache_line_offset == 2'd2) ? cache_rd_data2 :
                                   cache_rd_data3;

// Registered cache hit and data: captured in ST_TEX_CACHE (after tex_offset_r
// has settled in ST_TEX_ADDR), used in ST_PIXEL / ST_TURB_FETCH.
reg cache_hit_r;
reg [31:0] cache_data_r;

integer ci;

wire [7:0] cached_byte =
    (tex_byte_sel == 2'd0) ? cache_data_r[7:0] :
    (tex_byte_sel == 2'd1) ? cache_data_r[15:8] :
    (tex_byte_sel == 2'd2) ? cache_data_r[23:16] :
                             cache_data_r[31:24];

// Byte extraction from SDRAM read data (combinational, for merged TEX_WAIT+ACCUM)
wire [7:0] tex_rdata_byte =
    (tex_byte_sel == 2'd0) ? sdram_rdata[7:0] :
    (tex_byte_sel == 2'd1) ? sdram_rdata[15:8] :
    (tex_byte_sel == 2'd2) ? sdram_rdata[23:16] :
                              sdram_rdata[31:24];

// Colormap address computation (combinational, presented 1 cycle before ST_CMAP_WAIT)
// cmap_byte_addr = {light[13:8], texel[7:0]} = 14-bit byte address into 16KB colormap
wire [7:0] cmap_texel_byte = (state == ST_TEX_WAIT) ? tex_rdata_byte : cached_byte;
wire [13:0] cmap_byte_addr_w = {cur_light[13:8], cmap_texel_byte};
assign cmap_addr = cmap_byte_addr_w[13:2];

// Byte extraction from colormap BRAM read data (for ST_CMAP_WAIT)
wire [7:0] cmap_result_byte =
    (cmap_byte_sel_r == 2'd0) ? cmap_rdata[7:0] :
    (cmap_byte_sel_r == 2'd1) ? cmap_rdata[15:8] :
    (cmap_byte_sel_r == 2'd2) ? cmap_rdata[23:16] :
                                 cmap_rdata[31:24];

// Z address/value computation
wire [23:0] z_word_addr = cur_zaddr[25:2];
wire        z_half_sel  = cur_zaddr[1];
wire [15:0] z_value0    = cur_izi[31:16];
wire [31:0] z_izi_plus_step = cur_izi + cur_zistep;
wire [15:0] z_value1    = z_izi_plus_step[31:16];
wire        z_can_pair  = (!z_half_sel) && (z_remaining >= 16'd2);

// Surface block row light interpolation (combinational, used in ST_SURF_ROW_SETUP)
wire signed [31:0] surf_row_diff = $signed(surf_ll) - $signed(surf_lr);
wire signed [31:0] surf_row_sw_step =
    (surf_blockshift == 3'd4) ? (surf_row_diff >>> 4) :
    (surf_blockshift == 3'd3) ? (surf_row_diff >>> 3) :
    (surf_blockshift == 3'd2) ? (surf_row_diff >>> 2) :
                                (surf_row_diff >>> 1);
wire signed [31:0] surf_row_scaled =
    (surf_blockshift == 3'd4) ? (surf_row_sw_step <<< 4) :
    (surf_blockshift == 3'd3) ? (surf_row_sw_step <<< 3) :
    (surf_blockshift == 3'd2) ? (surf_row_sw_step <<< 2) :
                                (surf_row_sw_step <<< 1);
wire [31:0] surf_row_hw_light = surf_lr + surf_row_scaled - surf_row_sw_step;
wire [31:0] surf_row_neg_sw_step = -surf_row_sw_step;

wire [15:0] surf_blocksize =
    (surf_blockshift == 3'd4) ? 16'd16 :
    (surf_blockshift == 3'd3) ? 16'd8  :
    (surf_blockshift == 3'd2) ? 16'd4  : 16'd2;

// Register read mux
always @(*) begin
    case (reg_addr)
        5'd0:  reg_rdata = fb_addr_reg;
        5'd1:  reg_rdata = tex_addr_reg;
        5'd2:  reg_rdata = {tex_height_reg, tex_width_reg};
        5'd3:  reg_rdata = s_reg;
        5'd4:  reg_rdata = t_reg;
        5'd5:  reg_rdata = sstep_reg;
        5'd6:  reg_rdata = tstep_reg;
        5'd7:  reg_rdata = 32'd0; // write-only
        5'd8:  reg_rdata = {28'd0, fifo_overflow, can_accept, queue_full, busy_status};
        5'd9:  reg_rdata = z_addr_reg;
        5'd10: reg_rdata = zi_reg;
        5'd11: reg_rdata = zistep_reg;
        5'd12: reg_rdata = 32'd0; // write-only
        5'd13: reg_rdata = light_reg;
        5'd14: reg_rdata = lightstep_reg;
        5'd15: reg_rdata = {25'd0, turb_phase_reg};
        5'd16: reg_rdata = surf_light_tl_reg;
        5'd17: reg_rdata = surf_light_tr_reg;
        5'd18: reg_rdata = surf_light_bl_reg;
        5'd19: reg_rdata = surf_light_br_reg;
        5'd20: reg_rdata = surf_tex_step_reg;
        5'd21: reg_rdata = surf_dest_step_reg;
        5'd22: reg_rdata = 32'd0; // SURF_CONTROL write-only
        default: reg_rdata = 32'd0;
    endcase
end

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        fb_addr_reg      <= 32'd0;
        tex_addr_reg     <= 32'd0;
        tex_width_reg    <= 16'd0;
        tex_height_reg   <= 16'd0;
        s_reg            <= 32'd0;
        t_reg            <= 32'd0;
        sstep_reg        <= 32'd0;
        tstep_reg        <= 32'd0;
        light_reg        <= 32'd0;
        lightstep_reg    <= 32'd0;
        turb_phase_reg   <= 7'd0;
        z_addr_reg       <= 32'd0;
        zi_reg           <= 32'd0;
        zistep_reg       <= 32'd0;

        cur_fb           <= 32'd0;
        cur_tex_addr     <= 32'd0;
        cur_tex_width    <= 16'd0;
        cur_tex_height   <= 16'd0;
        cur_s            <= 32'd0;
        cur_t            <= 32'd0;
        cur_sstep        <= 32'd0;
        cur_tstep        <= 32'd0;
        remaining        <= 16'd0;
        cur_light        <= 32'd0;
        cur_lightstep    <= 32'd0;
        cur_cmap_en      <= 1'b0;
        cur_turb_en      <= 1'b0;
        turb_s_r         <= 6'd0;
        turb_t_r         <= 6'd0;
        turb_lut_addr_a  <= 7'd0;
        turb_lut_addr_b  <= 7'd0;

        cur_zaddr        <= 32'd0;
        cur_izi          <= 32'd0;
        cur_zistep       <= 32'd0;
        z_remaining      <= 16'd0;
        z_issue_pair     <= 1'b0;

        fifo_wr_ptr      <= 1'b0;
        fifo_rd_ptr      <= 1'b0;
        fifo_count       <= 2'd0;
        fifo_overflow    <= 1'b0;

        surf_light_tl_reg <= 32'd0;
        surf_light_tr_reg <= 32'd0;
        surf_light_bl_reg <= 32'd0;
        surf_light_br_reg <= 32'd0;
        surf_tex_step_reg <= 32'd0;
        surf_dest_step_reg<= 32'd0;

        surf_block_active <= 1'b0;
        surf_ll           <= 32'd0;
        surf_lr           <= 32'd0;
        surf_lls          <= 32'sd0;
        surf_lrs          <= 32'sd0;
        surf_tex_step     <= 32'd0;
        surf_dest_step    <= 32'd0;
        surf_rows_remaining <= 5'd0;
        surf_blockshift   <= 3'd0;
        surf_fb_base      <= 32'd0;
        surf_tex_base     <= 32'd0;

        // FIFO arrays don't need element-wise reset — fifo_count=0 prevents reads

        for (ci = 0; ci < 16; ci = ci + 1) begin
            tex_cache_tag[ci]   <= 18'd0;
            // tex_cache_data0-3 are M10K block RAM (no async reset needed;
            // tex_cache_valid=0 prevents stale reads after reset)
        end
        tex_cache_valid  <= 16'b0;
        fill_count       <= 2'd0;

        pf_pending       <= 1'b0;
        pf_filling       <= 1'b0;
        pf_addr          <= 24'd0;
        pf_idx           <= 4'd0;
        pf_tag           <= 18'd0;
        pf_fill_count    <= 2'd0;
        pf_just_finished <= 1'b0;

        cmap_byte_sel_r  <= 2'd0;

        tex_byte_addr_r  <= 32'd0;
        tex_addr_for_turb <= 1'b0;
        cache_hit_r      <= 1'b0;
        cache_data_r     <= 32'd0;

        acc_data         <= 32'd0;
        acc_strb         <= 4'b0000;
        acc_addr         <= 24'd0;

        state            <= ST_IDLE;
        cmd_issued       <= 1'b0;
        seen_busy        <= 1'b0;

        sdram_rd         <= 1'b0;
        sdram_wr         <= 1'b0;
        sdram_burst_len  <= 3'd0;
        sdram_addr       <= 24'd0;
        sdram_wdata      <= 32'd0;
        sdram_wstrb      <= 4'b0;

        sram_wr          <= 1'b0;
        sram_addr        <= 22'd0;
        sram_wdata       <= 32'd0;
        sram_wstrb       <= 4'b0;
    end else begin : main_logic
        // Blocking flags for simultaneous FIFO enqueue/dequeue handling
        reg did_enqueue, did_dequeue;

        // Default: deassert one-cycle strobes
        sdram_rd <= 1'b0;
        sdram_wr <= 1'b0;
        sdram_burst_len <= 3'd0;
        sram_wr <= 1'b0;
        did_enqueue = 1'b0;
        did_dequeue = 1'b0;

        // Clear pf_just_finished each cycle (one-cycle flag)
        pf_just_finished <= 1'b0;

        // Non-blocking prefetch: background cache line fill
        // When prefetch data arrives and FSM is NOT doing a real cache fill,
        // route sdram_rdata_valid to the prefetch target cache line.
        // Prefetch fill: data writes handled by M10K always blocks (tc_pf_wr path).
        // Here we only update tag, valid, fill count, and control signals.
        if (pf_filling && sdram_rdata_valid && state != ST_TEX_WAIT) begin
            if (pf_fill_count == 2'd3) begin
                tex_cache_tag[pf_idx]   <= pf_tag;
                tex_cache_valid         <= tex_cache_valid | (16'b1 << pf_idx);
                pf_filling <= 1'b0;
                // Signal ST_TEX_READ to re-check cache
                if (state == ST_TEX_READ)
                    pf_just_finished <= 1'b1;
            end else begin
                pf_fill_count <= pf_fill_count + 2'd1;
            end
        end

        // Free-running registered address (multiply + s_int_eff + cur_tex_addr, latched in ST_TEX_ADDR)
        tex_byte_addr_r <= tex_byte_addr_comb;

        // Register writes are always accepted.
        if (reg_wr) begin
            case (reg_addr)
                5'd0: fb_addr_reg   <= reg_wdata;
                5'd1: tex_addr_reg  <= reg_wdata;
                5'd2: begin tex_width_reg <= reg_wdata[15:0]; tex_height_reg <= reg_wdata[31:16]; end
                5'd3: s_reg         <= reg_wdata;
                5'd4: t_reg         <= reg_wdata;
                5'd5: sstep_reg     <= reg_wdata;
                5'd6: tstep_reg     <= reg_wdata;

                5'd7: begin
                    // Enqueue textured span command
                    if (reg_wdata[15:0] != 16'd0) begin
                        if (state == ST_IDLE && fifo_count == 2'd0) begin
                            // Direct launch (bypass FIFO)
                            cur_fb        <= fb_addr_reg;
                            cur_tex_addr  <= tex_addr_reg;
                            cur_tex_width <= tex_width_reg;
                            cur_tex_height <= tex_height_reg;
                            cur_s         <= s_reg;
                            cur_t         <= t_reg;
                            cur_sstep     <= sstep_reg;
                            cur_tstep     <= tstep_reg;
                            cur_light     <= light_reg;
                            cur_lightstep <= lightstep_reg;
                            cur_cmap_en   <= reg_wdata[16];
                            cur_turb_en   <= reg_wdata[17];
                            remaining     <= reg_wdata[15:0];
                            cmd_issued    <= 1'b0;
                            seen_busy     <= 1'b0;
                            tex_addr_for_turb <= 1'b0;
                            state         <= ST_TEX_ADDR;
                        end else if (fifo_count < 2'd2) begin
                            fifo_is_z[fifo_wr_ptr]      <= 1'b0;
                            fifo_is_surf[fifo_wr_ptr]   <= 1'b0;
                            fifo_fb[fifo_wr_ptr]        <= fb_addr_reg;
                            fifo_tex_addr[fifo_wr_ptr]  <= tex_addr_reg;
                            fifo_tex_wh[fifo_wr_ptr] <= {tex_height_reg, tex_width_reg};
                            fifo_s[fifo_wr_ptr]         <= s_reg;
                            fifo_t[fifo_wr_ptr]         <= t_reg;
                            fifo_sstep[fifo_wr_ptr]     <= sstep_reg;
                            fifo_tstep[fifo_wr_ptr]     <= tstep_reg;
                            fifo_light[fifo_wr_ptr]     <= light_reg;
                            fifo_lightstep[fifo_wr_ptr] <= lightstep_reg;
                            fifo_cmap_en[fifo_wr_ptr]   <= reg_wdata[16];
                            fifo_turb_en[fifo_wr_ptr]   <= reg_wdata[17];
                            fifo_count_f[fifo_wr_ptr]   <= reg_wdata[15:0];
                            fifo_wr_ptr <= ~fifo_wr_ptr;
                            did_enqueue = 1'b1;
                        end else begin
                            fifo_overflow <= 1'b1;
                        end
                    end
                end

                5'd13: light_reg    <= reg_wdata;
                5'd14: lightstep_reg <= reg_wdata;
                5'd15: turb_phase_reg <= reg_wdata[6:0];

                5'd9:  z_addr_reg   <= reg_wdata;
                5'd10: zi_reg       <= reg_wdata;
                5'd11: zistep_reg   <= reg_wdata;

                5'd12: begin
                    // Enqueue z-span command
                    if (reg_wdata[15:0] != 16'd0) begin
                        if (state == ST_IDLE && fifo_count == 2'd0) begin
                            // Direct launch (bypass FIFO)
                            cur_zaddr     <= z_addr_reg;
                            cur_izi       <= zi_reg;
                            cur_zistep    <= zistep_reg;
                            z_remaining   <= reg_wdata[15:0];
                            z_issue_pair  <= 1'b0;
                            cmd_issued    <= 1'b0;
                            seen_busy     <= 1'b0;
                            state         <= ST_Z_WRITE;
                        end else if (fifo_count < 2'd2) begin
                            fifo_is_z[fifo_wr_ptr]    <= 1'b1;
                            fifo_is_surf[fifo_wr_ptr] <= 1'b0;
                            fifo_zaddr[fifo_wr_ptr]   <= z_addr_reg;
                            fifo_izi[fifo_wr_ptr]     <= zi_reg;
                            fifo_zistep[fifo_wr_ptr]  <= zistep_reg;
                            fifo_zcount[fifo_wr_ptr]  <= reg_wdata[15:0];
                            fifo_wr_ptr <= ~fifo_wr_ptr;
                            did_enqueue = 1'b1;
                        end else begin
                            fifo_overflow <= 1'b1;
                        end
                    end
                end

                5'd16: surf_light_tl_reg  <= reg_wdata;
                5'd17: surf_light_tr_reg  <= reg_wdata;
                5'd18: surf_light_bl_reg  <= reg_wdata;
                5'd19: surf_light_br_reg  <= reg_wdata;
                5'd20: surf_tex_step_reg  <= reg_wdata;
                5'd21: surf_dest_step_reg <= reg_wdata;

                5'd22: begin
                    // Enqueue surface block command
                    if (state == ST_IDLE && fifo_count == 2'd0) begin
                        // Direct launch (bypass FIFO)
                        surf_fb_base    <= fb_addr_reg;
                        surf_tex_base   <= tex_addr_reg;
                        surf_ll         <= surf_light_tl_reg;
                        surf_lr         <= surf_light_tr_reg;
                        surf_blockshift <= reg_wdata[2:0];
                        surf_tex_step   <= surf_tex_step_reg;
                        surf_dest_step  <= surf_dest_step_reg;
                        surf_block_active <= 1'b1;
                        cmd_issued      <= 1'b0;
                        seen_busy       <= 1'b0;
                        state           <= ST_SURF_INIT;
                    end else if (fifo_count < 2'd2) begin
                        fifo_is_z[fifo_wr_ptr]             <= 1'b0;
                        fifo_is_surf[fifo_wr_ptr]          <= 1'b1;
                        fifo_fb[fifo_wr_ptr]               <= fb_addr_reg;
                        fifo_tex_addr[fifo_wr_ptr]         <= tex_addr_reg;
                        fifo_surf_light_tl[fifo_wr_ptr]    <= surf_light_tl_reg;
                        fifo_surf_light_tr[fifo_wr_ptr]    <= surf_light_tr_reg;
                        fifo_surf_light_bl[fifo_wr_ptr]    <= surf_light_bl_reg;
                        fifo_surf_light_br[fifo_wr_ptr]    <= surf_light_br_reg;
                        fifo_surf_tex_step[fifo_wr_ptr]    <= surf_tex_step_reg;
                        fifo_surf_dest_step[fifo_wr_ptr]   <= surf_dest_step_reg;
                        fifo_surf_blockshift[fifo_wr_ptr]  <= reg_wdata[2:0];
                        fifo_wr_ptr <= ~fifo_wr_ptr;
                        did_enqueue = 1'b1;
                    end else begin
                        fifo_overflow <= 1'b1;
                    end
                end

                default: ;
            endcase
        end

        // Execution FSM
        case (state)
            ST_IDLE: begin
                // If a command is queued in the FIFO, launch it.
                if (fifo_count > 2'd0) begin
                    if (fifo_is_z[fifo_rd_ptr]) begin
                        cur_zaddr    <= fifo_zaddr[fifo_rd_ptr];
                        cur_izi      <= fifo_izi[fifo_rd_ptr];
                        cur_zistep   <= fifo_zistep[fifo_rd_ptr];
                        z_remaining  <= fifo_zcount[fifo_rd_ptr];
                        z_issue_pair <= 1'b0;
                        cmd_issued   <= 1'b0;
                        seen_busy    <= 1'b0;
                        state        <= ST_Z_WRITE;
                    end else if (fifo_is_surf[fifo_rd_ptr]) begin
                        surf_fb_base   <= fifo_fb[fifo_rd_ptr];
                        surf_tex_base  <= fifo_tex_addr[fifo_rd_ptr];
                        surf_ll        <= fifo_surf_light_tl[fifo_rd_ptr];
                        surf_lr        <= fifo_surf_light_tr[fifo_rd_ptr];
                        surf_light_bl_reg <= fifo_surf_light_bl[fifo_rd_ptr];
                        surf_light_br_reg <= fifo_surf_light_br[fifo_rd_ptr];
                        surf_blockshift <= fifo_surf_blockshift[fifo_rd_ptr];
                        surf_tex_step  <= fifo_surf_tex_step[fifo_rd_ptr];
                        surf_dest_step <= fifo_surf_dest_step[fifo_rd_ptr];
                        surf_block_active <= 1'b1;
                        cmd_issued     <= 1'b0;
                        seen_busy      <= 1'b0;
                        state          <= ST_SURF_INIT;
                    end else begin
                        cur_fb        <= fifo_fb[fifo_rd_ptr];
                        cur_tex_addr  <= fifo_tex_addr[fifo_rd_ptr];
                        cur_tex_width <= fifo_tex_wh[fifo_rd_ptr][15:0];
                        cur_tex_height <= fifo_tex_wh[fifo_rd_ptr][31:16];
                        cur_s         <= fifo_s[fifo_rd_ptr];
                        cur_t         <= fifo_t[fifo_rd_ptr];
                        cur_sstep     <= fifo_sstep[fifo_rd_ptr];
                        cur_tstep     <= fifo_tstep[fifo_rd_ptr];
                        cur_light     <= fifo_light[fifo_rd_ptr];
                        cur_lightstep <= fifo_lightstep[fifo_rd_ptr];
                        cur_cmap_en   <= fifo_cmap_en[fifo_rd_ptr];
                        cur_turb_en   <= fifo_turb_en[fifo_rd_ptr];
                        remaining     <= fifo_count_f[fifo_rd_ptr];
                        cmd_issued    <= 1'b0;
                        seen_busy     <= 1'b0;
                        tex_addr_for_turb <= 1'b0;
                        state         <= ST_TEX_ADDR;
                    end
                    fifo_rd_ptr <= ~fifo_rd_ptr;
                    did_dequeue = 1'b1;
                end
            end

            ST_TEX_ADDR: begin
                // Wait state: 1 cycle for tex_offset_r to settle with correct
                // cur_s/cur_t values. Next cycle (ST_TEX_CACHE) will register the
                // cache lookup result using the now-correct address.
                // Issue prefetch read if pending and SDRAM idle
                if (pf_pending && !sdram_busy && !pf_filling) begin
                    sdram_rd        <= 1'b1;
                    sdram_addr      <= pf_addr;
                    sdram_burst_len <= 3'd3;
                    pf_filling      <= 1'b1;
                    pf_fill_count   <= 2'd0;
                    pf_pending      <= 1'b0;
                end
                state <= ST_TEX_M10K;
            end

            ST_TEX_M10K: begin
                // M10K synchronous read latency: tex_byte_addr_r settled in
                // ST_TEX_ADDR, but M10K reads capture at the edge entering this
                // state using the OLD address. This cycle lets the M10K read
                // capture using the CORRECT address (at the edge leaving here).
                state <= ST_TEX_CACHE;
            end

            ST_TEX_CACHE: begin
                // M10K data now valid for the correct cache index.
                // Register cache hit/data for ST_PIXEL / ST_TURB_FETCH.
                cache_hit_r  <= cache_hit_comb;
                cache_data_r <= cache_hit_data;
                state <= tex_addr_for_turb ? ST_TURB_FETCH : ST_PIXEL;
            end

            ST_PIXEL: begin
                if (cur_turb_en) begin
                    // Turb mode: issue dual LUT reads, then compute distorted coords
                    turb_lut_addr_a <= (cur_t[22:16] + turb_phase_reg) & 7'h7F;
                    turb_lut_addr_b <= (cur_s[22:16] + turb_phase_reg) & 7'h7F;
                    state <= ST_TURB_CALC;
                end else if (cache_hit_r) begin
                    if (cur_cmap_en) begin
                        // Cache hit + colormap: present cmap address, wait for BRAM
                        cmap_byte_sel_r <= cached_byte[1:0];
                        state <= ST_CMAP_WAIT;
                    end else begin
                        // Cache hit, no colormap: accumulate directly (1 cycle per pixel)
                        case (fb_byte_sel)
                            2'd0: acc_data[7:0]   <= cached_byte;
                            2'd1: acc_data[15:8]  <= cached_byte;
                            2'd2: acc_data[23:16] <= cached_byte;
                            2'd3: acc_data[31:24] <= cached_byte;
                        endcase
                        acc_strb <= acc_strb | (4'b0001 << fb_byte_sel);
                        if (acc_strb == 4'b0000)
                            acc_addr <= fb_word_addr;
                        cur_fb    <= cur_fb + 32'd1;
                        cur_s     <= next_s_clamped;
                        cur_t     <= next_t_clamped;
                        remaining <= remaining - 16'd1;
                        if (fb_byte_sel == 2'd3 || remaining == 16'd1) begin
                            cmd_issued <= 1'b0;
                            seen_busy  <= 1'b0;
                            state      <= ST_FB_WRITE;
                        end else begin
                            tex_addr_for_turb <= 1'b0;
                            state <= ST_TEX_ADDR;
                        end
                    end
                end else begin
                    state <= ST_TEX_READ;
                end
            end

            ST_TEX_READ: begin
                if (pf_filling) begin
                    // Prefetch in-flight — wait for it to complete.
                    // Background fill handler (above) will set pf_just_finished
                    // when done, which re-checks cache on next cycle.
                end else if (pf_just_finished) begin
                    // Prefetch just completed — re-check cache (may have filled our line)
                    tex_addr_for_turb <= cur_turb_en;
                    state <= ST_TEX_ADDR;
                end else if (!sdram_busy) begin
                    sdram_rd        <= 1'b1;
                    sdram_addr      <= {tex_word_addr[23:2], 2'b00}; // Align to 4-word boundary
                    sdram_burst_len <= 3'd3;                          // 4 words
                    fill_count      <= 2'd0;
                    cmd_issued      <= 1'b1;
                    pf_pending      <= 1'b0;  // Cancel stale prefetch
                    state           <= ST_TEX_WAIT;
                end
            end

            ST_TEX_WAIT: begin
                // Cache line fill: data writes handled by M10K always blocks (tc_fill_wr path).
                if (sdram_rdata_valid) begin
                    if (fill_count == 2'd3) begin
                        // All 4 words received — finalize cache line
                        tex_cache_tag[cache_idx] <= cache_tag;
                        tex_cache_valid <= tex_cache_valid | (16'b1 << cache_idx);
                        cmd_issued <= 1'b0;
                        // Schedule prefetch of next sequential cache line
                        pf_addr    <= pf_next_addr;
                        pf_idx     <= pf_next_addr[5:2];
                        pf_tag     <= pf_next_addr[23:6];
                        pf_pending <= 1'b1;
                        // Re-enter address pipeline → guaranteed cache hit
                        tex_addr_for_turb <= cur_turb_en;
                        state <= ST_TEX_ADDR;
                    end else begin
                        fill_count <= fill_count + 2'd1;
                    end
                end
            end

            ST_CMAP_WAIT: begin
                // Colormap BRAM data ready (1 cycle after address presented)
                case (fb_byte_sel)
                    2'd0: acc_data[7:0]   <= cmap_result_byte;
                    2'd1: acc_data[15:8]  <= cmap_result_byte;
                    2'd2: acc_data[23:16] <= cmap_result_byte;
                    2'd3: acc_data[31:24] <= cmap_result_byte;
                endcase
                acc_strb <= acc_strb | (4'b0001 << fb_byte_sel);
                if (acc_strb == 4'b0000)
                    acc_addr <= fb_word_addr;
                cur_fb    <= cur_fb + 32'd1;
                cur_s     <= next_s_clamped;
                cur_t     <= next_t_clamped;
                cur_light <= cur_light + cur_lightstep;
                remaining <= remaining - 16'd1;
                if (fb_byte_sel == 2'd3 || remaining == 16'd1) begin
                    cmd_issued <= 1'b0;
                    seen_busy  <= 1'b0;
                    state      <= ST_FB_WRITE;
                end else begin
                    tex_addr_for_turb <= 1'b0;
                    state <= ST_TEX_ADDR;
                end
            end

            ST_TURB_CALC: begin
                // LUT data ready (1 cycle after address issued in ST_PIXEL).
                // turb_lut_rd_a was indexed by t, turb_lut_rd_b by s.
                // sturb = ((s + turb[t_idx]) >> 16) & 63
                // tturb = ((t + turb[s_idx]) >> 16) & 63
                turb_s_r <= (cur_s + turb_lut_rd_a) >> 16;
                turb_t_r <= (cur_t + turb_lut_rd_b) >> 16;
                tex_addr_for_turb <= 1'b1;
                state <= ST_TEX_ADDR;
            end

            ST_TURB_FETCH: begin
                // tex_byte_addr now uses turb_s_r/turb_t_r via s_int_eff/t_int_eff mux.
                // Same logic as ST_PIXEL but with turb-distorted texture address.
                if (cache_hit_r) begin
                    if (cur_cmap_en) begin
                        cmap_byte_sel_r <= cached_byte[1:0];
                        state <= ST_CMAP_WAIT;
                    end else begin
                        case (fb_byte_sel)
                            2'd0: acc_data[7:0]   <= cached_byte;
                            2'd1: acc_data[15:8]  <= cached_byte;
                            2'd2: acc_data[23:16] <= cached_byte;
                            2'd3: acc_data[31:24] <= cached_byte;
                        endcase
                        acc_strb <= acc_strb | (4'b0001 << fb_byte_sel);
                        if (acc_strb == 4'b0000)
                            acc_addr <= fb_word_addr;
                        cur_fb    <= cur_fb + 32'd1;
                        cur_s     <= next_s_clamped;
                        cur_t     <= next_t_clamped;
                        remaining <= remaining - 16'd1;
                        if (fb_byte_sel == 2'd3 || remaining == 16'd1) begin
                            cmd_issued <= 1'b0;
                            seen_busy  <= 1'b0;
                            state      <= ST_FB_WRITE;
                        end else begin
                            tex_addr_for_turb <= 1'b0;
                            state <= ST_TEX_ADDR;
                        end
                    end
                end else begin
                    state <= ST_TEX_READ;
                end
            end

            ST_FB_WRITE: begin
                if (!sdram_busy) begin
                    sdram_wr    <= 1'b1;
                    sdram_addr  <= acc_addr;
                    sdram_wdata <= acc_data;
                    sdram_wstrb <= acc_strb;
                    if (remaining > 16'd0) begin
                        // Write-behind: continue pixel processing while SDRAM handles write
                        acc_strb          <= 4'b0000;
                        tex_addr_for_turb <= 1'b0;
                        state             <= ST_TEX_ADDR;
                    end else begin
                        // Last write of span: need ST_FB_WAIT for dequeue logic
                        cmd_issued  <= 1'b1;
                        seen_busy   <= 1'b0;
                        state       <= ST_FB_WAIT;
                    end
                end
            end

            ST_FB_WAIT: begin
                if (sdram_busy)
                    seen_busy <= 1'b1;

                if (cmd_issued && seen_busy && !sdram_busy) begin
                    cmd_issued <= 1'b0;
                    acc_strb   <= 4'b0000;

                    if (remaining == 16'd0) begin
                        if (surf_block_active && surf_rows_remaining > 5'd0) begin
                            state <= ST_SURF_ROW_SETUP;
                        end else begin
                            surf_block_active <= 1'b0;
                            if (fifo_count > 2'd0 || did_enqueue) begin
                                if (fifo_is_z[fifo_rd_ptr]) begin
                                    cur_zaddr    <= fifo_zaddr[fifo_rd_ptr];
                                    cur_izi      <= fifo_izi[fifo_rd_ptr];
                                    cur_zistep   <= fifo_zistep[fifo_rd_ptr];
                                    z_remaining  <= fifo_zcount[fifo_rd_ptr];
                                    z_issue_pair <= 1'b0;
                                    seen_busy    <= 1'b0;
                                    state        <= ST_Z_WRITE;
                                end else if (fifo_is_surf[fifo_rd_ptr]) begin
                                    surf_fb_base   <= fifo_fb[fifo_rd_ptr];
                                    surf_tex_base  <= fifo_tex_addr[fifo_rd_ptr];
                                    surf_ll        <= fifo_surf_light_tl[fifo_rd_ptr];
                                    surf_lr        <= fifo_surf_light_tr[fifo_rd_ptr];
                                    surf_light_bl_reg <= fifo_surf_light_bl[fifo_rd_ptr];
                                    surf_light_br_reg <= fifo_surf_light_br[fifo_rd_ptr];
                                    surf_blockshift <= fifo_surf_blockshift[fifo_rd_ptr];
                                    surf_tex_step  <= fifo_surf_tex_step[fifo_rd_ptr];
                                    surf_dest_step <= fifo_surf_dest_step[fifo_rd_ptr];
                                    surf_block_active <= 1'b1;
                                    seen_busy      <= 1'b0;
                                    state          <= ST_SURF_INIT;
                                end else begin
                                    cur_fb        <= fifo_fb[fifo_rd_ptr];
                                    cur_tex_addr  <= fifo_tex_addr[fifo_rd_ptr];
                                    cur_tex_width <= fifo_tex_wh[fifo_rd_ptr][15:0];
                                    cur_tex_height <= fifo_tex_wh[fifo_rd_ptr][31:16];
                                    cur_s         <= fifo_s[fifo_rd_ptr];
                                    cur_t         <= fifo_t[fifo_rd_ptr];
                                    cur_sstep     <= fifo_sstep[fifo_rd_ptr];
                                    cur_tstep     <= fifo_tstep[fifo_rd_ptr];
                                    cur_light     <= fifo_light[fifo_rd_ptr];
                                    cur_lightstep <= fifo_lightstep[fifo_rd_ptr];
                                    cur_cmap_en   <= fifo_cmap_en[fifo_rd_ptr];
                                    cur_turb_en   <= fifo_turb_en[fifo_rd_ptr];
                                    remaining     <= fifo_count_f[fifo_rd_ptr];
                                    seen_busy     <= 1'b0;
                                    tex_addr_for_turb <= 1'b0;
                                    state         <= ST_TEX_ADDR;
                                end
                                fifo_rd_ptr <= ~fifo_rd_ptr;
                                did_dequeue = 1'b1;
                            end else begin
                                state <= ST_IDLE;
                            end
                        end
                    end else begin
                        tex_addr_for_turb <= 1'b0;
                        state <= ST_TEX_ADDR;
                    end
                end
            end

            ST_Z_WRITE: begin
                if (!sram_busy) begin
                    sram_wr    <= 1'b1;
                    sram_addr  <= {6'd0, cur_zaddr[17:2]};  // SRAM word addr (256KB range)
                    if (z_can_pair) begin
                        // Packed 2x16-bit z write into one 32-bit SRAM word
                        sram_wdata  <= {z_value1, z_value0};
                        sram_wstrb  <= 4'b1111;
                        z_issue_pair <= 1'b1;
                    end else begin
                        sram_wdata  <= {z_value0, z_value0};
                        sram_wstrb  <= z_half_sel ? 4'b1100 : 4'b0011;
                        z_issue_pair <= 1'b0;
                    end
                    cmd_issued <= 1'b1;
                    seen_busy  <= 1'b0;
                    state      <= ST_Z_WAIT;
                end
            end

            ST_Z_WAIT: begin
                if (sram_busy)
                    seen_busy <= 1'b1;

                if (cmd_issued && seen_busy && !sram_busy) begin
                    cmd_issued <= 1'b0;

                    if (z_issue_pair) begin
                        cur_zaddr <= cur_zaddr + 32'd4;
                        cur_izi <= cur_izi + (cur_zistep << 1);
                        z_remaining <= z_remaining - 16'd2;

                        if (z_remaining <= 16'd2) begin
                            if (fifo_count > 2'd0 || did_enqueue) begin
                                if (fifo_is_z[fifo_rd_ptr]) begin
                                    cur_zaddr    <= fifo_zaddr[fifo_rd_ptr];
                                    cur_izi      <= fifo_izi[fifo_rd_ptr];
                                    cur_zistep   <= fifo_zistep[fifo_rd_ptr];
                                    z_remaining  <= fifo_zcount[fifo_rd_ptr];
                                    z_issue_pair <= 1'b0;
                                    seen_busy    <= 1'b0;
                                    state        <= ST_Z_WRITE;
                                end else if (fifo_is_surf[fifo_rd_ptr]) begin
                                    surf_fb_base   <= fifo_fb[fifo_rd_ptr];
                                    surf_tex_base  <= fifo_tex_addr[fifo_rd_ptr];
                                    surf_ll        <= fifo_surf_light_tl[fifo_rd_ptr];
                                    surf_lr        <= fifo_surf_light_tr[fifo_rd_ptr];
                                    surf_light_bl_reg <= fifo_surf_light_bl[fifo_rd_ptr];
                                    surf_light_br_reg <= fifo_surf_light_br[fifo_rd_ptr];
                                    surf_blockshift <= fifo_surf_blockshift[fifo_rd_ptr];
                                    surf_tex_step  <= fifo_surf_tex_step[fifo_rd_ptr];
                                    surf_dest_step <= fifo_surf_dest_step[fifo_rd_ptr];
                                    surf_block_active <= 1'b1;
                                    seen_busy      <= 1'b0;
                                    state          <= ST_SURF_INIT;
                                end else begin
                                    cur_fb        <= fifo_fb[fifo_rd_ptr];
                                    cur_tex_addr  <= fifo_tex_addr[fifo_rd_ptr];
                                    cur_tex_width <= fifo_tex_wh[fifo_rd_ptr][15:0];
                                    cur_tex_height <= fifo_tex_wh[fifo_rd_ptr][31:16];
                                    cur_s         <= fifo_s[fifo_rd_ptr];
                                    cur_t         <= fifo_t[fifo_rd_ptr];
                                    cur_sstep     <= fifo_sstep[fifo_rd_ptr];
                                    cur_tstep     <= fifo_tstep[fifo_rd_ptr];
                                    cur_light     <= fifo_light[fifo_rd_ptr];
                                    cur_lightstep <= fifo_lightstep[fifo_rd_ptr];
                                    cur_cmap_en   <= fifo_cmap_en[fifo_rd_ptr];
                                    cur_turb_en   <= fifo_turb_en[fifo_rd_ptr];
                                    remaining     <= fifo_count_f[fifo_rd_ptr];
                                    seen_busy     <= 1'b0;
                                    tex_addr_for_turb <= 1'b0;
                                    state         <= ST_TEX_ADDR;
                                end
                                fifo_rd_ptr <= ~fifo_rd_ptr;
                                did_dequeue = 1'b1;
                            end else begin
                                state <= ST_IDLE;
                            end
                        end else begin
                            state <= ST_Z_WRITE;
                        end
                    end else begin
                        cur_zaddr <= cur_zaddr + 32'd2;
                        cur_izi <= cur_izi + cur_zistep;
                        z_remaining <= z_remaining - 16'd1;

                        if (z_remaining <= 16'd1) begin
                            if (fifo_count > 2'd0 || did_enqueue) begin
                                if (fifo_is_z[fifo_rd_ptr]) begin
                                    cur_zaddr    <= fifo_zaddr[fifo_rd_ptr];
                                    cur_izi      <= fifo_izi[fifo_rd_ptr];
                                    cur_zistep   <= fifo_zistep[fifo_rd_ptr];
                                    z_remaining  <= fifo_zcount[fifo_rd_ptr];
                                    z_issue_pair <= 1'b0;
                                    seen_busy    <= 1'b0;
                                    state        <= ST_Z_WRITE;
                                end else if (fifo_is_surf[fifo_rd_ptr]) begin
                                    surf_fb_base   <= fifo_fb[fifo_rd_ptr];
                                    surf_tex_base  <= fifo_tex_addr[fifo_rd_ptr];
                                    surf_ll        <= fifo_surf_light_tl[fifo_rd_ptr];
                                    surf_lr        <= fifo_surf_light_tr[fifo_rd_ptr];
                                    surf_light_bl_reg <= fifo_surf_light_bl[fifo_rd_ptr];
                                    surf_light_br_reg <= fifo_surf_light_br[fifo_rd_ptr];
                                    surf_blockshift <= fifo_surf_blockshift[fifo_rd_ptr];
                                    surf_tex_step  <= fifo_surf_tex_step[fifo_rd_ptr];
                                    surf_dest_step <= fifo_surf_dest_step[fifo_rd_ptr];
                                    surf_block_active <= 1'b1;
                                    seen_busy      <= 1'b0;
                                    state          <= ST_SURF_INIT;
                                end else begin
                                    cur_fb        <= fifo_fb[fifo_rd_ptr];
                                    cur_tex_addr  <= fifo_tex_addr[fifo_rd_ptr];
                                    cur_tex_width <= fifo_tex_wh[fifo_rd_ptr][15:0];
                                    cur_tex_height <= fifo_tex_wh[fifo_rd_ptr][31:16];
                                    cur_s         <= fifo_s[fifo_rd_ptr];
                                    cur_t         <= fifo_t[fifo_rd_ptr];
                                    cur_sstep     <= fifo_sstep[fifo_rd_ptr];
                                    cur_tstep     <= fifo_tstep[fifo_rd_ptr];
                                    cur_light     <= fifo_light[fifo_rd_ptr];
                                    cur_lightstep <= fifo_lightstep[fifo_rd_ptr];
                                    cur_cmap_en   <= fifo_cmap_en[fifo_rd_ptr];
                                    cur_turb_en   <= fifo_turb_en[fifo_rd_ptr];
                                    remaining     <= fifo_count_f[fifo_rd_ptr];
                                    seen_busy     <= 1'b0;
                                    tex_addr_for_turb <= 1'b0;
                                    state         <= ST_TEX_ADDR;
                                end
                                fifo_rd_ptr <= ~fifo_rd_ptr;
                                did_dequeue = 1'b1;
                            end else begin
                                state <= ST_IDLE;
                            end
                        end else begin
                            state <= ST_Z_WRITE;
                        end
                    end
                end
            end

            ST_SURF_INIT: begin
                // Compute per-row light steps from corners
                surf_lls <= (surf_blockshift == 3'd4) ?
                    (($signed(surf_light_bl_reg) - $signed(surf_ll)) >>> 4) :
                    (surf_blockshift == 3'd3) ?
                    (($signed(surf_light_bl_reg) - $signed(surf_ll)) >>> 3) :
                    (surf_blockshift == 3'd2) ?
                    (($signed(surf_light_bl_reg) - $signed(surf_ll)) >>> 2) :
                    (($signed(surf_light_bl_reg) - $signed(surf_ll)) >>> 1);
                surf_lrs <= (surf_blockshift == 3'd4) ?
                    (($signed(surf_light_br_reg) - $signed(surf_lr)) >>> 4) :
                    (surf_blockshift == 3'd3) ?
                    (($signed(surf_light_br_reg) - $signed(surf_lr)) >>> 3) :
                    (surf_blockshift == 3'd2) ?
                    (($signed(surf_light_br_reg) - $signed(surf_lr)) >>> 2) :
                    (($signed(surf_light_br_reg) - $signed(surf_lr)) >>> 1);
                surf_rows_remaining <= surf_blocksize[4:0];
                state <= ST_SURF_ROW_SETUP;
            end

            ST_SURF_ROW_SETUP: begin
                // Set up standard textured span parameters for one surface row
                cur_fb        <= surf_fb_base;
                cur_tex_addr  <= surf_tex_base;
                cur_tex_width <= surf_blocksize;
                cur_tex_height <= surf_blocksize;
                cur_s         <= 32'd0;
                cur_t         <= 32'd0;
                cur_sstep     <= 32'h00010000;  // 1.0 in 16.16
                cur_tstep     <= 32'd0;
                cur_cmap_en   <= 1'b1;
                cur_turb_en   <= 1'b0;
                remaining     <= surf_blocksize;

                // Computed light for this row
                cur_light     <= surf_row_hw_light;
                cur_lightstep <= surf_row_neg_sw_step;

                // Advance for next row
                surf_ll       <= surf_ll + surf_lls;
                surf_lr       <= surf_lr + surf_lrs;
                surf_fb_base  <= surf_fb_base + surf_dest_step;
                surf_tex_base <= surf_tex_base + surf_tex_step;
                surf_rows_remaining <= surf_rows_remaining - 5'd1;

                cmd_issued        <= 1'b0;
                seen_busy         <= 1'b0;
                tex_addr_for_turb <= 1'b0;
                state             <= ST_TEX_ADDR;
            end

            default: begin
                state <= ST_IDLE;
            end
        endcase

        // Single-point FIFO count update (handles simultaneous enqueue+dequeue)
        case ({did_enqueue, did_dequeue})
            2'b10: fifo_count <= fifo_count + 2'd1;
            2'b01: fifo_count <= fifo_count - 2'd1;
            // 2'b11: simultaneous — net zero change
            // 2'b00: no change
            default: ;
        endcase
    end
end

endmodule
