//
// User core top-level (Minimal)
//
// Instantiated by the real top-level: apf_top
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
// Set to 1 for little-endian (RISC-V native format)
assign bridge_endian_little = 1;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// Link port directions/data are driven by link_mmio below.
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input
assign port_tran_so = link_so_oe ? link_so_out : 1'bz;
assign port_tran_so_dir = link_so_oe;
assign port_tran_sck = link_sck_oe ? link_sck_out : 1'bz;
assign port_tran_sck_dir = link_sck_oe;
assign port_tran_sd = link_sd_oe ? link_sd_out : 1'bz;
assign port_tran_sd_dir = link_sd_oe;
assign link_si_i = port_tran_si;
assign link_sck_i = port_tran_sck;
assign link_sd_i = port_tran_sd;

// PSRAM Controller for CRAM0 (16MB)
// Uses muxed signals for bridge/CPU arbitration
psram_controller #(
    .CLOCK_SPEED(100.0)
) psram0 (
    .clk(clk_ram_controller),
    .reset_n(reset_n),

    // Muxed word interface (bridge or CPU)
    .word_rd(psram_mux_rd),
    .word_wr(psram_mux_wr),
    .word_addr(psram_mux_addr),
    .word_data(psram_mux_wdata),
    .word_wstrb(psram_mux_wstrb),
    .word_q(psram_mux_rdata),
    .word_busy(psram_mux_busy),
    .word_q_valid(psram_mux_rdata_valid),

    // Physical PSRAM signals
    .cram_a(cram0_a),
    .cram_dq(cram0_dq),
    .cram_wait(cram0_wait),
    .cram_clk(cram0_clk),
    .cram_adv_n(cram0_adv_n),
    .cram_cre(cram0_cre),
    .cram_ce0_n(cram0_ce0_n),
    .cram_ce1_n(cram0_ce1_n),
    .cram_oe_n(cram0_oe_n),
    .cram_we_n(cram0_we_n),
    .cram_ub_n(cram0_ub_n),
    .cram_lb_n(cram0_lb_n)
);

// CRAM1 unused - tie off all outputs
assign cram1_a     = 6'h0;
assign cram1_dq    = 16'hZZZZ;
assign cram1_clk   = 1'b0;
assign cram1_adv_n = 1'b1;
assign cram1_cre   = 1'b0;
assign cram1_ce0_n = 1'b1;
assign cram1_ce1_n = 1'b1;
assign cram1_oe_n  = 1'b1;
assign cram1_we_n  = 1'b1;
assign cram1_ub_n  = 1'b1;
assign cram1_lb_n  = 1'b1;

// SDRAM word interface signals (directly matching io_sdram interface)
reg             ram1_word_rd;
reg             ram1_word_wr;
reg     [23:0]  ram1_word_addr;
reg     [31:0]  ram1_word_data;
reg     [3:0]   ram1_word_wstrb;
reg     [2:0]   ram1_word_burst_len;
wire    [31:0]  ram1_word_q;
wire            ram1_word_busy;
wire            ram1_word_q_valid;

// CPU to SDRAM interface (same clock as controller)
wire        cpu_sdram_rd;
wire        cpu_sdram_wr;
wire [23:0] cpu_sdram_addr;
wire [31:0] cpu_sdram_wdata;
wire [3:0]  cpu_sdram_wstrb;
wire [2:0]  cpu_sdram_burst_len;
wire [31:0] cpu_sdram_rdata;
wire        cpu_sdram_busy;

// CPU to PSRAM interface (same clock domain as CPU - no CDC needed)
// 22-bit word address covers 16MB (CRAM0 only)
wire        cpu_psram_rd;
wire        cpu_psram_wr;
wire [21:0] cpu_psram_addr;
wire [31:0] cpu_psram_wdata;
wire [3:0]  cpu_psram_wstrb;
wire [31:0] cpu_psram_rdata;
wire        cpu_psram_busy;
wire        cpu_psram_rdata_valid;

// Muxed PSRAM signals (bridge or CPU) going to psram_controller
wire        psram_mux_rd;
wire        psram_mux_wr;
wire [21:0] psram_mux_addr;
wire [31:0] psram_mux_wdata;
wire [3:0]  psram_mux_wstrb;
wire [31:0] psram_mux_rdata;
wire        psram_mux_busy;
wire        psram_mux_rdata_valid;

// DMA peripheral register interface (between cpu_system and dma_clear_blit)
wire        dma_reg_wr;
wire [4:0]  dma_reg_addr;
wire [31:0] dma_reg_wdata;
wire [31:0] dma_reg_rdata;

// DMA SDRAM interface (from dma_clear_blit to periph_sdram_mux)
wire        dma_sdram_rd;
wire        dma_sdram_wr;
wire [23:0] dma_sdram_addr;
wire [31:0] dma_sdram_wdata;
wire [3:0]  dma_sdram_wstrb;
wire        dma_active;

// SRAM fill register interface (between cpu_system and sram_fill)
wire        sramfill_reg_wr;
wire [4:0]  sramfill_reg_addr;
wire [31:0] sramfill_reg_wdata;
wire [31:0] sramfill_reg_rdata;

// SRAM fill write interface (to SRAM mux)
wire        sramfill_sram_wr;
wire [15:0] sramfill_sram_addr;
wire [31:0] sramfill_sram_wdata;
wire [3:0]  sramfill_sram_wstrb;
wire        sramfill_sram_busy;
wire        sramfill_active;

// Span rasterizer register interface (between cpu_system and span_rasterizer)
wire        span_reg_wr;
wire [4:0]  span_reg_addr;
wire [31:0] span_reg_wdata;
wire [31:0] span_reg_rdata;

// Alias Transform MAC register interface (between cpu_system and alias_transform_mac)
wire        atm_reg_wr;
wire [4:0]  atm_reg_addr;
wire [31:0] atm_reg_wdata;
wire [31:0] atm_reg_rdata;
wire        atm_norm_wr;
wire [8:0]  atm_norm_addr;
wire [31:0] atm_norm_wdata;
wire        atm_busy;

// Audio output interface (between cpu_system and audio_output)
wire        audio_sample_wr;
wire [31:0] audio_sample_data;
wire [11:0] audio_fifo_level;
wire        audio_fifo_full;

// Link MMIO register interface (between cpu_system and link_mmio)
wire        link_reg_wr;
wire        link_reg_rd;
wire [4:0]  link_reg_addr;
wire [31:0] link_reg_wdata;
wire [31:0] link_reg_rdata;

