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
//   0x1C: SPAN_CONTROL    (W)  - Write to enqueue: [15:0]=count, [16]=colormap, [17]=turb, [18]=persp, [19]=combined_z
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
    input wire [5:0]  reg_addr,     // byte_offset[7:2]
    input wire [31:0] reg_wdata,
    output reg [31:0] reg_rdata,

    // AXI4 Master interface (to axi_sdram_arbiter)
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    output reg  [31:0] m_axi_araddr,
    output reg  [7:0]  m_axi_arlen,

    input  wire        m_axi_rvalid,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,

    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output reg  [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,     // Always 0 (single-beat writes)

    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,     // Always 1 (single-beat writes)

    input  wire        m_axi_bvalid,
    input  wire [1:0]  m_axi_bresp,

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

// Static AXI4 ties — single-beat writes only
assign m_axi_awlen = 8'd0;
assign m_axi_wlast = 1'b1;

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

// Perspective staging registers (MMIO slots 26-35)
reg signed [31:0] persp_sdivz_reg;      // Per-span: current sdivz (8.24 signed)
reg signed [31:0] persp_tdivz_reg;      // Per-span: current tdivz (8.24 signed)
reg signed [31:0] persp_zi_reg;         // Per-span: current zi (8.24 signed)
reg signed [31:0] persp_sdivz_step_reg; // Sticky: sdivz step per 16px (8.24)
reg signed [31:0] persp_tdivz_step_reg; // Sticky: tdivz step per 16px (8.24)
reg signed [31:0] persp_zi_step_reg;    // Sticky: zi step per 16px (8.24)
reg signed [31:0] persp_sadjust_reg;    // Sticky: s offset (16.16 signed)
reg signed [31:0] persp_tadjust_reg;    // Sticky: t offset (16.16 signed)
reg [31:0] persp_bbextents_reg;         // Sticky: s clamp upper bound (16.16)
reg [31:0] persp_bbextentt_reg;         // Sticky: t clamp upper bound (16.16)

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

// Combined z-write state (z-values written alongside textured pixels)
reg        cur_combined_z;       // Combined z mode active for current command
reg [31:0] cur_z_addr_comb;     // Current z-buffer byte address (advances +2/pixel)
reg [31:0] cur_izi_comb;        // Current izi (advances by cur_zistep/pixel)

// Z-pair accumulator (packs 2x16-bit z values into one 32-bit SRAM word)
reg [15:0] z_pair_lo;           // Low-half z value
reg        z_pair_has_lo;       // Low half accumulated, waiting for high half
reg [21:0] z_pair_waddr;        // SRAM word address for the pair

// Pending SRAM write (fire-and-forget, retried opportunistically)
reg [31:0] z_pending_data;
reg [3:0]  z_pending_strb;
reg [21:0] z_pending_addr;
reg        z_pending_valid;     // Pending write waiting for !sram_busy

// Surface block active state
reg        surf_block_active;
reg [31:0] surf_ll, surf_lr;
reg signed [31:0] surf_lls, surf_lrs;
reg [31:0] surf_tex_step, surf_dest_step;
reg [4:0]  surf_rows_remaining;
reg [2:0]  surf_blockshift;
reg [31:0] surf_fb_base, surf_tex_base;

// Perspective active state
reg signed [31:0] persp_sdivz_cur;    // Accumulated sdivz
reg signed [31:0] persp_tdivz_cur;    // Accumulated tdivz
reg signed [31:0] persp_zi_cur;       // Accumulated zi
reg [15:0] persp_total_remaining;     // Total pixels left in entire span
reg signed [31:0] persp_s_saved;      // snext saved for next chunk's s
reg signed [31:0] persp_t_saved;      // tnext saved for next chunk's t
reg        persp_is_initial;          // First pass: compute initial s/t
reg        persp_is_last_chunk;       // Last chunk: use inv_lut for step
reg [4:0]  persp_lz;                  // CLZ result (5-bit)
reg [15:0] persp_recip_raw;           // Captured from reciprocal LUT
reg [4:0]  persp_chunk_count;         // Pixels in current chunk (1-16)
reg        cur_persp_en;              // Perspective mode active for current command
reg [3:0]  persp_adv_phase;          // DSP multiply phase for partial chunk advance
reg signed [31:0] persp_sdivz_advance_r;  // Registered partial sdivz advance from DSP
reg signed [31:0] persp_tdivz_advance_r;  // Registered partial tdivz advance from DSP
reg [4:0]  persp_shift_amt;           // Pre-computed shift amount (30 - lz)
reg signed [31:0] persp_shifted_r;   // Registered barrel shift output (product >>> shift_amt)

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

// Perspective FIFO fields
reg signed [31:0] fifo_persp_sdivz [0:1];
reg signed [31:0] fifo_persp_tdivz [0:1];
reg signed [31:0] fifo_persp_zi    [0:1];
reg        fifo_is_persp   [0:1];
reg        fifo_combined_z [0:1];  // Combined z mode flag

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
reg        pf_rd_pending;   // Prefetch arvalid issued, awaiting arready
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

// Reciprocal LUT for perspective correction: 1024 entries x 16-bit
// recip_lut[i] = round(2^25 / (1024 + i)), range [16392, 32768]
(* ramstyle = "M10K" *) reg [15:0] recip_lut [0:1023];
reg [9:0]  recip_lut_addr;
reg [15:0] recip_lut_rd;

initial $readmemh("core/recip_lut.hex", recip_lut);
always @(posedge clk) recip_lut_rd <= recip_lut[recip_lut_addr];

// Inverse LUT for last-chunk step division: inv_lut(n) = round(2^16 / n) for n=1..15
function [15:0] inv_lut;
    input [4:0] n;
    case (n)
        5'd1:  inv_lut = 16'h0000;  // Not used (single pixel, no step needed)
        5'd2:  inv_lut = 16'h8000;
        5'd3:  inv_lut = 16'h5555;
        5'd4:  inv_lut = 16'h4000;
        5'd5:  inv_lut = 16'h3333;
        5'd6:  inv_lut = 16'h2AAB;
        5'd7:  inv_lut = 16'h2492;
        5'd8:  inv_lut = 16'h2000;
        5'd9:  inv_lut = 16'h1C72;
        5'd10: inv_lut = 16'h199A;
        5'd11: inv_lut = 16'h1746;
        5'd12: inv_lut = 16'h1555;
        5'd13: inv_lut = 16'h13B1;
        5'd14: inv_lut = 16'h1249;
        5'd15: inv_lut = 16'h1111;
        default: inv_lut = 16'h0000;
    endcase
endfunction

// DSP multiply (time-multiplexed: perspective s, t, inv_s, inv_t)
// Two-stage registered pipeline for timing closure — 3-cycle latency:
//   Cycle N:   set mul_a, mul_b via NBA
//   Cycle N+1: multiply evaluates, result captured in persp_mul_pipe (DSP output reg)
//   Cycle N+2: persp_mul_pipe → persp_product (clean fabric register)
//   Cycle N+3: persp_product valid, safe to read
// The two-stage pipeline breaks the critical path: DSP partial product carry chain
// was being combined with downstream barrel shift + add + clamp (~13.7ns total).
// With the extra register stage, each half fits within 10ns.
reg signed [31:0] persp_mul_a;
reg signed [16:0] persp_mul_b;  // 17-bit signed (sign-extended unsigned recip/inv)
reg signed [48:0] persp_mul_pipe;   // Stage 1: DSP output register
(* dont_merge, preserve *) reg signed [48:0] persp_product;  // Stage 2: clean fabric register

always @(posedge clk) begin
    persp_mul_pipe <= persp_mul_a * persp_mul_b;
    persp_product  <= persp_mul_pipe;
end

// CLZ (count leading zeros) function — combinational 32-bit priority encoder
function [4:0] clz32;
    input [31:0] val;
    integer k;
    begin
        clz32 = 5'd31;
        for (k = 0; k <= 31; k = k + 1)
            if (val[k]) clz32 = 31 - k;
    end
endfunction

// Texture cache M10K write control (combinational, drives M10K always blocks)
// Normal fill (ST_TEX_WAIT) and prefetch fill are mutually exclusive.
wire        tc_fill_wr = (state == ST_TEX_WAIT) && m_axi_rvalid;
wire        tc_pf_wr   = pf_filling && m_axi_rvalid && (state != ST_TEX_WAIT);
wire        tc_wr_en   = tc_fill_wr || tc_pf_wr;
wire [3:0]  tc_wr_addr = tc_fill_wr ? cache_idx : pf_idx;
wire [1:0]  tc_wr_slot = tc_fill_wr ? fill_count : pf_fill_count;

// Texture cache M10K synchronous read outputs
reg [31:0] cache_rd_data0, cache_rd_data1, cache_rd_data2, cache_rd_data3;

always @(posedge clk) begin
    if (tc_wr_en && tc_wr_slot == 2'd0) tex_cache_data0[tc_wr_addr] <= m_axi_rdata;
    cache_rd_data0 <= tex_cache_data0[cache_idx];
end
always @(posedge clk) begin
    if (tc_wr_en && tc_wr_slot == 2'd1) tex_cache_data1[tc_wr_addr] <= m_axi_rdata;
    cache_rd_data1 <= tex_cache_data1[cache_idx];
end
always @(posedge clk) begin
    if (tc_wr_en && tc_wr_slot == 2'd2) tex_cache_data2[tc_wr_addr] <= m_axi_rdata;
    cache_rd_data2 <= tex_cache_data2[cache_idx];
end
always @(posedge clk) begin
    if (tc_wr_en && tc_wr_slot == 2'd3) tex_cache_data3[tc_wr_addr] <= m_axi_rdata;
    cache_rd_data3 <= tex_cache_data3[cache_idx];
end

// FSM
localparam ST_IDLE       = 6'd0;
localparam ST_PIXEL      = 6'd1;
localparam ST_TEX_READ   = 6'd2;
localparam ST_TEX_WAIT   = 6'd3;
localparam ST_FB_WRITE   = 6'd4;
localparam ST_FB_WAIT    = 6'd5;
localparam ST_Z_WRITE    = 6'd6;
localparam ST_Z_WAIT     = 6'd7;
localparam ST_CMAP_WAIT  = 6'd8;
localparam ST_TURB_CALC  = 6'd9;
localparam ST_TURB_FETCH = 6'd10;
localparam ST_TEX_ADDR   = 6'd11;
localparam ST_TEX_CACHE      = 6'd12;
localparam ST_SURF_INIT      = 6'd13;
localparam ST_SURF_ROW_SETUP = 6'd14;
localparam ST_TEX_M10K       = 6'd15;  // M10K read latency wait (1 cycle for synchronous read)
// Perspective correction states
localparam ST_PERSP_INIT     = 6'd16;  // CLZ(zi_cur)
localparam ST_PERSP_LUT      = 6'd17;  // Compute LUT addr from registered CLZ
localparam ST_PERSP_LUT2     = 6'd18;  // M10K recip LUT read latency
localparam ST_PERSP_MUL_S    = 6'd19;  // Capture recip_raw, set mul inputs sdivz*recip
localparam ST_PERSP_MUL_S_W  = 6'd20;  // Wait 1: DSP 3-cycle pipeline latency
localparam ST_PERSP_MUL_S_W2 = 6'd32;  // Wait 2: DSP 3-cycle pipeline latency
localparam ST_PERSP_MUL_T    = 6'd21;  // Read s product, set mul inputs tdivz*recip
localparam ST_PERSP_MUL_T_W  = 6'd22;  // Wait 1: DSP 3-cycle pipeline latency
localparam ST_PERSP_MUL_T_W2 = 6'd33;  // Wait 2: DSP 3-cycle pipeline latency
localparam ST_PERSP_CLAMP    = 6'd23;  // Read t product, shift, adjust, clamp → snext/tnext
localparam ST_PERSP_ACCUM    = 6'd24;  // Advance sdivz/tdivz/zi, CLZ
localparam ST_PERSP_STEP     = 6'd25;  // Compute sstep/tstep or set inv multiply inputs
localparam ST_PERSP_INV_W    = 6'd26;  // Wait 1: DSP multiply for (snext-s)*inv
localparam ST_PERSP_INV_W2   = 6'd34;  // Wait 2: DSP multiply for (snext-s)*inv
localparam ST_PERSP_INV      = 6'd27;  // Read s inv product, set t inv multiply inputs
localparam ST_PERSP_INV2_W   = 6'd28;  // Wait 1: DSP multiply for (tnext-t)*inv
localparam ST_PERSP_INV2_W2  = 6'd35;  // Wait 2: DSP multiply for (tnext-t)*inv
localparam ST_PERSP_INV2     = 6'd29;  // Read t inv product, launch chunk
localparam ST_Z_FLUSH        = 6'd30;  // Wait for combined z pending write to flush
localparam ST_PERSP_ADVANCE  = 6'd31;  // Compute & apply perspective chunk advance (multiply separated from clamp)
localparam ST_PERSP_CLAMP2   = 6'd36;  // Add adjust + clamp s/t (from registered barrel shift)
reg [5:0] state;
reg       cmd_issued;      // Used for SRAM z-write path
reg       seen_busy;       // Used for SRAM z-write path
reg       fb_wr_launched;  // AXI4 write AW+W asserted, waiting for acceptance

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
// Turb mode: no clamping needed — 6-bit turb_s_r/turb_t_r wrap naturally.
// Software wraps turb s/t to [0,128) via & ((CYCLE<<16)-1); clamping at 64 corrupts
// any turb span where s/t steps past the texture width within a chunk.
wire [31:0] next_s_clamped = cur_turb_en ? next_s : (next_s_over ? {cur_tex_width  - 16'd1, 16'hFFFF} : next_s);
wire [31:0] next_t_clamped = cur_turb_en ? next_t : (next_t_over ? {cur_tex_height - 16'd1, 16'hFFFF} : next_t);

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

// Performance counters (read/write-clear via register mux)
reg [31:0] perf_cache_hits;
reg [31:0] perf_cache_misses;
reg        perf_counter_pending;  // Deferred update flag (breaks cache compare → counter add path)
reg [31:0] perf_pixels;

integer ci;

wire [7:0] cached_byte =
    (tex_byte_sel == 2'd0) ? cache_data_r[7:0] :
    (tex_byte_sel == 2'd1) ? cache_data_r[15:8] :
    (tex_byte_sel == 2'd2) ? cache_data_r[23:16] :
                             cache_data_r[31:24];

// Byte extraction from SDRAM read data (combinational, for merged TEX_WAIT+ACCUM)
wire [7:0] tex_rdata_byte =
    (tex_byte_sel == 2'd0) ? m_axi_rdata[7:0] :
    (tex_byte_sel == 2'd1) ? m_axi_rdata[15:8] :
    (tex_byte_sel == 2'd2) ? m_axi_rdata[23:16] :
                              m_axi_rdata[31:24];

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

// Z address/value computation (standalone z-span mode)
wire [23:0] z_word_addr = cur_zaddr[25:2];
wire        z_half_sel  = cur_zaddr[1];

// Combined z computation (textured span + z-write mode)
wire [15:0] comb_z_val  = cur_izi_comb[31:16];
wire        comb_z_half = cur_z_addr_comb[1];       // 0=low half, 1=high half
wire [21:0] comb_z_waddr = {6'd0, cur_z_addr_comb[17:2]};  // SRAM word addr

// Combined z high-half write pre-computation (used in ST_PIXEL/ST_CMAP_WAIT)
wire [31:0] comb_zw_data = z_pair_has_lo ? {comb_z_val, z_pair_lo}   : {comb_z_val, 16'd0};
wire [3:0]  comb_zw_strb = z_pair_has_lo ? 4'b1111                   : 4'b1100;
wire [21:0] comb_zw_addr = z_pair_has_lo ? z_pair_waddr              : comb_z_waddr;
wire        comb_zw_direct = !sram_busy && !z_pending_valid;  // Can issue directly
wire [15:0] z_value0    = cur_izi[31:16];
wire [31:0] z_izi_plus_step = cur_izi + cur_zistep;
wire [15:0] z_value1    = z_izi_plus_step[31:16];
wire        z_can_pair  = (!z_half_sel) && (z_remaining >= 16'd2);

// Surface block row light interpolation (used in ST_SURF_ROW_SETUP)
// surf_row_diff_r is a free-running registered subtraction (like tex_byte_addr_r),
// breaking the critical path from state mux → surf_ll update → subtraction → downstream.
reg signed [31:0] surf_row_diff_r;
wire signed [31:0] surf_row_sw_step =
    (surf_blockshift == 3'd4) ? (surf_row_diff_r >>> 4) :
    (surf_blockshift == 3'd3) ? (surf_row_diff_r >>> 3) :
    (surf_blockshift == 3'd2) ? (surf_row_diff_r >>> 2) :
                                (surf_row_diff_r >>> 1);
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
        6'd0:  reg_rdata = fb_addr_reg;
        6'd1:  reg_rdata = tex_addr_reg;
        6'd2:  reg_rdata = {tex_height_reg, tex_width_reg};
        6'd3:  reg_rdata = s_reg;
        6'd4:  reg_rdata = t_reg;
        6'd5:  reg_rdata = sstep_reg;
        6'd6:  reg_rdata = tstep_reg;
        6'd7:  reg_rdata = 32'd0; // write-only
        6'd8:  reg_rdata = {28'd0, fifo_overflow, can_accept, queue_full, busy_status};
        6'd9:  reg_rdata = z_addr_reg;
        6'd10: reg_rdata = zi_reg;
        6'd11: reg_rdata = zistep_reg;
        6'd12: reg_rdata = 32'd0; // write-only
        6'd13: reg_rdata = light_reg;
        6'd14: reg_rdata = lightstep_reg;
        6'd15: reg_rdata = {25'd0, turb_phase_reg};
        6'd16: reg_rdata = surf_light_tl_reg;
        6'd17: reg_rdata = surf_light_tr_reg;
        6'd18: reg_rdata = surf_light_bl_reg;
        6'd19: reg_rdata = surf_light_br_reg;
        6'd20: reg_rdata = surf_tex_step_reg;
        6'd21: reg_rdata = surf_dest_step_reg;
        6'd22: reg_rdata = 32'd0; // SURF_CONTROL write-only
        6'd23: reg_rdata = perf_cache_hits;    // 0x4800005C
        6'd24: reg_rdata = perf_cache_misses;  // 0x48000060
        6'd25: reg_rdata = perf_pixels;        // 0x48000064
        6'd26: reg_rdata = persp_sdivz_reg;
        6'd27: reg_rdata = persp_tdivz_reg;
        6'd28: reg_rdata = persp_zi_reg;
        6'd29: reg_rdata = persp_sdivz_step_reg;
        6'd30: reg_rdata = persp_tdivz_step_reg;
        6'd31: reg_rdata = persp_zi_step_reg;
        6'd32: reg_rdata = persp_sadjust_reg;
        6'd33: reg_rdata = persp_tadjust_reg;
        6'd34: reg_rdata = persp_bbextents_reg;
        6'd35: reg_rdata = persp_bbextentt_reg;
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

        cur_combined_z   <= 1'b0;
        cur_z_addr_comb  <= 32'd0;
        cur_izi_comb     <= 32'd0;
        z_pair_lo        <= 16'd0;
        z_pair_has_lo    <= 1'b0;
        z_pair_waddr     <= 22'd0;
        z_pending_data   <= 32'd0;
        z_pending_strb   <= 4'b0;
        z_pending_addr   <= 22'd0;
        z_pending_valid  <= 1'b0;

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

        surf_row_diff_r   <= 32'sd0;
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
        pf_rd_pending    <= 1'b0;
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

        perf_cache_hits  <= 32'd0;
        perf_cache_misses <= 32'd0;
        perf_pixels      <= 32'd0;
        perf_counter_pending <= 1'b0;

        acc_data         <= 32'd0;
        acc_strb         <= 4'b0000;
        acc_addr         <= 24'd0;

        persp_sdivz_reg      <= 32'sd0;
        persp_tdivz_reg      <= 32'sd0;
        persp_zi_reg         <= 32'sd0;
        persp_sdivz_step_reg <= 32'sd0;
        persp_tdivz_step_reg <= 32'sd0;
        persp_zi_step_reg    <= 32'sd0;
        persp_sadjust_reg    <= 32'sd0;
        persp_tadjust_reg    <= 32'sd0;
        persp_bbextents_reg  <= 32'd0;
        persp_bbextentt_reg  <= 32'd0;
        persp_sdivz_cur      <= 32'sd0;
        persp_tdivz_cur      <= 32'sd0;
        persp_zi_cur         <= 32'sd0;
        persp_total_remaining <= 16'd0;
        persp_s_saved        <= 32'sd0;
        persp_t_saved        <= 32'sd0;
        persp_is_initial     <= 1'b0;
        persp_is_last_chunk  <= 1'b0;
        persp_lz             <= 5'd0;
        persp_recip_raw      <= 16'd0;
        persp_chunk_count    <= 5'd0;
        cur_persp_en         <= 1'b0;
        persp_adv_phase      <= 4'd0;
        persp_sdivz_advance_r <= 32'sd0;
        persp_tdivz_advance_r <= 32'sd0;
        persp_shift_amt      <= 5'd0;
        persp_shifted_r      <= 32'sd0;
        persp_mul_a          <= 32'sd0;
        persp_mul_b          <= 17'sd0;
        // persp_mul_pipe and persp_product driven by standalone always block (no reset needed)
        recip_lut_addr       <= 10'd0;

        state            <= ST_IDLE;
        cmd_issued       <= 1'b0;
        seen_busy        <= 1'b0;
        fb_wr_launched   <= 1'b0;

        m_axi_arvalid    <= 1'b0;
        m_axi_araddr     <= 32'd0;
        m_axi_arlen      <= 8'd0;
        m_axi_awvalid    <= 1'b0;
        m_axi_awaddr     <= 32'd0;
        m_axi_wvalid     <= 1'b0;
        m_axi_wdata      <= 32'd0;
        m_axi_wstrb      <= 4'b0;

        sram_wr          <= 1'b0;
        sram_addr        <= 22'd0;
        sram_wdata       <= 32'd0;
        sram_wstrb       <= 4'b0;
    end else begin : main_logic
        // Blocking flags for simultaneous FIFO enqueue/dequeue handling
        reg did_enqueue, did_dequeue;

        // AXI4 valid/ready handshake: deassert valid when ready fires
        if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            m_axi_arlen   <= 8'd0;
        end
        if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 1'b0;
        if (m_axi_wvalid && m_axi_wready)   m_axi_wvalid  <= 1'b0;
        sram_wr <= 1'b0;

        // Opportunistic combined z-pending flush (runs every cycle, zero pipeline stalls)
        // Only fires when NOT in standalone z-span mode (ST_Z_WRITE/ST_Z_WAIT use sram directly)
        if (z_pending_valid && !sram_busy && state != ST_Z_WRITE && state != ST_Z_WAIT) begin
            sram_wr         <= 1'b1;
            sram_addr       <= z_pending_addr;
            sram_wdata      <= z_pending_data;
            sram_wstrb      <= z_pending_strb;
            z_pending_valid <= 1'b0;
        end

        did_enqueue = 1'b0;
        did_dequeue = 1'b0;

        // Clear pf_just_finished each cycle (one-cycle flag)
        pf_just_finished <= 1'b0;

        // Handle prefetch read acceptance (can happen in any state after ST_TEX_ADDR)
        if (pf_rd_pending && m_axi_arvalid && m_axi_arready) begin
            pf_filling    <= 1'b1;
            pf_fill_count <= 2'd0;
            pf_rd_pending <= 1'b0;
        end

        // Non-blocking prefetch: background cache line fill
        // When prefetch data arrives and FSM is NOT doing a real cache fill,
        // route m_axi_rvalid to the prefetch target cache line.
        // Prefetch fill: data writes handled by M10K always blocks (tc_pf_wr path).
        // Here we only update tag, valid, fill count, and control signals.
        if (pf_filling && m_axi_rvalid && state != ST_TEX_WAIT) begin
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

        // Free-running registered subtraction (breaks state mux → subtraction critical path)
        surf_row_diff_r <= $signed(surf_ll) - $signed(surf_lr);

        // Deferred performance counter update (breaks cache tag compare → 32-bit counter add path)
        // perf_counter_pending is set in ST_TEX_CACHE; cache_hit_r is already registered there.
        if (perf_counter_pending) begin
            if (cache_hit_r)
                perf_cache_hits <= perf_cache_hits + 32'd1;
            else
                perf_cache_misses <= perf_cache_misses + 32'd1;
            perf_counter_pending <= 1'b0;
        end

        // Register writes are always accepted.
        if (reg_wr) begin
            case (reg_addr)
                6'd0: fb_addr_reg   <= reg_wdata;
                6'd1: tex_addr_reg  <= reg_wdata;
                6'd2: begin tex_width_reg <= reg_wdata[15:0]; tex_height_reg <= reg_wdata[31:16]; end
                6'd3: s_reg         <= reg_wdata;
                6'd4: t_reg         <= reg_wdata;
                6'd5: sstep_reg     <= reg_wdata;
                6'd6: tstep_reg     <= reg_wdata;

                6'd7: begin
                    // Enqueue textured span command (bit 18 = perspective mode)
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
                            cur_persp_en  <= reg_wdata[18];
                            cur_combined_z <= reg_wdata[19];
                            remaining     <= reg_wdata[15:0];
                            cmd_issued    <= 1'b0;
                            seen_busy     <= 1'b0;
                            tex_addr_for_turb <= 1'b0;
                            if (reg_wdata[19]) begin
                                cur_z_addr_comb <= z_addr_reg;
                                cur_izi_comb    <= zi_reg;
                                cur_zistep      <= zistep_reg;
                                z_pair_has_lo   <= 1'b0;
                                z_pending_valid <= 1'b0;
                            end
                            if (reg_wdata[18]) begin
                                // Perspective mode: load per-span params → ST_PERSP_INIT
                                persp_sdivz_cur <= persp_sdivz_reg;
                                persp_tdivz_cur <= persp_tdivz_reg;
                                persp_zi_cur    <= persp_zi_reg;
                                persp_total_remaining <= reg_wdata[15:0];
                                persp_is_initial <= 1'b1;
                                state <= ST_PERSP_INIT;
                            end else begin
                                state <= ST_TEX_ADDR;
                            end
                        end else if (fifo_count < 2'd2) begin
                            fifo_is_z[fifo_wr_ptr]      <= 1'b0;
                            fifo_is_surf[fifo_wr_ptr]   <= 1'b0;
                            fifo_is_persp[fifo_wr_ptr]  <= reg_wdata[18];
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
                            fifo_persp_sdivz[fifo_wr_ptr] <= persp_sdivz_reg;
                            fifo_persp_tdivz[fifo_wr_ptr] <= persp_tdivz_reg;
                            fifo_persp_zi[fifo_wr_ptr]    <= persp_zi_reg;
                            fifo_combined_z[fifo_wr_ptr]  <= reg_wdata[19];
                            if (reg_wdata[19]) begin
                                fifo_zaddr[fifo_wr_ptr]   <= z_addr_reg;
                                fifo_izi[fifo_wr_ptr]     <= zi_reg;
                                fifo_zistep[fifo_wr_ptr]  <= zistep_reg;
                            end
                            fifo_wr_ptr <= ~fifo_wr_ptr;
                            did_enqueue = 1'b1;
                        end else begin
                            fifo_overflow <= 1'b1;
                        end
                    end
                end

                6'd13: light_reg    <= reg_wdata;
                6'd14: lightstep_reg <= reg_wdata;
                6'd15: turb_phase_reg <= reg_wdata[6:0];

                6'd23: begin
                    // Write-clear all perf counters
                    perf_cache_hits  <= 32'd0;
                    perf_cache_misses <= 32'd0;
                    perf_pixels      <= 32'd0;
                end

                6'd9:  z_addr_reg   <= reg_wdata;
                6'd10: zi_reg       <= reg_wdata;
                6'd11: zistep_reg   <= reg_wdata;

                6'd12: begin
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

                6'd16: surf_light_tl_reg  <= reg_wdata;
                6'd17: surf_light_tr_reg  <= reg_wdata;
                6'd18: surf_light_bl_reg  <= reg_wdata;
                6'd19: surf_light_br_reg  <= reg_wdata;
                6'd20: surf_tex_step_reg  <= reg_wdata;
                6'd21: surf_dest_step_reg <= reg_wdata;

                6'd22: begin
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

                6'd26: persp_sdivz_reg      <= reg_wdata;
                6'd27: persp_tdivz_reg      <= reg_wdata;
                6'd28: persp_zi_reg         <= reg_wdata;
                6'd29: persp_sdivz_step_reg <= reg_wdata;
                6'd30: persp_tdivz_step_reg <= reg_wdata;
                6'd31: persp_zi_step_reg    <= reg_wdata;
                6'd32: persp_sadjust_reg    <= reg_wdata;
                6'd33: persp_tadjust_reg    <= reg_wdata;
                6'd34: persp_bbextents_reg  <= reg_wdata;
                6'd35: persp_bbextentt_reg  <= reg_wdata;

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
                        cur_persp_en  <= fifo_is_persp[fifo_rd_ptr];
                        cur_combined_z <= fifo_combined_z[fifo_rd_ptr];
                        remaining     <= fifo_count_f[fifo_rd_ptr];
                        cmd_issued    <= 1'b0;
                        seen_busy     <= 1'b0;
                        tex_addr_for_turb <= 1'b0;
                        if (fifo_combined_z[fifo_rd_ptr]) begin
                            cur_z_addr_comb <= fifo_zaddr[fifo_rd_ptr];
                            cur_izi_comb    <= fifo_izi[fifo_rd_ptr];
                            cur_zistep      <= fifo_zistep[fifo_rd_ptr];
                            z_pair_has_lo   <= 1'b0;
                            z_pending_valid <= 1'b0;
                        end
                        if (fifo_is_persp[fifo_rd_ptr]) begin
                            persp_sdivz_cur <= fifo_persp_sdivz[fifo_rd_ptr];
                            persp_tdivz_cur <= fifo_persp_tdivz[fifo_rd_ptr];
                            persp_zi_cur    <= fifo_persp_zi[fifo_rd_ptr];
                            persp_total_remaining <= fifo_count_f[fifo_rd_ptr];
                            persp_is_initial <= 1'b1;
                            state <= ST_PERSP_INIT;
                        end else begin
                            state <= ST_TEX_ADDR;
                        end
                    end
                    fifo_rd_ptr <= ~fifo_rd_ptr;
                    did_dequeue = 1'b1;
                end
            end

            ST_TEX_ADDR: begin
                // Wait state: 1 cycle for tex_offset_r to settle with correct
                // cur_s/cur_t values. Next cycle (ST_TEX_CACHE) will register the
                // cache lookup result using the now-correct address.
                // Issue prefetch read if pending and no outstanding AXI read.
                // arvalid is held until arready (handled above state machine).
                if (pf_pending && !pf_filling && !pf_rd_pending && !m_axi_arvalid) begin
                    m_axi_arvalid   <= 1'b1;
                    m_axi_araddr    <= {6'b0, pf_addr, 2'b00};
                    m_axi_arlen     <= 8'd3;
                    pf_rd_pending   <= 1'b1;
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
                // Performance counters: cache hit/miss deferred to next cycle
                // (breaks cache tag compare → 32-bit counter add critical path)
                perf_counter_pending <= 1'b1;
                if (!tex_addr_for_turb)
                    perf_pixels <= perf_pixels + 32'd1;
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

                        // Combined z accumulation (fire-and-forget SRAM writes)
                        if (cur_combined_z) begin
                            if (!comb_z_half) begin
                                // Low half: accumulate into z_pair
                                z_pair_lo     <= comb_z_val;
                                z_pair_waddr  <= comb_z_waddr;
                                z_pair_has_lo <= 1'b1;
                                // Last pixel of entire span with dangling low half → flush
                                if (remaining == 16'd1 && (!cur_persp_en || persp_total_remaining == 16'd0)) begin
                                    z_pending_data  <= {16'd0, comb_z_val};
                                    z_pending_strb  <= 4'b0011;
                                    z_pending_addr  <= comb_z_waddr;
                                    z_pending_valid <= 1'b1;
                                    z_pair_has_lo   <= 1'b0;
                                end
                            end else begin
                                // High half: complete pair or odd-start single
                                if (comb_zw_direct) begin
                                    sram_wr    <= 1'b1;
                                    sram_addr  <= comb_zw_addr;
                                    sram_wdata <= comb_zw_data;
                                    sram_wstrb <= comb_zw_strb;
                                end else begin
                                    z_pending_data  <= comb_zw_data;
                                    z_pending_strb  <= comb_zw_strb;
                                    z_pending_addr  <= comb_zw_addr;
                                    z_pending_valid <= 1'b1;
                                end
                                z_pair_has_lo <= 1'b0;
                            end
                            cur_izi_comb    <= cur_izi_comb + cur_zistep;
                            cur_z_addr_comb <= cur_z_addr_comb + 32'd2;
                        end

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
                end else if (pf_rd_pending) begin
                    // Prefetch read not yet accepted — wait for it before
                    // issuing our cache miss read (can't overlap requests).
                end else if (pf_just_finished) begin
                    // Prefetch just completed — re-check cache (may have filled our line)
                    tex_addr_for_turb <= cur_turb_en;
                    state <= ST_TEX_ADDR;
                end else if (m_axi_arvalid && m_axi_arready) begin
                    // Arbiter accepted our cache miss read — wait for data
                    fill_count      <= 2'd0;
                    pf_pending      <= 1'b0;  // Cancel stale prefetch
                    state           <= ST_TEX_WAIT;
                end else if (!m_axi_arvalid) begin
                    // Issue cache miss read — hold until accepted
                    m_axi_arvalid   <= 1'b1;
                    m_axi_araddr    <= {6'b0, tex_word_addr[23:2], 2'b00, 2'b00};
                    m_axi_arlen     <= 8'd3;
                end
            end

            ST_TEX_WAIT: begin
                // Cache line fill: data writes handled by M10K always blocks (tc_fill_wr path).
                if (m_axi_rvalid) begin
                    if (fill_count == 2'd3) begin
                        // All 4 words received — finalize cache line
                        tex_cache_tag[cache_idx] <= cache_tag;
                        tex_cache_valid <= tex_cache_valid | (16'b1 << cache_idx);
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

                // Combined z accumulation (fire-and-forget SRAM writes)
                if (cur_combined_z) begin
                    if (!comb_z_half) begin
                        z_pair_lo     <= comb_z_val;
                        z_pair_waddr  <= comb_z_waddr;
                        z_pair_has_lo <= 1'b1;
                        if (remaining == 16'd1 && (!cur_persp_en || persp_total_remaining == 16'd0)) begin
                            z_pending_data  <= {16'd0, comb_z_val};
                            z_pending_strb  <= 4'b0011;
                            z_pending_addr  <= comb_z_waddr;
                            z_pending_valid <= 1'b1;
                            z_pair_has_lo   <= 1'b0;
                        end
                    end else begin
                        // High half: complete pair or odd-start single
                        if (comb_zw_direct) begin
                            sram_wr    <= 1'b1;
                            sram_addr  <= comb_zw_addr;
                            sram_wdata <= comb_zw_data;
                            sram_wstrb <= comb_zw_strb;
                        end else begin
                            z_pending_data  <= comb_zw_data;
                            z_pending_strb  <= comb_zw_strb;
                            z_pending_addr  <= comb_zw_addr;
                            z_pending_valid <= 1'b1;
                        end
                        z_pair_has_lo <= 1'b0;
                    end
                    cur_izi_comb    <= cur_izi_comb + cur_zistep;
                    cur_z_addr_comb <= cur_z_addr_comb + 32'd2;
                end

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

                        // Combined z accumulation (fire-and-forget SRAM writes)
                        if (cur_combined_z) begin
                            if (!comb_z_half) begin
                                z_pair_lo     <= comb_z_val;
                                z_pair_waddr  <= comb_z_waddr;
                                z_pair_has_lo <= 1'b1;
                                if (remaining == 16'd1) begin
                                    z_pending_data  <= {16'd0, comb_z_val};
                                    z_pending_strb  <= 4'b0011;
                                    z_pending_addr  <= comb_z_waddr;
                                    z_pending_valid <= 1'b1;
                                    z_pair_has_lo   <= 1'b0;
                                end
                            end else begin
                                if (comb_zw_direct) begin
                                    sram_wr    <= 1'b1;
                                    sram_addr  <= comb_zw_addr;
                                    sram_wdata <= comb_zw_data;
                                    sram_wstrb <= comb_zw_strb;
                                end else begin
                                    z_pending_data  <= comb_zw_data;
                                    z_pending_strb  <= comb_zw_strb;
                                    z_pending_addr  <= comb_zw_addr;
                                    z_pending_valid <= 1'b1;
                                end
                                z_pair_has_lo <= 1'b0;
                            end
                            cur_izi_comb    <= cur_izi_comb + cur_zistep;
                            cur_z_addr_comb <= cur_z_addr_comb + 32'd2;
                        end

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
                if (pf_rd_pending || m_axi_arvalid) begin
                    // Prefetch AR still pending — wait before issuing write
                end else if (fb_wr_launched && !m_axi_awvalid && !m_axi_wvalid) begin
                    // Both AW and W accepted by arbiter/slave
                    fb_wr_launched <= 1'b0;
                    if (remaining > 16'd0) begin
                        // Write-behind: continue pixel processing while SDRAM handles write
                        acc_strb          <= 4'b0000;
                        tex_addr_for_turb <= 1'b0;
                        state             <= ST_TEX_ADDR;
                    end else if (cur_persp_en && persp_total_remaining > 16'd0) begin
                        // Perspective chunk done, more chunks remain
                        acc_strb  <= 4'b0000;
                        cur_s     <= persp_s_saved;
                        cur_t     <= persp_t_saved;
                        state     <= ST_PERSP_ACCUM;
                    end else begin
                        // Last write of span: need ST_FB_WAIT for B response + dequeue
                        state       <= ST_FB_WAIT;
                    end
                end else if (!fb_wr_launched) begin
                    // Issue AXI4 write — AW+W simultaneously
                    m_axi_awvalid <= 1'b1;
                    m_axi_awaddr  <= {6'b0, acc_addr, 2'b00};
                    m_axi_wvalid  <= 1'b1;
                    m_axi_wdata   <= acc_data;
                    m_axi_wstrb   <= acc_strb;
                    fb_wr_launched <= 1'b1;
                end
            end

            ST_FB_WAIT: begin
                if (m_axi_bvalid) begin
                    acc_strb   <= 4'b0000;

                    if (remaining == 16'd0 && cur_persp_en && persp_total_remaining > 16'd0) begin
                        // Perspective chunk done, more chunks remain
                        cur_s <= persp_s_saved;
                        cur_t <= persp_t_saved;
                        state <= ST_PERSP_ACCUM;
                    end else if (remaining == 16'd0) begin
                        if (cur_combined_z && z_pending_valid) begin
                            // Combined z has pending SRAM write — wait for flush
                            state <= ST_Z_FLUSH;
                        end else if (surf_block_active && surf_rows_remaining > 5'd0) begin
                            state <= ST_SURF_ROW_SETUP;
                        end else begin
                            surf_block_active <= 1'b0;
                            cur_combined_z    <= 1'b0;
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
                                    cur_persp_en  <= fifo_is_persp[fifo_rd_ptr];
                                    cur_combined_z <= fifo_combined_z[fifo_rd_ptr];
                                    remaining     <= fifo_count_f[fifo_rd_ptr];
                                    seen_busy     <= 1'b0;
                                    tex_addr_for_turb <= 1'b0;
                                    if (fifo_combined_z[fifo_rd_ptr]) begin
                                        cur_z_addr_comb <= fifo_zaddr[fifo_rd_ptr];
                                        cur_izi_comb    <= fifo_izi[fifo_rd_ptr];
                                        cur_zistep      <= fifo_zistep[fifo_rd_ptr];
                                        z_pair_has_lo   <= 1'b0;
                                        z_pending_valid <= 1'b0;
                                    end
                                    if (fifo_is_persp[fifo_rd_ptr]) begin
                                        persp_sdivz_cur <= fifo_persp_sdivz[fifo_rd_ptr];
                                        persp_tdivz_cur <= fifo_persp_tdivz[fifo_rd_ptr];
                                        persp_zi_cur    <= fifo_persp_zi[fifo_rd_ptr];
                                        persp_total_remaining <= fifo_count_f[fifo_rd_ptr];
                                        persp_is_initial <= 1'b1;
                                        state <= ST_PERSP_INIT;
                                    end else begin
                                        state <= ST_TEX_ADDR;
                                    end
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
                                    cur_persp_en  <= fifo_is_persp[fifo_rd_ptr];
                                    cur_combined_z <= fifo_combined_z[fifo_rd_ptr];
                                    remaining     <= fifo_count_f[fifo_rd_ptr];
                                    seen_busy     <= 1'b0;
                                    tex_addr_for_turb <= 1'b0;
                                    if (fifo_combined_z[fifo_rd_ptr]) begin
                                        cur_z_addr_comb <= fifo_zaddr[fifo_rd_ptr];
                                        cur_izi_comb    <= fifo_izi[fifo_rd_ptr];
                                        cur_zistep      <= fifo_zistep[fifo_rd_ptr];
                                        z_pair_has_lo   <= 1'b0;
                                        z_pending_valid <= 1'b0;
                                    end
                                    if (fifo_is_persp[fifo_rd_ptr]) begin
                                        persp_sdivz_cur <= fifo_persp_sdivz[fifo_rd_ptr];
                                        persp_tdivz_cur <= fifo_persp_tdivz[fifo_rd_ptr];
                                        persp_zi_cur    <= fifo_persp_zi[fifo_rd_ptr];
                                        persp_total_remaining <= fifo_count_f[fifo_rd_ptr];
                                        persp_is_initial <= 1'b1;
                                        state <= ST_PERSP_INIT;
                                    end else begin
                                        state <= ST_TEX_ADDR;
                                    end
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
                                    cur_persp_en  <= fifo_is_persp[fifo_rd_ptr];
                                    cur_combined_z <= fifo_combined_z[fifo_rd_ptr];
                                    remaining     <= fifo_count_f[fifo_rd_ptr];
                                    seen_busy     <= 1'b0;
                                    tex_addr_for_turb <= 1'b0;
                                    if (fifo_combined_z[fifo_rd_ptr]) begin
                                        cur_z_addr_comb <= fifo_zaddr[fifo_rd_ptr];
                                        cur_izi_comb    <= fifo_izi[fifo_rd_ptr];
                                        cur_zistep      <= fifo_zistep[fifo_rd_ptr];
                                        z_pair_has_lo   <= 1'b0;
                                        z_pending_valid <= 1'b0;
                                    end
                                    if (fifo_is_persp[fifo_rd_ptr]) begin
                                        persp_sdivz_cur <= fifo_persp_sdivz[fifo_rd_ptr];
                                        persp_tdivz_cur <= fifo_persp_tdivz[fifo_rd_ptr];
                                        persp_zi_cur    <= fifo_persp_zi[fifo_rd_ptr];
                                        persp_total_remaining <= fifo_count_f[fifo_rd_ptr];
                                        persp_is_initial <= 1'b1;
                                        state <= ST_PERSP_INIT;
                                    end else begin
                                        state <= ST_TEX_ADDR;
                                    end
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

            // ============================================
            // Perspective correction FSM states
            // ============================================
            ST_PERSP_INIT: begin
                // CLZ of zi_cur only — registered for use next cycle
                // (splitting CLZ from barrel shift breaks the critical path)
                persp_lz <= clz32(persp_zi_cur);
                state <= ST_PERSP_LUT;
            end

            ST_PERSP_LUT: begin
                // Use registered persp_lz to compute normalized LUT address
                recip_lut_addr <= (persp_zi_cur << persp_lz) >> 21;
                // Pre-compute barrel shift amount (used in MUL_T and CLAMP)
                persp_shift_amt <= 5'd30 - persp_lz;
                state <= ST_PERSP_LUT2;
            end

            ST_PERSP_LUT2: begin
                // M10K recip LUT read latency — data available next cycle
                state <= ST_PERSP_MUL_S;
            end

            ST_PERSP_MUL_S: begin
                // Capture recip_raw from LUT, set DSP multiply inputs sdivz × recip
                persp_recip_raw <= recip_lut_rd;
                persp_mul_a <= persp_sdivz_cur;
                persp_mul_b <= {1'b0, recip_lut_rd};  // zero-extend to 17-bit signed
                state <= ST_PERSP_MUL_S_W;
            end

            ST_PERSP_MUL_S_W: begin
                // Wait 1 of 2: DSP two-stage pipeline has 3-cycle latency
                state <= ST_PERSP_MUL_S_W2;
            end

            ST_PERSP_MUL_S_W2: begin
                // Wait 2 of 2: persp_mul_pipe → persp_product register transfer
                state <= ST_PERSP_MUL_T;
            end

            ST_PERSP_MUL_T: begin
                // persp_product = sdivz * recip (now valid after 3-cycle DSP latency)
                // Register barrel-shifted value (defer add to break shift→add→clamp path)
                persp_shifted_r <= persp_product >>> persp_shift_amt;
                // Set DSP multiply inputs for tdivz × recip
                persp_mul_a <= persp_tdivz_cur;
                persp_mul_b <= {1'b0, persp_recip_raw};
                state <= ST_PERSP_MUL_T_W;
            end

            ST_PERSP_MUL_T_W: begin
                // Wait 1 of 2 for DSP t multiply. Compute s_raw from registered shift.
                persp_s_saved <= persp_shifted_r + persp_sadjust_reg;
                state <= ST_PERSP_MUL_T_W2;
            end

            ST_PERSP_MUL_T_W2: begin
                // Wait 2 of 2: persp_mul_pipe → persp_product register transfer
                state <= ST_PERSP_CLAMP;
            end

            ST_PERSP_CLAMP: begin
                // persp_product = tdivz * recip (now valid after 3-cycle DSP latency)
                // Register barrel-shifted value (defer add+clamp to CLAMP2)
                persp_shifted_r <= persp_product >>> persp_shift_amt;
                state <= ST_PERSP_CLAMP2;
            end

            ST_PERSP_CLAMP2: begin
                // Add adjust + clamp both s and t from registered shifted values
                // (barrel shift isolated in ST_PERSP_MUL_T / ST_PERSP_CLAMP)
                begin : persp_clamp_block
                    reg signed [31:0] s_raw, t_raw;
                    reg signed [31:0] s_clamped, t_clamped;
                    reg signed [31:0] min_clamp;

                    s_raw = persp_s_saved;  // Computed in ST_PERSP_MUL_T_W
                    t_raw = persp_shifted_r + persp_tadjust_reg;

                    // Clamp minimum: 0 for initial, 16 for regular, 8 for last chunk
                    min_clamp = persp_is_initial ? 32'sd0 :
                                persp_is_last_chunk ? 32'sd8 : 32'sd16;

                    // Clamp s
                    if (s_raw > $signed(persp_bbextents_reg))
                        s_clamped = persp_bbextents_reg;
                    else if (s_raw < min_clamp)
                        s_clamped = min_clamp;
                    else
                        s_clamped = s_raw;

                    // Clamp t
                    if (t_raw > $signed(persp_bbextentt_reg))
                        t_clamped = persp_bbextentt_reg;
                    else if (t_raw < min_clamp)
                        t_clamped = min_clamp;
                    else
                        t_clamped = t_raw;

                    if (persp_is_initial) begin
                        // First pass: initial s/t for the span
                        cur_s <= s_clamped;
                        cur_t <= t_clamped;
                        persp_is_initial <= 1'b0;
                        // Determine chunk size (advance computed in ST_PERSP_ADVANCE)
                        if (persp_total_remaining >= 16'd16) begin
                            persp_chunk_count <= 5'd16;
                            persp_is_last_chunk <= 1'b0;
                        end else begin
                            persp_chunk_count <= persp_total_remaining[4:0];
                            persp_is_last_chunk <= 1'b1;
                        end
                        // Advance computed in separate state to break critical multiply→clamp path
                        state <= ST_PERSP_ADVANCE;
                    end else begin
                        // Second pass: snext/tnext → compute steps
                        persp_s_saved <= s_clamped;
                        persp_t_saved <= t_clamped;
                        state <= ST_PERSP_STEP;
                    end
                end
            end

            ST_PERSP_ACCUM: begin
                // Determine chunk params for next chunk (advance computed in ST_PERSP_ADVANCE)
                if (persp_total_remaining >= 16'd16) begin
                    persp_chunk_count <= 5'd16;
                    persp_is_last_chunk <= 1'b0;
                end else begin
                    persp_chunk_count <= persp_total_remaining[4:0];
                    persp_is_last_chunk <= 1'b1;
                end
                // Advance computed in separate state to break critical multiply→clamp path
                state <= ST_PERSP_ADVANCE;
            end

            ST_PERSP_ADVANCE: begin
                // Perspective advance computation, separated from ST_PERSP_CLAMP
                // to break the critical Mult0→ShiftRight→Add→LessThan timing path.
                //
                // Full chunks (common case): 3 simple additions, 1 cycle.
                // Partial chunks (last chunk only): uses DSP multiply pipeline
                // to compute step*(count-1)/16 for each axis sequentially (10 cycles).
                // DSP has 3-cycle latency (two-stage pipeline).
                if (!persp_is_last_chunk) begin
                    // Full 16-pixel chunk: advance by full step (1 cycle)
                    persp_sdivz_cur <= persp_sdivz_cur + persp_sdivz_step_reg;
                    persp_tdivz_cur <= persp_tdivz_cur + persp_tdivz_step_reg;
                    persp_zi_cur    <= persp_zi_cur + persp_zi_step_reg;
                    state <= ST_PERSP_INIT;
                end else begin
                    // Partial chunk: time-share DSP multiply for 3 axes (3 cycles each + 1 final)
                    case (persp_adv_phase)
                        4'd0: begin
                            // Set DSP inputs: sdivz_step * (count-1)
                            persp_mul_a <= persp_sdivz_step_reg;
                            persp_mul_b <= {1'b0, 11'd0, persp_chunk_count - 5'd1};
                            persp_adv_phase <= 4'd1;
                        end
                        4'd1: begin
                            // DSP pipeline wait 1
                            persp_adv_phase <= 4'd2;
                        end
                        4'd2: begin
                            // DSP pipeline wait 2
                            persp_adv_phase <= 4'd3;
                        end
                        4'd3: begin
                            // sdivz product ready — capture advance, set tdivz inputs
                            persp_sdivz_advance_r <= persp_product >>> 4;
                            persp_mul_a <= persp_tdivz_step_reg;
                            // mul_b unchanged (same count-1 value)
                            persp_adv_phase <= 4'd4;
                        end
                        4'd4: begin
                            // DSP pipeline wait 1
                            persp_adv_phase <= 4'd5;
                        end
                        4'd5: begin
                            // DSP pipeline wait 2
                            persp_adv_phase <= 4'd6;
                        end
                        4'd6: begin
                            // tdivz product ready — capture advance, set zi inputs
                            persp_tdivz_advance_r <= persp_product >>> 4;
                            persp_mul_a <= persp_zi_step_reg;
                            persp_adv_phase <= 4'd7;
                        end
                        4'd7: begin
                            // DSP pipeline wait 1
                            persp_adv_phase <= 4'd8;
                        end
                        4'd8: begin
                            // DSP pipeline wait 2
                            persp_adv_phase <= 4'd9;
                        end
                        4'd9: begin
                            // zi product ready — apply all three advances
                            persp_sdivz_cur <= persp_sdivz_cur + persp_sdivz_advance_r;
                            persp_tdivz_cur <= persp_tdivz_cur + persp_tdivz_advance_r;
                            persp_zi_cur    <= persp_zi_cur + $signed(persp_product >>> 4);
                            persp_adv_phase <= 4'd0;
                            state <= ST_PERSP_INIT;
                        end
                        default: begin
                            persp_adv_phase <= 4'd0;
                            state <= ST_PERSP_INIT;
                        end
                    endcase
                end
            end

            ST_PERSP_STEP: begin
                // Compute sstep/tstep for this chunk and launch pixel drawing
                if (persp_is_last_chunk && persp_chunk_count > 5'd2) begin
                    // Last chunk (3+ pixels): use inv_lut for non-power-of-2 step
                    persp_mul_a <= persp_s_saved - cur_s;
                    persp_mul_b <= {1'b0, inv_lut(persp_chunk_count - 5'd1)};
                    state <= ST_PERSP_INV_W;
                end else if (persp_is_last_chunk && persp_chunk_count == 5'd2) begin
                    // 2-pixel last chunk: step = snext - s (division by 1)
                    cur_sstep <= persp_s_saved - cur_s;
                    cur_tstep <= persp_t_saved - cur_t;
                    remaining <= 16'd2;
                    persp_total_remaining <= persp_total_remaining - 16'd2;
                    cmd_issued <= 1'b0;
                    seen_busy  <= 1'b0;
                    tex_addr_for_turb <= 1'b0;
                    state <= ST_TEX_ADDR;
                end else if (persp_chunk_count <= 5'd1) begin
                    // Single pixel: no stepping needed
                    cur_sstep <= 32'd0;
                    cur_tstep <= 32'd0;
                    remaining <= {11'd0, persp_chunk_count};
                    persp_total_remaining <= persp_total_remaining - {11'd0, persp_chunk_count};
                    cmd_issued <= 1'b0;
                    seen_busy  <= 1'b0;
                    tex_addr_for_turb <= 1'b0;
                    state <= ST_TEX_ADDR;
                end else begin
                    // Full 16-pixel chunk: sstep = (snext - s) >> 4
                    cur_sstep <= (persp_s_saved - $signed(cur_s)) >>> 4;
                    cur_tstep <= (persp_t_saved - $signed(cur_t)) >>> 4;
                    remaining <= {11'd0, persp_chunk_count};
                    persp_total_remaining <= persp_total_remaining - {11'd0, persp_chunk_count};
                    cmd_issued <= 1'b0;
                    seen_busy  <= 1'b0;
                    tex_addr_for_turb <= 1'b0;
                    state <= ST_TEX_ADDR;
                end
            end

            ST_PERSP_INV_W: begin
                // Wait 1 of 2: DSP two-stage pipeline has 3-cycle latency
                state <= ST_PERSP_INV_W2;
            end

            ST_PERSP_INV_W2: begin
                // Wait 2 of 2: persp_mul_pipe → persp_product register transfer
                state <= ST_PERSP_INV;
            end

            ST_PERSP_INV: begin
                // DSP product = (snext-s) * inv_lut (valid after 3-cycle latency)
                // Capture sstep, set DSP inputs for t multiply
                cur_sstep <= persp_product >>> 16;
                persp_mul_a <= persp_t_saved - cur_t;
                persp_mul_b <= {1'b0, inv_lut(persp_chunk_count - 5'd1)};
                state <= ST_PERSP_INV2_W;
            end

            ST_PERSP_INV2_W: begin
                // Wait 1 of 2: DSP two-stage pipeline has 3-cycle latency
                state <= ST_PERSP_INV2_W2;
            end

            ST_PERSP_INV2_W2: begin
                // Wait 2 of 2: persp_mul_pipe → persp_product register transfer
                state <= ST_PERSP_INV2;
            end

            ST_PERSP_INV2: begin
                // DSP product = (tnext-t) * inv_lut (valid after 3-cycle latency)
                // Capture tstep, launch chunk
                cur_tstep <= persp_product >>> 16;
                remaining <= {11'd0, persp_chunk_count};
                persp_total_remaining <= persp_total_remaining - {11'd0, persp_chunk_count};
                cmd_issued <= 1'b0;
                seen_busy  <= 1'b0;
                tex_addr_for_turb <= 1'b0;
                state <= ST_TEX_ADDR;
            end

            ST_Z_FLUSH: begin
                // Wait for combined z pending SRAM write to flush
                // (opportunistic handler above clears z_pending_valid)
                if (!z_pending_valid) begin
                    cur_combined_z <= 1'b0;
                    state <= ST_IDLE;
                end
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
