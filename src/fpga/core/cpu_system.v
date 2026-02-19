//
// VexRiscv CPU System (Minimal)
// - VexRiscv RISC-V CPU with Wishbone interface
// - 64KB RAM for program/data (using block RAM)
// - Memory-mapped terminal at 0x20000000
// - SDRAM access at 0x10000000 (64MB) - includes framebuffer
// - PSRAM access at 0x30000000 (16MB) - cram0 only
// - SRAM access at 0x38000000 (256KB) - async SRAM
// - System registers at 0x40000000
//

`default_nettype none

module cpu_system (
    input wire clk,           // CPU clock (currently 66 MHz, same as SDRAM controller)
    input wire clk_74a,       // Bridge clock (74.25 MHz) - for APF interface
    input wire reset_n,
    input wire dataslot_allcomplete,  // All data slots loaded by APF
    input wire vsync,         // Vertical sync for buffer swap timing
    input wire [31:0] cont1_key,      // Controller 1 key bitmap (from APF pad controller)
    input wire [31:0] cont1_joy,      // Controller 1 analog sticks
    input wire [15:0] cont1_trig,     // Controller 1 analog triggers
    input wire [31:0] cont2_key,      // Controller 2 key bitmap (from APF pad controller)
    input wire [31:0] cont2_joy,      // Controller 2 analog sticks
    input wire [15:0] cont2_trig,     // Controller 2 analog triggers

    // Terminal memory interface
    output wire        term_mem_valid,
    output wire [31:0] term_mem_addr,
    output wire [31:0] term_mem_wdata,
    output wire [3:0]  term_mem_wstrb,
    input wire  [31:0] term_mem_rdata,
    input wire         term_mem_ready,

    // SDRAM word interface (directly to io_sdram via core_top)
    // CPU and SDRAM controller run at same clock (currently 66 MHz)
    output reg         sdram_rd,
    output reg         sdram_wr,
    output reg  [23:0] sdram_addr,
    output reg  [31:0] sdram_wdata,
    output reg  [3:0]  sdram_wstrb,  // Byte enables for SDRAM writes
    output reg  [2:0]  sdram_burst_len,  // Burst length: 0=single word, 7=8 words (cache line fill)
    input wire  [31:0] sdram_rdata,
    input wire         sdram_busy,
    input wire         sdram_accepted,     // Pulses when arbiter actually forwards CPU command
    input wire         sdram_rdata_valid,  // Pulses when read data is valid

    // PSRAM word interface (to psram_controller via core_top)
    output reg         psram_rd,
    output reg         psram_wr,
    output reg  [21:0] psram_addr,         // 22-bit word address (16MB addressable, CRAM0)
    output reg  [31:0] psram_wdata,
    output reg  [3:0]  psram_wstrb,        // Byte enables for PSRAM writes
    input wire  [31:0] psram_rdata,
    input wire         psram_busy,
    input wire         psram_rdata_valid,  // Pulses when read data is valid

    // SRAM word interface (to sram_controller via core_top)
    output reg         sram_rd,
    output reg         sram_wr,
    output reg  [21:0] sram_addr,          // 22-bit word address (256KB addressable)
    output reg  [31:0] sram_wdata,
    output reg  [3:0]  sram_wstrb,         // Byte enables for SRAM writes
    input wire  [31:0] sram_rdata,
    input wire         sram_busy,
    input wire         sram_q_valid,       // Pulses when read data is valid

    // Display control outputs
    output wire        display_mode,       // 0=terminal overlay, 1=framebuffer only
    output wire [24:0] fb_display_addr,    // SDRAM word address for video scanout

    // Palette write interface (directly to video_scanout_indexed)
    output reg         pal_wr,
    output reg  [7:0]  pal_addr,
    output reg  [23:0] pal_data,

    // Target dataslot interface (directly to core_bridge_cmd via core_top)
    output reg         target_dataslot_read,
    output reg         target_dataslot_write,
    output reg         target_dataslot_openfile,
    output reg  [15:0] target_dataslot_id,
    output reg  [31:0] target_dataslot_slotoffset,
    output reg  [31:0] target_dataslot_bridgeaddr,
    output reg  [31:0] target_dataslot_length,
    output reg  [31:0] target_buffer_param_struct,
    output reg  [31:0] target_buffer_resp_struct,
    input wire         target_dataslot_ack,
    input wire         target_dataslot_done,
    input wire  [2:0]  target_dataslot_err,

    // DMA peripheral register interface (directly to dma_clear_blit)
    output reg         dma_reg_wr,
    output reg  [4:0]  dma_reg_addr,
    output reg  [31:0] dma_reg_wdata,
    input wire  [31:0] dma_reg_rdata,

    // Span rasterizer register interface (directly to span_rasterizer)
    output reg         span_reg_wr,
    output reg  [4:0]  span_reg_addr,
    output reg  [31:0] span_reg_wdata,
    input wire  [31:0] span_reg_rdata,

    // Alias Transform MAC register interface (directly to alias_transform_mac)
    output reg         atm_reg_wr,
    output reg  [4:0]  atm_reg_addr,
    output reg  [31:0] atm_reg_wdata,
    input wire  [31:0] atm_reg_rdata,
    output reg         atm_norm_wr,
    output reg  [8:0]  atm_norm_addr,
    output reg  [31:0] atm_norm_wdata,
    input wire         atm_busy,

    // SRAM fill register interface (directly to sram_fill)
    output reg         sramfill_reg_wr,
    output reg  [4:0]  sramfill_reg_addr,
    output reg  [31:0] sramfill_reg_wdata,
    input wire  [31:0] sramfill_reg_rdata,

    // Audio output interface (directly to audio_output)
    output reg         audio_sample_wr,
    output reg  [31:0] audio_sample_data,
    input  wire [11:0] audio_fifo_level,
    input  wire        audio_fifo_full,

    // Link MMIO interface (to link_mmio)
    output reg         link_reg_wr,
    output reg         link_reg_rd,
    output reg  [4:0]  link_reg_addr,
    output reg  [31:0] link_reg_wdata,
    input  wire [31:0] link_reg_rdata,

    // Colormap BRAM port B (read-only, for span rasterizer)
    input wire  [11:0] span_cmap_addr,
    output wire [31:0] span_cmap_rdata
);

// ============================================
// VexRiscv Wishbone signals
// ============================================

// Instruction bus (Wishbone)
wire        ibus_cyc;
wire        ibus_stb;
reg         ibus_ack;
wire        ibus_we;
wire [29:0] ibus_adr;
reg  [31:0] ibus_dat_miso;
wire [31:0] ibus_dat_mosi;
wire [3:0]  ibus_sel;
wire [1:0]  ibus_bte;
wire [2:0]  ibus_cti;

// Data bus (Wishbone)
wire        dbus_cyc;
wire        dbus_stb;
reg         dbus_ack;
wire        dbus_we;
wire [29:0] dbus_adr;
reg  [31:0] dbus_dat_miso;
wire [31:0] dbus_dat_mosi;
wire [3:0]  dbus_sel;
wire [1:0]  dbus_bte;
wire [2:0]  dbus_cti;

// Active-high reset for VexRiscv
wire reset = ~reset_n;

// Instantiate VexRiscv CPU
VexRiscv cpu (
    .clk(clk),
    .reset(reset),

    // Reset vector - boot at 0x00000000
    .externalResetVector(32'h00000000),

    // Interrupts (tie off for now)
    .timerInterrupt(1'b0),
    .softwareInterrupt(1'b0),
    .externalInterrupt(1'b0),

    // Instruction Wishbone bus
    .iBusWishbone_CYC(ibus_cyc),
    .iBusWishbone_STB(ibus_stb),
    .iBusWishbone_ACK(ibus_ack),
    .iBusWishbone_WE(ibus_we),
    .iBusWishbone_ADR(ibus_adr),
    .iBusWishbone_DAT_MISO(ibus_dat_miso),
    .iBusWishbone_DAT_MOSI(ibus_dat_mosi),
    .iBusWishbone_SEL(ibus_sel),
    .iBusWishbone_ERR(1'b0),
    .iBusWishbone_BTE(ibus_bte),
    .iBusWishbone_CTI(ibus_cti),

    // Data Wishbone bus
    .dBusWishbone_CYC(dbus_cyc),
    .dBusWishbone_STB(dbus_stb),
    .dBusWishbone_ACK(dbus_ack),
    .dBusWishbone_WE(dbus_we),
    .dBusWishbone_ADR(dbus_adr),
    .dBusWishbone_DAT_MISO(dbus_dat_miso),
    .dBusWishbone_DAT_MOSI(dbus_dat_mosi),
    .dBusWishbone_SEL(dbus_sel),
    .dBusWishbone_ERR(1'b0),
    .dBusWishbone_BTE(dbus_bte),
    .dBusWishbone_CTI(dbus_cti)
);

// ============================================
// Arbitrated memory interface
// ============================================
// Round-robin arbiter: prevents I-bus starvation during sustained D-bus
// traffic (e.g. large memcpy causing continuous D-cache line fills).
// Convert Wishbone to simple valid/ready protocol

wire live_ibus_req = ibus_cyc & ibus_stb & ~ibus_ack;
wire live_dbus_req = dbus_cyc & dbus_stb & ~dbus_ack;

// Round-robin: track last grant, give priority to the other bus
reg last_grant_dbus;
wire live_dbus_grant = live_dbus_req & (~live_ibus_req | ~last_grant_dbus);
wire live_ibus_grant = live_ibus_req & ~live_dbus_grant;

// Muxed memory interface signals
wire        live_mem_valid = live_dbus_grant | live_ibus_grant;
wire [31:0] live_mem_addr  = live_dbus_grant ? {dbus_adr, 2'b00} : {ibus_adr, 2'b00};
wire [31:0] live_mem_wdata = dbus_dat_mosi;
wire [3:0]  live_mem_wstrb = live_dbus_grant ? (dbus_we ? dbus_sel : 4'b0) : 4'b0;
wire        live_mem_write = live_dbus_grant & dbus_we;

// Memory map:
// 0x00000000 - 0x0000FFFF : RAM (64KB)
// 0x10000000 - 0x13FFFFFF : SDRAM (64MB) - includes framebuffers
//   Framebuffer 0: 0x10000000 - 0x10025800 (153,600 bytes)
//   Framebuffer 1: 0x10100000 - 0x10125800 (153,600 bytes)
// 0x50000000 - 0x53FFFFFF : SDRAM uncached alias (64MB, same physical SDRAM window)
// 0x20000000 - 0x20001FFF : Terminal VRAM
// 0x30000000 - 0x30FFFFFF : PSRAM (16MB) - cram0 only
// 0x38000000 - 0x3803FFFF : SRAM (256KB) - async SRAM
// 0x40000000 - 0x400000FF : System registers
// 0x44000000 - 0x44FFFFFF : DMA Clear/Blit peripheral
// 0x48000000 - 0x48FFFFFF : Span Rasterizer
// 0x4D000000 - 0x4DFFFFFF : Link MMIO peripheral
// 0x54000000 - 0x54003FFF : Colormap BRAM (16KB)
// 0x58000000 - 0x58001FFF : Alias Transform MAC (registers + normal table)
// 0x5C000000 - 0x5C025FFF : Z-buffer BRAM (153,600 bytes)
// Pre-decode address regions from each bus independently.
// This runs address decode in PARALLEL with grant arbitration, removing
// the 32-bit address mux + comparator chain from the critical path.
// After the grant decision, only a 1-bit mux is needed per region.
wire [31:0] dbus_byte_addr = {dbus_adr, 2'b00};
wire [31:0] ibus_byte_addr = {ibus_adr, 2'b00};

// D-bus pre-decode
wire dbus_ram_select       = (dbus_byte_addr[31:16] == 16'b0);
wire dbus_sdram_select     = (dbus_byte_addr[31:26] == 6'b000100);
wire dbus_sdram_uc_select  = (dbus_byte_addr[31:26] == 6'b010100);
wire dbus_term_select      = (dbus_byte_addr[31:13] == 19'h10000);
wire dbus_psram_select     = (dbus_byte_addr[31:24] == 8'h30);  // 0x30 only (16MB, CRAM0)
wire dbus_sram_select      = (dbus_byte_addr[31:18] == 14'h0E00);
wire dbus_sysreg_select    = (dbus_byte_addr[31:8]  == 24'h400000);
wire dbus_dma_select       = (dbus_byte_addr[31:24] == 8'h44);
wire dbus_span_select      = (dbus_byte_addr[31:24] == 8'h48);
wire dbus_link_select      = (dbus_byte_addr[31:24] == 8'h4D);
wire dbus_cmap_select      = (dbus_byte_addr[31:14] == 18'h15000);
wire dbus_atm_select       = (dbus_byte_addr[31:13] == 19'h2C000);
wire dbus_audio_select     = (dbus_byte_addr[31:24] == 8'h4C);
wire dbus_sramfill_select  = (dbus_byte_addr[31:24] == 8'h5C);

// I-bus pre-decode
wire ibus_ram_select       = (ibus_byte_addr[31:16] == 16'b0);
wire ibus_sdram_select     = (ibus_byte_addr[31:26] == 6'b000100);
wire ibus_sdram_uc_select  = (ibus_byte_addr[31:26] == 6'b010100);
wire ibus_term_select      = (ibus_byte_addr[31:13] == 19'h10000);
wire ibus_psram_select     = (ibus_byte_addr[31:24] == 8'h30);  // 0x30 only (16MB, CRAM0)
wire ibus_sram_select      = (ibus_byte_addr[31:18] == 14'h0E00);
wire ibus_sysreg_select    = (ibus_byte_addr[31:8]  == 24'h400000);
wire ibus_dma_select       = (ibus_byte_addr[31:24] == 8'h44);
wire ibus_span_select      = (ibus_byte_addr[31:24] == 8'h48);
wire ibus_link_select      = (ibus_byte_addr[31:24] == 8'h4D);
wire ibus_cmap_select      = (ibus_byte_addr[31:14] == 18'h15000);
wire ibus_atm_select       = (ibus_byte_addr[31:13] == 19'h2C000);
wire ibus_audio_select     = (ibus_byte_addr[31:24] == 8'h4C);
wire ibus_sramfill_select  = (ibus_byte_addr[31:24] == 8'h5C);

// Mux decoded results based on grant (1-bit mux vs 32-bit address mux + decode)
wire live_ram_select       = live_dbus_grant ? dbus_ram_select       : ibus_ram_select;       // 0x00000000-0x0000FFFF (64KB)
wire live_sdram_select     = live_dbus_grant ? dbus_sdram_select     : ibus_sdram_select;     // 0x10000000-0x13FFFFFF (64MB)
wire live_sdram_uc_select  = live_dbus_grant ? dbus_sdram_uc_select  : ibus_sdram_uc_select;  // 0x50000000-0x53FFFFFF (64MB uncached alias)
wire live_term_select      = live_dbus_grant ? dbus_term_select      : ibus_term_select;      // 0x20000000-0x20001FFF
wire live_psram_select     = live_dbus_grant ? dbus_psram_select     : ibus_psram_select;     // 0x30000000-0x30FFFFFF (16MB)
wire live_sram_select      = live_dbus_grant ? dbus_sram_select      : ibus_sram_select;      // 0x38000000-0x3803FFFF (256KB)
wire live_sysreg_select    = live_dbus_grant ? dbus_sysreg_select    : ibus_sysreg_select;    // 0x40000000-0x400000FF
wire live_dma_select       = live_dbus_grant ? dbus_dma_select       : ibus_dma_select;       // 0x44000000-0x44FFFFFF
wire live_span_select      = live_dbus_grant ? dbus_span_select      : ibus_span_select;      // 0x48000000-0x48FFFFFF
wire live_link_select      = live_dbus_grant ? dbus_link_select      : ibus_link_select;      // 0x4D000000-0x4DFFFFFF
wire live_cmap_select      = live_dbus_grant ? dbus_cmap_select      : ibus_cmap_select;      // 0x54000000-0x54003FFF (colormap BRAM, 16KB)
wire live_atm_select       = live_dbus_grant ? dbus_atm_select       : ibus_atm_select;       // 0x58000000-0x58001FFF (ATM regs + norm table)
wire live_audio_select     = live_dbus_grant ? dbus_audio_select     : ibus_audio_select;     // 0x4C000000-0x4CFFFFFF (audio output)
wire live_sramfill_select  = live_dbus_grant ? dbus_sramfill_select  : ibus_sramfill_select;  // 0x5C000000-0x5CFFFFFF (SRAM fill)
wire accept_access         = !mem_pending && live_mem_valid;

// ============================================
// RAM using block RAM (64KB = 16384 x 32-bit words)
// ============================================
wire [31:0] ram_rdata;
wire [13:0] ram_addr_mux;
wire ram_wren;

altsyncram #(
    .operation_mode("SINGLE_PORT"),
    .width_a(32),
    .widthad_a(14),              // 14 bits = 16384 words = 64KB
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
    .data_a(mem_pending ? req_wdata : live_mem_wdata),
    .wren_a(ram_wren),
    .byteena_a(mem_pending ? req_wstrb : live_mem_wstrb),
    .q_a(ram_rdata),
    // Unused ports
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
// Quake colormap: 64 light levels * 256 palette entries = 16384 bytes
// CPU reads via lb instruction get ~2-cycle latency (vs ~12 for SDRAM)
// ============================================
reg [31:0] cmap_rdata;
wire [11:0] cmap_addr_mux = mem_pending ? req_addr[13:2] : live_mem_addr[13:2];
wire cmap_wren = accept_access && live_cmap_select && |live_mem_wstrb;
wire [3:0] cmap_byteena = mem_pending ? req_wstrb : live_mem_wstrb;
wire [31:0] cmap_wdata = mem_pending ? req_wdata : live_mem_wdata;

// Inferred dual-port RAM - Quartus maps to M10K blocks automatically
// Port A: CPU read/write with byte enables
// Port B: Span rasterizer read-only
(* ramstyle = "M10K" *) reg [7:0] cmap_mem0 [0:4095];
(* ramstyle = "M10K" *) reg [7:0] cmap_mem1 [0:4095];
(* ramstyle = "M10K" *) reg [7:0] cmap_mem2 [0:4095];
(* ramstyle = "M10K" *) reg [7:0] cmap_mem3 [0:4095];

reg [31:0] span_cmap_rdata_r;
assign span_cmap_rdata = span_cmap_rdata_r;

// Port A - CPU read/write
always @(posedge clk) begin
    if (cmap_wren && cmap_byteena[0]) cmap_mem0[cmap_addr_mux] <= cmap_wdata[7:0];
    if (cmap_wren && cmap_byteena[1]) cmap_mem1[cmap_addr_mux] <= cmap_wdata[15:8];
    if (cmap_wren && cmap_byteena[2]) cmap_mem2[cmap_addr_mux] <= cmap_wdata[23:16];
    if (cmap_wren && cmap_byteena[3]) cmap_mem3[cmap_addr_mux] <= cmap_wdata[31:24];
    cmap_rdata <= {cmap_mem3[cmap_addr_mux], cmap_mem2[cmap_addr_mux],
                   cmap_mem1[cmap_addr_mux], cmap_mem0[cmap_addr_mux]};
end

// Port B - Span rasterizer read-only
always @(posedge clk) begin
    span_cmap_rdata_r <= {cmap_mem3[span_cmap_addr], cmap_mem2[span_cmap_addr],
                          cmap_mem1[span_cmap_addr], cmap_mem0[span_cmap_addr]};
end

// ============================================
// Forward terminal requests to terminal module
assign term_mem_valid = mem_pending ? term_pending : (live_mem_valid && live_term_select);
assign term_mem_addr = mem_pending ? req_addr : live_mem_addr;
assign term_mem_wdata = mem_pending ? req_wdata : live_mem_wdata;
assign term_mem_wstrb = mem_pending ? req_wstrb : live_mem_wstrb;

// ============================================
// System registers
// ============================================
// 0x00: SYS_STATUS       - Bit 0: always 1 (SDRAM ready), Bit 1: dataslot_allcomplete
// 0x04: SYS_CYCLE_LO     - Cycle counter low
// 0x08: SYS_CYCLE_HI     - Cycle counter high
// 0x0C: SYS_DISPLAY_MODE - 0=terminal overlay, 1=framebuffer only
// 0x10: SYS_FB_DISPLAY   - Display framebuffer SDRAM address (read-only)
// 0x14: SYS_FB_DRAW      - Draw framebuffer SDRAM address (read-only)
// 0x18: SYS_FB_SWAP      - Write 1 to swap buffers (on next vsync)
// 0x40: SYS_PAL_INDEX    - Palette write index (0-255)
// 0x44: SYS_PAL_DATA     - Write RGB888, triggers palette write, auto-increments index
// 0x50: SYS_CONT1_KEY    - Controller 1 key bitmap (read-only)
// 0x54: SYS_CONT1_JOY    - Controller 1 joystick axes (read-only)
// 0x58: SYS_CONT1_TRIG   - Controller 1 triggers in bits [15:0] (read-only)
// 0x5C: SYS_CONT2_KEY    - Controller 2 key bitmap (read-only)
// 0x60: SYS_CONT2_JOY    - Controller 2 joystick axes (read-only)
// 0x64: SYS_CONT2_TRIG   - Controller 2 triggers in bits [15:0] (read-only)
//
// Target dataslot registers (0x20-0x3C):
// 0x20: DS_SLOT_ID       - Data slot ID (16-bit)
// 0x24: DS_SLOT_OFFSET   - Slot offset for read/write
// 0x28: DS_BRIDGE_ADDR   - Bridge address (destination for read, source for write)
// 0x2C: DS_LENGTH        - Transfer length in bytes
// 0x30: DS_PARAM_ADDR    - Address of parameter struct (for openfile)
// 0x34: DS_RESP_ADDR     - Address of response struct
// 0x38: DS_COMMAND       - Write to trigger: 1=read, 2=write, 3=openfile
// 0x3C: DS_STATUS        - Status: bit0=ack, bit1=done, bits[4:2]=err

reg [31:0] sysreg_rdata;
reg [63:0] cycle_counter;
reg display_mode_reg;  // 0=terminal overlay, 1=framebuffer only

// Target dataslot registers
reg [15:0] ds_slot_id_reg;
reg [31:0] ds_slot_offset_reg;
reg [31:0] ds_bridge_addr_reg;
reg [31:0] ds_length_reg;
reg [31:0] ds_param_addr_reg;
reg [31:0] ds_resp_addr_reg;

// Palette write index register
reg [7:0] pal_index_reg;

// Double buffer addresses (22-bit PSRAM 16-bit word addresses)
// Buffer 0: PSRAM byte 0x000000 = word addr 0x000000 (base of PSRAM)
// Buffer 1: PSRAM byte 0x100000 = word addr 0x080000 (1MB into PSRAM)
// CPU writes to 0x30000000 (PSRAM), video reads from PSRAM via CRAM1
localparam FB_ADDR_0 = 25'h0000000;  // Framebuffer 0 at PSRAM base
localparam FB_ADDR_1 = 25'h0080000;  // Framebuffer 1 at 1MB offset
reg [24:0] fb_display_addr_reg;      // Currently displayed buffer
reg [24:0] fb_draw_addr_reg;         // Buffer being drawn to
reg fb_swap_pending;                  // Swap requested, waiting for vsync

assign display_mode = display_mode_reg;
assign fb_display_addr = fb_display_addr_reg;

// Synchronize dataslot_allcomplete from bridge clock domain (clk_74a) to CPU clock domain
reg [2:0] dataslot_allcomplete_sync;
always @(posedge clk) begin
    dataslot_allcomplete_sync <= {dataslot_allcomplete_sync[1:0], dataslot_allcomplete};
end
wire dataslot_allcomplete_s = dataslot_allcomplete_sync[2];

// Synchronize vsync to CPU clock domain
reg [2:0] vsync_sync;
always @(posedge clk) begin
    vsync_sync <= {vsync_sync[1:0], vsync};
end
wire vsync_rising = vsync_sync[1] && !vsync_sync[2];

// Synchronize target_dataslot_ack and target_dataslot_done from bridge clock domain
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

// Synchronize controller state from APF clock domain into CPU clock domain.
wire [31:0] cont1_key_s;
wire [31:0] cont1_joy_s;
wire [15:0] cont1_trig_s;
wire [31:0] cont2_key_s;
wire [31:0] cont2_joy_s;
wire [15:0] cont2_trig_s;
synch_3 #(.WIDTH(32)) s_cont1_key(
    .i(cont1_key),
    .o(cont1_key_s),
    .clk(clk),
    .rise(),
    .fall()
);
synch_3 #(.WIDTH(32)) s_cont2_key(
    .i(cont2_key),
    .o(cont2_key_s),
    .clk(clk),
    .rise(),
    .fall()
);
synch_3 #(.WIDTH(32)) s_cont2_joy(
    .i(cont2_joy),
    .o(cont2_joy_s),
    .clk(clk),
    .rise(),
    .fall()
);
synch_3 #(.WIDTH(16)) s_cont2_trig(
    .i(cont2_trig),
    .o(cont2_trig_s),
    .clk(clk),
    .rise(),
    .fall()
);
synch_3 #(.WIDTH(32)) s_cont1_joy(
    .i(cont1_joy),
    .o(cont1_joy_s),
    .clk(clk),
    .rise(),
    .fall()
);
synch_3 #(.WIDTH(16)) s_cont1_trig(
    .i(cont1_trig),
    .o(cont1_trig_s),
    .clk(clk),
    .rise(),
    .fall()
);

always @(posedge clk) begin
    if (reset) begin
        cycle_counter <= 0;
        display_mode_reg <= 0;  // Start in terminal overlay mode
        fb_display_addr_reg <= FB_ADDR_0;
        fb_draw_addr_reg <= FB_ADDR_1;
        fb_swap_pending <= 0;
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

        // Keep command request asserted until bridge ACK is observed.
        // A 1-cycle pulse can be missed crossing to clk_74a; level-hold avoids that.
        if (target_ack_s) begin
            target_dataslot_read <= 0;
            target_dataslot_write <= 0;
            target_dataslot_openfile <= 0;
        end

        // Perform buffer swap on vsync if pending
        if (fb_swap_pending && vsync_rising) begin
            // Swap display and draw addresses
            fb_display_addr_reg <= fb_draw_addr_reg;
            fb_draw_addr_reg <= fb_display_addr_reg;
            fb_swap_pending <= 0;
        end

        // Write to display mode register (0x4000000C)
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b000011) begin
            display_mode_reg <= live_mem_wdata[0];
        end

        // Write to swap register (0x40000018) - request buffer swap
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b000110) begin
            if (live_mem_wdata[0])
                fb_swap_pending <= 1;
        end

        // Target dataslot register writes
        // 0x20: DS_SLOT_ID
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b001000) begin
            ds_slot_id_reg <= live_mem_wdata[15:0];
        end
        // 0x24: DS_SLOT_OFFSET
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b001001) begin
            ds_slot_offset_reg <= live_mem_wdata;
        end
        // 0x28: DS_BRIDGE_ADDR
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b001010) begin
            ds_bridge_addr_reg <= live_mem_wdata;
        end
        // 0x2C: DS_LENGTH
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b001011) begin
            ds_length_reg <= live_mem_wdata;
        end
        // 0x30: DS_PARAM_ADDR
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b001100) begin
            ds_param_addr_reg <= live_mem_wdata;
        end
        // 0x34: DS_RESP_ADDR
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b001101) begin
            ds_resp_addr_reg <= live_mem_wdata;
        end
        // 0x40: PAL_INDEX
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b010000) begin
            pal_index_reg <= live_mem_wdata[7:0];
        end
        // 0x44: PAL_DATA - write palette entry and auto-increment
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b010001) begin
            pal_wr <= 1;
            pal_addr <= pal_index_reg;
            pal_data <= live_mem_wdata[23:0];
            pal_index_reg <= pal_index_reg + 1;
        end

        // 0x38: DS_COMMAND - triggers the operation
        if (accept_access && live_sysreg_select && |live_mem_wstrb && live_mem_addr[7:2] == 6'b001110) begin
            // Only accept a new command when no command is currently in flight.
            if (!(target_dataslot_read || target_dataslot_write || target_dataslot_openfile || target_ack_s)) begin
                // Set up the target dataslot interface
                target_dataslot_id <= ds_slot_id_reg;
                target_dataslot_slotoffset <= ds_slot_offset_reg;
                target_dataslot_bridgeaddr <= ds_bridge_addr_reg;
                target_dataslot_length <= ds_length_reg;
                target_buffer_param_struct <= ds_param_addr_reg;
                target_buffer_resp_struct <= ds_resp_addr_reg;

                // Drive only one command line high.
                target_dataslot_read <= 0;
                target_dataslot_write <= 0;
                target_dataslot_openfile <= 0;
                case (live_mem_wdata[1:0])
                    2'b01: target_dataslot_read <= 1;      // Read from slot
                    2'b10: target_dataslot_write <= 1;     // Write to slot
                    2'b11: target_dataslot_openfile <= 1;  // Open file into slot
                endcase
            end
        end
    end
end

wire [5:0] sysreg_addr = mem_pending ? req_addr[7:2] : live_mem_addr[7:2];

always @(*) begin
    case (sysreg_addr)
        6'b000000: sysreg_rdata = {30'b0, dataslot_allcomplete_s, 1'b1};  // SYS_STATUS
        6'b000001: sysreg_rdata = cycle_counter[31:0];   // SYS_CYCLE_LO
        6'b000010: sysreg_rdata = cycle_counter[63:32];  // SYS_CYCLE_HI
        6'b000011: sysreg_rdata = {31'b0, display_mode_reg};  // SYS_DISPLAY_MODE
        6'b000100: sysreg_rdata = {7'b0, fb_display_addr_reg};  // SYS_FB_DISPLAY
        6'b000101: sysreg_rdata = {7'b0, fb_draw_addr_reg};     // SYS_FB_DRAW
        6'b000110: sysreg_rdata = {31'b0, fb_swap_pending};     // SYS_FB_SWAP
        // Target dataslot registers
        6'b001000: sysreg_rdata = {16'b0, ds_slot_id_reg};      // DS_SLOT_ID
        6'b001001: sysreg_rdata = ds_slot_offset_reg;           // DS_SLOT_OFFSET
        6'b001010: sysreg_rdata = ds_bridge_addr_reg;           // DS_BRIDGE_ADDR
        6'b001011: sysreg_rdata = ds_length_reg;                // DS_LENGTH
        6'b001100: sysreg_rdata = ds_param_addr_reg;            // DS_PARAM_ADDR
        6'b001101: sysreg_rdata = ds_resp_addr_reg;             // DS_RESP_ADDR
        6'b001110: sysreg_rdata = 32'h0;                        // DS_COMMAND (write-only)
        6'b001111: sysreg_rdata = {27'b0, target_err_s, target_done_s, target_ack_s};  // DS_STATUS
        6'b010000: sysreg_rdata = {24'b0, pal_index_reg};   // PAL_INDEX
        6'b010001: sysreg_rdata = 32'h0;                     // PAL_DATA (write-only)
        6'b010100: sysreg_rdata = cont1_key_s;               // SYS_CONT1_KEY
        6'b010101: sysreg_rdata = cont1_joy_s;               // SYS_CONT1_JOY
        6'b010110: sysreg_rdata = {16'b0, cont1_trig_s};     // SYS_CONT1_TRIG
        6'b010111: sysreg_rdata = cont2_key_s;               // SYS_CONT2_KEY
        6'b011000: sysreg_rdata = cont2_joy_s;               // SYS_CONT2_JOY
        6'b011001: sysreg_rdata = {16'b0, cont2_trig_s};     // SYS_CONT2_TRIG
        default: sysreg_rdata = 32'h0;
    endcase
end

// ============================================
// Memory access state machine
// ============================================
// Handle RAM, SDRAM, terminal, and sysreg accesses
// Generate Wishbone ACK when complete

reg mem_pending;
reg [1:0] pending_bus;  // 0=none, 1=ibus, 2=dbus
reg [31:0] req_addr;
reg [31:0] req_wdata;
reg [3:0] req_wstrb;
reg ram_pending;
reg term_pending;
reg sdram_read_pending;
reg sdram_write_pending;
reg sdram_read_started;
reg sdram_write_started;
reg sdram_cmd_issued;
reg psram_read_pending;
reg psram_write_pending;
reg psram_read_started;
reg psram_write_started;
reg psram_cmd_issued;
reg sram_read_pending;
reg sram_write_pending;
reg sram_read_started;
reg sram_write_started;
reg sram_cmd_issued;
reg [7:0] sram_issue_wait;
reg [7:0] sdram_issue_wait;
reg [7:0] psram_issue_wait;
reg sysreg_pending;
reg dma_pending;
reg span_pending;
reg cmap_pending;
reg atm_pending;
reg atm_is_write;
reg audio_pending;
reg link_pending;
reg sramfill_pending;
reg [31:0] pending_rdata;
reg sdram_read_is_prefetch;
reg sdram_prefetch_primary_done;
reg [20:0] sdram_prefetch_line_tag;
reg [2:0] sdram_prefetch_req_idx;
reg [2:0] sdram_prefetch_fill_idx;
reg [3:0] sdram_prefetch_fill_count;
reg sdram_prefetch_valid;
reg [31:0] sdram_prefetch_data [0:7];
reg [31:0] prefetch_hit_rdata;

localparam BUS_NONE = 2'd0;
localparam BUS_IBUS = 2'd1;
localparam BUS_DBUS = 2'd2;
localparam [2:0] SDRAM_PREFETCH_BURST_LEN = 3'd7;  // 8-word cache line fill

assign ram_addr_mux = mem_pending ? req_addr[15:2] : live_mem_addr[15:2];
assign ram_wren = accept_access && live_ram_select && |live_mem_wstrb;

wire [2:0] live_sdram_word_idx = live_mem_addr[4:2];
wire live_prefetch_line_hit = sdram_prefetch_valid &&
                              live_sdram_select &&
                              (live_mem_addr[25:5] == sdram_prefetch_line_tag);
wire live_prefetch_word_available =
    live_prefetch_line_hit && (sdram_prefetch_fill_count > {1'b0, live_sdram_word_idx});
wire live_ibus_prefetch_hit = live_ibus_grant && !live_mem_write && live_prefetch_word_available;

always @(*) begin
    case (live_sdram_word_idx)
        3'd0: prefetch_hit_rdata = sdram_prefetch_data[0];
        3'd1: prefetch_hit_rdata = sdram_prefetch_data[1];
        3'd2: prefetch_hit_rdata = sdram_prefetch_data[2];
        3'd3: prefetch_hit_rdata = sdram_prefetch_data[3];
        3'd4: prefetch_hit_rdata = sdram_prefetch_data[4];
        3'd5: prefetch_hit_rdata = sdram_prefetch_data[5];
        3'd6: prefetch_hit_rdata = sdram_prefetch_data[6];
        3'd7: prefetch_hit_rdata = sdram_prefetch_data[7];
    endcase
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        ibus_ack <= 0;
        dbus_ack <= 0;
        ibus_dat_miso <= 0;
        dbus_dat_miso <= 0;
        mem_pending <= 0;
        pending_bus <= BUS_NONE;
        last_grant_dbus <= 0;
        req_addr <= 0;
        req_wdata <= 0;
        req_wstrb <= 0;
        ram_pending <= 0;
        term_pending <= 0;
        sdram_read_pending <= 0;
        sdram_write_pending <= 0;
        sdram_read_started <= 0;
        sdram_write_started <= 0;
        sdram_cmd_issued <= 0;
        sdram_read_is_prefetch <= 0;
        sdram_prefetch_primary_done <= 0;
        sdram_prefetch_line_tag <= 0;
        sdram_prefetch_req_idx <= 0;
        sdram_prefetch_fill_idx <= 0;
        sdram_prefetch_fill_count <= 0;
        sdram_prefetch_valid <= 0;
        psram_read_pending <= 0;
        psram_write_pending <= 0;
        psram_read_started <= 0;
        psram_write_started <= 0;
        psram_cmd_issued <= 0;
        sram_read_pending <= 0;
        sram_write_pending <= 0;
        sram_read_started <= 0;
        sram_write_started <= 0;
        sram_cmd_issued <= 0;
        sram_issue_wait <= 0;
        sdram_issue_wait <= 0;
        sdram_burst_len <= 0;
        psram_issue_wait <= 0;
        sysreg_pending <= 0;
        dma_pending <= 0;
        dma_reg_wr <= 0;
        dma_reg_addr <= 0;
        dma_reg_wdata <= 0;
        span_pending <= 0;
        cmap_pending <= 0;
        atm_pending <= 0;
        atm_is_write <= 0;
        audio_pending <= 0;
        link_pending <= 0;
        sramfill_pending <= 0;
        sramfill_reg_wr <= 0;
        sramfill_reg_addr <= 0;
        sramfill_reg_wdata <= 0;
        link_reg_wr <= 0;
        link_reg_rd <= 0;
        link_reg_addr <= 0;
        link_reg_wdata <= 0;
        audio_sample_wr <= 0;
        audio_sample_data <= 0;
        span_reg_wr <= 0;
        span_reg_addr <= 0;
        span_reg_wdata <= 0;
        atm_reg_wr <= 0;
        atm_reg_addr <= 0;
        atm_reg_wdata <= 0;
        atm_norm_wr <= 0;
        atm_norm_addr <= 0;
        atm_norm_wdata <= 0;
        sdram_rd <= 0;
        sdram_wr <= 0;
        sdram_addr <= 0;
        sdram_wdata <= 0;
        psram_rd <= 0;
        psram_wr <= 0;
        psram_addr <= 0;
        psram_wdata <= 0;
        psram_wstrb <= 0;
        sram_rd <= 0;
        sram_wr <= 0;
        sram_addr <= 0;
        sram_wdata <= 0;
        sram_wstrb <= 0;
        pending_rdata <= 0;
    end else begin
        // Default: deassert ACKs and single-cycle signals
        ibus_ack <= 0;
        dbus_ack <= 0;
        sdram_rd <= 0;
        sdram_wr <= 0;
        sdram_burst_len <= 3'd0;
        psram_rd <= 0;
        psram_wr <= 0;
        sram_rd <= 0;
        sram_wr <= 0;
        dma_reg_wr <= 0;
        span_reg_wr <= 0;
        sramfill_reg_wr <= 0;
        atm_reg_wr <= 0;
        atm_norm_wr <= 0;
        audio_sample_wr <= 0;
        link_reg_wr <= 0;
        link_reg_rd <= 0;

        if (!mem_pending && live_mem_valid) begin
            if (live_ibus_prefetch_hit) begin
                // Cache hit in completed SDRAM prefetch line.
                ibus_ack <= 1;
                ibus_dat_miso <= prefetch_hit_rdata;
            end else begin
                // Start new memory access
                pending_bus <= live_dbus_grant ? BUS_DBUS : BUS_IBUS;
                last_grant_dbus <= live_dbus_grant;
                req_addr <= live_mem_addr;
                req_wdata <= live_mem_wdata;
                req_wstrb <= live_mem_wstrb;
                if (live_ram_select) begin
                    mem_pending <= 1;
                    ram_pending <= 1;
                end else if (live_sdram_select || live_sdram_uc_select) begin
                    sdram_wdata <= live_mem_wdata;
                    sdram_wstrb <= live_mem_wstrb;  // Pass byte enables to SDRAM
                    if (live_mem_write) begin
                        sdram_addr <= live_mem_addr[25:2];
                        mem_pending <= 1;
                        sdram_write_pending <= 1;
                        sdram_read_started <= 0;
                        sdram_write_started <= 0;
                        sdram_cmd_issued <= 0;
                        sdram_issue_wait <= 0;
                        sdram_read_is_prefetch <= 0;
                        // Any SDRAM write can invalidate the prefetched instruction line.
                        sdram_prefetch_valid <= 0;
                        sdram_prefetch_fill_count <= 0;
                    end else begin
                        mem_pending <= 1;
                        sdram_read_pending <= 1;
                        sdram_read_started <= 0;
                        sdram_write_started <= 0;
                        sdram_cmd_issued <= 0;
                        sdram_issue_wait <= 0;

                        // Only prefetch cached instruction reads (0x1000....).
                        if (live_sdram_select && live_ibus_grant) begin
                            sdram_addr <= {live_mem_addr[25:5], 3'b000};  // 8-word line aligned
                            sdram_burst_len <= SDRAM_PREFETCH_BURST_LEN;
                            sdram_read_is_prefetch <= 1;
                            sdram_prefetch_primary_done <= 0;
                            sdram_prefetch_line_tag <= live_mem_addr[25:5];
                            sdram_prefetch_req_idx <= live_mem_addr[4:2];
                            sdram_prefetch_fill_idx <= 0;
                            sdram_prefetch_fill_count <= 0;
                            sdram_prefetch_valid <= 1;
                        end else begin
                            sdram_addr <= live_mem_addr[25:2];
                            sdram_read_is_prefetch <= 0;
                        end
                    end
                end else if (live_psram_select) begin
                    psram_addr <= live_mem_addr[23:2];  // 22-bit word address (16MB, CRAM0)
                    psram_wdata <= live_mem_wdata;
                    psram_wstrb <= live_mem_wstrb;  // Pass byte enables to PSRAM
                    if (live_mem_write) begin
                        mem_pending <= 1;
                        psram_write_pending <= 1;
                        psram_read_started <= 0;
                        psram_write_started <= 0;
                        psram_cmd_issued <= 0;
                        psram_issue_wait <= 0;
                    end else begin
                        mem_pending <= 1;
                        psram_read_pending <= 1;
                        psram_read_started <= 0;
                        psram_write_started <= 0;
                        psram_cmd_issued <= 0;
                        psram_issue_wait <= 0;
                    end
                end else if (live_sram_select) begin
                    sram_addr <= live_mem_addr[23:2];  // 22-bit word address (256KB)
                    sram_wdata <= live_mem_wdata;
                    sram_wstrb <= live_mem_wstrb;
                    if (live_mem_write) begin
                        mem_pending <= 1;
                        sram_write_pending <= 1;
                        sram_read_started <= 0;
                        sram_write_started <= 0;
                        sram_cmd_issued <= 0;
                        sram_issue_wait <= 0;
                    end else begin
                        mem_pending <= 1;
                        sram_read_pending <= 1;
                        sram_read_started <= 0;
                        sram_write_started <= 0;
                        sram_cmd_issued <= 0;
                        sram_issue_wait <= 0;
                    end
                end else if (live_term_select) begin
                    mem_pending <= 1;
                    term_pending <= 1;
                end else if (live_sysreg_select) begin
                    mem_pending <= 1;
                    sysreg_pending <= 1;
                end else if (live_dma_select) begin
                    mem_pending <= 1;
                    dma_pending <= 1;
                    // Always set address (for both reads and writes)
                    dma_reg_addr <= live_mem_addr[6:2];
                    // Issue DMA register write immediately on accept
                    if (|live_mem_wstrb) begin
                        dma_reg_wr <= 1;
                        dma_reg_wdata <= live_mem_wdata;
                    end
                end else if (live_span_select) begin
                    mem_pending <= 1;
                    span_pending <= 1;
                    span_reg_addr <= live_mem_addr[6:2];
                    if (|live_mem_wstrb) begin
                        span_reg_wr <= 1;
                        span_reg_wdata <= live_mem_wdata;
                    end
                end else if (live_cmap_select) begin
                    // Colormap BRAM: address presented via cmap_addr_mux,
                    // write via cmap_wren. Data ready next cycle.
                    mem_pending <= 1;
                    cmap_pending <= 1;
                end else if (live_atm_select) begin
                    mem_pending <= 1;
                    atm_pending <= 1;
                    atm_is_write <= |live_mem_wstrb;
                    if (live_mem_addr[12]) begin
                        // Normal table write (0x58001000+)
                        if (|live_mem_wstrb) begin
                            atm_norm_wr <= 1;
                            atm_norm_addr <= {live_mem_addr[2], live_mem_addr[10:3]};
                            atm_norm_wdata <= live_mem_wdata;
                        end
                    end else begin
                        // Control registers (0x58000000-0x5800007F)
                        atm_reg_addr <= live_mem_addr[6:2];
                        if (|live_mem_wstrb) begin
                            atm_reg_wr <= 1;
                            atm_reg_wdata <= live_mem_wdata;
                        end
                    end
                end else if (live_sramfill_select) begin
                    mem_pending <= 1;
                    sramfill_pending <= 1;
                    sramfill_reg_addr <= live_mem_addr[6:2];
                    if (|live_mem_wstrb) begin
                        sramfill_reg_wr <= 1;
                        sramfill_reg_wdata <= live_mem_wdata;
                    end
                end else if (live_audio_select) begin
                    mem_pending <= 1;
                    audio_pending <= 1;
                    // Write to 0x4C000000: push sample to FIFO
                    if (|live_mem_wstrb && live_mem_addr[3:2] == 2'b00) begin
                        audio_sample_wr <= 1;
                        audio_sample_data <= live_mem_wdata;
                    end
                end else if (live_link_select) begin
                    mem_pending <= 1;
                    link_pending <= 1;
                    link_reg_addr <= live_mem_addr[6:2];
                    if (|live_mem_wstrb) begin
                        link_reg_wr <= 1;
                        link_reg_wdata <= live_mem_wdata;
                    end else begin
                        // Pulse read so RX_DATA can pop on demand.
                        link_reg_rd <= 1;
                    end
                end else begin
                    // Unknown region - return 0 immediately
                    if (live_dbus_grant) begin
                        dbus_ack <= 1;
                        dbus_dat_miso <= 32'h0;
                    end else begin
                        ibus_ack <= 1;
                        ibus_dat_miso <= 32'h0;
                    end
                end
            end
        end else if (mem_pending) begin
            // Complete pending access
            if (ram_pending) begin
                pending_rdata <= ram_rdata;
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= ram_rdata;
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= ram_rdata;
                end
                mem_pending <= 0;
                ram_pending <= 0;
                pending_bus <= BUS_NONE;
            end else if (sdram_read_pending) begin
                // While draining an instruction prefetch burst, allow hits on already
                // captured words so instruction fetch can advance within the same line.
                if (sdram_read_is_prefetch && sdram_prefetch_primary_done && live_ibus_prefetch_hit) begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= prefetch_hit_rdata;
                end

                // Issue read when controller is idle.
                // Use sdram_accepted (from arbiter) to confirm command was forwarded,
                // not sdram_busy which can rise from unrelated bridge/peripheral activity.
                if (!sdram_cmd_issued) begin
                    if (!sdram_busy) begin
                        sdram_rd <= 1;
                        sdram_cmd_issued <= 1;
                        sdram_read_started <= 0;
                        sdram_issue_wait <= 0;
                    end
                end else begin
                    if (!sdram_read_started) begin
                        if (sdram_accepted) begin
                            sdram_read_started <= 1;
                            sdram_issue_wait <= 0;
                        end else begin
                            sdram_issue_wait <= sdram_issue_wait + 1'b1;
                            if (&sdram_issue_wait) begin
                                // Command likely not accepted; retry.
                                sdram_cmd_issued <= 0;
                                sdram_issue_wait <= 0;
                            end
                        end
                    end
                    if (sdram_rdata_valid) begin
                        if (sdram_read_is_prefetch) begin
                            // Capture each word from the 8-word burst into the line buffer.
                            case (sdram_prefetch_fill_idx)
                                3'd0: sdram_prefetch_data[0] <= sdram_rdata;
                                3'd1: sdram_prefetch_data[1] <= sdram_rdata;
                                3'd2: sdram_prefetch_data[2] <= sdram_rdata;
                                3'd3: sdram_prefetch_data[3] <= sdram_rdata;
                                3'd4: sdram_prefetch_data[4] <= sdram_rdata;
                                3'd5: sdram_prefetch_data[5] <= sdram_rdata;
                                3'd6: sdram_prefetch_data[6] <= sdram_rdata;
                                3'd7: sdram_prefetch_data[7] <= sdram_rdata;
                            endcase
                            sdram_prefetch_fill_count <= sdram_prefetch_fill_count + 1'b1;

                            // First complete the original miss that triggered this burst.
                            if (!sdram_prefetch_primary_done &&
                                (sdram_prefetch_fill_idx == sdram_prefetch_req_idx)) begin
                                pending_rdata <= sdram_rdata;
                                if (pending_bus == BUS_DBUS) begin
                                    dbus_ack <= 1;
                                    dbus_dat_miso <= sdram_rdata;
                                end else begin
                                    ibus_ack <= 1;
                                    ibus_dat_miso <= sdram_rdata;
                                end
                                sdram_prefetch_primary_done <= 1;
                                pending_bus <= BUS_NONE;
                            end

                            // Burst done after 8 returned words.
                            if (sdram_prefetch_fill_idx == 3'd7) begin
                                if (!sdram_prefetch_primary_done) begin
                                    // Safety fallback: never leave the original request unacked.
                                    pending_rdata <= sdram_rdata;
                                    if (pending_bus == BUS_DBUS) begin
                                        dbus_ack <= 1;
                                        dbus_dat_miso <= sdram_rdata;
                                    end else begin
                                        ibus_ack <= 1;
                                        ibus_dat_miso <= sdram_rdata;
                                    end
                                end
                                mem_pending <= 0;
                                sdram_read_pending <= 0;
                                sdram_read_started <= 0;
                                sdram_write_started <= 0;
                                sdram_cmd_issued <= 0;
                                sdram_issue_wait <= 0;
                                sdram_read_is_prefetch <= 0;
                                pending_bus <= BUS_NONE;
                            end
                            sdram_prefetch_fill_idx <= sdram_prefetch_fill_idx + 1'b1;
                        end else begin
                            pending_rdata <= sdram_rdata;
                            if (pending_bus == BUS_DBUS) begin
                                dbus_ack <= 1;
                                dbus_dat_miso <= sdram_rdata;
                            end else begin
                                ibus_ack <= 1;
                                ibus_dat_miso <= sdram_rdata;
                            end
                            mem_pending <= 0;
                            sdram_read_pending <= 0;
                            sdram_read_started <= 0;
                            sdram_write_started <= 0;
                            sdram_cmd_issued <= 0;
                            sdram_issue_wait <= 0;
                            sdram_read_is_prefetch <= 0;
                            pending_bus <= BUS_NONE;
                        end
                    end
                end
            end else if (sdram_write_pending) begin
                if (!sdram_cmd_issued) begin
                    if (!sdram_busy) begin
                        sdram_wr <= 1;
                        sdram_cmd_issued <= 1;
                        sdram_write_started <= 0;
                        sdram_issue_wait <= 0;
                    end
                end else begin
                    // Write completion: wait for busy HIGH then LOW after command issue.
                    // Note: using sdram_busy (not sdram_accepted) here because write
                    // completion is detected by !sdram_busy, and we need word_busy to
                    // have risen in io_sdram before we check for its fall.
                    if (!sdram_write_started && sdram_busy) begin
                        sdram_write_started <= 1;
                        sdram_issue_wait <= 0;
                    end else if (!sdram_write_started) begin
                        sdram_issue_wait <= sdram_issue_wait + 1'b1;
                        if (&sdram_issue_wait) begin
                            sdram_cmd_issued <= 0;
                            sdram_issue_wait <= 0;
                        end
                    end else if (sdram_write_started && !sdram_busy) begin
                        if (pending_bus == BUS_DBUS) begin
                            dbus_ack <= 1;
                            dbus_dat_miso <= 32'h0;
                        end else begin
                            ibus_ack <= 1;
                            ibus_dat_miso <= 32'h0;
                        end
                        mem_pending <= 0;
                        sdram_write_pending <= 0;
                        sdram_read_started <= 0;
                        sdram_write_started <= 0;
                        sdram_cmd_issued <= 0;
                        sdram_issue_wait <= 0;
                        sdram_read_is_prefetch <= 0;
                        pending_bus <= BUS_NONE;
                    end
                end
            end else if (psram_read_pending) begin
                if (!psram_cmd_issued) begin
                    if (!psram_busy) begin
                        psram_rd <= 1;
                        psram_cmd_issued <= 1;
                        psram_read_started <= 0;
                        psram_issue_wait <= 0;
                    end
                end else begin
                    if (!psram_read_started) begin
                        if (psram_busy) begin
                            psram_read_started <= 1;
                            psram_issue_wait <= 0;
                        end else begin
                            psram_issue_wait <= psram_issue_wait + 1'b1;
                            if (&psram_issue_wait) begin
                                psram_cmd_issued <= 0;
                                psram_issue_wait <= 0;
                            end
                        end
                    end
                    if (psram_rdata_valid) begin
                        pending_rdata <= psram_rdata;
                        if (pending_bus == BUS_DBUS) begin
                            dbus_ack <= 1;
                            dbus_dat_miso <= psram_rdata;
                        end else begin
                            ibus_ack <= 1;
                            ibus_dat_miso <= psram_rdata;
                        end
                        mem_pending <= 0;
                        psram_read_pending <= 0;
                        psram_read_started <= 0;
                        psram_write_started <= 0;
                        psram_cmd_issued <= 0;
                        psram_issue_wait <= 0;
                        pending_bus <= BUS_NONE;
                    end
                end
            end else if (psram_write_pending) begin
                if (!psram_cmd_issued) begin
                    if (!psram_busy) begin
                        psram_wr <= 1;
                        psram_cmd_issued <= 1;
                        psram_write_started <= 0;
                        psram_issue_wait <= 0;
                    end
                end else begin
                    // Write completion: wait for busy HIGH then LOW after command issue.
                    // If busy never rises, retry command.
                    if (!psram_write_started && psram_busy) begin
                        psram_write_started <= 1;
                        psram_issue_wait <= 0;
                    end else if (!psram_write_started) begin
                        psram_issue_wait <= psram_issue_wait + 1'b1;
                        if (&psram_issue_wait) begin
                            psram_cmd_issued <= 0;
                            psram_issue_wait <= 0;
                        end
                    end else if (psram_write_started && !psram_busy) begin
                        if (pending_bus == BUS_DBUS) begin
                            dbus_ack <= 1;
                            dbus_dat_miso <= 32'h0;
                        end else begin
                            ibus_ack <= 1;
                            ibus_dat_miso <= 32'h0;
                        end
                        mem_pending <= 0;
                        psram_write_pending <= 0;
                        psram_read_started <= 0;
                        psram_write_started <= 0;
                        psram_cmd_issued <= 0;
                        psram_issue_wait <= 0;
                        pending_bus <= BUS_NONE;
                    end
                end
            end else if (sram_read_pending) begin
                if (!sram_cmd_issued) begin
                    if (!sram_busy) begin
                        sram_rd <= 1;
                        sram_cmd_issued <= 1;
                        sram_read_started <= 0;
                        sram_issue_wait <= 0;
                    end
                end else begin
                    if (!sram_read_started) begin
                        if (sram_busy) begin
                            sram_read_started <= 1;
                            sram_issue_wait <= 0;
                        end else begin
                            sram_issue_wait <= sram_issue_wait + 1'b1;
                            if (&sram_issue_wait) begin
                                sram_cmd_issued <= 0;
                                sram_issue_wait <= 0;
                            end
                        end
                    end
                    if (sram_q_valid) begin
                        pending_rdata <= sram_rdata;
                        if (pending_bus == BUS_DBUS) begin
                            dbus_ack <= 1;
                            dbus_dat_miso <= sram_rdata;
                        end else begin
                            ibus_ack <= 1;
                            ibus_dat_miso <= sram_rdata;
                        end
                        mem_pending <= 0;
                        sram_read_pending <= 0;
                        sram_read_started <= 0;
                        sram_write_started <= 0;
                        sram_cmd_issued <= 0;
                        sram_issue_wait <= 0;
                        pending_bus <= BUS_NONE;
                    end
                end
            end else if (sram_write_pending) begin
                if (!sram_cmd_issued) begin
                    if (!sram_busy) begin
                        sram_wr <= 1;
                        sram_cmd_issued <= 1;
                        sram_write_started <= 0;
                        sram_issue_wait <= 0;
                    end
                end else begin
                    if (!sram_write_started && sram_busy) begin
                        sram_write_started <= 1;
                        sram_issue_wait <= 0;
                    end else if (!sram_write_started) begin
                        sram_issue_wait <= sram_issue_wait + 1'b1;
                        if (&sram_issue_wait) begin
                            sram_cmd_issued <= 0;
                            sram_issue_wait <= 0;
                        end
                    end else if (sram_write_started && !sram_busy) begin
                        if (pending_bus == BUS_DBUS) begin
                            dbus_ack <= 1;
                            dbus_dat_miso <= 32'h0;
                        end else begin
                            ibus_ack <= 1;
                            ibus_dat_miso <= 32'h0;
                        end
                        mem_pending <= 0;
                        sram_write_pending <= 0;
                        sram_read_started <= 0;
                        sram_write_started <= 0;
                        sram_cmd_issued <= 0;
                        sram_issue_wait <= 0;
                        pending_bus <= BUS_NONE;
                    end
                end
            end else if (term_pending && term_mem_ready) begin
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= term_mem_rdata;
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= term_mem_rdata;
                end
                mem_pending <= 0;
                term_pending <= 0;
                pending_bus <= BUS_NONE;
            end else if (sysreg_pending) begin
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= sysreg_rdata;
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= sysreg_rdata;
                end
                mem_pending <= 0;
                sysreg_pending <= 0;
                pending_bus <= BUS_NONE;
            end else if (dma_pending) begin
                // DMA registers respond in 1 cycle (combinatorial read)
                // dma_reg_addr was set during accept cycle
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= dma_reg_rdata;
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= dma_reg_rdata;
                end
                mem_pending <= 0;
                dma_pending <= 0;
                pending_bus <= BUS_NONE;
            end else if (span_pending) begin
                // Span registers respond in 1 cycle (combinatorial read)
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= span_reg_rdata;
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= span_reg_rdata;
                end
                mem_pending <= 0;
                span_pending <= 0;
                pending_bus <= BUS_NONE;
            end else if (cmap_pending) begin
                // Colormap BRAM: data ready after 1 cycle (same as main RAM)
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= cmap_rdata;
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= cmap_rdata;
                end
                mem_pending <= 0;
                cmap_pending <= 0;
                pending_bus <= BUS_NONE;
            end else if (atm_pending) begin
                // Writes complete immediately; reads stall until MAC is idle
                if (atm_is_write || !atm_busy) begin
                    if (pending_bus == BUS_DBUS) begin
                        dbus_ack <= 1;
                        dbus_dat_miso <= atm_reg_rdata;
                    end else begin
                        ibus_ack <= 1;
                        ibus_dat_miso <= atm_reg_rdata;
                    end
                    mem_pending <= 0;
                    atm_pending <= 0;
                    pending_bus <= BUS_NONE;
                end
            end else if (sramfill_pending) begin
                // SRAM fill registers respond in 1 cycle
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= sramfill_reg_rdata;
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= sramfill_reg_rdata;
                end
                mem_pending <= 0;
                sramfill_pending <= 0;
                pending_bus <= BUS_NONE;
            end else if (audio_pending) begin
                // Audio registers respond in 1 cycle
                // Read from 0x4C000004: return FIFO status
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= {19'b0, audio_fifo_full, audio_fifo_level};
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= {19'b0, audio_fifo_full, audio_fifo_level};
                end
                mem_pending <= 0;
                audio_pending <= 0;
                pending_bus <= BUS_NONE;
            end else if (link_pending) begin
                // Link MMIO registers respond in 1 cycle
                if (pending_bus == BUS_DBUS) begin
                    dbus_ack <= 1;
                    dbus_dat_miso <= link_reg_rdata;
                end else begin
                    ibus_ack <= 1;
                    ibus_dat_miso <= link_reg_rdata;
                end
                mem_pending <= 0;
                link_pending <= 0;
                pending_bus <= BUS_NONE;
            end
        end
    end
end

endmodule