// Link physical interface (to Pocket link port level translators)
wire        link_si_i;
wire        link_sck_i;
wire        link_sd_i;
wire        link_so_out;
wire        link_so_oe;
wire        link_sck_out;
wire        link_sck_oe;
wire        link_sd_out;
wire        link_sd_oe;

// Span rasterizer colormap BRAM interface (port B, through cpu_system)
wire [11:0] span_cmap_addr;
wire [31:0] span_cmap_rdata;

// Span rasterizer SDRAM interface (from span_rasterizer to periph_sdram_mux)
wire        span_sdram_rd;
wire        span_sdram_wr;
wire [23:0] span_sdram_addr;
wire [31:0] span_sdram_wdata;
wire [3:0]  span_sdram_wstrb;
wire [2:0]  span_sdram_burst_len;
wire        span_active;

// Span rasterizer SRAM interface (for z-span writes to SRAM z-buffer)
wire        span_sram_wr;
wire [21:0] span_sram_addr;
wire [31:0] span_sram_wdata;
wire [3:0]  span_sram_wstrb;
wire        span_sram_busy;

// Peripheral SDRAM mux output (to SDRAM arbiter)
wire        periph_sdram_rd;
wire        periph_sdram_wr;
wire [23:0] periph_sdram_addr;
wire [31:0] periph_sdram_wdata;
wire [3:0]  periph_sdram_wstrb;
wire [2:0]  periph_sdram_burst_len;
wire        periph_active;

// CPU to SRAM interface
wire        cpu_sram_rd;
wire        cpu_sram_wr;
wire [21:0] cpu_sram_addr;
wire [31:0] cpu_sram_wdata;
wire [3:0]  cpu_sram_wstrb;
wire [31:0] cpu_sram_rdata;
wire        cpu_sram_busy;
wire        cpu_sram_q_valid;

// SRAM Controller (256KB async SRAM)
// Tristate handled here at top level to avoid synthesis issues through hierarchy
wire [15:0] sram_dq_out_w;
wire [15:0] sram_dq_in_w = sram_dq;
wire        sram_dq_oe_w;
wire        sram_ctrl_busy;  // Raw busy from controller

assign sram_dq = sram_dq_oe_w ? sram_dq_out_w : 16'hZZZZ;

// SRAM arbitration: CPU > span rasterizer > sram_fill
wire cpu_sram_active = cpu_sram_rd | cpu_sram_wr;
wire span_or_fill    = span_sram_wr | sramfill_sram_wr;
wire        mux_sram_rd    = cpu_sram_rd;
wire        mux_sram_wr    = cpu_sram_active ? cpu_sram_wr      :
                             span_sram_wr    ? 1'b1              :
                                               sramfill_sram_wr;
