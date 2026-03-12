//
// Hardware CalcGradients Engine
// Computes per-surface perspective gradient parameters for textured spans.
// Replaces D_CalcGradients() on the CPU with a ~50 cycle hardware pipeline.
//
// Two FP32 units (multiply + add) are time-multiplexed through all operations.
// Frame-constant data (view matrix, screen params) is loaded once per frame.
// Per-surface data (texture vectors, mip info) triggers computation.
//
// Register map (reg_addr = byte_offset[6:2]):
//   Frame constants (write once per frame):
//     0x00-0x08: VRIGHT[0..2]      (W) float32
//     0x0C-0x14: VUP[0..2]         (W) float32
//     0x18-0x20: VPN[0..2]         (W) float32
//     0x24:      XSCALEINV         (W) float32
//     0x28:      YSCALEINV         (W) float32
//     0x2C:      XCENTER           (W) float32
//     0x30:      YCENTER           (W) float32
//     0x34-0x3C: MODELORG[0..2]    (W) float32
//
//   Per-surface (write to start computation):
//     0x40-0x4C: SVEC[0..3]        (W) float32 (texinfo->vecs[0])
//     0x50-0x5C: TVEC[0..3]        (W) float32 (texinfo->vecs[1])
//     0x60:      MIPLEVEL          (W) integer (0-3)
//     0x64:      TEXMINS_EXTENTS   (W) {texmins_s[7:0], texmins_t[15:8], extents_s[23:16], extents_t[31:24]}
//     0x68:      KICK              (W) triggers computation (write any value)
//
//   Results (read after done):
//     0x80:      D_SDIVZSTEPU      (R) float32
//     0x84:      D_TDIVZSTEPU      (R) float32
//     0x88:      D_SDIVZSTEPV      (R) float32
//     0x8C:      D_TDIVZSTEPV      (R) float32
//     0x90:      D_SDIVZORIGIN     (R) float32
//     0x94:      D_TDIVZORIGIN     (R) float32
//     0x98:      SADJUST           (R) int32 (fixed16_t)
//     0x9C:      TADJUST           (R) int32 (fixed16_t)
//     0xA0:      BBEXTENTS         (R) int32
//     0xA4:      BBEXTENTT         (R) int32
//     0xA8:      STATUS            (R) bit0=busy
//

