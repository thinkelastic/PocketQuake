//
// AXI4 Peripheral Slave
// Handles all local/peripheral accesses from the CPU:
//   - BRAM (64KB, burst reads for I-cache line fills)
//   - Colormap BRAM (dual-port, port B for span rasterizer)
//   - System registers (cycle counter, display, palette, dataslot, controllers)
//   - CDC synchronizers (vsync, allcomplete, controller inputs, dataslot ack/done)
//   - Terminal forwarding
//   - DMA/Span/ATM/Audio/Link register dispatch
//
// AXI4 slave (NOT AXI4-Lite) — iBus issues burst reads to BRAM for I-cache fills.
//

`default_nettype none

module axi_periph_slave #(
    parameter ENABLE_DEBUG_CTRS = 1   // Debug scanline counters
) (
    input wire clk,
    input wire reset_n,

    // AXI4 slave interface (from cpu_system m_local)
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    input  wire [31:0] s_axi_araddr,
    input  wire [7:0]  s_axi_arlen,

    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rlast,

    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,

    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wlast,

    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    output reg  [1:0]  s_axi_bresp,

    // CDC inputs
    input wire         dataslot_allcomplete,
    input wire         vsync,
    input wire [31:0]  cont1_key,
    input wire [31:0]  cont1_joy,
    input wire [15:0]  cont1_trig,
    input wire [31:0]  cont2_key,
    input wire [31:0]  cont2_joy,
    input wire [15:0]  cont2_trig,
    input wire         target_dataslot_ack,
    input wire         target_dataslot_done,
    input wire [2:0]   target_dataslot_err,

    // Terminal memory interface
    output wire        term_mem_valid,
    output wire [31:0] term_mem_addr,
    output wire [31:0] term_mem_wdata,
    output wire [3:0]  term_mem_wstrb,
    input wire  [31:0] term_mem_rdata,
    input wire         term_mem_ready,

    // Display control outputs
    output wire        display_mode,
    output wire [24:0] fb_display_addr,

    // Palette write interface
    output reg         pal_wr,
    output reg  [7:0]  pal_addr,
    output reg  [23:0] pal_data,

    // Target dataslot interface
    output reg         target_dataslot_read,
    output reg         target_dataslot_write,
    output reg         target_dataslot_openfile,
    output reg  [15:0] target_dataslot_id,
    output reg  [31:0] target_dataslot_slotoffset,
    output reg  [31:0] target_dataslot_bridgeaddr,
    output reg  [31:0] target_dataslot_length,
    output reg  [31:0] target_buffer_param_struct,
    output reg  [31:0] target_buffer_resp_struct,

    // DMA peripheral register interface
    output reg         dma_reg_wr,
    output reg  [4:0]  dma_reg_addr,
    output reg  [31:0] dma_reg_wdata,
    input wire  [31:0] dma_reg_rdata,

    // Span rasterizer register interface
    output reg         span_reg_wr,
    output reg  [5:0]  span_reg_addr,
    output reg  [31:0] span_reg_wdata,
    input wire  [31:0] span_reg_rdata,

    // Alias Transform MAC register interface
    output reg         atm_reg_wr,
    output reg  [4:0]  atm_reg_addr,
    output reg  [31:0] atm_reg_wdata,
    input wire  [31:0] atm_reg_rdata,
    output reg         atm_norm_wr,
    output reg  [8:0]  atm_norm_addr,
    output reg  [31:0] atm_norm_wdata,
    input wire         atm_busy,

    // Audio output interface
    output reg         audio_sample_wr,
    output reg  [31:0] audio_sample_data,
    input wire  [11:0] audio_fifo_level,
    input wire         audio_fifo_full,

    // Link MMIO interface
    output reg         link_reg_wr,
    output reg         link_reg_rd,
    output reg  [4:0]  link_reg_addr,
    output reg  [31:0] link_reg_wdata,
    input wire  [31:0] link_reg_rdata,

    // Colormap BRAM port B (read-only, for span rasterizer)
    input wire  [11:0] span_cmap_addr,
    output wire [31:0] span_cmap_rdata,

    // SRAM word interface (for CPU z-buffer access)
    output reg         cpu_sram_rd,
    output reg         cpu_sram_wr,
    output reg  [21:0] cpu_sram_addr,
    output reg  [31:0] cpu_sram_wdata,
    output reg  [3:0]  cpu_sram_wstrb,
    input wire         cpu_sram_busy,
    input wire  [31:0] cpu_sram_q,
    input wire         cpu_sram_q_valid,

    // sram_fill register interface
    output reg         sramfill_reg_wr,
    output reg  [4:0]  sramfill_reg_addr,
    output reg  [31:0] sramfill_reg_wdata,
    input wire  [31:0] sramfill_reg_rdata,

    // Scanline engine register interface
    output reg         scanline_reg_wr,
    output reg         scanline_reg_rd,
    output reg  [3:0]  scanline_reg_addr,
    output reg  [31:0] scanline_reg_wdata,
    input wire  [31:0] scanline_reg_rdata
);

wire reset = ~reset_n;

// ============================================
// Address decode (combinatorial, on AXI address channels)
// ============================================
// Decode is performed on the incoming AXI address for first beat,
// then on latched address for subsequent operations.

wire [31:0] ar_addr = s_axi_araddr;
wire [31:0] aw_addr = s_axi_awaddr;

// ============================================
// BRAM (64KB = 16384 x 32-bit words)
// ============================================
wire [31:0] ram_rdata;
reg  [13:0] ram_addr_mux;
wire ram_wren;

altsyncram #(
    .operation_mode("SINGLE_PORT"),
    .width_a(32),
    .widthad_a(14),
    .numwords_a(16384),
    .width_byteena_a(4),
    .lpm_type("altsyncram"),
    .outdata_reg_a("UNREGISTERED"),
    .init_file("core/firmware.mif"),
    .intended_device_family("Cyclone V"),
    .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ")
) ram (
    .clock0(clk),
    .address_a(ram_addr_mux),
    .data_a(req_wdata),
    .wren_a(ram_wren),
    .byteena_a(req_wstrb),
    .q_a(ram_rdata),
    .aclr0(1'b0),
    .aclr1(1'b0),
    .address_b(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_b(1'b1),
    .clock1(1'b1),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .data_b({32{1'b0}}),
    .eccstatus(),
    .q_b(),
    .rden_a(1'b1),
    .rden_b(1'b0),
    .wren_b(1'b0)
);

// ============================================
// Colormap BRAM (16KB = 4096 x 32-bit words)
// ============================================
reg [31:0] cmap_rdata;
reg [11:0] cmap_addr_mux;
wire cmap_wren;
wire [3:0] cmap_byteena;
wire [31:0] cmap_wdata_mux;

(* ramstyle = "M10K" *) reg [7:0] cmap_mem0 [0:4095];
(* ramstyle = "M10K" *) reg [7:0] cmap_mem1 [0:4095];
(* ramstyle = "M10K" *) reg [7:0] cmap_mem2 [0:4095];
(* ramstyle = "M10K" *) reg [7:0] cmap_mem3 [0:4095];

reg [31:0] span_cmap_rdata_r;
assign span_cmap_rdata = span_cmap_rdata_r;

// Port A - CPU read/write
always @(posedge clk) begin
    if (cmap_wren && cmap_byteena[0]) cmap_mem0[cmap_addr_mux] <= cmap_wdata_mux[7:0];
    if (cmap_wren && cmap_byteena[1]) cmap_mem1[cmap_addr_mux] <= cmap_wdata_mux[15:8];
    if (cmap_wren && cmap_byteena[2]) cmap_mem2[cmap_addr_mux] <= cmap_wdata_mux[23:16];
    if (cmap_wren && cmap_byteena[3]) cmap_mem3[cmap_addr_mux] <= cmap_wdata_mux[31:24];
    cmap_rdata <= {cmap_mem3[cmap_addr_mux], cmap_mem2[cmap_addr_mux],
                   cmap_mem1[cmap_addr_mux], cmap_mem0[cmap_addr_mux]};
end

// Port B - Span rasterizer read-only
always @(posedge clk) begin
    span_cmap_rdata_r <= {cmap_mem3[span_cmap_addr], cmap_mem2[span_cmap_addr],
                          cmap_mem1[span_cmap_addr], cmap_mem0[span_cmap_addr]};
end

// ============================================
// Terminal forwarding
// ============================================
assign term_mem_valid = term_pending;
assign term_mem_addr  = req_addr;
assign term_mem_wdata = req_wdata;
assign term_mem_wstrb = is_write ? req_wstrb : 4'b0;

// ============================================
// System registers
// ============================================
reg [31:0] sysreg_rdata;
reg [63:0] cycle_counter;
reg display_mode_reg;

reg [15:0] ds_slot_id_reg;
reg [31:0] ds_slot_offset_reg;
reg [31:0] ds_bridge_addr_reg;
reg [31:0] ds_length_reg;
reg [31:0] ds_param_addr_reg;
reg [31:0] ds_resp_addr_reg;

reg [7:0] pal_index_reg;

// Triple-buffered framebuffer: 3 fixed buffers, indexed by role
localparam FB_ADDR_0 = 25'h0000000;  // 0x10000000 in CPU space
localparam FB_ADDR_1 = 25'h0080000;  // 0x10100000
localparam FB_ADDR_2 = 25'h0100000;  // 0x10200000 (quake.bin LMA, free after boot)
reg [1:0] fb_display_idx;   // buffer being scanned out
reg [1:0] fb_ready_idx;     // completed frame waiting for vsync (3 = none)
reg [1:0] fb_draw_idx;      // buffer CPU is rendering to

// Lookup table: index → word address
function [24:0] fb_addr;
    input [1:0] idx;
    case (idx)
        2'd0: fb_addr = FB_ADDR_0;
        2'd1: fb_addr = FB_ADDR_1;
        2'd2: fb_addr = FB_ADDR_2;
        default: fb_addr = FB_ADDR_0;
    endcase
endfunction

wire [24:0] fb_display_addr_reg = fb_addr(fb_display_idx);
wire [24:0] fb_draw_addr_reg = fb_addr(fb_draw_idx);

// Find the free buffer (neither display nor draw)
function [1:0] fb_free;
    input [1:0] disp, draw;
    begin
        if (disp != 2'd0 && draw != 2'd0) fb_free = 2'd0;
        else if (disp != 2'd1 && draw != 2'd1) fb_free = 2'd1;
        else fb_free = 2'd2;
    end
endfunction

assign display_mode = display_mode_reg;
assign fb_display_addr = fb_display_addr_reg;

// ============================================
// CDC synchronizers
// ============================================

// dataslot_allcomplete from bridge clock domain
reg [2:0] dataslot_allcomplete_sync;
always @(posedge clk) begin
    dataslot_allcomplete_sync <= {dataslot_allcomplete_sync[1:0], dataslot_allcomplete};
end
wire dataslot_allcomplete_s = dataslot_allcomplete_sync[2];

// vsync to CPU clock domain
reg [2:0] vsync_sync;
always @(posedge clk) begin
    vsync_sync <= {vsync_sync[1:0], vsync};
end
wire vsync_rising = vsync_sync[1] && !vsync_sync[2];

// target_dataslot_ack and target_dataslot_done from bridge clock domain
reg [2:0] target_ack_sync;
reg [2:0] target_done_sync;
reg [2:0] target_err_sync [2:0];
always @(posedge clk or posedge reset) begin
    if (reset) begin
        target_ack_sync <= 3'b0;
        target_done_sync <= 3'b0;
        target_err_sync[0] <= 3'b0;
        target_err_sync[1] <= 3'b0;
        target_err_sync[2] <= 3'b0;
    end else begin
        target_ack_sync <= {target_ack_sync[1:0], target_dataslot_ack};
        target_done_sync <= {target_done_sync[1:0], target_dataslot_done};
        target_err_sync[0] <= {target_err_sync[0][1:0], target_dataslot_err[0]};
        target_err_sync[1] <= {target_err_sync[1][1:0], target_dataslot_err[1]};
        target_err_sync[2] <= {target_err_sync[2][1:0], target_dataslot_err[2]};
    end
end
wire target_ack_s = target_ack_sync[2];
wire target_done_s = target_done_sync[2];
wire [2:0] target_err_s = {target_err_sync[2][2], target_err_sync[1][2], target_err_sync[0][2]};

// Controller state from APF clock domain
wire [31:0] cont1_key_s;
wire [31:0] cont1_joy_s;
wire [15:0] cont1_trig_s;
wire [31:0] cont2_key_s;
wire [31:0] cont2_joy_s;
wire [15:0] cont2_trig_s;
synch_3 #(.WIDTH(32)) s_cont1_key(.i(cont1_key), .o(cont1_key_s), .clk(clk), .rise(), .fall());
synch_3 #(.WIDTH(32)) s_cont2_key(.i(cont2_key), .o(cont2_key_s), .clk(clk), .rise(), .fall());
synch_3 #(.WIDTH(32)) s_cont2_joy(.i(cont2_joy), .o(cont2_joy_s), .clk(clk), .rise(), .fall());
synch_3 #(.WIDTH(16)) s_cont2_trig(.i(cont2_trig), .o(cont2_trig_s), .clk(clk), .rise(), .fall());
synch_3 #(.WIDTH(32)) s_cont1_joy(.i(cont1_joy), .o(cont1_joy_s), .clk(clk), .rise(), .fall());
synch_3 #(.WIDTH(16)) s_cont1_trig(.i(cont1_trig), .o(cont1_trig_s), .clk(clk), .rise(), .fall());

// ============================================
// System register write logic
// ============================================
reg sysreg_wr_fire;

always @(posedge clk) begin
    if (reset) begin
        cycle_counter <= 0;
        display_mode_reg <= 0;
        fb_display_idx <= 2'd0;
        fb_ready_idx <= 2'd3;  // 3 = none ready
        fb_draw_idx <= 2'd1;
        pal_wr <= 0;
        pal_addr <= 0;
        pal_data <= 0;
        pal_index_reg <= 0;
        ds_slot_id_reg <= 0;
        ds_slot_offset_reg <= 0;
        ds_bridge_addr_reg <= 0;
        ds_length_reg <= 0;
        ds_param_addr_reg <= 0;
        ds_resp_addr_reg <= 0;
        target_dataslot_read <= 0;
        target_dataslot_write <= 0;
        target_dataslot_openfile <= 0;
        target_dataslot_id <= 0;
        target_dataslot_slotoffset <= 0;
        target_dataslot_bridgeaddr <= 0;
        target_dataslot_length <= 0;
        target_buffer_param_struct <= 0;
        target_buffer_resp_struct <= 0;
    end else begin
        cycle_counter <= cycle_counter + 1;
        pal_wr <= 0;

        if (target_ack_s) begin
            target_dataslot_read <= 0;
            target_dataslot_write <= 0;
            target_dataslot_openfile <= 0;
        end

        // Triple buffer: CPU swap request (before vsync so vsync can override fb_ready_idx)
        if (sysreg_wr_fire) begin
            case (req_addr[7:2])
                6'b000011: display_mode_reg <= req_wdata[0];
                6'b000110: if (req_wdata[0]) begin
                    // Draw buffer complete → ready; assign free buffer as new draw
                    fb_ready_idx <= fb_draw_idx;
                    fb_draw_idx <= fb_free(fb_display_idx, fb_draw_idx);
                end
                6'b001000: ds_slot_id_reg <= req_wdata[15:0];
                6'b001001: ds_slot_offset_reg <= req_wdata;
                6'b001010: ds_bridge_addr_reg <= req_wdata;
                6'b001011: ds_length_reg <= req_wdata;
                6'b001100: ds_param_addr_reg <= req_wdata;
                6'b001101: ds_resp_addr_reg <= req_wdata;
                6'b001110: begin
                    if (!(target_dataslot_read || target_dataslot_write || target_dataslot_openfile || target_ack_s)) begin
                        target_dataslot_id <= ds_slot_id_reg;
                        target_dataslot_slotoffset <= ds_slot_offset_reg;
                        target_dataslot_bridgeaddr <= ds_bridge_addr_reg;
                        target_dataslot_length <= ds_length_reg;
                        target_buffer_param_struct <= ds_param_addr_reg;
                        target_buffer_resp_struct <= ds_resp_addr_reg;
                        target_dataslot_read <= 0;
                        target_dataslot_write <= 0;
                        target_dataslot_openfile <= 0;
                        case (req_wdata[1:0])
                            2'b01: target_dataslot_read <= 1;
                            2'b10: target_dataslot_write <= 1;
                            2'b11: target_dataslot_openfile <= 1;
                            default: ;
                        endcase
                    end
                end
                6'b010000: pal_index_reg <= req_wdata[7:0];
                6'b010001: begin
                    pal_wr <= 1;
                    pal_addr <= pal_index_reg;
                    pal_data <= req_wdata[23:0];
                    pal_index_reg <= pal_index_reg + 1;
                end
                default: ;
            endcase
        end

        // Triple buffer vsync: promote ready → display (after sysreg_wr so vsync wins on collision)
        if (fb_ready_idx != 2'd3 && vsync_rising) begin
            fb_display_idx <= fb_ready_idx;
            fb_ready_idx <= 2'd3;  // consumed
        end
    end
end

// System register read mux (combinatorial)
always @(*) begin
    case (req_addr[7:2])
        6'b000000: sysreg_rdata = {30'b0, dataslot_allcomplete_s, 1'b1};
        6'b000001: sysreg_rdata = cycle_counter[31:0];
        6'b000010: sysreg_rdata = cycle_counter[63:32];
        6'b000011: sysreg_rdata = {31'b0, display_mode_reg};
        6'b000100: sysreg_rdata = {7'b0, fb_display_addr_reg};
        6'b000101: sysreg_rdata = {7'b0, fb_draw_addr_reg};
        6'b000110: sysreg_rdata = 32'h0;  // triple buffer: never blocks
        6'b001000: sysreg_rdata = {16'b0, ds_slot_id_reg};
        6'b001001: sysreg_rdata = ds_slot_offset_reg;
        6'b001010: sysreg_rdata = ds_bridge_addr_reg;
        6'b001011: sysreg_rdata = ds_length_reg;
        6'b001100: sysreg_rdata = ds_param_addr_reg;
        6'b001101: sysreg_rdata = ds_resp_addr_reg;
        6'b001110: sysreg_rdata = 32'h0;
        6'b001111: sysreg_rdata = {27'b0, target_err_s, target_done_s, target_ack_s};
        6'b010000: sysreg_rdata = {24'b0, pal_index_reg};
        6'b010001: sysreg_rdata = 32'h0;
        6'b010100: sysreg_rdata = cont1_key_s;
        6'b010101: sysreg_rdata = cont1_joy_s;
        6'b010110: sysreg_rdata = {16'b0, cont1_trig_s};
        6'b010111: sysreg_rdata = cont2_key_s;
        6'b011000: sysreg_rdata = cont2_joy_s;
        6'b011001: sysreg_rdata = {16'b0, cont2_trig_s};
        6'b011100: sysreg_rdata = 32'h0; // 0x70 (perf counters removed)
        6'b011101: sysreg_rdata = 32'h0; // 0x74
        6'b011110: sysreg_rdata = 32'h0; // 0x78
        6'b011111: sysreg_rdata = 32'h0; // 0x7C
        6'b100000: sysreg_rdata = 32'h0; // 0x80
        6'b100001: sysreg_rdata = 32'h0; // 0x84
        6'b100010: sysreg_rdata = 32'h0; // 0x88
        6'b100011: sysreg_rdata = 32'h0; // 0x8C
        6'b100100: sysreg_rdata = ENABLE_DEBUG_CTRS ? {dbg_scanline_rd_hit, dbg_scanline_ar_hit} : 32'h0; // 0x90
        6'b100101: sysreg_rdata = ENABLE_DEBUG_CTRS ? dbg_periph_rd_capture : 32'h0; // 0x94
        6'b100110: sysreg_rdata = 32'h0; // 0x98
        6'b100111: sysreg_rdata = 32'h0; // 0x9C
        default: sysreg_rdata = 32'h0;
    endcase
end

// ============================================
// Debug: scanline read path diagnostics (readable from sysreg space)
// ============================================
reg [15:0] dbg_scanline_ar_hit;    // S_IDLE: ar_dec_scanline was true
reg [15:0] dbg_scanline_rd_hit;    // S_PERIPH_RD: reg_scanline was true
reg [31:0] dbg_periph_rd_capture;  // last periph_rd_mux value when reg_scanline

// ============================================
// Peripheral read data mux (combinatorial)
// ============================================
wire [31:0] periph_rd_mux = reg_sysreg   ? sysreg_rdata :
                             reg_dma      ? dma_reg_rdata :
                             reg_span     ? span_reg_rdata :
                             reg_cmap     ? cmap_rdata :
                             reg_atm      ? atm_reg_rdata :
                             reg_audio    ? {19'b0, audio_fifo_full, audio_fifo_level} :
                             reg_link     ? link_reg_rdata :
                             reg_sramfill ? sramfill_reg_rdata :
                             reg_scanline ? scanline_reg_rdata :
                             32'h0;

// ============================================
// FSM
// ============================================
localparam S_IDLE      = 3'd0;
localparam S_BRAM_RD   = 3'd1;
localparam S_PERIPH_RD = 3'd2;
localparam S_PERIPH_WR = 3'd3;
localparam S_TERM      = 3'd4;
localparam S_WR_NEXT   = 3'd5;
localparam S_BRAM_WR   = 3'd6;
localparam S_SRAM_WAIT = 3'd7;

reg [2:0] state;

// Latched request fields
reg [31:0] req_addr;
reg [31:0] req_wdata;
reg [3:0]  req_wstrb;
reg        is_write;
reg [7:0]  burst_len;
reg [7:0]  burst_count;

// Region flags (latched on accept)
reg reg_ram;
reg reg_term;
reg reg_sysreg;
reg reg_dma;
reg reg_span;
reg reg_audio;
reg reg_link;
reg reg_cmap;
reg reg_atm;
reg reg_sram;
reg reg_sramfill;
reg reg_scanline;

// Whether this beat is the last of a burst
wire beat_is_last = (burst_count == burst_len);

// SRAM access tracking
reg sram_accepted;

// Terminal pending flag
wire term_pending = (state == S_TERM);

// BRAM address mux:
// - S_IDLE: use AR/AW addr combinatorially for first-beat address setup
// - S_BRAM_RD burst: advance combinatorially so BRAM captures NEXT address
// - S_BRAM_WR / other: use latched addr
wire [13:0] bram_next_word = req_addr[15:2] + 14'd1;

always @(*) begin
    case (state)
        S_IDLE: begin
            // Combinatorial: pick address from AR or AW channel
            if (s_axi_arvalid && !s_axi_awvalid)
                ram_addr_mux = ar_addr[15:2];
            else if (s_axi_awvalid)
                ram_addr_mux = aw_addr[15:2];
            else
                ram_addr_mux = 14'd0;
        end
        S_BRAM_RD: begin
            if (!beat_is_last)
                ram_addr_mux = bram_next_word;
            else
                ram_addr_mux = req_addr[15:2];
        end
        default: ram_addr_mux = req_addr[15:2];
    endcase
end

// BRAM write enable
assign ram_wren = (state == S_BRAM_WR) && (|req_wstrb);

// Colormap address mux
always @(*) begin
    if (state == S_IDLE) begin
        if (s_axi_arvalid && !s_axi_awvalid)
            cmap_addr_mux = ar_addr[13:2];
        else if (s_axi_awvalid)
            cmap_addr_mux = aw_addr[13:2];
        else
            cmap_addr_mux = 12'd0;
    end else begin
        cmap_addr_mux = req_addr[13:2];
    end
end

assign cmap_wren = (state == S_PERIPH_WR) && reg_cmap && (|req_wstrb);
assign cmap_byteena = req_wstrb;
assign cmap_wdata_mux = req_wdata;

// ============================================
// Region decode helpers (for first-beat routing)
// ============================================
wire ar_dec_ram    = (ar_addr[31:16] == 16'b0);
wire ar_dec_term   = (ar_addr[31:13] == 19'h10000);
wire ar_dec_sysreg = (ar_addr[31:8]  == 24'h400000);
wire ar_dec_dma    = (ar_addr[31:24] == 8'h44);
wire ar_dec_span   = (ar_addr[31:24] == 8'h48);
wire ar_dec_audio  = (ar_addr[31:24] == 8'h4C);
wire ar_dec_link   = (ar_addr[31:24] == 8'h4D);
wire ar_dec_cmap   = (ar_addr[31:14] == 18'h15000);
wire ar_dec_atm      = (ar_addr[31:13] == 19'h2C000);
wire ar_dec_sram     = (ar_addr[31:24] == 8'h38);
wire ar_dec_sramfill = (ar_addr[31:24] == 8'h5C);
wire ar_dec_scanline = (ar_addr[31:24] == 8'h60);

wire aw_dec_ram    = (aw_addr[31:16] == 16'b0);
wire aw_dec_term   = (aw_addr[31:13] == 19'h10000);
wire aw_dec_sysreg = (aw_addr[31:8]  == 24'h400000);
wire aw_dec_dma    = (aw_addr[31:24] == 8'h44);
wire aw_dec_span   = (aw_addr[31:24] == 8'h48);
wire aw_dec_audio  = (aw_addr[31:24] == 8'h4C);
wire aw_dec_link   = (aw_addr[31:24] == 8'h4D);
wire aw_dec_cmap   = (aw_addr[31:14] == 18'h15000);
wire aw_dec_atm      = (aw_addr[31:13] == 19'h2C000);
wire aw_dec_sram     = (aw_addr[31:24] == 8'h38);
wire aw_dec_sramfill = (aw_addr[31:24] == 8'h5C);
wire aw_dec_scanline = (aw_addr[31:24] == 8'h60);

// ============================================
// Main FSM
// ============================================
always @(posedge clk or posedge reset) begin
    if (reset) begin
        state <= S_IDLE;
        s_axi_arready <= 0;
        s_axi_rvalid <= 0;
        s_axi_rdata <= 0;
        s_axi_rresp <= 0;
        s_axi_rlast <= 0;
        s_axi_awready <= 0;
        s_axi_wready <= 0;
        s_axi_bvalid <= 0;
        s_axi_bresp <= 0;

        req_addr <= 0;
        req_wdata <= 0;
        req_wstrb <= 0;
        is_write <= 0;
        burst_len <= 0;
        burst_count <= 0;

        reg_ram <= 0;
        reg_term <= 0;
        reg_sysreg <= 0;
        reg_dma <= 0;
        reg_span <= 0;
        reg_audio <= 0;
        reg_link <= 0;
        reg_cmap <= 0;
        reg_atm <= 0;
        reg_sram <= 0;
        reg_sramfill <= 0;
        reg_scanline <= 0;
        sram_accepted <= 0;

        cpu_sram_rd <= 0;
        cpu_sram_wr <= 0;
        cpu_sram_addr <= 0;
        cpu_sram_wdata <= 0;
        cpu_sram_wstrb <= 0;
        sramfill_reg_wr <= 0;
        sramfill_reg_addr <= 0;
        sramfill_reg_wdata <= 0;
        scanline_reg_wr <= 0;
        scanline_reg_rd <= 0;
        scanline_reg_addr <= 0;
        scanline_reg_wdata <= 0;

        dbg_scanline_ar_hit <= 0;
        dbg_scanline_rd_hit <= 0;
        dbg_periph_rd_capture <= 0;

        sysreg_wr_fire <= 0;
        dma_reg_wr <= 0;
        dma_reg_addr <= 0;
        dma_reg_wdata <= 0;
        span_reg_wr <= 0;
        span_reg_addr <= 0;
        span_reg_wdata <= 0;
        atm_reg_wr <= 0;
        atm_reg_addr <= 0;
        atm_reg_wdata <= 0;
        atm_norm_wr <= 0;
        atm_norm_addr <= 0;
        atm_norm_wdata <= 0;
        audio_sample_wr <= 0;
        audio_sample_data <= 0;
        link_reg_wr <= 0;
        link_reg_rd <= 0;
        link_reg_addr <= 0;
        link_reg_wdata <= 0;
    end else begin
        // Defaults: deassert single-cycle pulses
        s_axi_arready <= 0;
        s_axi_rvalid <= 0;
        s_axi_awready <= 0;
        s_axi_wready <= 0;
        s_axi_bvalid <= 0;
        sysreg_wr_fire <= 0;
        dma_reg_wr <= 0;
        span_reg_wr <= 0;
        atm_reg_wr <= 0;
        atm_norm_wr <= 0;
        audio_sample_wr <= 0;
        link_reg_wr <= 0;
        link_reg_rd <= 0;
        sramfill_reg_wr <= 0;
        scanline_reg_wr <= 0;
        scanline_reg_rd <= 0;

        case (state)

        // ============================================
        // IDLE: Accept AR (read) or AW+W (write)
        // ============================================
        S_IDLE: begin
            if (s_axi_arvalid) begin
                // Accept read address
                s_axi_arready <= 1;
                is_write <= 0;
                req_addr <= ar_addr;
                burst_len <= s_axi_arlen;
                burst_count <= 0;

                // Latch region decode
                reg_ram      <= ar_dec_ram;
                reg_term     <= ar_dec_term;
                reg_sysreg   <= ar_dec_sysreg;
                reg_dma      <= ar_dec_dma;
                reg_span     <= ar_dec_span;
                reg_audio    <= ar_dec_audio;
                reg_link     <= ar_dec_link;
                reg_cmap     <= ar_dec_cmap;
                reg_atm      <= ar_dec_atm;
                reg_sram     <= ar_dec_sram;
                reg_sramfill <= ar_dec_sramfill;
                reg_scanline <= ar_dec_scanline;

                // Route to appropriate state
                if (ar_dec_ram)
                    state <= S_BRAM_RD;
                else if (ar_dec_term)
                    state <= S_TERM;
                else if (ar_dec_sram) begin
                    cpu_sram_rd <= 1;
                    cpu_sram_addr <= ar_addr[23:2];
                    sram_accepted <= 0;
                    state <= S_SRAM_WAIT;
                end else begin
                    state <= S_PERIPH_RD;
                    if (ar_dec_dma) dma_reg_addr <= ar_addr[6:2];
                    if (ar_dec_span) span_reg_addr <= ar_addr[7:2];
                    if (ar_dec_atm) atm_reg_addr <= ar_addr[6:2];
                    if (ar_dec_link) begin
                        link_reg_addr <= ar_addr[6:2];
                        link_reg_rd <= 1;
                    end
                    if (ar_dec_sramfill) sramfill_reg_addr <= ar_addr[6:2];
                    if (ar_dec_scanline) begin
                        scanline_reg_addr <= ar_addr[5:2];
                        if (ENABLE_DEBUG_CTRS) dbg_scanline_ar_hit <= dbg_scanline_ar_hit + 1;
                    end
                end

            end else if (s_axi_awvalid) begin
                // Accept write address
                s_axi_awready <= 1;
                is_write <= 1;
                req_addr <= aw_addr;
                burst_len <= s_axi_awlen;
                burst_count <= 0;

                // Latch region decode
                reg_ram      <= aw_dec_ram;
                reg_term     <= aw_dec_term;
                reg_sysreg   <= aw_dec_sysreg;
                reg_dma      <= aw_dec_dma;
                reg_span     <= aw_dec_span;
                reg_audio    <= aw_dec_audio;
                reg_link     <= aw_dec_link;
                reg_cmap     <= aw_dec_cmap;
                reg_atm      <= aw_dec_atm;
                reg_sram     <= aw_dec_sram;
                reg_sramfill <= aw_dec_sramfill;
                reg_scanline <= aw_dec_scanline;

                // Also accept W if valid on same cycle
                if (s_axi_wvalid) begin
                    s_axi_wready <= 1;
                    req_wdata <= s_axi_wdata;
                    req_wstrb <= s_axi_wstrb;

                    if (aw_dec_ram)
                        state <= S_BRAM_WR;
                    else if (aw_dec_term)
                        state <= S_TERM;
                    else if (aw_dec_sram) begin
                        cpu_sram_wr <= 1;
                        cpu_sram_addr <= aw_addr[23:2];
                        cpu_sram_wdata <= s_axi_wdata;
                        cpu_sram_wstrb <= s_axi_wstrb;
                        sram_accepted <= 0;
                        state <= S_SRAM_WAIT;
                    end else begin
                        // Peripheral write: fire write pulses immediately
                        state <= S_PERIPH_WR;
                        if (aw_dec_sysreg && |s_axi_wstrb)
                            sysreg_wr_fire <= 1;
                        if (aw_dec_dma) begin
                            dma_reg_addr <= aw_addr[6:2];
                            if (|s_axi_wstrb) begin
                                dma_reg_wr <= 1;
                                dma_reg_wdata <= s_axi_wdata;
                            end
                        end
                        if (aw_dec_span) begin
                            span_reg_addr <= aw_addr[7:2];
                            if (|s_axi_wstrb) begin
                                span_reg_wr <= 1;
                                span_reg_wdata <= s_axi_wdata;
                            end
                        end
                        if (aw_dec_audio && |s_axi_wstrb && aw_addr[3:2] == 2'b00) begin
                            audio_sample_wr <= 1;
                            audio_sample_data <= s_axi_wdata;
                        end
                        if (aw_dec_link && |s_axi_wstrb) begin
                            link_reg_wr <= 1;
                            link_reg_addr <= aw_addr[6:2];
                            link_reg_wdata <= s_axi_wdata;
                        end
                        if (aw_dec_atm) begin
                            if (aw_addr[12]) begin
                                if (|s_axi_wstrb) begin
                                    atm_norm_wr <= 1;
                                    atm_norm_addr <= {aw_addr[2], aw_addr[10:3]};
                                    atm_norm_wdata <= s_axi_wdata;
                                end
                            end else begin
                                atm_reg_addr <= aw_addr[6:2];
                                if (|s_axi_wstrb) begin
                                    atm_reg_wr <= 1;
                                    atm_reg_wdata <= s_axi_wdata;
                                end
                            end
                        end
                        if (aw_dec_sramfill) begin
                            sramfill_reg_addr <= aw_addr[6:2];
                            if (|s_axi_wstrb) begin
                                sramfill_reg_wr <= 1;
                                sramfill_reg_wdata <= s_axi_wdata;
                            end
                        end
                        if (aw_dec_scanline) begin
                            scanline_reg_addr <= aw_addr[5:2];
                            if (|s_axi_wstrb) begin
                                scanline_reg_wr <= 1;
                                scanline_reg_wdata <= s_axi_wdata;
                            end
                        end
                    end
                end else begin
                    // W not ready yet — wait for it
                    state <= S_WR_NEXT;
                end
            end
        end

        // ============================================
        // BRAM read: data available 1 cycle after address
        // ============================================
        S_BRAM_RD: begin
            s_axi_rvalid <= 1;
            s_axi_rdata <= ram_rdata;
            s_axi_rresp <= 2'b00;
            s_axi_rlast <= beat_is_last;
            burst_count <= burst_count + 1;
            if (beat_is_last) begin
                state <= S_IDLE;
            end else begin
                req_addr <= req_addr + 32'd4;
            end
        end

        // ============================================
        // BRAM write: execute write, advance burst
        // ============================================
        S_BRAM_WR: begin
            // ram_wren fires this cycle (combinatorial from state==S_BRAM_WR)
            burst_count <= burst_count + 1;
            if (beat_is_last) begin
                s_axi_bvalid <= 1;
                s_axi_bresp <= 2'b00;
                state <= S_IDLE;
            end else begin
                req_addr <= req_addr + 32'd4;
                state <= S_WR_NEXT;
            end
        end

        // ============================================
        // Peripheral read: data on mux
        // ============================================
        S_PERIPH_RD: begin
            if (reg_atm && atm_busy) begin
                // Stay, wait for ATM
            end else begin
                s_axi_rvalid <= 1;
                s_axi_rdata <= periph_rd_mux;
                s_axi_rresp <= 2'b00;
                s_axi_rlast <= beat_is_last;
                burst_count <= burst_count + 1;
                if (reg_scanline) begin
                    scanline_reg_rd <= 1;
                    scanline_reg_addr <= req_addr[5:2];
                    if (ENABLE_DEBUG_CTRS) begin
                        dbg_scanline_rd_hit <= dbg_scanline_rd_hit + 1;
                        dbg_periph_rd_capture <= {reg_ram, reg_term, reg_sysreg,
                            reg_dma, reg_span, reg_audio, reg_link, reg_cmap,
                            reg_atm, reg_sram, reg_sramfill, reg_scanline,
                            4'b0, periph_rd_mux[15:0]};
                    end
                end
                if (beat_is_last) begin
                    state <= S_IDLE;
                end else begin
                    req_addr <= req_addr + 32'd4;
                end
            end
        end

        // ============================================
        // Peripheral write: drive bvalid
        // ============================================
        S_PERIPH_WR: begin
            // Colormap write (cmap_wren) fires combinatorially this cycle
            burst_count <= burst_count + 1;
            if (beat_is_last) begin
                s_axi_bvalid <= 1;
                s_axi_bresp <= 2'b00;
                state <= S_IDLE;
            end else begin
                req_addr <= req_addr + 32'd4;
                state <= S_WR_NEXT;
            end
        end

        // ============================================
        // Terminal: wait for ready
        // ============================================
        S_TERM: begin
            if (term_mem_ready) begin
                if (is_write) begin
                    burst_count <= burst_count + 1;
                    if (beat_is_last) begin
                        s_axi_bvalid <= 1;
                        s_axi_bresp <= 2'b00;
                        state <= S_IDLE;
                    end else begin
                        req_addr <= req_addr + 32'd4;
                        state <= S_WR_NEXT;
                    end
                end else begin
                    s_axi_rvalid <= 1;
                    s_axi_rdata <= term_mem_rdata;
                    s_axi_rresp <= 2'b00;
                    s_axi_rlast <= beat_is_last;
                    burst_count <= burst_count + 1;
                    if (beat_is_last) begin
                        state <= S_IDLE;
                    end else begin
                        req_addr <= req_addr + 32'd4;
                    end
                end
            end
        end

        // ============================================
        // WR_NEXT: Accept next W beat
        // ============================================
        S_WR_NEXT: begin
            if (s_axi_wvalid) begin
                s_axi_wready <= 1;
                req_wdata <= s_axi_wdata;
                req_wstrb <= s_axi_wstrb;

                if (reg_ram) begin
                    state <= S_BRAM_WR;
                end else if (reg_term) begin
                    state <= S_TERM;
                end else if (reg_sram) begin
                    cpu_sram_wr <= 1;
                    cpu_sram_addr <= req_addr[23:2];
                    cpu_sram_wdata <= s_axi_wdata;
                    cpu_sram_wstrb <= s_axi_wstrb;
                    sram_accepted <= 0;
                    state <= S_SRAM_WAIT;
                end else begin
                    // Peripheral write beat
                    state <= S_PERIPH_WR;
                    if (reg_sysreg && |s_axi_wstrb)
                        sysreg_wr_fire <= 1;
                    if (reg_dma) begin
                        dma_reg_addr <= req_addr[6:2];
                        if (|s_axi_wstrb) begin
                            dma_reg_wr <= 1;
                            dma_reg_wdata <= s_axi_wdata;
                        end
                    end
                    if (reg_span) begin
                        span_reg_addr <= req_addr[7:2];
                        if (|s_axi_wstrb) begin
                            span_reg_wr <= 1;
                            span_reg_wdata <= s_axi_wdata;
                        end
                    end
                    if (reg_audio && |s_axi_wstrb && req_addr[3:2] == 2'b00) begin
                        audio_sample_wr <= 1;
                        audio_sample_data <= s_axi_wdata;
                    end
                    if (reg_link && |s_axi_wstrb) begin
                        link_reg_wr <= 1;
                        link_reg_addr <= req_addr[6:2];
                        link_reg_wdata <= s_axi_wdata;
                    end
                    if (reg_atm) begin
                        if (req_addr[12]) begin
                            if (|s_axi_wstrb) begin
                                atm_norm_wr <= 1;
                                atm_norm_addr <= {req_addr[2], req_addr[10:3]};
                                atm_norm_wdata <= s_axi_wdata;
                            end
                        end else begin
                            atm_reg_addr <= req_addr[6:2];
                            if (|s_axi_wstrb) begin
                                atm_reg_wr <= 1;
                                atm_reg_wdata <= s_axi_wdata;
                            end
                        end
                    end
                    if (reg_sramfill) begin
                        sramfill_reg_addr <= req_addr[6:2];
                        if (|s_axi_wstrb) begin
                            sramfill_reg_wr <= 1;
                            sramfill_reg_wdata <= s_axi_wdata;
                        end
                    end
                    if (reg_scanline) begin
                        scanline_reg_addr <= req_addr[5:2];
                        if (|s_axi_wstrb) begin
                            scanline_reg_wr <= 1;
                            scanline_reg_wdata <= s_axi_wdata;
                        end
                    end
                end
            end
        end

        // ============================================
        // SRAM_WAIT: Wait for SRAM controller to complete
        // ============================================
        S_SRAM_WAIT: begin
            if (!is_write) begin
                // Read: wait for acceptance, then q_valid
                if (!sram_accepted) begin
                    if (!cpu_sram_busy) begin
                        sram_accepted <= 1;
                        cpu_sram_rd <= 0;
                    end
                end else if (cpu_sram_q_valid) begin
                    s_axi_rvalid <= 1;
                    s_axi_rdata <= cpu_sram_q;
                    s_axi_rresp <= 2'b00;
                    s_axi_rlast <= 1;
                    state <= S_IDLE;
                end
            end else begin
                // Write: wait for acceptance, then !busy
                if (!sram_accepted) begin
                    if (!cpu_sram_busy) begin
                        sram_accepted <= 1;
                        cpu_sram_wr <= 0;
                    end
                end else if (!cpu_sram_busy) begin
                    s_axi_bvalid <= 1;
                    s_axi_bresp <= 2'b00;
                    state <= S_IDLE;
                end
            end
        end

        default: state <= S_IDLE;

        endcase
    end
end

endmodule