wire [21:0] mux_sram_addr  = cpu_sram_active ? cpu_sram_addr                      :
                             span_sram_wr    ? span_sram_addr                      :
                                               {6'd0, sramfill_sram_addr};
wire [31:0] mux_sram_wdata = cpu_sram_active ? cpu_sram_wdata   :
                             span_sram_wr    ? span_sram_wdata   :
                                               sramfill_sram_wdata;
wire [3:0]  mux_sram_wstrb = cpu_sram_active ? cpu_sram_wstrb   :
                             span_sram_wr    ? span_sram_wstrb   :
                                               sramfill_sram_wstrb;

// CPU busy comes from controller (CPU has priority, never blocked by mux)
assign cpu_sram_busy = sram_ctrl_busy;
// Span sees busy when CPU is accessing or controller is busy
assign span_sram_busy = cpu_sram_active | sram_ctrl_busy;
// Fill sees busy when CPU or span is accessing or controller is busy
assign sramfill_sram_busy = cpu_sram_active | span_sram_wr | sram_ctrl_busy;

sram_controller sram0 (
    .clk(clk_ram_controller),
    .reset_n(reset_n),
    .word_rd(mux_sram_rd),
    .word_wr(mux_sram_wr),
    .word_addr(mux_sram_addr),
    .word_data(mux_sram_wdata),
    .word_wstrb(mux_sram_wstrb),
    .word_q(cpu_sram_rdata),
    .word_busy(sram_ctrl_busy),
    .word_q_valid(cpu_sram_q_valid),
    .sram_a(sram_a),
    .sram_dq_out(sram_dq_out_w),
    .sram_dq_in(sram_dq_in_w),
    .sram_dq_oe(sram_dq_oe_w),
    .sram_oe_n(sram_oe_n),
    .sram_we_n(sram_we_n),
    .sram_ub_n(sram_ub_n),
    .sram_lb_n(sram_lb_n)
);

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// Bridge read data mux
// NOTE: bridge_rd_data_captured is in clk_ram_controller domain but read here in clk_74a.
// This is safe because: (1) data is captured before bridge_rd_done asserts, and
// (2) bridge_rd_done goes through 2-stage sync, so data is stable for 2+ cycles when read.

always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'b000000xx_xxxxxxxx_xxxxxxxx_xxxxxxxx: begin
        // SDRAM mapped at 0x00000000 - 0x03FFFFFF (64MB)
        bridge_rd_data <= bridge_rd_data_captured;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase
end

// Synchronize bridge signals from clk_74a to clk_ram_controller
reg [31:0] bridge_addr_captured;
reg [31:0] bridge_wr_data_captured;
reg bridge_sdram_wr, bridge_sdram_rd;
reg bridge_psram_wr;  // Bridge write to PSRAM
reg [31:0] bridge_addr_ram_clk;
reg [31:0] bridge_wr_data_ram_clk;
reg bridge_wr_done, bridge_rd_done;  // Feedback to 74a domain
reg bridge_wr_done_sync1, bridge_wr_done_sync2;
reg bridge_rd_done_sync1, bridge_rd_done_sync2;
reg bridge_wr_pending;  // Tracks bridge write in progress (waiting for busy high->low)
reg bridge_wr_started;
reg bridge_rd_pending;  // Tracks bridge read in progress (waiting for data)
reg [31:0] bridge_rd_data_captured;  // Data captured in clk_ram_controller domain

// Capture bridge signals in clk_74a domain
// IMPORTANT: Hold the captured values until the RAM controller has processed them
// This prevents race conditions when multiple writes come quickly
always @(posedge clk_74a) begin
    // Synchronize done signals back from RAM controller clock
    bridge_wr_done_sync1 <= bridge_wr_done;
    bridge_wr_done_sync2 <= bridge_wr_done_sync1;
    bridge_rd_done_sync1 <= bridge_rd_done;
    bridge_rd_done_sync2 <= bridge_rd_done_sync1;
    bridge_psram_wr_done_sync1 <= bridge_psram_wr_done;
    bridge_psram_wr_done_sync2 <= bridge_psram_wr_done_sync1;

    // Clear the request when done is seen
    if (bridge_wr_done_sync2) bridge_sdram_wr <= 0;
    if (bridge_rd_done_sync2) bridge_sdram_rd <= 0;
    if (bridge_psram_wr_done_sync2) bridge_psram_wr <= 0;

    // Only accept new requests when not busy
    if (!bridge_sdram_wr && !bridge_psram_wr && bridge_wr) begin
        casex(bridge_addr[31:24])
        8'b000000xx: begin
            // SDRAM: bridge 0x00000000-0x03FFFFFF
            bridge_sdram_wr <= 1;
            bridge_addr_captured <= bridge_addr;
            bridge_wr_data_captured <= bridge_wr_data;
        end
        8'h20: begin
            // PSRAM: bridge 0x20000000-0x20FFFFFF -> CPU 0x30000000
            bridge_psram_wr <= 1;
            bridge_addr_captured <= bridge_addr;
            bridge_wr_data_captured <= bridge_wr_data;
        end
        endcase
    end
    if (!bridge_sdram_rd && bridge_rd) begin
        casex(bridge_addr[31:24])
        8'b000000xx: begin
            bridge_sdram_rd <= 1;
            bridge_addr_captured <= bridge_addr;
            // NOTE: Don't capture ram1_word_q here - data isn't ready yet!
            // Data will be captured in clk_ram_controller domain when ram1_word_q_valid asserts
        end
        endcase
    end
end

// 4-stage synchronizer for control signals + data synchronization
// sync1 -> sync2 -> sync3 -> sync4 gives data plenty of time to stabilize
// Data is also double-registered to reduce metastability risk
reg bridge_wr_sync1, bridge_wr_sync2, bridge_wr_sync3, bridge_wr_sync4;
reg bridge_rd_sync1, bridge_rd_sync2, bridge_rd_sync3, bridge_rd_sync4;
reg bridge_psram_wr_sync1, bridge_psram_wr_sync2, bridge_psram_wr_sync3, bridge_psram_wr_sync4;
reg bridge_psram_wr_done, bridge_psram_wr_done_sync1, bridge_psram_wr_done_sync2;
reg [31:0] bridge_psram_addr_ram_clk;
reg [31:0] bridge_psram_wr_data_ram_clk;

// Double-register data for CDC (sync stages for data)
reg [31:0] bridge_addr_sync1, bridge_addr_sync2;
reg [31:0] bridge_wr_data_sync1, bridge_wr_data_sync2;

always @(posedge clk_ram_controller) begin
    // 4-stage sync for SDRAM control signals
    bridge_wr_sync1 <= bridge_sdram_wr;
    bridge_wr_sync2 <= bridge_wr_sync1;
    bridge_wr_sync3 <= bridge_wr_sync2;
    bridge_wr_sync4 <= bridge_wr_sync3;
    bridge_rd_sync1 <= bridge_sdram_rd;
    bridge_rd_sync2 <= bridge_rd_sync1;
    bridge_rd_sync3 <= bridge_rd_sync2;
    bridge_rd_sync4 <= bridge_rd_sync3;

    // 4-stage sync for PSRAM control signals
    bridge_psram_wr_sync1 <= bridge_psram_wr;
    bridge_psram_wr_sync2 <= bridge_psram_wr_sync1;
    bridge_psram_wr_sync3 <= bridge_psram_wr_sync2;
    bridge_psram_wr_sync4 <= bridge_psram_wr_sync3;

    // Double-register data from clk_74a domain to reduce metastability
    // Sample on sync2 rising edge (earlier than sync3, gives more settling time)
    if ((bridge_wr_sync2 && !bridge_wr_sync3) ||
        (bridge_rd_sync2 && !bridge_rd_sync3) ||
        (bridge_psram_wr_sync2 && !bridge_psram_wr_sync3)) begin
        bridge_addr_sync1 <= bridge_addr_captured;
    end
    if ((bridge_wr_sync2 && !bridge_wr_sync3) ||
        (bridge_psram_wr_sync2 && !bridge_psram_wr_sync3)) begin
        bridge_wr_data_sync1 <= bridge_wr_data_captured;
    end
    // Second stage - always sample from first stage for clean CDC
    bridge_addr_sync2 <= bridge_addr_sync1;
    bridge_wr_data_sync2 <= bridge_wr_data_sync1;

    // Capture SDRAM address/data on sync3 rising edge (using synchronized data)
    if (bridge_wr_sync3 && !bridge_wr_sync4) begin
        bridge_addr_ram_clk <= bridge_addr_sync2;
        bridge_wr_data_ram_clk <= bridge_wr_data_sync2;
    end
    if (bridge_rd_sync3 && !bridge_rd_sync4) begin
        bridge_addr_ram_clk <= bridge_addr_sync2;
    end

    // Capture PSRAM address/data on sync3 rising edge (using synchronized data)
    if (bridge_psram_wr_sync3 && !bridge_psram_wr_sync4) begin
        bridge_psram_addr_ram_clk <= bridge_addr_sync2;
        bridge_psram_wr_data_ram_clk <= bridge_wr_data_sync2;
    end

    // For writes: issue only when controller is idle, then wait for busy high->low
    if (!bridge_wr_pending && !bridge_wr_done && bridge_wr_sync4 && !ram1_word_busy) begin
        bridge_wr_pending <= 1;
        bridge_wr_started <= 0;
    end else if (bridge_wr_pending) begin
        if (!bridge_wr_started && ram1_word_busy) begin
            bridge_wr_started <= 1;
        end else if (bridge_wr_started && !ram1_word_busy) begin
            bridge_wr_pending <= 0;
            bridge_wr_started <= 0;
            bridge_wr_done <= 1;
        end
    end

    // For reads: issue only when controller is idle, then wait for valid data
    if (!bridge_rd_pending && !bridge_rd_done && bridge_rd_sync4 && !ram1_word_busy) begin
        bridge_rd_pending <= 1;  // Read issued, waiting for data
    end

    // Capture read data when valid and we're waiting for it
    if (bridge_rd_pending && ram1_word_q_valid) begin
        bridge_rd_data_captured <= ram1_word_q;
        bridge_rd_pending <= 0;
        bridge_rd_done <= 1;  // Now we can signal done
    end

    // Clear done when sync goes low
    if (!bridge_wr_sync1) begin
        bridge_wr_done <= 0;
        bridge_wr_pending <= 0;
        bridge_wr_started <= 0;
    end
    if (!bridge_rd_sync1) begin
        bridge_rd_done <= 0;
        bridge_rd_pending <= 0;
    end
end

// Bridge is active from sync3 through done (when we're processing)
wire bridge_wr_active = bridge_wr_sync3 | bridge_wr_sync4 | bridge_wr_pending | bridge_wr_done;
wire bridge_rd_active = bridge_rd_sync3 | bridge_rd_sync4 | bridge_rd_pending | bridge_rd_done;

// SDRAM access arbiter - runs at SDRAM controller clock (95 MHz)
// Priority: Bridge > Peripheral DMA > CPU
// CPU runs at same clock as SDRAM controller (no CDC needed)
reg cpu_sdram_accepted;  // Pulses when arbiter actually forwards a CPU command
always @(posedge clk_ram_controller) begin
    ram1_word_rd <= 0;
    ram1_word_wr <= 0;
    ram1_word_burst_len <= 3'd0;  // Default: single word reads
    cpu_sdram_accepted <= 0;

    // Issue SDRAM command on sync4 rising edge for bridge
    if (bridge_wr_sync4 && !bridge_wr_done && !bridge_wr_pending && !ram1_word_busy) begin
        ram1_word_wr <= 1;
        ram1_word_addr <= bridge_addr_ram_clk[25:2];
        ram1_word_data <= bridge_wr_data_ram_clk;
        ram1_word_wstrb <= 4'b1111;  // Bridge always does full word writes
    end else if (bridge_rd_sync4 && !bridge_rd_done && !bridge_rd_pending && !ram1_word_busy) begin
        ram1_word_rd <= 1;
        ram1_word_addr <= bridge_addr_ram_clk[25:2];
    end else if (!bridge_wr_active && !bridge_rd_active) begin
        // Peripheral DMA has priority over CPU
        if (periph_sdram_rd) begin
            ram1_word_rd <= 1;
            ram1_word_addr <= periph_sdram_addr;
            ram1_word_burst_len <= periph_sdram_burst_len;
        end else if (periph_sdram_wr) begin
            ram1_word_wr <= 1;
            ram1_word_addr <= periph_sdram_addr;
            ram1_word_data <= periph_sdram_wdata;
            ram1_word_wstrb <= periph_sdram_wstrb;
        end else if (cpu_sdram_rd) begin
            // CPU SDRAM access - direct pass-through (same clock domain)
            ram1_word_rd <= 1;
            ram1_word_addr <= cpu_sdram_addr;
            ram1_word_burst_len <= cpu_sdram_burst_len;
            cpu_sdram_accepted <= 1;
        end else if (cpu_sdram_wr) begin
            ram1_word_wr <= 1;
            ram1_word_addr <= cpu_sdram_addr;
            ram1_word_data <= cpu_sdram_wdata;
            ram1_word_wstrb <= cpu_sdram_wstrb;
            cpu_sdram_accepted <= 1;
        end
    end
end

// CPU SDRAM data connections - direct (same clock domain)
assign cpu_sdram_rdata = ram1_word_q;
// Busy also reflects bridge/peripheral ownership to avoid CPU issuing commands into a masked window.
assign cpu_sdram_busy = ram1_word_busy | bridge_wr_active | bridge_rd_active | periph_active;

// Bridge PSRAM write active signal
wire bridge_psram_wr_active = bridge_psram_wr_sync3 | bridge_psram_wr_sync4 | bridge_psram_wr_done | bridge_psram_write_pending;

// PSRAM write pending state machine
reg bridge_psram_write_pending;
reg bridge_psram_write_started;

// Bridge PSRAM state machine - only handles bridge writes (at clk_ram_controller)
always @(posedge clk_ram_controller) begin
    // Bridge PSRAM write - issue on sync4 rising edge
    if (bridge_psram_wr_sync4 && !bridge_psram_wr_done && !bridge_psram_write_pending) begin
        bridge_psram_write_pending <= 1;
        bridge_psram_write_started <= 0;
    end else if (bridge_psram_write_pending) begin
        // Wait for PSRAM to complete
        if (!bridge_psram_write_started && psram_mux_busy) begin
            bridge_psram_write_started <= 1;
        end else if (bridge_psram_write_started && !psram_mux_busy) begin
            bridge_psram_write_pending <= 0;
            bridge_psram_write_started <= 0;
            bridge_psram_wr_done <= 1;
        end
    end

    // Clear PSRAM done when sync goes low
    if (!bridge_psram_wr_sync1) bridge_psram_wr_done <= 0;
end

// PSRAM mux: Bridge writes have priority, CPU access when bridge idle
// CPU runs at same clock as PSRAM controller (no CDC needed)
assign psram_mux_rd = bridge_psram_wr_active ? 1'b0 : cpu_psram_rd;
assign psram_mux_wr = bridge_psram_write_pending ? 1'b1 : cpu_psram_wr;
assign psram_mux_addr = bridge_psram_write_pending ? bridge_psram_addr_ram_clk[23:2] : cpu_psram_addr;
assign psram_mux_wdata = bridge_psram_write_pending ? bridge_psram_wr_data_ram_clk : cpu_psram_wdata;
assign psram_mux_wstrb = bridge_psram_write_pending ? 4'b1111 : cpu_psram_wstrb;

// CPU PSRAM data connections - single CRAM0
assign cpu_psram_rdata = psram_mux_rdata;
assign cpu_psram_busy = bridge_psram_wr_active | psram_mux_busy;
assign cpu_psram_rdata_valid = psram_mux_rdata_valid;


//
// host/target command handler
//
    wire            reset_n_apf;            // driven by host commands from APF bridge
    wire    [31:0]  cmd_bridge_rd_data;

    wire reset_n = reset_n_apf;

// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s;
    wire            status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;

    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;

    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a
// CPU-controlled via system registers - synced from clk_ram_controller to clk_74a

    // CPU-side signals (in clk_ram_controller domain)
    wire            cpu_target_dataslot_read;
    wire            cpu_target_dataslot_write;
    wire            cpu_target_dataslot_openfile;
    wire    [15:0]  cpu_target_dataslot_id;
    wire    [31:0]  cpu_target_dataslot_slotoffset;
    wire    [31:0]  cpu_target_dataslot_bridgeaddr;
    wire    [31:0]  cpu_target_dataslot_length;
    wire    [31:0]  cpu_target_buffer_param_struct;
    wire    [31:0]  cpu_target_buffer_resp_struct;

    // Bridge-side signals (in clk_74a domain)
    wire            target_dataslot_ack;
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    // Synchronize trigger signals from CPU clock to bridge clock
    wire            target_dataslot_read;
    wire            target_dataslot_write;
    wire            target_dataslot_openfile;
    wire            target_dataslot_getfile = 0;  // Not used

    synch_3 sync_ds_read(cpu_target_dataslot_read, target_dataslot_read, clk_74a);
    synch_3 sync_ds_write(cpu_target_dataslot_write, target_dataslot_write, clk_74a);
    synch_3 sync_ds_openfile(cpu_target_dataslot_openfile, target_dataslot_openfile, clk_74a);

    // Synchronize dataslot parameters from CPU clock to bridge clock.
    // Parameters are held stable in cpu_system until the next command, so
    // double-registering provides clean sampling before trigger edge handling.
    reg [15:0]  cpu_ds_id_sync1, cpu_ds_id_sync2;
    reg [31:0]  cpu_ds_slotoffset_sync1, cpu_ds_slotoffset_sync2;
    reg [31:0]  cpu_ds_bridgeaddr_sync1, cpu_ds_bridgeaddr_sync2;
    reg [31:0]  cpu_ds_length_sync1, cpu_ds_length_sync2;
    reg [31:0]  cpu_ds_param_sync1, cpu_ds_param_sync2;
    reg [31:0]  cpu_ds_resp_sync1, cpu_ds_resp_sync2;

    // Latch parameters when trigger asserts (edge detection in bridge clock domain)
    reg target_dataslot_read_1, target_dataslot_write_1, target_dataslot_openfile_1;
    reg [15:0]  target_dataslot_id;
    reg [31:0]  target_dataslot_slotoffset;
    reg [31:0]  target_dataslot_bridgeaddr;
    reg [31:0]  target_dataslot_length;
    reg [31:0]  target_buffer_param_struct;
    reg [31:0]  target_buffer_resp_struct;

    always @(posedge clk_74a) begin
        cpu_ds_id_sync1 <= cpu_target_dataslot_id;
        cpu_ds_id_sync2 <= cpu_ds_id_sync1;
        cpu_ds_slotoffset_sync1 <= cpu_target_dataslot_slotoffset;
        cpu_ds_slotoffset_sync2 <= cpu_ds_slotoffset_sync1;
        cpu_ds_bridgeaddr_sync1 <= cpu_target_dataslot_bridgeaddr;
        cpu_ds_bridgeaddr_sync2 <= cpu_ds_bridgeaddr_sync1;
        cpu_ds_length_sync1 <= cpu_target_dataslot_length;
        cpu_ds_length_sync2 <= cpu_ds_length_sync1;
        cpu_ds_param_sync1 <= cpu_target_buffer_param_struct;
        cpu_ds_param_sync2 <= cpu_ds_param_sync1;
        cpu_ds_resp_sync1 <= cpu_target_buffer_resp_struct;
        cpu_ds_resp_sync2 <= cpu_ds_resp_sync1;

        target_dataslot_read_1 <= target_dataslot_read;
        target_dataslot_write_1 <= target_dataslot_write;
        target_dataslot_openfile_1 <= target_dataslot_openfile;

        // Latch parameters on rising edge of any trigger
        if ((target_dataslot_read && !target_dataslot_read_1) ||
            (target_dataslot_write && !target_dataslot_write_1) ||
            (target_dataslot_openfile && !target_dataslot_openfile_1)) begin
            target_dataslot_id <= cpu_ds_id_sync2;
            target_dataslot_slotoffset <= cpu_ds_slotoffset_sync2;
            target_dataslot_bridgeaddr <= cpu_ds_bridgeaddr_sync2;
            target_dataslot_length <= cpu_ds_length_sync2;
            target_buffer_param_struct <= cpu_ds_param_sync2;
            target_buffer_resp_struct <= cpu_ds_resp_sync2;
        end
    end

// bridge data slot access
// synchronous to clk_74a
// Not used - APF handles data slot loading automatically

    wire    [9:0]   datatable_addr = 0;
    wire    [31:0]  datatable_q;
    wire            datatable_wren = 0;
    wire    [31:0]  datatable_data = 0;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n_apf ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);