`default_nettype none

module calc_gradients (
    input wire        clk,
    input wire        reset_n,

    input wire        reg_wr,
    input wire        reg_rd,
    input wire [5:0]  reg_addr,   // byte_offset[7:2]
    input wire [31:0] reg_wdata,
    output reg [31:0] reg_rdata,

    output wire       busy_o
);

// ============================================
// Frame-constant registers
// ============================================
reg [31:0] vright [0:2];
reg [31:0] vup    [0:2];
reg [31:0] vpn    [0:2];
reg [31:0] xscaleinv, yscaleinv;
reg [31:0] xcenter, ycenter;
reg [31:0] modelorg [0:2];

// Per-surface input registers
reg [31:0] svec [0:3];  // texinfo->vecs[0] (3 floats + offset)
reg [31:0] tvec [0:3];  // texinfo->vecs[1]
reg [2:0]  miplevel;
reg signed [15:0] texmins_s, texmins_t;
reg [15:0] extents_s, extents_t;

// Result registers
reg [31:0] r_sdivzstepu, r_tdivzstepu;
reg [31:0] r_sdivzstepv, r_tdivzstepv;
reg [31:0] r_sdivzorigin, r_tdivzorigin;
reg signed [31:0] r_sadjust, r_tadjust;
reg signed [31:0] r_bbextents, r_bbextentt;

// ============================================
// FP32 Multiply Unit (3-cycle pipeline)
// Uses DSP for 24x24 mantissa multiply
// ============================================
reg [31:0] fmul_a, fmul_b;
reg        fmul_start;

// Stage 1: extract fields, start mantissa multiply
wire        mul_a_sign = fmul_a[31];
wire [7:0]  mul_a_exp  = fmul_a[30:23];
wire [23:0] mul_a_mant = (mul_a_exp == 0) ? 24'd0 : {1'b1, fmul_a[22:0]};
wire        mul_b_sign = fmul_b[31];
wire [7:0]  mul_b_exp  = fmul_b[30:23];
wire [23:0] mul_b_mant = (mul_b_exp == 0) ? 24'd0 : {1'b1, fmul_b[22:0]};

wire        mul_a_zero = (mul_a_exp == 0);
wire        mul_b_zero = (mul_b_exp == 0);

// DSP multiply (registered output for timing)
wire [47:0] mant_product = mul_a_mant * mul_b_mant;
reg  [47:0] mant_product_r;
reg         mul_sign_r;
reg  [8:0]  mul_exp_sum_r;  // 9-bit to handle overflow
reg         mul_zero_r;
reg         mul_valid_s1;

always @(posedge clk) begin
    mant_product_r <= mant_product;
    mul_sign_r     <= mul_a_sign ^ mul_b_sign;
    mul_exp_sum_r  <= {1'b0, mul_a_exp} + {1'b0, mul_b_exp} - 9'd127;
    mul_zero_r     <= mul_a_zero | mul_b_zero;
    mul_valid_s1   <= fmul_start;
end

// Stage 2: normalize and pack result
wire        mul_top_bit = mant_product_r[47];
wire [22:0] mul_result_mant = mul_top_bit ? mant_product_r[46:24] : mant_product_r[45:23];
wire [8:0]  mul_result_exp  = mul_top_bit ? mul_exp_sum_r + 9'd1 : mul_exp_sum_r;

reg [31:0]  fmul_result;
reg         fmul_valid;

always @(posedge clk) begin
    fmul_valid <= mul_valid_s1;
    if (mul_zero_r)
        fmul_result <= 32'd0;
    else
        fmul_result <= {mul_sign_r, mul_result_exp[7:0], mul_result_mant};
end

// ============================================
// FP32 Add/Sub Unit (2-cycle pipeline)
// ============================================
reg [31:0] fadd_a, fadd_b;
reg        fadd_sub;   // 1 = subtract b from a
reg        fadd_start;

// Stage 1: align mantissas, add/sub
wire        add_a_sign = fadd_a[31];
wire [7:0]  add_a_exp  = fadd_a[30:23];
wire [24:0] add_a_mant = (add_a_exp == 0) ? 25'd0 : {2'b01, fadd_a[22:0]};
wire        add_b_sign = fadd_b[31] ^ fadd_sub;
wire [7:0]  add_b_exp  = fadd_b[30:23];
wire [24:0] add_b_mant = (add_b_exp == 0) ? 25'd0 : {2'b01, fadd_b[22:0]};

wire        add_a_zero = (add_a_exp == 0);
wire        add_b_zero = (add_b_exp == 0);

// Determine which has larger exponent
wire [7:0]  exp_diff_ab = add_a_exp - add_b_exp;
wire [7:0]  exp_diff_ba = add_b_exp - add_a_exp;
wire        a_ge_b = (add_a_exp > add_b_exp) ||
                      (add_a_exp == add_b_exp && add_a_mant >= add_b_mant);

wire [7:0]  result_exp_pre = a_ge_b ? add_a_exp : add_b_exp;
wire [4:0]  shift_amt = a_ge_b ?
    (exp_diff_ab > 8'd24 ? 5'd24 : exp_diff_ab[4:0]) :
    (exp_diff_ba > 8'd24 ? 5'd24 : exp_diff_ba[4:0]);

wire [24:0] aligned_a = a_ge_b ? add_a_mant : (add_a_mant >> shift_amt);
wire [24:0] aligned_b = a_ge_b ? (add_b_mant >> shift_amt) : add_b_mant;

// Effective operation
wire eff_sub = (add_a_sign != add_b_sign);
wire [25:0] sum_raw = eff_sub ?
    (a_ge_b ? {1'b0, aligned_a} - {1'b0, aligned_b} :
              {1'b0, aligned_b} - {1'b0, aligned_a}) :
    {1'b0, aligned_a} + {1'b0, aligned_b};

wire result_sign_pre = eff_sub ?
    (a_ge_b ? add_a_sign : add_b_sign) :
    add_a_sign;

// Register pipeline stage 1
reg [25:0] sum_raw_r;
reg [7:0]  add_exp_r;
reg        add_sign_r;
reg        add_valid_s1;
reg        add_both_zero_r;

always @(posedge clk) begin
    sum_raw_r      <= sum_raw;
    add_exp_r      <= result_exp_pre;
    add_sign_r     <= result_sign_pre;
    add_valid_s1   <= fadd_start;
    add_both_zero_r <= add_a_zero & add_b_zero;
end

// Stage 2: normalize (CLZ + shift)
// Find leading one in sum_raw_r[25:0]
wire [4:0] clz;
wire sum_is_zero = (sum_raw_r == 0);

// CLZ for normalization
assign clz = sum_raw_r[25] ? 5'd0 :
             sum_raw_r[24] ? 5'd1 :
             sum_raw_r[23] ? 5'd2 :
             sum_raw_r[22] ? 5'd3 :
             sum_raw_r[21] ? 5'd4 :
             sum_raw_r[20] ? 5'd5 :
             sum_raw_r[19] ? 5'd6 :
             sum_raw_r[18] ? 5'd7 :
             sum_raw_r[17] ? 5'd8 :
             sum_raw_r[16] ? 5'd9 :
             sum_raw_r[15] ? 5'd10 :
             sum_raw_r[14] ? 5'd11 :
             sum_raw_r[13] ? 5'd12 :
             sum_raw_r[12] ? 5'd13 :
             sum_raw_r[11] ? 5'd14 :
             sum_raw_r[10] ? 5'd15 :
             sum_raw_r[9]  ? 5'd16 :
             sum_raw_r[8]  ? 5'd17 :
             sum_raw_r[7]  ? 5'd18 :
             sum_raw_r[6]  ? 5'd19 :
             sum_raw_r[5]  ? 5'd20 :
             sum_raw_r[4]  ? 5'd21 :
             sum_raw_r[3]  ? 5'd22 :
             sum_raw_r[2]  ? 5'd23 :
             sum_raw_r[1]  ? 5'd24 :
             sum_raw_r[0]  ? 5'd25 : 5'd25;

// Normalization: shift so bit 23 is the hidden bit
// Mantissa format {2'b01, frac[22:0]}: hidden bit at position 23
// clz=0: bit 25 set (overflow by 2), shift right 2, exp+2
// clz=1: bit 24 set (overflow by 1), shift right 1, exp+1
// clz=2: bit 23 set (normal), no shift, exp+0
// clz>2: shift left by (clz-2), exp-(clz-2)
wire        clz_overflow = (clz <= 5'd2);
wire [4:0]  clz_rshift = 5'd2 - clz;   // right shift amount (valid when clz <= 2)
wire [4:0]  clz_lshift = clz - 5'd2;   // left shift amount (valid when clz > 2)

wire [25:0] norm_shifted = clz_overflow ? (sum_raw_r >> clz_rshift) :
                                          (sum_raw_r << clz_lshift);
wire [7:0]  norm_exp = clz_overflow ? (add_exp_r + {3'd0, clz_rshift}) :
                        (add_exp_r >= {3'd0, clz_lshift}) ? (add_exp_r - {3'd0, clz_lshift}) : 8'd0;

reg [31:0]  fadd_result;
reg         fadd_valid;

always @(posedge clk) begin
    fadd_valid <= add_valid_s1;
    if (add_both_zero_r || sum_is_zero)
        fadd_result <= 32'd0;
    else
        fadd_result <= {add_sign_r, norm_exp, norm_shifted[22:0]};
end

// ============================================
// FP32 Negate (combinational)
// ============================================
function [31:0] fp_neg;
    input [31:0] x;
    fp_neg = {~x[31], x[30:0]};
endfunction

// ============================================
// FP32 to int32 (truncation toward zero)
// ============================================
function signed [31:0] fp_to_int;
    input [31:0] f;
    reg        s;
    reg [7:0]  e;
    reg [23:0] m;
    reg [31:0] val;
    begin
        s = f[31];
        e = f[30:23];
        m = {1'b1, f[22:0]};
        if (e < 8'd127) begin
            fp_to_int = 0;  // |f| < 1.0
        end else if (e <= 8'd150) begin
            // 1.0 <= |f| < 2^24: shift right
            val = {8'd0, m} >> (8'd150 - e);
            fp_to_int = s ? -$signed(val) : $signed(val);
        end else if (e <= 8'd158) begin
            // 2^24 <= |f| < 2^32: shift left
            val = {8'd0, m} << (e - 8'd150);
            fp_to_int = s ? -$signed(val) : $signed(val);
        end else begin
            fp_to_int = s ? 32'sh80000000 : 32'sh7FFFFFFF;
        end
    end
endfunction

// ============================================
// Mipscale: 1.0 >> miplevel (as FP32)
// ============================================
wire [31:0] mipscale_fp = (miplevel == 0) ? 32'h3F800000 :  // 1.0
                           (miplevel == 1) ? 32'h3F000000 :  // 0.5
                           (miplevel == 2) ? 32'h3E800000 :  // 0.25
                                             32'h3E000000;   // 0.125

// t_16 = 0x10000 * mipscale (for sadjust/tadjust computation)
wire [31:0] t_16_fp    = (miplevel == 0) ? 32'h47800000 :  // 65536.0
                           (miplevel == 1) ? 32'h47000000 :  // 32768.0
                           (miplevel == 2) ? 32'h46800000 :  // 16384.0
                                             32'h46000000;   // 8192.0

localparam FP_HALF = 32'h3F000000;  // 0.5f

// ============================================
// Computation State Machine
// ============================================
// Phase 1: TransformVector(svec) → p_saxis[3]
// Phase 2: TransformVector(tvec) → p_taxis[3]
// Phase 3: Compute step/origin values
// Phase 4: sadjust/tadjust, bbextents

localparam ST_IDLE        = 7'd0;
// TransformVector(svec) → p_saxis: dot(svec, vright/vup/vpn)
localparam ST_TV_S0_MUL   = 7'd1;   // svec[0]*vright[0], svec[1]*vright[1], svec[2]*vright[2]
localparam ST_TV_S0_W1    = 7'd2;   // wait for mul
localparam ST_TV_S0_ADD1  = 7'd3;   // prod0 + prod1
localparam ST_TV_S0_ADD2  = 7'd4;   // sum01 + prod2 → p_saxis[0]
localparam ST_TV_S1_MUL   = 7'd5;
localparam ST_TV_S1_W1    = 7'd6;
localparam ST_TV_S1_ADD1  = 7'd7;
localparam ST_TV_S1_ADD2  = 7'd8;   // → p_saxis[1]
localparam ST_TV_S2_MUL   = 7'd9;
localparam ST_TV_S2_W1    = 7'd10;
localparam ST_TV_S2_ADD1  = 7'd11;
localparam ST_TV_S2_ADD2  = 7'd12;  // → p_saxis[2]
// TransformVector(tvec) → p_taxis
localparam ST_TV_T0_MUL   = 7'd13;
localparam ST_TV_T0_W1    = 7'd14;
localparam ST_TV_T0_ADD1  = 7'd15;
localparam ST_TV_T0_ADD2  = 7'd16;  // → p_taxis[0]
localparam ST_TV_T1_MUL   = 7'd17;
localparam ST_TV_T1_W1    = 7'd18;
localparam ST_TV_T1_ADD1  = 7'd19;
localparam ST_TV_T1_ADD2  = 7'd20;  // → p_taxis[1]
localparam ST_TV_T2_MUL   = 7'd21;
localparam ST_TV_T2_W1    = 7'd22;
localparam ST_TV_T2_ADD1  = 7'd23;
localparam ST_TV_T2_ADD2  = 7'd24;  // → p_taxis[2]
// Phase 3: step/origin
localparam ST_STEPU       = 7'd25;  // t = xscaleinv * mipscale
localparam ST_STEPU_W     = 7'd26;
localparam ST_STEPU_S     = 7'd27;  // sdivzstepu = p_saxis[0] * t
localparam ST_STEPU_T     = 7'd28;  // tdivzstepu = p_taxis[0] * t
localparam ST_STEPV       = 7'd29;  // t = yscaleinv * mipscale
localparam ST_STEPV_W     = 7'd30;
localparam ST_STEPV_S     = 7'd31;  // sdivzstepv = -p_saxis[1] * t
localparam ST_STEPV_T     = 7'd32;  // tdivzstepv = -p_taxis[1] * t
// Origins: d_sdivzorigin = p_saxis[2]*mipscale - xcenter*stepu - ycenter*stepv
localparam ST_ORIG_MUL1   = 7'd33;  // p_saxis[2]*mipscale
localparam ST_ORIG_MUL1_W = 7'd34;
localparam ST_ORIG_SUB1   = 7'd35;  // - xcenter*stepu (start mul)
localparam ST_ORIG_SUB1_W = 7'd36;
localparam ST_ORIG_SUB1A  = 7'd37;  // do subtraction
localparam ST_ORIG_SUB2   = 7'd38;  // - ycenter*stepv (start mul)
localparam ST_ORIG_SUB2_W = 7'd39;
localparam ST_ORIG_SUB2A  = 7'd40;  // do subtraction → sdivzorigin
localparam ST_ORIG_T      = 7'd41;  // same for tdivz (start p_taxis[2]*mipscale)
localparam ST_ORIG_T_W    = 7'd42;
localparam ST_ORIG_T_SUB1 = 7'd43;
localparam ST_ORIG_T_S1W  = 7'd44;
localparam ST_ORIG_T_S1A  = 7'd45;
localparam ST_ORIG_T_SUB2 = 7'd46;
localparam ST_ORIG_T_S2W  = 7'd47;
localparam ST_ORIG_T_S2A  = 7'd48;  // → tdivzorigin
// Phase 4: bbextents, sadjust/tadjust (DotProduct + FP→int)
localparam ST_ADJ_BBEXT     = 7'd49;  // bbextents (integer), start DotProduct(modelorg, p_saxis)
localparam ST_ADJ_DS_W1     = 7'd50;  // Pipeline 3 multiplies
localparam ST_ADJ_DS_ADD1   = 7'd51;  // Add prod0+prod1
localparam ST_ADJ_DS_ADD2   = 7'd52;  // Add sum+prod2
localparam ST_ADJ_DS_SCALE  = 7'd53;  // dot_s * t_16_fp
localparam ST_ADJ_DS_SCALE_W= 7'd54;  // Wait, add FP_HALF
localparam ST_ADJ_DS_RND    = 7'd55;  // Wait, fp_to_int, start svec[3]*t_16
localparam ST_ADJ_DS_VEC    = 7'd56;  // Wait, fp_to_int, integer sadjust
localparam ST_ADJ_DT_MUL    = 7'd57;  // Start DotProduct(modelorg, p_taxis)
localparam ST_ADJ_DT_W1     = 7'd58;  // Pipeline 3 multiplies
localparam ST_ADJ_DT_ADD1   = 7'd59;  // Add prod0+prod1
localparam ST_ADJ_DT_ADD2   = 7'd60;  // Add sum+prod2
localparam ST_ADJ_DT_SCALE  = 7'd61;  // dot_t * t_16_fp
localparam ST_ADJ_DT_SCALE_W= 7'd62;  // Wait, add FP_HALF
localparam ST_ADJ_DT_RND    = 7'd63;  // Wait, fp_to_int, start tvec[3]*t_16
localparam ST_ADJ_DT_VEC    = 7'd64;  // Wait, fp_to_int, integer tadjust
localparam ST_DONE           = 7'd65;

reg [6:0] state;

// Intermediate registers
reg [31:0] p_saxis [0:2];
reg [31:0] p_taxis [0:2];
reg [31:0] t_reg;        // Temporary for xscaleinv*mipscale etc.
reg [31:0] mul_result_hold;  // Hold multiply result
reg [31:0] add_result_hold;
reg [31:0] origin_accum;  // Accumulator for origin computation
reg signed [31:0] adj_fp_int;  // Holds (int)(DotProduct*t_16 + 0.5) for adjust

// For dot product pipelining: we need 3 products then 2 additions
// We use the multiply unit sequentially (3 products), then add unit
reg [31:0] dp_prod0, dp_prod1, dp_prod2;
reg [1:0]  dp_mul_cnt;  // Which product we're collecting

wire busy = (state != ST_IDLE);
assign busy_o = busy;

// ============================================
// Register write handling
// ============================================
always @(posedge clk) begin
    if (!reset_n) begin
        state <= ST_IDLE;
    end else begin
        // Default: no FP operations
        fmul_start <= 1'b0;
        fadd_start <= 1'b0;

        // Register writes
        if (reg_wr && !busy) begin
            case (reg_addr)
                // Frame constants
                6'h00: vright[0]   <= reg_wdata;
                6'h01: vright[1]   <= reg_wdata;
                6'h02: vright[2]   <= reg_wdata;
                6'h03: vup[0]      <= reg_wdata;
                6'h04: vup[1]      <= reg_wdata;
                6'h05: vup[2]      <= reg_wdata;
                6'h06: vpn[0]      <= reg_wdata;
                6'h07: vpn[1]      <= reg_wdata;
                6'h08: vpn[2]      <= reg_wdata;
                6'h09: xscaleinv   <= reg_wdata;
                6'h0A: yscaleinv   <= reg_wdata;
                6'h0B: xcenter     <= reg_wdata;
                6'h0C: ycenter     <= reg_wdata;
                6'h0D: modelorg[0] <= reg_wdata;
                6'h0E: modelorg[1] <= reg_wdata;
                6'h0F: modelorg[2] <= reg_wdata;
                // Per-surface
                6'h10: svec[0]     <= reg_wdata;
                6'h11: svec[1]     <= reg_wdata;
                6'h12: svec[2]     <= reg_wdata;
                6'h13: svec[3]     <= reg_wdata;
                6'h14: tvec[0]     <= reg_wdata;
                6'h15: tvec[1]     <= reg_wdata;
                6'h16: tvec[2]     <= reg_wdata;
                6'h17: tvec[3]     <= reg_wdata;
                6'h18: miplevel    <= reg_wdata[2:0];
                6'h19: begin
                    texmins_s <= reg_wdata[15:0];
                    texmins_t <= reg_wdata[31:16];
                end
                6'h1A: begin
                    extents_s <= reg_wdata[15:0];
                    extents_t <= reg_wdata[31:16];
                end
                6'h1B: begin
                    // KICK — start computation
                    state <= ST_TV_S0_MUL;
                end
                default: ;
            endcase
        end

        // ============================================
        // Computation FSM
        // ============================================
        case (state)
            ST_IDLE: ; // Do nothing — KICK write handles transition

            // ---- TransformVector(svec) → p_saxis ----
            // Dot product: svec[0]*vright[0] + svec[1]*vright[1] + svec[2]*vright[2]
            ST_TV_S0_MUL: begin
                // Start svec[0] * vright[0]
                fmul_a <= svec[0]; fmul_b <= vright[0]; fmul_start <= 1'b1;
                dp_mul_cnt <= 0;
                state <= ST_TV_S0_W1;
            end
            ST_TV_S0_W1: begin
                // Pipeline: start next mul while waiting (3-cycle mul latency)
                if (dp_mul_cnt == 0) begin
                    fmul_a <= svec[1]; fmul_b <= vright[1]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 1;
                end else if (dp_mul_cnt == 1) begin
                    fmul_a <= svec[2]; fmul_b <= vright[2]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 2;
                end else if (dp_mul_cnt == 2) begin
                    dp_prod0 <= fmul_result;  // svec[0]*vright[0] ready
                    dp_mul_cnt <= 3;
                end else begin
                    dp_prod1 <= fmul_result;  // svec[1]*vup[0] ready
                    state <= ST_TV_S0_ADD1;
                end
            end
            ST_TV_S0_ADD1: begin
                dp_prod2 <= fmul_result;  // svec[2]*vpn[0] ready
                // Add prod0 + prod1
                fadd_a <= dp_prod0; fadd_b <= dp_prod1; fadd_sub <= 0; fadd_start <= 1'b1;
                state <= ST_TV_S0_ADD2;
            end
            ST_TV_S0_ADD2: begin
                if (fadd_valid) begin
                    // Add (prod0+prod1) + prod2
                    fadd_a <= fadd_result; fadd_b <= dp_prod2; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_TV_S1_MUL;
                end
            end

            // p_saxis[0] captured, start p_saxis[1] = dot(svec, vup)
            ST_TV_S1_MUL: begin
                if (fadd_valid) begin
                    p_saxis[0] <= fadd_result;
                    fmul_a <= svec[0]; fmul_b <= vup[0]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 0;
                    state <= ST_TV_S1_W1;
                end
            end
            ST_TV_S1_W1: begin
                if (dp_mul_cnt == 0) begin
                    fmul_a <= svec[1]; fmul_b <= vup[1]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 1;
                end else if (dp_mul_cnt == 1) begin
                    fmul_a <= svec[2]; fmul_b <= vup[2]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 2;
                end else if (dp_mul_cnt == 2) begin
                    dp_prod0 <= fmul_result;
                    dp_mul_cnt <= 3;
                end else begin
                    dp_prod1 <= fmul_result;
                    state <= ST_TV_S1_ADD1;
                end
            end
            ST_TV_S1_ADD1: begin
                dp_prod2 <= fmul_result;
                fadd_a <= dp_prod0; fadd_b <= dp_prod1; fadd_sub <= 0; fadd_start <= 1'b1;
                state <= ST_TV_S1_ADD2;
            end
            ST_TV_S1_ADD2: begin
                if (fadd_valid) begin
                    fadd_a <= fadd_result; fadd_b <= dp_prod2; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_TV_S2_MUL;
                end
            end

            // p_saxis[1] captured, start p_saxis[2] = dot(svec, vpn)
            ST_TV_S2_MUL: begin
                if (fadd_valid) begin
                    p_saxis[1] <= fadd_result;
                    fmul_a <= svec[0]; fmul_b <= vpn[0]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 0;
                    state <= ST_TV_S2_W1;
                end
            end
            ST_TV_S2_W1: begin
                if (dp_mul_cnt == 0) begin
                    fmul_a <= svec[1]; fmul_b <= vpn[1]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 1;
                end else if (dp_mul_cnt == 1) begin
                    fmul_a <= svec[2]; fmul_b <= vpn[2]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 2;
                end else if (dp_mul_cnt == 2) begin
                    dp_prod0 <= fmul_result;
                    dp_mul_cnt <= 3;
                end else begin
                    dp_prod1 <= fmul_result;
                    state <= ST_TV_S2_ADD1;
                end
            end
            ST_TV_S2_ADD1: begin
                dp_prod2 <= fmul_result;
                fadd_a <= dp_prod0; fadd_b <= dp_prod1; fadd_sub <= 0; fadd_start <= 1'b1;
                state <= ST_TV_S2_ADD2;
            end
            ST_TV_S2_ADD2: begin
                if (fadd_valid) begin
                    fadd_a <= fadd_result; fadd_b <= dp_prod2; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_TV_T0_MUL;
                end
            end

            // ---- TransformVector(tvec) → p_taxis ----
            // p_taxis[0] = dot(tvec, vright)
            ST_TV_T0_MUL: begin
                if (fadd_valid) begin
                    p_saxis[2] <= fadd_result;
                    fmul_a <= tvec[0]; fmul_b <= vright[0]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 0;
                    state <= ST_TV_T0_W1;
                end
            end
            ST_TV_T0_W1: begin
                if (dp_mul_cnt == 0) begin
                    fmul_a <= tvec[1]; fmul_b <= vright[1]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 1;
                end else if (dp_mul_cnt == 1) begin
                    fmul_a <= tvec[2]; fmul_b <= vright[2]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 2;
                end else if (dp_mul_cnt == 2) begin
                    dp_prod0 <= fmul_result;
                    dp_mul_cnt <= 3;
                end else begin
                    dp_prod1 <= fmul_result;
                    state <= ST_TV_T0_ADD1;
                end
            end
            ST_TV_T0_ADD1: begin
                dp_prod2 <= fmul_result;
                fadd_a <= dp_prod0; fadd_b <= dp_prod1; fadd_sub <= 0; fadd_start <= 1'b1;
                state <= ST_TV_T0_ADD2;
            end
            ST_TV_T0_ADD2: begin
                if (fadd_valid) begin
                    fadd_a <= fadd_result; fadd_b <= dp_prod2; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_TV_T1_MUL;
                end
            end

            // p_taxis[1] = dot(tvec, vup)
            ST_TV_T1_MUL: begin
                if (fadd_valid) begin
                    p_taxis[0] <= fadd_result;
                    fmul_a <= tvec[0]; fmul_b <= vup[0]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 0;
                    state <= ST_TV_T1_W1;
                end
            end
            ST_TV_T1_W1: begin
                if (dp_mul_cnt == 0) begin
                    fmul_a <= tvec[1]; fmul_b <= vup[1]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 1;
                end else if (dp_mul_cnt == 1) begin
                    fmul_a <= tvec[2]; fmul_b <= vup[2]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 2;
                end else if (dp_mul_cnt == 2) begin
                    dp_prod0 <= fmul_result;
                    dp_mul_cnt <= 3;
                end else begin
                    dp_prod1 <= fmul_result;
                    state <= ST_TV_T1_ADD1;
                end
            end
            ST_TV_T1_ADD1: begin
                dp_prod2 <= fmul_result;
                fadd_a <= dp_prod0; fadd_b <= dp_prod1; fadd_sub <= 0; fadd_start <= 1'b1;
                state <= ST_TV_T1_ADD2;
            end
            ST_TV_T1_ADD2: begin
                if (fadd_valid) begin
                    fadd_a <= fadd_result; fadd_b <= dp_prod2; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_TV_T2_MUL;
                end
            end

            // p_taxis[2] = dot(tvec, vpn)
            ST_TV_T2_MUL: begin
                if (fadd_valid) begin
                    p_taxis[1] <= fadd_result;
                    fmul_a <= tvec[0]; fmul_b <= vpn[0]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 0;
                    state <= ST_TV_T2_W1;
                end
            end
            ST_TV_T2_W1: begin
                if (dp_mul_cnt == 0) begin
                    fmul_a <= tvec[1]; fmul_b <= vpn[1]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 1;
                end else if (dp_mul_cnt == 1) begin
                    fmul_a <= tvec[2]; fmul_b <= vpn[2]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 2;
                end else if (dp_mul_cnt == 2) begin
                    dp_prod0 <= fmul_result;
                    dp_mul_cnt <= 3;
                end else begin
                    dp_prod1 <= fmul_result;
                    state <= ST_TV_T2_ADD1;
                end
            end
            ST_TV_T2_ADD1: begin
                dp_prod2 <= fmul_result;
                fadd_a <= dp_prod0; fadd_b <= dp_prod1; fadd_sub <= 0; fadd_start <= 1'b1;
                state <= ST_TV_T2_ADD2;
            end
            ST_TV_T2_ADD2: begin
                if (fadd_valid) begin
                    fadd_a <= fadd_result; fadd_b <= dp_prod2; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_STEPU;
                end
            end

            // ---- Phase 3: Step and origin computation ----
            // t = xscaleinv * mipscale
            ST_STEPU: begin
                if (fadd_valid) begin
                    p_taxis[2] <= fadd_result;
                    fmul_a <= xscaleinv; fmul_b <= mipscale_fp; fmul_start <= 1'b1;
                    state <= ST_STEPU_W;
                end
            end
            ST_STEPU_W: begin
                if (fmul_valid) begin
                    t_reg <= fmul_result;  // t = xscaleinv * mipscale
                    // d_sdivzstepu = p_saxis[0] * t
                    fmul_a <= p_saxis[0]; fmul_b <= fmul_result; fmul_start <= 1'b1;
                    state <= ST_STEPU_S;
                end
            end
            ST_STEPU_S: begin
                if (fmul_valid) begin
                    r_sdivzstepu <= fmul_result;
                    // d_tdivzstepu = p_taxis[0] * t
                    fmul_a <= p_taxis[0]; fmul_b <= t_reg; fmul_start <= 1'b1;
                    state <= ST_STEPU_T;
                end
            end
            ST_STEPU_T: begin
                if (fmul_valid) begin
                    r_tdivzstepu <= fmul_result;
                    // t = yscaleinv * mipscale
                    fmul_a <= yscaleinv; fmul_b <= mipscale_fp; fmul_start <= 1'b1;
                    state <= ST_STEPV;
                end
            end

            ST_STEPV: begin
                // Wait for yscaleinv * mipscale
                state <= ST_STEPV_W;
            end
            ST_STEPV_W: begin
                if (fmul_valid) begin
                    t_reg <= fmul_result;
                    // d_sdivzstepv = -p_saxis[1] * t
                    fmul_a <= fp_neg(p_saxis[1]); fmul_b <= fmul_result; fmul_start <= 1'b1;
                    state <= ST_STEPV_S;
                end
            end
            ST_STEPV_S: begin
                if (fmul_valid) begin
                    r_sdivzstepv <= fmul_result;
                    // d_tdivzstepv = -p_taxis[1] * t
                    fmul_a <= fp_neg(p_taxis[1]); fmul_b <= t_reg; fmul_start <= 1'b1;
                    state <= ST_STEPV_T;
                end
            end
            ST_STEPV_T: begin
                if (fmul_valid) begin
                    r_tdivzstepv <= fmul_result;
                    // Start origin computation: p_saxis[2] * mipscale
                    fmul_a <= p_saxis[2]; fmul_b <= mipscale_fp; fmul_start <= 1'b1;
                    state <= ST_ORIG_MUL1;
                end
            end

            // d_sdivzorigin = p_saxis[2]*mipscale - xcenter*sdivzstepu - ycenter*sdivzstepv
            ST_ORIG_MUL1: state <= ST_ORIG_MUL1_W;
            ST_ORIG_MUL1_W: begin
                if (fmul_valid) begin
                    origin_accum <= fmul_result;  // p_saxis[2]*mipscale
                    fmul_a <= xcenter; fmul_b <= r_sdivzstepu; fmul_start <= 1'b1;
                    state <= ST_ORIG_SUB1;
                end
            end
            ST_ORIG_SUB1: state <= ST_ORIG_SUB1_W;
            ST_ORIG_SUB1_W: begin
                if (fmul_valid) begin
                    fadd_a <= origin_accum; fadd_b <= fmul_result; fadd_sub <= 1; fadd_start <= 1'b1;
                    fmul_a <= ycenter; fmul_b <= r_sdivzstepv; fmul_start <= 1'b1;
                    state <= ST_ORIG_SUB1A;
                end
            end
            ST_ORIG_SUB1A: begin
                if (fmul_valid) mul_result_hold <= fmul_result;  // ycenter*sdivzstepv (same cycle as fadd_valid)
                if (fadd_valid) begin
                    origin_accum <= fadd_result;
                    state <= ST_ORIG_SUB2;
                end
            end
            ST_ORIG_SUB2: begin
                // Use captured mul result directly (fmul_valid already pulsed in SUB1A)
                fadd_a <= origin_accum; fadd_b <= mul_result_hold; fadd_sub <= 1; fadd_start <= 1'b1;
                state <= ST_ORIG_SUB2A;
            end
            ST_ORIG_SUB2A: begin
                if (fadd_valid) begin
                    r_sdivzorigin <= fadd_result;
                    // Now do same for tdivz origin
                    fmul_a <= p_taxis[2]; fmul_b <= mipscale_fp; fmul_start <= 1'b1;
                    state <= ST_ORIG_T;
                end
            end

            // d_tdivzorigin = p_taxis[2]*mipscale - xcenter*tdivzstepu - ycenter*tdivzstepv
            ST_ORIG_T: state <= ST_ORIG_T_W;
            ST_ORIG_T_W: begin
                if (fmul_valid) begin
                    origin_accum <= fmul_result;
                    fmul_a <= xcenter; fmul_b <= r_tdivzstepu; fmul_start <= 1'b1;
                    state <= ST_ORIG_T_SUB1;
                end
            end
            ST_ORIG_T_SUB1: state <= ST_ORIG_T_S1W;
            ST_ORIG_T_S1W: begin
                if (fmul_valid) begin
                    fadd_a <= origin_accum; fadd_b <= fmul_result; fadd_sub <= 1; fadd_start <= 1'b1;
                    fmul_a <= ycenter; fmul_b <= r_tdivzstepv; fmul_start <= 1'b1;
                    state <= ST_ORIG_T_S1A;
                end
            end
            ST_ORIG_T_S1A: begin
                if (fmul_valid) mul_result_hold <= fmul_result;  // ycenter*tdivzstepv (same cycle as fadd_valid)
                if (fadd_valid) begin
                    origin_accum <= fadd_result;
                    state <= ST_ORIG_T_SUB2;
                end
            end
            ST_ORIG_T_SUB2: begin
                // Use captured mul result directly (fmul_valid already pulsed in T_S1A)
                fadd_a <= origin_accum; fadd_b <= mul_result_hold; fadd_sub <= 1; fadd_start <= 1'b1;
                state <= ST_ORIG_T_S2A;
            end
            ST_ORIG_T_S2A: begin
                if (fadd_valid) begin
                    r_tdivzorigin <= fadd_result;
                    state <= ST_ADJ_BBEXT;
                end
            end

            // ---- Phase 4: bbextents + sadjust/tadjust ----
            // sadjust = (int)(DotProduct(modelorg, p_saxis) * t_16 + 0.5)
            //         - (texmins_s << 16 >> miplevel) + (int)(svec[3] * t_16)
            // where t_16 = 0x10000 * mipscale, modelorg = transformed_modelorg

            ST_ADJ_BBEXT: begin
                r_bbextents <= (({16'd0, extents_s} << 16) >> miplevel) - 32'd1;
                r_bbextentt <= (({16'd0, extents_t} << 16) >> miplevel) - 32'd1;
                // Start DotProduct(modelorg, p_saxis)
                fmul_a <= modelorg[0]; fmul_b <= p_saxis[0]; fmul_start <= 1'b1;
                dp_mul_cnt <= 0;
                state <= ST_ADJ_DS_W1;
            end
            ST_ADJ_DS_W1: begin
                if (dp_mul_cnt == 0) begin
                    fmul_a <= modelorg[1]; fmul_b <= p_saxis[1]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 1;
                end else if (dp_mul_cnt == 1) begin
                    fmul_a <= modelorg[2]; fmul_b <= p_saxis[2]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 2;
                end else if (dp_mul_cnt == 2) begin
                    dp_prod0 <= fmul_result;
                    dp_mul_cnt <= 3;
                end else begin
                    dp_prod1 <= fmul_result;
                    state <= ST_ADJ_DS_ADD1;
                end
            end
            ST_ADJ_DS_ADD1: begin
                dp_prod2 <= fmul_result;
                fadd_a <= dp_prod0; fadd_b <= dp_prod1; fadd_sub <= 0; fadd_start <= 1'b1;
                state <= ST_ADJ_DS_ADD2;
            end
            ST_ADJ_DS_ADD2: begin
                if (fadd_valid) begin
                    fadd_a <= fadd_result; fadd_b <= dp_prod2; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_ADJ_DS_SCALE;
                end
            end
            ST_ADJ_DS_SCALE: begin
                if (fadd_valid) begin
                    fmul_a <= fadd_result; fmul_b <= t_16_fp; fmul_start <= 1'b1;
                    state <= ST_ADJ_DS_SCALE_W;
                end
            end
            ST_ADJ_DS_SCALE_W: begin
                if (fmul_valid) begin
                    fadd_a <= fmul_result; fadd_b <= FP_HALF; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_ADJ_DS_RND;
                end
            end
            ST_ADJ_DS_RND: begin
                if (fadd_valid) begin
                    adj_fp_int <= fp_to_int(fadd_result);
                    fmul_a <= svec[3]; fmul_b <= t_16_fp; fmul_start <= 1'b1;
                    state <= ST_ADJ_DS_VEC;
                end
            end
            ST_ADJ_DS_VEC: begin
                if (fmul_valid) begin
                    r_sadjust <= adj_fp_int
                               - ($signed({texmins_s, 16'd0}) >>> miplevel)
                               + fp_to_int(fmul_result);
                    // Start DotProduct(modelorg, p_taxis)
                    fmul_a <= modelorg[0]; fmul_b <= p_taxis[0]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 0;
                    state <= ST_ADJ_DT_W1;
                end
            end

            // tadjust: same pattern with p_taxis and tvec[3]
            ST_ADJ_DT_MUL: begin
                fmul_a <= modelorg[0]; fmul_b <= p_taxis[0]; fmul_start <= 1'b1;
                dp_mul_cnt <= 0;
                state <= ST_ADJ_DT_W1;
            end
            ST_ADJ_DT_W1: begin
                if (dp_mul_cnt == 0) begin
                    fmul_a <= modelorg[1]; fmul_b <= p_taxis[1]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 1;
                end else if (dp_mul_cnt == 1) begin
                    fmul_a <= modelorg[2]; fmul_b <= p_taxis[2]; fmul_start <= 1'b1;
                    dp_mul_cnt <= 2;
                end else if (dp_mul_cnt == 2) begin
                    dp_prod0 <= fmul_result;
                    dp_mul_cnt <= 3;
                end else begin
                    dp_prod1 <= fmul_result;
                    state <= ST_ADJ_DT_ADD1;
                end
            end
            ST_ADJ_DT_ADD1: begin
                dp_prod2 <= fmul_result;
                fadd_a <= dp_prod0; fadd_b <= dp_prod1; fadd_sub <= 0; fadd_start <= 1'b1;
                state <= ST_ADJ_DT_ADD2;
            end
            ST_ADJ_DT_ADD2: begin
                if (fadd_valid) begin
                    fadd_a <= fadd_result; fadd_b <= dp_prod2; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_ADJ_DT_SCALE;
                end
            end
            ST_ADJ_DT_SCALE: begin
                if (fadd_valid) begin
                    fmul_a <= fadd_result; fmul_b <= t_16_fp; fmul_start <= 1'b1;
                    state <= ST_ADJ_DT_SCALE_W;
                end
            end
            ST_ADJ_DT_SCALE_W: begin
                if (fmul_valid) begin
                    fadd_a <= fmul_result; fadd_b <= FP_HALF; fadd_sub <= 0; fadd_start <= 1'b1;
                    state <= ST_ADJ_DT_RND;
                end
            end
            ST_ADJ_DT_RND: begin
                if (fadd_valid) begin
                    adj_fp_int <= fp_to_int(fadd_result);
                    fmul_a <= tvec[3]; fmul_b <= t_16_fp; fmul_start <= 1'b1;
                    state <= ST_ADJ_DT_VEC;
                end
            end
            ST_ADJ_DT_VEC: begin
                if (fmul_valid) begin
                    r_tadjust <= adj_fp_int
                               - ($signed({texmins_t, 16'd0}) >>> miplevel)
                               + fp_to_int(fmul_result);
                    state <= ST_DONE;
                end
            end

            ST_DONE: begin
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

// ============================================
// Register read mux
// ============================================
always @(*) begin
    case (reg_addr)
        6'h20: reg_rdata = r_sdivzstepu;
        6'h21: reg_rdata = r_tdivzstepu;
        6'h22: reg_rdata = r_sdivzstepv;
        6'h23: reg_rdata = r_tdivzstepv;
        6'h24: reg_rdata = r_sdivzorigin;
        6'h25: reg_rdata = r_tdivzorigin;
        6'h26: reg_rdata = r_sadjust;
        6'h27: reg_rdata = r_tadjust;
        6'h28: reg_rdata = r_bbextents;
        6'h29: reg_rdata = r_bbextentt;
        6'h2A: reg_rdata = {31'd0, busy};
        default: reg_rdata = 32'd0;
    endcase
end

endmodule