////////////////////////////////////////////////////////////////////////////////////////



// video generation
// Using 12.288 MHz pixel clock
//
// For 60 Hz: 12,288,000 / 60 = 204,800 pixels per frame
// Using 320x240 visible with blanking:
// - 400 total horizontal (320 visible + 80 blanking)
// - 262 total vertical (240 visible + 22 blanking)
// - 400 * 262 = 104,800 -> ~117 Hz (too fast)
//
// Let's try 320x200 with more blanking for ~60Hz:
// - 408 total horizontal (320 + 88)
// - 502 total vertical (200 + 302) -> way too much blanking
//
// Better approach: 320x240 @ ~48Hz (close enough for scaler)
// - 400 H total, 256 V total = 102,400 -> 120 Hz
// - 400 H total, 512 V total = 204,800 -> 60 Hz exactly!
//
// 320x240 visible, 400x512 total = 60 Hz at 12.288 MHz

assign video_rgb_clock = clk_core_12288;
assign video_rgb_clock_90 = clk_core_12288_90deg;
assign video_rgb = vidout_rgb;
assign video_de = vidout_de;
assign video_skip = vidout_skip;
assign video_vs = vidout_vs;
assign video_hs = vidout_hs;

    // 320x240 @ 60Hz with 12.288 MHz pixel clock
    // Total: 400 x 512 = 204,800 pixels/frame
    // 12,288,000 / 204,800 = 60 Hz
    localparam  VID_V_BPORCH = 'd16;
    localparam  VID_V_ACTIVE = 'd240;
    localparam  VID_V_TOTAL = 'd512;
    localparam  VID_H_BPORCH = 'd40;
    localparam  VID_H_ACTIVE = 'd320;
    localparam  VID_H_TOTAL = 'd400;

    reg [15:0]  frame_count;

    reg [9:0]   x_count;
    reg [9:0]   y_count;

    wire [9:0]  visible_x = x_count - VID_H_BPORCH;
    wire [9:0]  visible_y = y_count - VID_V_BPORCH;

    reg [23:0]  vidout_rgb;
    reg         vidout_de, vidout_de_1;
    reg         vidout_skip;
    reg         vidout_vs;
    reg         vidout_hs, vidout_hs_1;

    // CPU to terminal interface signals
    wire        term_mem_valid;
    wire [31:0] term_mem_addr;
    wire [31:0] term_mem_wdata;
    wire [3:0]  term_mem_wstrb;
    wire [31:0] term_mem_rdata;
    wire        term_mem_ready;

    // Display mode and framebuffer address from CPU
    wire display_mode;
    wire [24:0] fb_display_addr;

    // VexRiscv CPU system - running at 95 MHz (CPU + memory)
    cpu_system cpu (
        .clk(clk_cpu),  // 95 MHz
        .clk_74a(clk_74a),
        .reset_n(reset_n),
        .dataslot_allcomplete(dataslot_allcomplete),
        .vsync(vidout_vs),
        .cont1_key(cont1_key),
        .cont1_joy(cont1_joy),
        .cont1_trig(cont1_trig),
        .cont2_key(cont2_key),
        .cont2_joy(cont2_joy),
        .cont2_trig(cont2_trig),
        // Terminal interface
        .term_mem_valid(term_mem_valid),
        .term_mem_addr(term_mem_addr),
        .term_mem_wdata(term_mem_wdata),
        .term_mem_wstrb(term_mem_wstrb),
        .term_mem_rdata(term_mem_rdata),
        .term_mem_ready(term_mem_ready),
        // SDRAM interface - CDC handled via synch_3 in core_top
        .sdram_rd(cpu_sdram_rd),
        .sdram_wr(cpu_sdram_wr),
        .sdram_addr(cpu_sdram_addr),
        .sdram_wdata(cpu_sdram_wdata),
        .sdram_wstrb(cpu_sdram_wstrb),
        .sdram_burst_len(cpu_sdram_burst_len),
        .sdram_rdata(cpu_sdram_rdata),
        .sdram_busy(cpu_sdram_busy),
        .sdram_accepted(cpu_sdram_accepted),
        .sdram_rdata_valid(ram1_word_q_valid),
        // PSRAM interface (to psram_controller)
        .psram_rd(cpu_psram_rd),
        .psram_wr(cpu_psram_wr),
        .psram_addr(cpu_psram_addr),
        .psram_wdata(cpu_psram_wdata),
        .psram_wstrb(cpu_psram_wstrb),
        .psram_rdata(cpu_psram_rdata),
        .psram_busy(cpu_psram_busy),
        .psram_rdata_valid(cpu_psram_rdata_valid),
        // SRAM interface (to sram_controller)
        .sram_rd(cpu_sram_rd),
        .sram_wr(cpu_sram_wr),
        .sram_addr(cpu_sram_addr),
        .sram_wdata(cpu_sram_wdata),
        .sram_wstrb(cpu_sram_wstrb),
        .sram_rdata(cpu_sram_rdata),
        .sram_busy(cpu_sram_busy),
        .sram_q_valid(cpu_sram_q_valid),
        // Display control
        .display_mode(display_mode),
        .fb_display_addr(fb_display_addr),
        // Palette write interface
        .pal_wr(cpu_pal_wr),
        .pal_addr(cpu_pal_addr),
        .pal_data(cpu_pal_data),
        // Target dataslot interface
        .target_dataslot_read(cpu_target_dataslot_read),
        .target_dataslot_write(cpu_target_dataslot_write),
        .target_dataslot_openfile(cpu_target_dataslot_openfile),
        .target_dataslot_id(cpu_target_dataslot_id),
        .target_dataslot_slotoffset(cpu_target_dataslot_slotoffset),
        .target_dataslot_bridgeaddr(cpu_target_dataslot_bridgeaddr),
        .target_dataslot_length(cpu_target_dataslot_length),
        .target_buffer_param_struct(cpu_target_buffer_param_struct),
        .target_buffer_resp_struct(cpu_target_buffer_resp_struct),
        .target_dataslot_ack(target_dataslot_ack),
        .target_dataslot_done(target_dataslot_done),
        .target_dataslot_err(target_dataslot_err),
        // DMA peripheral register interface
        .dma_reg_wr(dma_reg_wr),
        .dma_reg_addr(dma_reg_addr),
        .dma_reg_wdata(dma_reg_wdata),
        .dma_reg_rdata(dma_reg_rdata),
        // SRAM fill register interface
        .sramfill_reg_wr(sramfill_reg_wr),
        .sramfill_reg_addr(sramfill_reg_addr),
        .sramfill_reg_wdata(sramfill_reg_wdata),
        .sramfill_reg_rdata(sramfill_reg_rdata),
        // Span rasterizer register interface
        .span_reg_wr(span_reg_wr),
        .span_reg_addr(span_reg_addr),
        .span_reg_wdata(span_reg_wdata),
        .span_reg_rdata(span_reg_rdata),
        // Alias Transform MAC register interface
        .atm_reg_wr(atm_reg_wr),
        .atm_reg_addr(atm_reg_addr),
        .atm_reg_wdata(atm_reg_wdata),
        .atm_reg_rdata(atm_reg_rdata),
        .atm_norm_wr(atm_norm_wr),
        .atm_norm_addr(atm_norm_addr),
        .atm_norm_wdata(atm_norm_wdata),
        .atm_busy(atm_busy),
        // Audio output interface
        .audio_sample_wr(audio_sample_wr),
        .audio_sample_data(audio_sample_data),
        .audio_fifo_level(audio_fifo_level),
        .audio_fifo_full(audio_fifo_full),
        // Link MMIO interface
        .link_reg_wr(link_reg_wr),
        .link_reg_rd(link_reg_rd),
        .link_reg_addr(link_reg_addr),
        .link_reg_wdata(link_reg_wdata),
        .link_reg_rdata(link_reg_rdata),
        // Colormap BRAM port B (for span rasterizer)
        .span_cmap_addr(span_cmap_addr),
        .span_cmap_rdata(span_cmap_rdata)
    );

    // DMA Clear/Blit peripheral
    dma_clear_blit dma (
        .clk(clk_cpu),
        .reset_n(reset_n),
        // CPU register interface (directly from cpu_system)
        .reg_wr(dma_reg_wr),
        .reg_addr(dma_reg_addr),
        .reg_wdata(dma_reg_wdata),
        .reg_rdata(dma_reg_rdata),
        // SDRAM word interface (to periph_sdram_mux)
        .sdram_rd(dma_sdram_rd),
        .sdram_wr(dma_sdram_wr),
        .sdram_addr(dma_sdram_addr),
        .sdram_wdata(dma_sdram_wdata),
        .sdram_wstrb(dma_sdram_wstrb),
        .sdram_rdata(ram1_word_q),
        .sdram_busy(ram1_word_busy | bridge_wr_active | bridge_rd_active),
        .sdram_rdata_valid(ram1_word_q_valid),
        // Status
        .active(dma_active)
    );

    // SRAM Fill Engine (z-buffer clear via SRAM)
    sram_fill sramfill0 (
        .clk(clk_cpu),
        .reset_n(reset_n),
        .reg_wr(sramfill_reg_wr),
        .reg_addr(sramfill_reg_addr),
        .reg_wdata(sramfill_reg_wdata),
        .reg_rdata(sramfill_reg_rdata),
        .word_wr(sramfill_sram_wr),
        .word_addr(sramfill_sram_addr),
        .word_data(sramfill_sram_wdata),
        .word_wstrb(sramfill_sram_wstrb),
        .word_busy(sramfill_sram_busy),
        .active(sramfill_active)
    );

    // Span Rasterizer peripheral
    span_rasterizer span (
        .clk(clk_cpu),
        .reset_n(reset_n),
        // CPU register interface (directly from cpu_system)
        .reg_wr(span_reg_wr),
        .reg_addr(span_reg_addr),
        .reg_wdata(span_reg_wdata),
        .reg_rdata(span_reg_rdata),
        // SDRAM word interface (to periph_sdram_mux)
        .sdram_rd(span_sdram_rd),
        .sdram_wr(span_sdram_wr),
        .sdram_addr(span_sdram_addr),
        .sdram_wdata(span_sdram_wdata),
        .sdram_wstrb(span_sdram_wstrb),
        .sdram_burst_len(span_sdram_burst_len),
        .sdram_rdata(ram1_word_q),
        .sdram_busy(ram1_word_busy | bridge_wr_active | bridge_rd_active),
        .sdram_rdata_valid(ram1_word_q_valid),
        // SRAM write interface (for z-span writes to SRAM z-buffer)
        .sram_wr(span_sram_wr),
        .sram_addr(span_sram_addr),
        .sram_wdata(span_sram_wdata),
        .sram_wstrb(span_sram_wstrb),
        .sram_busy(span_sram_busy),
        // Status
        .active(span_active),
        // Colormap BRAM interface (port B, read-only)
        .cmap_addr(span_cmap_addr),
        .cmap_rdata(span_cmap_rdata)
    );

    // Alias Transform MAC (register-only, no SDRAM)
    alias_transform_mac atm (
        .clk(clk_cpu),
        .reset_n(reset_n),
        .reg_wr(atm_reg_wr),
        .reg_addr(atm_reg_addr),
        .reg_wdata(atm_reg_wdata),
        .reg_rdata(atm_reg_rdata),
        .norm_wr(atm_norm_wr),
        .norm_addr(atm_norm_addr),
        .norm_wdata(atm_norm_wdata),
        .busy_o(atm_busy)
    );

    // Peripheral SDRAM mux (DMA + Span Rasterizer)
    periph_sdram_mux periph_mux (
        .clk(clk_cpu),
        // DMA port
        .dma_rd(dma_sdram_rd),
        .dma_wr(dma_sdram_wr),
        .dma_addr(dma_sdram_addr),
        .dma_wdata(dma_sdram_wdata),
        .dma_wstrb(dma_sdram_wstrb),
        .dma_active(dma_active),
        // Span rasterizer port
        .span_rd(span_sdram_rd),
        .span_wr(span_sdram_wr),
        .span_addr(span_sdram_addr),
        .span_wdata(span_sdram_wdata),
        .span_wstrb(span_sdram_wstrb),
        .span_burst_len(span_sdram_burst_len),
        .span_active(span_active),
        // Muxed output to SDRAM arbiter
        .mux_rd(periph_sdram_rd),
        .mux_wr(periph_sdram_wr),
        .mux_addr(periph_sdram_addr),
        .mux_wdata(periph_sdram_wdata),
        .mux_wstrb(periph_sdram_wstrb),
        .mux_burst_len(periph_sdram_burst_len),
        .mux_active(periph_active)
    );

    // Terminal display (40x30 characters, 320x240 pixels)
    wire [23:0] terminal_pixel_color;

    text_terminal terminal (
        .clk(clk_core_12288),
        .clk_cpu(clk_cpu),  // CPU clock for memory interface (95 MHz)
        .reset_n(reset_n),
        .pixel_x(visible_x),
        .pixel_y(visible_y),
        .pixel_color(terminal_pixel_color),
        .mem_valid(term_mem_valid),
        .mem_addr(term_mem_addr),
        .mem_wdata(term_mem_wdata),
        .mem_wstrb(term_mem_wstrb),
        .mem_rdata(term_mem_rdata),
        .mem_ready(term_mem_ready)
    );

    // Line start signal for video scanout (pulses when x_count == 0)
    reg line_start;
    always @(posedge clk_core_12288) begin
        line_start <= (x_count == 0);
    end

    // Video scanout from SDRAM framebuffer (8-bit indexed with hardware palette)
    wire [23:0] framebuffer_pixel_color;

    // Palette write signals from CPU
    wire        cpu_pal_wr;
    wire [7:0]  cpu_pal_addr;
    wire [23:0] cpu_pal_data;

    // SDRAM burst interface signals for video scanout
    wire        video_burst_rd;
    wire [24:0] video_burst_addr;
    wire [10:0] video_burst_len;
    wire        video_burst_32bit;
    wire [31:0] video_burst_data;
    wire        video_burst_data_valid;
    wire        video_burst_data_done;

    video_scanout_indexed scanout (
        // Video clock domain (12.288 MHz)
        .clk_video(clk_core_12288),
        .reset_n(reset_n),
        .x_count(x_count),
        .y_count(y_count),
        .line_start(line_start),
        .pixel_color(framebuffer_pixel_color),
        .fb_base_addr(fb_display_addr),  // 25-bit SDRAM 16-bit word address
        // SDRAM clock domain (110 MHz)
        .clk_sdram(clk_ram_controller),
        // SDRAM burst read interface
        .burst_rd(video_burst_rd),
        .burst_addr(video_burst_addr),
        .burst_len(video_burst_len),
        .burst_32bit(video_burst_32bit),
        .burst_data(video_burst_data),
        .burst_data_valid(video_burst_data_valid),
        .burst_data_done(video_burst_data_done),
        // Palette write interface (from CPU, same clock as SDRAM)
        .pal_wr(cpu_pal_wr),
        .pal_addr(cpu_pal_addr),
        .pal_data(cpu_pal_data)
    );

always @(posedge clk_core_12288 or negedge reset_n) begin

    if(~reset_n) begin

        x_count <= 0;
        y_count <= 0;

    end else begin
        vidout_de <= 0;
        vidout_skip <= 0;
        vidout_vs <= 0;
        vidout_hs <= 0;

        vidout_hs_1 <= vidout_hs;
        vidout_de_1 <= vidout_de;

        // x and y counters
        x_count <= x_count + 1'b1;
        if(x_count == VID_H_TOTAL-1) begin
            x_count <= 0;

            y_count <= y_count + 1'b1;
            if(y_count == VID_V_TOTAL-1) begin
                y_count <= 0;
            end
        end

        // generate sync
        if(x_count == 0 && y_count == 0) begin
            // sync signal in back porch
            // new frame
            vidout_vs <= 1;
            frame_count <= frame_count + 1'b1;
        end

        // we want HS to occur a bit after VS, not on the same cycle
        if(x_count == 3) begin
            // sync signal in back porch
            // new line
            vidout_hs <= 1;
        end

        // inactive screen areas are black
        vidout_rgb <= 24'h0;
        // generate active video
        if(x_count >= VID_H_BPORCH && x_count < VID_H_ACTIVE+VID_H_BPORCH) begin

            if(y_count >= VID_V_BPORCH && y_count < VID_V_ACTIVE+VID_V_BPORCH) begin
                // data enable. this is the active region of the line
                vidout_de <= 1;

                // Display mode: 0=terminal overlay, 1=framebuffer only
                if (display_mode) begin
                    // Framebuffer only mode
                    vidout_rgb <= framebuffer_pixel_color;
                end else begin
                    // Terminal overlay mode - white text overlays framebuffer
                    if (terminal_pixel_color == 24'hFFFFFF)
                        vidout_rgb <= terminal_pixel_color;
                    else
                        vidout_rgb <= framebuffer_pixel_color;
                end
            end
        end
    end
end




//
// Link MMIO peripheral (FIFO + synchronous SCK/SO/SI PHY)
//
link_mmio #(
    .CLK_HZ(100000000),
    .SCK_HZ(256000),
    .POLL_HZ(3000),
    .FIFO_DEPTH(256)
) link0 (
    .clk(clk_cpu),
    .reset_n(reset_n),

    .reg_wr(link_reg_wr),
    .reg_rd(link_reg_rd),
    .reg_addr(link_reg_addr),
    .reg_wdata(link_reg_wdata),
    .reg_rdata(link_reg_rdata),

    .link_si_i(link_si_i),
    .link_so_o(link_so_out),
    .link_so_oe(link_so_oe),
    .link_sck_i(link_sck_i),
    .link_sck_o(link_sck_out),
    .link_sck_oe(link_sck_oe),
    .link_sd_i(link_sd_i),
    .link_sd_o(link_sd_out),
    .link_sd_oe(link_sd_oe)
);

//
// Audio output (FIFO + I2S)
// CPU writes samples via MMIO, FIFO bridges to I2S at 48 kHz
//
audio_output audio_out (
    .clk_sys     (clk_cpu),
    .clk_audio   (clk_core_12288),
    .reset_n     (reset_n),

    .sample_wr   (audio_sample_wr),
    .sample_data (audio_sample_data),
    .fifo_level  (audio_fifo_level),
    .fifo_full   (audio_fifo_full),

    .audio_mclk  (audio_mclk),
    .audio_lrck  (audio_lrck),
    .audio_dac   (audio_dac)
);


///////////////////////////////////////////////


    wire    clk_core_12288;
    wire    clk_core_12288_90deg;
    wire    clk_cpu;            // CPU clock (95 MHz)
    wire    clk_ram_controller; // 95 MHz SDRAM controller clock
    wire    clk_ram_chip;       // 95 MHz SDRAM chip clock (phase shifted)

    wire    pll_core_locked;
    wire    pll_ram_locked;
    wire    pll_locked_all = pll_core_locked & pll_ram_locked;
    wire    pll_core_locked_s;
synch_3 s01(pll_locked_all, pll_core_locked_s, clk_74a);

mf_pllbase mp1 (
    .refclk         ( clk_74a ),
    .rst            ( 0 ),

    .outclk_0       ( clk_core_12288 ),
    .outclk_1       ( clk_core_12288_90deg ),

    .outclk_2       ( ),                    // 33 MHz (unused)
    .outclk_3       ( ),                    // 66 MHz (unused)
    .outclk_4       ( ),                    // 66 MHz (unused)

    .locked         ( pll_core_locked )
);

mf_pllram_133 mp_ram (
    .refclk         ( clk_74a ),
    .rst            ( 0 ),
    .outclk_0       ( clk_ram_controller ), // 95 MHz for SDRAM controller
    .outclk_1       ( clk_ram_chip ),       // 95 MHz for SDRAM chip (phase shifted)
    .locked         ( pll_ram_locked )
);

// CPU runs at same clock as SDRAM controller (no CDC needed)
// TODO: Implement proper CDC for split CPU/memory clocks
assign clk_cpu = clk_ram_controller;


// SDRAM controller
// Uses word interface for both bridge writes and CPU access

io_sdram isr0 (
    .controller_clk ( clk_ram_controller ),
    .chip_clk       ( clk_ram_chip ),
    .clk_90         ( clk_ram_chip ),  // Not used in io_sdram, tie to valid clock
    .reset_n        ( 1'b1 ), // Keep SDRAM controller active during APF-managed reset/load

    .phy_cke        ( dram_cke ),
    .phy_clk        ( dram_clk ),
    .phy_cas        ( dram_cas_n ),
    .phy_ras        ( dram_ras_n ),
    .phy_we         ( dram_we_n ),
    .phy_ba         ( dram_ba ),
    .phy_a          ( dram_a ),
    .phy_dq         ( dram_dq ),
    .phy_dqm        ( dram_dqm ),

    // Burst interface - used for video scanout
    .burst_rd           ( video_burst_rd ),
    .burst_addr         ( video_burst_addr ),
    .burst_len          ( video_burst_len ),
    .burst_32bit        ( video_burst_32bit ),
    .burst_data         ( video_burst_data ),
    .burst_data_valid   ( video_burst_data_valid ),
    .burst_data_done    ( video_burst_data_done ),

    // Burst write interface - not used
    .burstwr        ( 1'b0 ),
    .burstwr_addr   ( 25'b0 ),
    .burstwr_ready  ( ),
    .burstwr_strobe ( 1'b0 ),
    .burstwr_data   ( 16'b0 ),
    .burstwr_done   ( 1'b0 ),

    // Word interface - used for bridge writes and CPU access
    .word_rd    ( ram1_word_rd ),
    .word_wr    ( ram1_word_wr ),
    .word_addr  ( ram1_word_addr ),
    .word_data  ( ram1_word_data ),
    .word_wstrb ( ram1_word_wstrb ),
    .word_burst_len ( ram1_word_burst_len ),
    .word_q     ( ram1_word_q ),
    .word_busy  ( ram1_word_busy ),
    .word_q_valid ( ram1_word_q_valid )

);



endmodule
