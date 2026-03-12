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

// ============================================================
// Analogizer adapter (optional, directly controls cart port)
// ============================================================

//Pocket Menu settings
reg [31:0] analogizer_settings;
//wire [31:0] analogizer_settings_s;

reg analogizer_ena;
reg [3:0] analogizer_video_type;
reg [4:0] snac_game_cont_type /* synthesis keep */;
reg [3:0] snac_cont_assignment /* synthesis keep */;

//synch_3 #(.WIDTH(32)) sync_analogizer(analogizer_settings, analogizer_settings_s, clk_core_49152);

  //create aditional switch to blank Pocket screen.
  //assign video_rgb = (analogizer_video_type[3]) ? 24'h000000: video_rgb_reg;

always @(*) begin
  snac_game_cont_type   = analogizer_settings[4:0];
  snac_cont_assignment  = analogizer_settings[9:6];
  analogizer_video_type = analogizer_settings[13:10];
end 

//use PSX Dual Shock style left analog stick as directional pad
wire is_analog_input = (snac_game_cont_type == 5'h13);
// Interact variable: SNAC adapter type (bridge address 0xF0000000)
reg [31:0] analogizer_snac_type;
wire [15:0] snac_p1_btn;
wire [31:0] snac_p1_joy;
wire [15:0] snac_p2_btn;
wire [31:0] snac_p2_joy;
wire [15:0] snac_p3_btn;
wire [15:0] snac_p4_btn;

// Video Y/C Encoder settings
// Follows the Mike Simone Y/C encoder settings:
// https://github.com/MikeS11/MiSTerFPGA_YC_Encoder
// SET PAL and NTSC TIMING and pass through status bits. ** YC must be enabled in the qsf file **
wire [39:0] CHROMA_PHASE_INC;
wire [26:0] COLORBURST_RANGE;
wire [4:0] CHROMA_ADD;
wire [4:0] CHROMA_MULT;
wire PALFLAG;

parameter NTSC_REF = 3.579545;   
parameter PAL_REF = 4.43361875;

// Parameters to be modifed
parameter CLK_VIDEO_NTSC = 49.152; 
parameter CLK_VIDEO_PAL  = 49.152; 

localparam [39:0] NTSC_PHASE_INC = 40'd80073066196;  //print(round(3.579545 * 2**40 / 49.152)) 
localparam [39:0] PAL_PHASE_INC =  40'd99178372574; //print(round(4.43361875 * 2**40 / 49.152)) 

assign CHROMA_PHASE_INC = ((analogizer_video_type == 4'h4)|| (analogizer_video_type == 4'hC)) ? PAL_PHASE_INC : NTSC_PHASE_INC; 
assign PALFLAG = (analogizer_video_type == 4'h4) || (analogizer_video_type == 4'hC); 


// Directly pass analog_video_type=0 (ACCENT_ACCENT=ACCENT_ACCENT) to disable video output (SNAC only for now)
// Video output through the Analogizer can be wired up later if desired.
openFPGA_Pocket_Analogizer #(
    .MASTER_CLK_FREQ(49_152_000),
    .LINE_LENGTH(640)
) analogizer (
    .i_clk(clk_core_49152), //currently 50MHz
    .i_rst(~reset_n),
    .i_ena(1'b1),
    // Video interface (active but directly from our pipeline)
    .video_clk(clk_core_12288), ////currently 12.25MHz
    .analog_video_type(analogizer_video_type),       // 0 RGBS
    .R(vidout_rgb[23:16]),
    .G(vidout_rgb[15:8]),
    .B(vidout_rgb[7:0]),
    .Hblank(crt_hblank),
    .Vblank(crt_vblank),
    .BLANKn(crt_blankn),
    .Hsync(crt_hs),
    .Vsync(crt_vs),
    .Csync(crt_csync ),
    // Y/C encoder (unused)
    .CHROMA_PHASE_INC(CHROMA_PHASE_INC),
    .PALFLAG(PALFLAG),
    // Scandoubler (unused)
    .ce_pix(1'b1),
    .scandoubler(1'b0),
    .fx(3'd0), //0 disable, 1 scanlines 25%, 2 scanlines 50%, 3 scanlines 75%, 4 hq2x
    // SNAC controller interface
    .conf_AB(snac_game_cont_type >= 5'd16),  //0 conf. A(default), 1 conf. B (see graph above)
    .game_cont_type(snac_game_cont_type),
    .p1_btn_state(snac_p1_btn),
    .p1_joy_state(snac_p1_joy),
    .p2_btn_state(snac_p2_btn),
    .p2_joy_state(snac_p2_joy),
    .p3_btn_state(snac_p3_btn),
    .p4_btn_state(snac_p4_btn),
    // Rumble (unused)
    .i_VIB_SW1(2'b0),
    .i_VIB_DAT1(8'h0),
    .i_VIB_SW2(2'b0),
    .i_VIB_DAT2(8'h0),
    // Status
    .busy(),
    // Cartridge port (directly driven by Analogizer)
    .cart_tran_bank2(cart_tran_bank2),
    .cart_tran_bank2_dir(cart_tran_bank2_dir),
    .cart_tran_bank3(cart_tran_bank3),
    .cart_tran_bank3_dir(cart_tran_bank3_dir),
    .cart_tran_bank1(cart_tran_bank1),
    .cart_tran_bank1_dir(cart_tran_bank1_dir),
    .cart_tran_bank0(cart_tran_bank0),
    .cart_tran_bank0_dir(cart_tran_bank0_dir),
    .cart_tran_pin30(cart_tran_pin30),
    .cart_tran_pin30_dir(cart_tran_pin30_dir),
    .cart_pin30_pwroff_reset(cart_pin30_pwroff_reset),
    .cart_tran_pin31(cart_tran_pin31),
    .cart_tran_pin31_dir(cart_tran_pin31_dir),
    // Debug
    .DBG_TX(),
    .o_stb()
);

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
// CRAM0 CLK driven by PLL outclk_2 (105 MHz, phase-shifted) for sync burst
wire clk_cram0;  // declared near PLL, assigned to cram0_clk below
assign cram0_clk = clk_cram0;

// BCR init FSM signals
reg        bcr_config_en = 0;
reg [15:0] bcr_config_data = 0;
reg        bcr_bank_sel = 0;
reg        bcr_init_done = 0;

// Raw psram.sv busy (for BCR init FSM — bypasses word_busy)
wire        psram_raw_busy;
wire        psram_dbg_wait_seen;
wire [15:0] psram_dbg_wait_cycles;
wire [15:0] psram_dbg_burst_count;
wire [15:0] psram_dbg_stale_count;

// Sync burst read signals (psram_controller ↔ axi_psram_slave)
wire        psram_burst_rd;
wire [5:0]  psram_burst_len;
wire        psram_burst_rdata_valid;
wire [31:0] psram_burst_rdata;

psram_controller #(
    .CLOCK_SPEED(105.0)
) psram0 (
    .clk(clk_ram_controller),
    .reset_n(reset_n_apf),  // Use raw reset, not bcr_init_done-gated reset

    // Muxed word interface (bridge or CPU)
    .word_rd(psram_mux_rd),
    .word_wr(psram_mux_wr),
    .word_addr(psram_mux_addr),
    .word_data(psram_mux_wdata),
    .word_wstrb(psram_mux_wstrb),
    .word_q(psram_mux_rdata),
    .word_busy(psram_mux_busy),
    .word_q_valid(psram_mux_rdata_valid),

    // BCR configuration (from init FSM)
    .config_en(bcr_config_en),
    .config_data(bcr_config_data),
    .config_bank_sel(bcr_bank_sel),

    // Sync burst read (from axi_psram_slave)
    .burst_rd(psram_burst_rd),
    .burst_len(psram_burst_len),
    .burst_rdata_valid(psram_burst_rdata_valid),
    .burst_rdata(psram_burst_rdata),

    // Raw psram.sv busy (for BCR init FSM)
    .raw_busy(psram_raw_busy),

    // Debug pass-through
    .dbg_wait_seen(psram_dbg_wait_seen),
    .dbg_wait_cycles(psram_dbg_wait_cycles),
    .dbg_burst_count(psram_dbg_burst_count),
    .dbg_stale_count(psram_dbg_stale_count),

    // Physical PSRAM signals (cram0_clk driven by PLL, not psram.sv)
    .cram_a(cram0_a),
    .cram_dq(cram0_dq),
    .cram_wait(cram0_wait),
    .cram_adv_n(cram0_adv_n),
    .cram_cre(cram0_cre),
    .cram_ce0_n(cram0_ce0_n),
    .cram_ce1_n(cram0_ce1_n),
    .cram_oe_n(cram0_oe_n),
    .cram_we_n(cram0_we_n),
    .cram_ub_n(cram0_ub_n),
    .cram_lb_n(cram0_lb_n)
);

// CRAM1 unused — tie off all outputs
assign cram1_a     = 6'd0;
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

// ============================================
// BCR init FSM — configure CRAM0 for synchronous burst mode
// Writes BCR 0x645F to both CE0# and CE1# dies after PLL lock.
// BCR 0x645F = sync mode, FIXED latency code 4, WAIT during delay, continuous burst.
// Bit 8 = 0: WAIT asserted DURING delay (not look-ahead). Matches psram.sv
// FSM which gates reads on !cram_wait (HIGH = invalid, LOW = valid).
// Code 4 required at 105 MHz (code 3 rated ≤104 MHz).
// Must complete before CPU reset deasserts (gated by bcr_init_done).
// ============================================
localparam BCR_VALUE = 16'h641F;

localparam [3:0] BCR_IDLE       = 4'd0;
localparam [3:0] BCR_CE0_START  = 4'd1;
localparam [3:0] BCR_CE0_BUSY   = 4'd2;  // Wait for busy to assert
localparam [3:0] BCR_CE0_WAIT   = 4'd3;  // Wait for busy to deassert
localparam [3:0] BCR_CE1_START  = 4'd4;
localparam [3:0] BCR_CE1_BUSY   = 4'd5;
localparam [3:0] BCR_CE1_WAIT   = 4'd6;
localparam [3:0] BCR_DONE       = 4'd7;

reg [3:0] bcr_state = BCR_IDLE;

always @(posedge clk_ram_controller) begin
    // Default: clear single-cycle config_en pulse
    bcr_config_en <= 1'b0;

    case (bcr_state)
        BCR_IDLE: begin
            bcr_init_done <= 1'b0;
            // Wait for PLL lock AND bridge reset release before configuring PSRAM.
            // psram_controller is held in reset by reset_n_apf — if we start
            // before that deasserts, psram_raw_busy never rises and we deadlock.
            if (pll_ram_locked && reset_n_apf)
                bcr_state <= BCR_CE0_START;
        end

        BCR_CE0_START: begin
            if (!psram_raw_busy) begin
                bcr_config_en <= 1'b1;
                bcr_config_data <= BCR_VALUE;
                bcr_bank_sel <= 1'b0;  // CE0#
                bcr_state <= BCR_CE0_BUSY;
            end
        end

        BCR_CE0_BUSY: begin
            // Wait for psram.sv to see config_en and go busy
            if (psram_raw_busy)
                bcr_state <= BCR_CE0_WAIT;
        end

        BCR_CE0_WAIT: begin
            // Wait for config write to complete
            if (!psram_raw_busy)
                bcr_state <= BCR_CE1_START;
        end

        BCR_CE1_START: begin
            if (!psram_raw_busy) begin
                bcr_config_en <= 1'b1;
                bcr_config_data <= BCR_VALUE;
                bcr_bank_sel <= 1'b1;  // CE1#
                bcr_state <= BCR_CE1_BUSY;
            end
        end

        BCR_CE1_BUSY: begin
            if (psram_raw_busy)
                bcr_state <= BCR_CE1_WAIT;
        end

        BCR_CE1_WAIT: begin
            if (!psram_raw_busy)
                bcr_state <= BCR_DONE;
        end

        BCR_DONE: begin
            bcr_init_done <= 1'b1;
            // Stay here permanently
        end

        default: bcr_state <= BCR_IDLE;
    endcase
end

// SDRAM word interface signals (to io_sdram)
// Driven by one-cycle pulse adapter (see below)
reg             ram1_word_rd;
reg             ram1_word_wr;
reg     [23:0]  ram1_word_addr;
reg     [31:0]  ram1_word_data;
reg     [3:0]   ram1_word_wstrb;
reg     [3:0]   ram1_word_burst_len;
wire    [31:0]  ram1_word_q;
wire            ram1_word_busy;
wire            ram1_word_q_valid;

// axi_sdram_slave word-level outputs (held signals, need pulse conversion)
wire            sdram_slave_rd;
wire            sdram_slave_wr;
wire    [23:0]  sdram_slave_addr;
wire    [31:0]  sdram_slave_wdata;
wire    [3:0]   sdram_slave_wstrb;
wire    [3:0]   sdram_slave_burst_len;

// CPU AXI4 master → axi_sdram_slave
wire        cpu_m_sdram_arvalid;
wire        cpu_m_sdram_arready;
wire [31:0] cpu_m_sdram_araddr;
wire [7:0]  cpu_m_sdram_arlen;
wire        cpu_m_sdram_rvalid;
wire [31:0] cpu_m_sdram_rdata;
wire [1:0]  cpu_m_sdram_rresp;
wire        cpu_m_sdram_rlast;
wire        cpu_m_sdram_awvalid;
wire        cpu_m_sdram_awready;
wire [31:0] cpu_m_sdram_awaddr;
wire [7:0]  cpu_m_sdram_awlen;
wire        cpu_m_sdram_wvalid;
wire        cpu_m_sdram_wready;
wire [31:0] cpu_m_sdram_wdata;
wire [3:0]  cpu_m_sdram_wstrb;
wire        cpu_m_sdram_wlast;
wire        cpu_m_sdram_bvalid;
wire [1:0]  cpu_m_sdram_bresp;

// CPU AXI4 master → axi_psram_slave
wire        cpu_m_psram_arvalid;
wire        cpu_m_psram_arready;
wire [31:0] cpu_m_psram_araddr;
wire [7:0]  cpu_m_psram_arlen;
wire        cpu_m_psram_rvalid;
wire [31:0] cpu_m_psram_rdata;
wire [1:0]  cpu_m_psram_rresp;
wire        cpu_m_psram_rlast;
wire        cpu_m_psram_awvalid;
wire        cpu_m_psram_awready;
wire [31:0] cpu_m_psram_awaddr;
wire [7:0]  cpu_m_psram_awlen;
wire        cpu_m_psram_wvalid;
wire        cpu_m_psram_wready;
wire [31:0] cpu_m_psram_wdata;
wire [3:0]  cpu_m_psram_wstrb;
wire        cpu_m_psram_wlast;
wire        cpu_m_psram_bvalid;
wire [1:0]  cpu_m_psram_bresp;

// axi_psram_slave → PSRAM mux (word-level, same names as before)
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

// DMA status
wire        dma_active;

// Span rasterizer register interface (between cpu_system and span_rasterizer)
wire        span_reg_wr;
wire [5:0]  span_reg_addr;
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
wire [10:0] audio_fifo_level;
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


// Span rasterizer colormap BRAM interface (port B, through axi_periph_slave)
wire [11:0] span_cmap_addr;
wire [31:0] span_cmap_rdata;

// Span rasterizer status
wire        span_active;
wire        span_fifo_full;

// CPU AXI4 master → axi_periph_slave (local peripherals)
wire        cpu_m_local_arvalid;
wire        cpu_m_local_arready;
wire [31:0] cpu_m_local_araddr;
wire [7:0]  cpu_m_local_arlen;
wire        cpu_m_local_rvalid;
wire [31:0] cpu_m_local_rdata;
wire [1:0]  cpu_m_local_rresp;
wire        cpu_m_local_rlast;
wire        cpu_m_local_awvalid;
wire        cpu_m_local_awready;
wire [31:0] cpu_m_local_awaddr;
wire [7:0]  cpu_m_local_awlen;
wire        cpu_m_local_wvalid;
wire        cpu_m_local_wready;
wire [31:0] cpu_m_local_wdata;
wire [3:0]  cpu_m_local_wstrb;
wire        cpu_m_local_wlast;
wire        cpu_m_local_bvalid;
wire [1:0]  cpu_m_local_bresp;

// Span AXI4 master (from span_rasterizer to axi_sdram_arbiter M0)
wire        span_m_arvalid, span_m_arready;
wire [31:0] span_m_araddr;
wire [7:0]  span_m_arlen;
wire        span_m_rvalid, span_m_rlast;
wire [31:0] span_m_rdata;
wire [1:0]  span_m_rresp;
wire        span_m_awvalid, span_m_awready;
wire [31:0] span_m_awaddr;
wire [7:0]  span_m_awlen;
wire        span_m_wvalid, span_m_wready, span_m_wlast;
wire [31:0] span_m_wdata;
wire [3:0]  span_m_wstrb;
wire        span_m_bvalid;
wire [1:0]  span_m_bresp;

// DMA AXI4 master (from dma_clear_blit to axi_sdram_arbiter M1)
wire        dma_m_arvalid, dma_m_arready;
wire [31:0] dma_m_araddr;
wire [7:0]  dma_m_arlen;
wire        dma_m_rvalid, dma_m_rlast;
wire [31:0] dma_m_rdata;
wire [1:0]  dma_m_rresp;
wire        dma_m_awvalid, dma_m_awready;
wire [31:0] dma_m_awaddr;
wire [7:0]  dma_m_awlen;
wire        dma_m_wvalid, dma_m_wready, dma_m_wlast;
wire [31:0] dma_m_wdata;
wire [3:0]  dma_m_wstrb;
wire        dma_m_bvalid;
wire [1:0]  dma_m_bresp;

// AXI4 arbiter output → axi_sdram_slave
wire        arb_s_arvalid, arb_s_arready;
wire [31:0] arb_s_araddr;
wire [7:0]  arb_s_arlen;
wire        arb_s_rvalid, arb_s_rlast;
wire [31:0] arb_s_rdata;
wire [1:0]  arb_s_rresp;
wire        arb_s_awvalid, arb_s_awready;
wire [31:0] arb_s_awaddr;
wire [7:0]  arb_s_awlen;
wire        arb_s_wvalid, arb_s_wready, arb_s_wlast;
wire [31:0] arb_s_wdata;
wire [3:0]  arb_s_wstrb;
wire        arb_s_bvalid;
wire [1:0]  arb_s_bresp;

// Bridge AXI4 master (from axi_bridge_master to axi_sdram_arbiter M3)
wire        bridge_m_arvalid, bridge_m_arready;
wire [31:0] bridge_m_araddr;
wire [7:0]  bridge_m_arlen;
wire        bridge_m_rvalid, bridge_m_rlast;
wire [31:0] bridge_m_rdata;
wire [1:0]  bridge_m_rresp;
wire        bridge_m_awvalid, bridge_m_awready;
wire [31:0] bridge_m_awaddr;
wire [7:0]  bridge_m_awlen;
wire        bridge_m_wvalid, bridge_m_wready, bridge_m_wlast;
wire [31:0] bridge_m_wdata;
wire [3:0]  bridge_m_wstrb;
wire        bridge_m_bvalid;
wire [1:0]  bridge_m_bresp;
wire        bridge_m_idle;
wire        bridge_m_wr_idle;
wire [31:0] bridge_axi_rd_data;  // Read data from axi_bridge_master
wire        bridge_axi_rd_done;  // Read done pulse from axi_bridge_master

// ============================================================
// Z-buffer in physical SRAM chip + Fill Engine + 3-way Arbitration Mux
// Priority: CPU > Span rasterizer > sram_fill
// ============================================================

// SRAM controller for physical SRAM chip (z-buffer)
wire [15:0] sram_dq_out;
wire [15:0] sram_dq_in;
wire        sram_dq_oe;
assign sram_dq    = sram_dq_oe ? sram_dq_out : 16'hZZZZ;
assign sram_dq_in = sram_dq;

sram_controller #(.WAIT_CYCLES(5)) sram_zbuf (
    .clk(clk_ram_controller),
    .reset_n(reset_n),
    .word_rd(sram_ctrl_rd),
    .word_wr(sram_ctrl_wr),
    .word_addr(sram_ctrl_addr),
    .word_data(sram_ctrl_wdata),
    .word_wstrb(sram_ctrl_wstrb),
    .word_q(sram_ctrl_q),
    .word_busy(sram_ctrl_busy),
    .word_q_valid(sram_ctrl_q_valid),
    .sram_a(sram_a),
    .sram_dq_out(sram_dq_out),
    .sram_dq_in(sram_dq_in),
    .sram_dq_oe(sram_dq_oe),
    .sram_oe_n(sram_oe_n),
    .sram_we_n(sram_we_n),
    .sram_ub_n(sram_ub_n),
    .sram_lb_n(sram_lb_n)
);

// Z-buffer controller word interface (driven by sram_zbuf above)
wire        sram_ctrl_rd;
wire        sram_ctrl_wr;
wire [21:0] sram_ctrl_addr;
wire [31:0] sram_ctrl_wdata;
wire [3:0]  sram_ctrl_wstrb;
wire [31:0] sram_ctrl_q;
wire        sram_ctrl_busy;
wire        sram_ctrl_q_valid;

// CPU SRAM interface (from axi_periph_slave)
wire        cpu_sram_rd;
wire        cpu_sram_wr;
wire [21:0] cpu_sram_addr;
wire [31:0] cpu_sram_wdata;
wire [3:0]  cpu_sram_wstrb;
wire        cpu_sram_busy;
wire [31:0] cpu_sram_q;
wire        cpu_sram_q_valid;

// Span rasterizer SRAM interface (z-buffer reads + writes)
wire        span_sram_wr;
wire        span_sram_rd;
wire [21:0] span_sram_addr;
wire [31:0] span_sram_wdata;
wire [3:0]  span_sram_wstrb;
wire        span_sram_busy;
wire [31:0] span_sram_rdata;
wire        span_sram_rdata_valid;

// sram_fill register interface (from axi_periph_slave)
wire        sramfill_reg_wr;
wire [4:0]  sramfill_reg_addr;
wire [31:0] sramfill_reg_wdata;
wire [31:0] sramfill_reg_rdata;

// Scanline engine register interface (from axi_periph_slave)
wire        scanline_reg_wr;
wire        scanline_reg_rd;
wire [5:0]  scanline_reg_addr;
wire [31:0] scanline_reg_wdata;
wire [31:0] scanline_reg_rdata;

// sram_fill word interface (to SRAM mux)
wire        fill_sram_wr;
wire [15:0] fill_sram_addr;
wire [31:0] fill_sram_data;
wire [3:0]  fill_sram_wstrb;
wire        fill_sram_busy;
wire        fill_active;

sram_fill sram_fill_inst (
    .clk(clk_ram_controller),
    .reset_n(reset_n),
    .reg_wr(sramfill_reg_wr),
    .reg_addr(sramfill_reg_addr),
    .reg_wdata(sramfill_reg_wdata),
    .reg_rdata(sramfill_reg_rdata),
    .word_wr(fill_sram_wr),
    .word_addr(fill_sram_addr),
    .word_data(fill_sram_data),
    .word_wstrb(fill_sram_wstrb),
    .word_busy(fill_sram_busy),
    .active(fill_active)
);

// calc_gradients replaces scanline_engine — FP32 D_CalcGradients in hardware
calc_gradients calc_gradients_inst (
    .clk(clk_ram_controller),
    .reset_n(reset_n),
    .reg_wr(scanline_reg_wr),
    .reg_rd(scanline_reg_rd),
    .reg_addr(scanline_reg_addr),
    .reg_wdata(scanline_reg_wdata),
    .reg_rdata(scanline_reg_rdata),
    .busy_o()
);

// 3-way SRAM word arbitration mux (combinational priority)
// Priority: CPU > Span rasterizer > sram_fill
wire cpu_sram_req  = cpu_sram_rd | cpu_sram_wr;
wire span_sram_req = span_sram_wr | span_sram_rd;

assign sram_ctrl_rd    = cpu_sram_req  ? cpu_sram_rd  :
                          span_sram_rd  ? 1'b1         : 1'b0;
assign sram_ctrl_wr    = cpu_sram_req  ? cpu_sram_wr  :
                          span_sram_req ? span_sram_wr :
                          fill_sram_wr  ? 1'b1         : 1'b0;
assign sram_ctrl_addr  = cpu_sram_req  ? cpu_sram_addr  :
                          span_sram_req ? span_sram_addr :
                          fill_sram_wr  ? {6'd0, fill_sram_addr} : 22'd0;
assign sram_ctrl_wdata = cpu_sram_req  ? cpu_sram_wdata :
                          span_sram_req ? span_sram_wdata :
                          fill_sram_wr  ? fill_sram_data : 32'd0;
assign sram_ctrl_wstrb = cpu_sram_req  ? cpu_sram_wstrb :
                          span_sram_req ? span_sram_wstrb :
                          fill_sram_wr  ? fill_sram_wstrb : 4'b0;

// Per-source busy: higher priority blocks lower
assign cpu_sram_busy    = sram_ctrl_busy;
assign cpu_sram_q       = sram_ctrl_q;
assign span_sram_busy   = sram_ctrl_busy | cpu_sram_req;
assign fill_sram_busy   = sram_ctrl_busy | cpu_sram_req | span_sram_req;

// Track SRAM read source for response routing (CPU vs span rasterizer)
reg sram_rd_is_span;
always @(posedge clk_ram_controller or negedge reset_n) begin
    if (!reset_n)
        sram_rd_is_span <= 1'b0;
    else if (sram_ctrl_q_valid)
        sram_rd_is_span <= 1'b0;
    else if (!sram_ctrl_busy && sram_ctrl_rd && !cpu_sram_req)
        sram_rd_is_span <= 1'b1;
end

assign cpu_sram_q_valid       = sram_ctrl_q_valid & !sram_rd_is_span;
assign span_sram_rdata        = sram_ctrl_q;
assign span_sram_rdata_valid  = sram_ctrl_q_valid & sram_rd_is_span;

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
    32'b000000xx_xxxxxxxx_xxxxxxxx_xxxxxxxx: begin
        // SDRAM mapped at 0x00000000 - 0x03FFFFFF (64MB)
        bridge_rd_data <= bridge_rd_data_captured;
    end
    32'hF7000000: begin 
        bridge_rd_data <= {analogizer_settings[7:0],analogizer_settings[15:8],analogizer_settings[23:16],analogizer_settings[31:24]};
      end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
        default: begin
        bridge_rd_data <= 0;
    end
    endcase
end

// Interact variable writes (SNAC adapter type + game mode from APF menu/instance)
// memory_writes must use 0xF0xxxxxx addresses (bridge clk_74a domain, not SDRAM path).
// NeoGeo core uses the same pattern for per-game configuration.
reg [31:0] game_mode_reg;     // 0xF0000010: 0=base, 1=game, 2=hipnotic, 3=rogue
reg [31:0] game_name_0_reg;   // 0xF0000014: mod name bytes 0-3
reg [31:0] game_name_1_reg;   // 0xF0000018: mod name bytes 4-7
reg [31:0] game_name_2_reg;   // 0xF000001C: mod name bytes 8-11

// Byte-swap bridge data for game mode regs: APF memory_writes are big-endian
wire [31:0] bridge_wr_data_le = {bridge_wr_data[7:0], bridge_wr_data[15:8],
                                  bridge_wr_data[23:16], bridge_wr_data[31:24]};

always @(posedge clk_74a) begin
    if (bridge_wr && bridge_addr[31:24] == 8'hF0) begin
        case (bridge_addr[7:0])
            8'h00: analogizer_snac_type <= bridge_wr_data;
            8'h10: game_mode_reg   <= bridge_wr_data_le;
            8'h14: game_name_0_reg <= bridge_wr_data_le;
            8'h18: game_name_1_reg <= bridge_wr_data_le;
            8'h1C: game_name_2_reg <= bridge_wr_data_le;
            default: ;
        endcase
    end
end

// ============================================================
// Bridge SDRAM Write CDC: dcfifo (clk_74a -> clk_ram_controller)
// ============================================================
// Bridge SDRAM writes buffered via dcfifo for CDC (clk_74a -> clk_ram_controller).
// FIFO entry: {bridge_addr[25:2], bridge_wr_data[31:0]} = 56 bits.
// Writes on the bridge bus are pulse-based (no backpressure), so we stage them
// through a small clk_74a skid queue before pushing into dcfifo.

localparam integer BRIDGE_WR_SKID_DEPTH = 4;
wire        bridge_sdram_wr = bridge_wr && (bridge_addr[31:26] == 6'b000000);

wire        bridge_wr_fifo_wrreq;
wire        bridge_wr_fifo_full;
wire [55:0] bridge_wr_fifo_wdata;
wire        bridge_wr_fifo_drain;  // Driven by axi_bridge_master fifo_rdreq
wire        bridge_wr_fifo_empty;
wire [55:0] bridge_wr_fifo_q;
reg [55:0]  bridge_wr_skid_data [0:BRIDGE_WR_SKID_DEPTH-1];
reg [1:0]   bridge_wr_skid_wrptr;
reg [1:0]   bridge_wr_skid_rdptr;
reg [2:0]   bridge_wr_skid_count;
wire        bridge_wr_skid_empty = (bridge_wr_skid_count == 0);
wire        bridge_wr_skid_nonempty_74a = !bridge_wr_skid_empty;
wire        bridge_wr_skid_pop = !bridge_wr_skid_empty && !bridge_wr_fifo_full;
wire [55:0] bridge_wr_skid_head =
            (bridge_wr_skid_rdptr == 2'd0) ? bridge_wr_skid_data[0] :
            (bridge_wr_skid_rdptr == 2'd1) ? bridge_wr_skid_data[1] :
            (bridge_wr_skid_rdptr == 2'd2) ? bridge_wr_skid_data[2] :
                                             bridge_wr_skid_data[3];
wire        bridge_wr_skid_push = bridge_sdram_wr;
wire        bridge_wr_skid_has_space = (bridge_wr_skid_count != 3'd4);
wire        bridge_wr_skid_push_ok = bridge_wr_skid_push &&
                                     (bridge_wr_skid_has_space || bridge_wr_skid_pop);
assign bridge_wr_fifo_wrreq = bridge_wr_skid_pop;
assign bridge_wr_fifo_wdata = bridge_wr_skid_head;

always @(posedge clk_74a) begin
    if (!reset_n_apf) begin
        bridge_wr_skid_wrptr <= 2'd0;
        bridge_wr_skid_rdptr <= 2'd0;
        bridge_wr_skid_count <= 3'd0;
    end else begin
        if (bridge_wr_skid_pop) begin
            bridge_wr_skid_rdptr <= bridge_wr_skid_rdptr + 2'd1;
        end

        if (bridge_wr_skid_push_ok) begin
            case (bridge_wr_skid_wrptr)
                2'd0: bridge_wr_skid_data[0] <= {bridge_addr[25:2], bridge_wr_data[31:0]};
                2'd1: bridge_wr_skid_data[1] <= {bridge_addr[25:2], bridge_wr_data[31:0]};
                2'd2: bridge_wr_skid_data[2] <= {bridge_addr[25:2], bridge_wr_data[31:0]};
                default: bridge_wr_skid_data[3] <= {bridge_addr[25:2], bridge_wr_data[31:0]};
            endcase
            bridge_wr_skid_wrptr <= bridge_wr_skid_wrptr + 2'd1;
        end

        case ({bridge_wr_skid_push_ok, bridge_wr_skid_pop})
            2'b10: bridge_wr_skid_count <= bridge_wr_skid_count + 3'd1;
            2'b01: bridge_wr_skid_count <= bridge_wr_skid_count - 3'd1;
            default: ;
        endcase
    end
end

dcfifo bridge_wr_fifo (
    .wrclk   (clk_74a),
    .wrreq   (bridge_wr_fifo_wrreq),
    .data    (bridge_wr_fifo_wdata),
    .wrfull  (bridge_wr_fifo_full),
    .rdclk   (clk_ram_controller),
    .rdreq   (bridge_wr_fifo_drain),
    .q       (bridge_wr_fifo_q),
    .rdempty (bridge_wr_fifo_empty),
    .aclr    (1'b0),
    .wrusedw (),
    .wrempty (),
    .rdfull  (),
    .rdusedw ()
);
defparam bridge_wr_fifo.intended_device_family = "Cyclone V",
    bridge_wr_fifo.lpm_numwords  = 512,
    bridge_wr_fifo.lpm_showahead = "ON",
    bridge_wr_fifo.lpm_type      = "dcfifo",
    bridge_wr_fifo.lpm_width     = 56,
    bridge_wr_fifo.lpm_widthu    = 9,
    bridge_wr_fifo.overflow_checking  = "ON",
    bridge_wr_fifo.underflow_checking = "ON",
    bridge_wr_fifo.rdsync_delaypipe   = 5,
    bridge_wr_fifo.wrsync_delaypipe   = 5,
    bridge_wr_fifo.use_eab       = "ON";

// Synchronize skid-queue nonempty flag into RAM clock domain.
reg [2:0] bridge_wr_skid_nonempty_sync;
always @(posedge clk_ram_controller) begin
    bridge_wr_skid_nonempty_sync <= {bridge_wr_skid_nonempty_sync[1:0], bridge_wr_skid_nonempty_74a};
end
wire bridge_wr_skid_nonempty = bridge_wr_skid_nonempty_sync[2];

// Bridge writes fully complete: skid empty and bridge master has no writes in flight.
wire bridge_wr_idle = !bridge_wr_skid_nonempty && bridge_m_wr_idle;

// Bridge DMA active tracking: tracks dataslot read/write DMA completion.
// Set when CPU triggers a dataslot read/write, cleared when done + writes drained.
// No longer blocks CPU/span — the AXI4 arbiter handles serialization.
reg bridge_dma_active;
reg cpu_ds_read_prev, cpu_ds_write_prev, cpu_ds_open_prev;
reg [2:0] ds_done_ram_sync;  // synchronize target_dataslot_done to 100 MHz
reg [9:0] ds_done_quiet_count;
reg       ds_done_quiet_reached;
reg [7:0] ds_done_blanking;       // blanking counter: ignore DONE during this period
localparam [9:0] DS_DONE_QUIET_CYCLES = 10'd1023;  // ~10 us @ 100 MHz quiet window
// Blanking period: after cpu_ds_start, ignore DONE for this many cycles.
// Gives bridge time to process new command and clear stale DONE.
// Worst-case: synch_3(3 clk_74a) + edge_det(1) + IDLE(1) + DATASLOTOP(1) = 6 clk_74a
//   = ~8 clk_100MHz + ds_done_ram_sync(3) = ~11 cycles.  Use 128 for safety margin.
localparam [7:0] DS_DONE_BLANKING_CYCLES = 8'd128;
wire cpu_ds_read_start = cpu_target_dataslot_read && !cpu_ds_read_prev;
wire cpu_ds_write_start = cpu_target_dataslot_write && !cpu_ds_write_prev;
wire cpu_ds_open_start = cpu_target_dataslot_openfile && !cpu_ds_open_prev;
wire cpu_ds_start = cpu_ds_read_start || cpu_ds_write_start || cpu_ds_open_start;
wire ds_done_blanking_active = (ds_done_blanking != 8'd0);
wire target_dataslot_done_safe = ds_done_ram_sync[2] && ds_done_quiet_reached;
always @(posedge clk_ram_controller) begin
    cpu_ds_read_prev <= cpu_target_dataslot_read;
    cpu_ds_write_prev <= cpu_target_dataslot_write;
    cpu_ds_open_prev <= cpu_target_dataslot_openfile;

    if (!reset_n_apf) begin
        bridge_dma_active <= 1'b0;
        ds_done_ram_sync <= 3'b000;
        ds_done_quiet_count <= 10'd0;
        ds_done_quiet_reached <= 1'b0;
        ds_done_blanking <= 8'd0;
    end else begin
        ds_done_ram_sync <= {ds_done_ram_sync[1:0], target_dataslot_done};

        // Blanking countdown
        if (ds_done_blanking != 8'd0)
            ds_done_blanking <= ds_done_blanking - 8'd1;

        if (cpu_ds_start) begin
            // New command: start blanking period to reject stale DONE.
            // Unlike the old ds_done_seen_low approach, we do NOT force the sync
            // chain to 000 — that created an artificial "low" at [2] which
            // false-armed the seen_low guard.  Instead, we let the sync chain
            // run naturally and simply ignore its output during blanking.
            ds_done_quiet_count <= 10'd0;
            ds_done_quiet_reached <= 1'b0;
            ds_done_blanking <= DS_DONE_BLANKING_CYCLES;

            // Bridge DMA activity only applies to read/write transfers.
            if (cpu_ds_read_start || cpu_ds_write_start)
                bridge_dma_active <= 1'b1;
        end else if (!ds_done_blanking_active) begin
            // Blanking expired: now monitor DONE + quiet window normally.
            // By this time, the bridge has processed the new command and
            // cleared stale target_dataslot_done.  The sync chain reflects
            // the genuine state.
            if (ds_done_ram_sync[2]) begin
                if (bridge_wr_idle) begin
                    if (!ds_done_quiet_reached) begin
                        ds_done_quiet_count <= ds_done_quiet_count + 10'd1;
                        if (ds_done_quiet_count == DS_DONE_QUIET_CYCLES - 10'd1)
                            ds_done_quiet_reached <= 1'b1;
                    end
                end else begin
                    ds_done_quiet_count <= 10'd0;
                    ds_done_quiet_reached <= 1'b0;
                end
            end else begin
                ds_done_quiet_count <= 10'd0;
                ds_done_quiet_reached <= 1'b0;
            end

            if (bridge_dma_active && target_dataslot_done_safe)
                bridge_dma_active <= 1'b0;
        end
    end
end

// Bridge SDRAM read and PSRAM write still use handshake CDC
reg [31:0] bridge_addr_captured;
reg [31:0] bridge_wr_data_captured;
reg bridge_sdram_rd;
reg bridge_psram_wr;  // Bridge write to PSRAM
reg [31:0] bridge_addr_ram_clk;
reg bridge_rd_done;  // Feedback to 74a domain
reg bridge_rd_done_sync1, bridge_rd_done_sync2;
reg [31:0] bridge_rd_data_captured;  // Data captured in clk_ram_controller domain

// Capture bridge signals in clk_74a domain
// SDRAM writes are staged through bridge_wr_skid -> dcfifo (no source backpressure)
// SDRAM reads and PSRAM writes still use handshake CDC
always @(posedge clk_74a) begin
    // Synchronize done signals back from RAM controller clock
    bridge_rd_done_sync1 <= bridge_rd_done;
    bridge_rd_done_sync2 <= bridge_rd_done_sync1;
    bridge_psram_wr_done_sync1 <= bridge_psram_wr_done;
    bridge_psram_wr_done_sync2 <= bridge_psram_wr_done_sync1;

    // Clear the request when done is seen
    if (bridge_rd_done_sync2) bridge_sdram_rd <= 0;
    if (bridge_psram_wr_done_sync2) bridge_psram_wr <= 0;

    // PSRAM writes (handshake CDC)
    if (!bridge_psram_wr && bridge_wr && bridge_addr[31:24] == 8'h20) begin
        bridge_psram_wr <= 1;
        bridge_addr_captured <= bridge_addr;
        bridge_wr_data_captured <= bridge_wr_data;
    end

    // SDRAM reads (handshake CDC)
    if (!bridge_sdram_rd && bridge_rd) begin
        casex(bridge_addr[31:24])
        8'b000000xx: begin
            bridge_sdram_rd <= 1;
            bridge_addr_captured <= bridge_addr;
        end
        endcase
    end
end

// 4-stage synchronizer for bridge reads and PSRAM writes
// (SDRAM writes go through dcfifo, no sync chain needed)
reg bridge_rd_sync1, bridge_rd_sync2, bridge_rd_sync3, bridge_rd_sync4;
reg bridge_psram_wr_sync1, bridge_psram_wr_sync2, bridge_psram_wr_sync3, bridge_psram_wr_sync4;
reg bridge_psram_wr_done, bridge_psram_wr_done_sync1, bridge_psram_wr_done_sync2;
reg [31:0] bridge_psram_addr_ram_clk;
reg [31:0] bridge_psram_wr_data_ram_clk;

// Double-register data for CDC (reads and PSRAM writes only)
reg [31:0] bridge_addr_sync1, bridge_addr_sync2;
reg [31:0] bridge_wr_data_sync1, bridge_wr_data_sync2;

always @(posedge clk_ram_controller) begin
    // 4-stage sync for SDRAM read control signals
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
    if ((bridge_rd_sync2 && !bridge_rd_sync3) ||
        (bridge_psram_wr_sync2 && !bridge_psram_wr_sync3)) begin
        bridge_addr_sync1 <= bridge_addr_captured;
    end
    if (bridge_psram_wr_sync2 && !bridge_psram_wr_sync3) begin
        bridge_wr_data_sync1 <= bridge_wr_data_captured;
    end
    bridge_addr_sync2 <= bridge_addr_sync1;
    bridge_wr_data_sync2 <= bridge_wr_data_sync1;

    // Capture SDRAM read address on sync3 rising edge
    if (bridge_rd_sync3 && !bridge_rd_sync4) begin
        bridge_addr_ram_clk <= bridge_addr_sync2;
    end

    // Capture PSRAM address/data on sync3 rising edge
    if (bridge_psram_wr_sync3 && !bridge_psram_wr_sync4) begin
        bridge_psram_addr_ram_clk <= bridge_addr_sync2;
        bridge_psram_wr_data_ram_clk <= bridge_wr_data_sync2;
    end

    // Bridge reads: data captured by axi_bridge_master, latch done level for CDC
    if (bridge_axi_rd_done) begin
        bridge_rd_data_captured <= bridge_axi_rd_data;
        bridge_rd_done <= 1;
    end
    if (!bridge_rd_sync1) begin
        bridge_rd_done <= 0;
    end
end

// Word-level mux removed — all SDRAM access goes through AXI4 arbiter → axi_sdram_slave → io_sdram

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

    wire reset_n = reset_n_apf & bcr_init_done;

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

    reg     [9:0]   datatable_addr;
    wire    [31:0]  datatable_q;
    reg             datatable_wren;
    reg     [31:0]  datatable_data;

// Write save slot size to datatable after all data slots are loaded.
// The framework reads datatable entry (slot_id * 2 + 1) at shutdown
// to know how many bytes to read back from SDRAM and save to SD card.
reg dt_init_done;
always @(posedge clk_74a or negedge reset_n_apf) begin
    if (~reset_n_apf) begin
        datatable_addr <= 0;
        datatable_data <= 0;
        datatable_wren <= 0;
        dt_init_done   <= 0;
    end else begin
        datatable_wren <= 0;
        if (dataslot_allcomplete && !dt_init_done) begin
            datatable_addr <= 10'd11;           // slot 5 * 2 + 1
            datatable_data <= 32'h000D0000;     // 832KB (matches data.json size_maximum)
            datatable_wren <= 1;
            dt_init_done   <= 1;
        end
    end
end

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

    reg [9:0]   x_count;
    reg [9:0]   y_count;


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

    // Timer interrupt (from axi_periph_slave mtimecmp comparator)
    wire timer_irq;

    // VexiiRiscv CPU system - running at 100 MHz (CPU + memory)
    // Pure bus routing: VexiiRiscv → arbiter → {SDRAM, PSRAM, Local} AXI4 masters
    // CPU performance counters
    wire [31:0] cpu_perf_icache_miss;
    wire [31:0] cpu_perf_dcache_miss;
    wire [31:0] cpu_perf_icache_stall;
    wire [31:0] cpu_perf_dcache_stall;

    cpu_system cpu (
        .clk(clk_cpu),  // 100 MHz
        .reset_n(reset_n),
        // SDRAM AXI4 master interface (to axi_sdram_slave)
        .m_sdram_arvalid(cpu_m_sdram_arvalid),
        .m_sdram_arready(cpu_m_sdram_arready),
        .m_sdram_araddr(cpu_m_sdram_araddr),
        .m_sdram_arlen(cpu_m_sdram_arlen),
        .m_sdram_rvalid(cpu_m_sdram_rvalid),
        .m_sdram_rdata(cpu_m_sdram_rdata),
        .m_sdram_rresp(cpu_m_sdram_rresp),
        .m_sdram_rlast(cpu_m_sdram_rlast),
        .m_sdram_awvalid(cpu_m_sdram_awvalid),
        .m_sdram_awready(cpu_m_sdram_awready),
        .m_sdram_awaddr(cpu_m_sdram_awaddr),
        .m_sdram_awlen(cpu_m_sdram_awlen),
        .m_sdram_wvalid(cpu_m_sdram_wvalid),
        .m_sdram_wready(cpu_m_sdram_wready),
        .m_sdram_wdata(cpu_m_sdram_wdata),
        .m_sdram_wstrb(cpu_m_sdram_wstrb),
        .m_sdram_wlast(cpu_m_sdram_wlast),
        .m_sdram_bvalid(cpu_m_sdram_bvalid),
        .m_sdram_bresp(cpu_m_sdram_bresp),
        // PSRAM AXI4 master interface (to axi_psram_slave)
        .m_psram_arvalid(cpu_m_psram_arvalid),
        .m_psram_arready(cpu_m_psram_arready),
        .m_psram_araddr(cpu_m_psram_araddr),
        .m_psram_arlen(cpu_m_psram_arlen),
        .m_psram_rvalid(cpu_m_psram_rvalid),
        .m_psram_rdata(cpu_m_psram_rdata),
        .m_psram_rresp(cpu_m_psram_rresp),
        .m_psram_rlast(cpu_m_psram_rlast),
        .m_psram_awvalid(cpu_m_psram_awvalid),
        .m_psram_awready(cpu_m_psram_awready),
        .m_psram_awaddr(cpu_m_psram_awaddr),
        .m_psram_awlen(cpu_m_psram_awlen),
        .m_psram_wvalid(cpu_m_psram_wvalid),
        .m_psram_wready(cpu_m_psram_wready),
        .m_psram_wdata(cpu_m_psram_wdata),
        .m_psram_wstrb(cpu_m_psram_wstrb),
        .m_psram_wlast(cpu_m_psram_wlast),
        .m_psram_bvalid(cpu_m_psram_bvalid),
        .m_psram_bresp(cpu_m_psram_bresp),
        // Local peripheral AXI4 master interface (to axi_periph_slave)
        .m_local_arvalid(cpu_m_local_arvalid),
        .m_local_arready(cpu_m_local_arready),
        .m_local_araddr(cpu_m_local_araddr),
        .m_local_arlen(cpu_m_local_arlen),
        .m_local_rvalid(cpu_m_local_rvalid),
        .m_local_rdata(cpu_m_local_rdata),
        .m_local_rresp(cpu_m_local_rresp),
        .m_local_rlast(cpu_m_local_rlast),
        .m_local_awvalid(cpu_m_local_awvalid),
        .m_local_awready(cpu_m_local_awready),
        .m_local_awaddr(cpu_m_local_awaddr),
        .m_local_awlen(cpu_m_local_awlen),
        .m_local_wvalid(cpu_m_local_wvalid),
        .m_local_wready(cpu_m_local_wready),
        .m_local_wdata(cpu_m_local_wdata),
        .m_local_wstrb(cpu_m_local_wstrb),
        .m_local_wlast(cpu_m_local_wlast),
        .m_local_bvalid(cpu_m_local_bvalid),
        .m_local_bresp(cpu_m_local_bresp),
        .timer_irq(timer_irq),
        .perf_icache_miss(cpu_perf_icache_miss),
        .perf_dcache_miss(cpu_perf_dcache_miss),
        .perf_icache_stall(cpu_perf_icache_stall),
        .perf_dcache_stall(cpu_perf_dcache_stall)
    );

    // AXI4 peripheral slave: BRAM, colormap, system registers, CDC, terminal,
    // and DMA/Span/ATM/Audio/Link register dispatch
    axi_periph_slave #(
        .ENABLE_DEBUG_CTRS(0)
    ) periph (
        .clk(clk_cpu),
        .reset_n(reset_n),
        // AXI4 slave interface (from cpu_system m_local)
        .s_axi_arvalid(cpu_m_local_arvalid),
        .s_axi_arready(cpu_m_local_arready),
        .s_axi_araddr(cpu_m_local_araddr),
        .s_axi_arlen(cpu_m_local_arlen),
        .s_axi_rvalid(cpu_m_local_rvalid),
        .s_axi_rready(1'b1),
        .s_axi_rdata(cpu_m_local_rdata),
        .s_axi_rresp(cpu_m_local_rresp),
        .s_axi_rlast(cpu_m_local_rlast),
        .s_axi_awvalid(cpu_m_local_awvalid),
        .s_axi_awready(cpu_m_local_awready),
        .s_axi_awaddr(cpu_m_local_awaddr),
        .s_axi_awlen(cpu_m_local_awlen),
        .s_axi_wvalid(cpu_m_local_wvalid),
        .s_axi_wready(cpu_m_local_wready),
        .s_axi_wdata(cpu_m_local_wdata),
        .s_axi_wstrb(cpu_m_local_wstrb),
        .s_axi_wlast(cpu_m_local_wlast),
        .s_axi_bvalid(cpu_m_local_bvalid),
        .s_axi_bready(1'b1),
        .s_axi_bresp(cpu_m_local_bresp),
        // CDC inputs
        .dataslot_allcomplete(dataslot_allcomplete && bridge_wr_idle),
        .vsync(vidout_vs),
        .cont1_key(cont1_key),
        .cont1_joy(cont1_joy),
        .cont1_trig(cont1_trig),
        .cont2_key(cont2_key),
        .cont2_joy(cont2_joy),
        .cont2_trig(cont2_trig),
        // Analogizer SNAC controller data
        .snac1_btn(snac_p1_btn),
        .snac1_joy(snac_p1_joy),
        .snac2_btn(snac_p2_btn),
        .snac2_joy(snac_p2_joy),
        // Dock keyboard (cont3) and mouse (cont4)
        .cont3_key(cont3_key),
        .cont3_joy(cont3_joy),
        .cont3_trig(cont3_trig),
        .cont4_key(cont4_key),
        .cont4_joy(cont4_joy),
        .cont4_trig(cont4_trig),
        .game_mode(game_mode_reg),
        .game_name_0(game_name_0_reg),
        .game_name_1(game_name_1_reg),
        .game_name_2(game_name_2_reg),
        .target_dataslot_ack(target_dataslot_ack),
        .target_dataslot_done(target_dataslot_done_safe),
        .target_dataslot_err(target_dataslot_err),
        // Terminal interface
        .term_mem_valid(term_mem_valid),
        .term_mem_addr(term_mem_addr),
        .term_mem_wdata(term_mem_wdata),
        .term_mem_wstrb(term_mem_wstrb),
        .term_mem_rdata(term_mem_rdata),
        .term_mem_ready(term_mem_ready),
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
        // DMA peripheral register interface
        .dma_reg_wr(dma_reg_wr),
        .dma_reg_addr(dma_reg_addr),
        .dma_reg_wdata(dma_reg_wdata),
        .dma_reg_rdata(dma_reg_rdata),
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
        .span_cmap_rdata(span_cmap_rdata),
        // SRAM word interface (CPU z-buffer access)
        .cpu_sram_rd(cpu_sram_rd),
        .cpu_sram_wr(cpu_sram_wr),
        .cpu_sram_addr(cpu_sram_addr),
        .cpu_sram_wdata(cpu_sram_wdata),
        .cpu_sram_wstrb(cpu_sram_wstrb),
        .cpu_sram_busy(cpu_sram_busy),
        .cpu_sram_q(cpu_sram_q),
        .cpu_sram_q_valid(cpu_sram_q_valid),
        // sram_fill register interface
        .sramfill_reg_wr(sramfill_reg_wr),
        .sramfill_reg_addr(sramfill_reg_addr),
        .sramfill_reg_wdata(sramfill_reg_wdata),
        .sramfill_reg_rdata(sramfill_reg_rdata),
        // Scanline engine register interface
        .scanline_reg_wr(scanline_reg_wr),
        .scanline_reg_rd(scanline_reg_rd),
        .scanline_reg_addr(scanline_reg_addr),
        .scanline_reg_wdata(scanline_reg_wdata),
        .scanline_reg_rdata(scanline_reg_rdata),
        .timer_irq(timer_irq),
        // PSRAM debug
        .psram_dbg_wait_seen(psram_dbg_wait_seen),
        .psram_dbg_wait_cycles(psram_dbg_wait_cycles),
        .psram_dbg_burst_count(psram_dbg_burst_count),
        .psram_dbg_stale_count(psram_dbg_stale_count),
        // Performance counters
        .span_active(span_active),
        .span_fifo_full(span_fifo_full),
        .perf_icache_miss(cpu_perf_icache_miss),
        .perf_dcache_miss(cpu_perf_dcache_miss),
        .perf_icache_stall(cpu_perf_icache_stall),
        .perf_dcache_stall(cpu_perf_dcache_stall)
    );

    // Slave → io_sdram pulse adapter: axi_sdram_slave holds rd/wr high until
    // accepted, but io_sdram expects single-cycle pulses.  This adapter converts
    // the held signals to one-cycle pulses and generates the accepted feedback.
    reg sdram_accepted_r;
    reg sdram_cmd_forwarded;  // Set after forwarding, cleared when slave deasserts
    always @(posedge clk_ram_controller) begin
        ram1_word_rd <= 0;
        ram1_word_wr <= 0;
        ram1_word_burst_len <= 4'd0;
        sdram_accepted_r <= 0;

        if (!sdram_slave_rd && !sdram_slave_wr)
            sdram_cmd_forwarded <= 0;

        if (!ram1_word_busy && !sdram_cmd_forwarded &&
            (sdram_slave_rd || sdram_slave_wr)) begin
            ram1_word_rd <= sdram_slave_rd;
            ram1_word_wr <= sdram_slave_wr;
            ram1_word_addr <= sdram_slave_addr;
            ram1_word_data <= sdram_slave_wdata;
            ram1_word_wstrb <= sdram_slave_wstrb;
            ram1_word_burst_len <= sdram_slave_burst_len;
            sdram_accepted_r <= 1;
            sdram_cmd_forwarded <= 1;
        end
    end

    // AXI4 bridge master: converts bridge FIFO drains + reads into AXI4 transactions
    axi_bridge_master bridge_axi_m (
        .clk(clk_cpu),
        .reset_n(reset_n),
        // Bridge write FIFO interface
        .fifo_q(bridge_wr_fifo_q),
        .fifo_empty(bridge_wr_fifo_empty),
        .fifo_rdreq(bridge_wr_fifo_drain),
        // Bridge read interface
        .bridge_rd_req(bridge_rd_sync4),
        .bridge_rd_addr(bridge_addr_ram_clk[25:2]),
        .bridge_rd_data(bridge_axi_rd_data),
        .bridge_rd_done(bridge_axi_rd_done),
        // AXI4 master
        .m_axi_arvalid(bridge_m_arvalid), .m_axi_arready(bridge_m_arready),
        .m_axi_araddr(bridge_m_araddr),   .m_axi_arlen(bridge_m_arlen),
        .m_axi_rvalid(bridge_m_rvalid),   .m_axi_rdata(bridge_m_rdata),
        .m_axi_rresp(bridge_m_rresp),     .m_axi_rlast(bridge_m_rlast),
        .m_axi_awvalid(bridge_m_awvalid), .m_axi_awready(bridge_m_awready),
        .m_axi_awaddr(bridge_m_awaddr),   .m_axi_awlen(bridge_m_awlen),
        .m_axi_wvalid(bridge_m_wvalid),   .m_axi_wready(bridge_m_wready),
        .m_axi_wdata(bridge_m_wdata),     .m_axi_wstrb(bridge_m_wstrb),
        .m_axi_wlast(bridge_m_wlast),
        .m_axi_bvalid(bridge_m_bvalid),   .m_axi_bresp(bridge_m_bresp),
        .idle(bridge_m_idle),
        .wr_idle(bridge_m_wr_idle)
    );

    // AXI4 slave wrapper: CPU AXI4 → SDRAM word-level interface
    // AXI4 SDRAM arbiter: Span(M0) > DMA(M1) > CPU(M2) > Bridge(M3) → slave
    // Span, DMA, and Bridge now have native AXI4 master ports
    axi_sdram_arbiter sdram_arb (
        .clk(clk_cpu),
        .reset_n(reset_n),
        // M0: Span (highest priority)
        .m0_arvalid(span_m_arvalid), .m0_arready(span_m_arready),
        .m0_araddr(span_m_araddr),   .m0_arlen(span_m_arlen),
        .m0_rvalid(span_m_rvalid),   .m0_rdata(span_m_rdata),
        .m0_rresp(span_m_rresp),     .m0_rlast(span_m_rlast),
        .m0_awvalid(span_m_awvalid), .m0_awready(span_m_awready),
        .m0_awaddr(span_m_awaddr),   .m0_awlen(span_m_awlen),
        .m0_wvalid(span_m_wvalid),   .m0_wready(span_m_wready),
        .m0_wdata(span_m_wdata),     .m0_wstrb(span_m_wstrb),
        .m0_wlast(span_m_wlast),
        .m0_bvalid(span_m_bvalid),   .m0_bresp(span_m_bresp),
        // M1: DMA
        .m1_arvalid(dma_m_arvalid), .m1_arready(dma_m_arready),
        .m1_araddr(dma_m_araddr),   .m1_arlen(dma_m_arlen),
        .m1_rvalid(dma_m_rvalid),   .m1_rdata(dma_m_rdata),
        .m1_rresp(dma_m_rresp),     .m1_rlast(dma_m_rlast),
        .m1_awvalid(dma_m_awvalid), .m1_awready(dma_m_awready),
        .m1_awaddr(dma_m_awaddr),   .m1_awlen(dma_m_awlen),
        .m1_wvalid(dma_m_wvalid),   .m1_wready(dma_m_wready),
        .m1_wdata(dma_m_wdata),     .m1_wstrb(dma_m_wstrb),
        .m1_wlast(dma_m_wlast),
        .m1_bvalid(dma_m_bvalid),   .m1_bresp(dma_m_bresp),
        // M2: CPU
        .m2_arvalid(cpu_m_sdram_arvalid), .m2_arready(cpu_m_sdram_arready),
        .m2_araddr(cpu_m_sdram_araddr),   .m2_arlen(cpu_m_sdram_arlen),
        .m2_rvalid(cpu_m_sdram_rvalid),   .m2_rdata(cpu_m_sdram_rdata),
        .m2_rresp(cpu_m_sdram_rresp),     .m2_rlast(cpu_m_sdram_rlast),
        .m2_awvalid(cpu_m_sdram_awvalid), .m2_awready(cpu_m_sdram_awready),
        .m2_awaddr(cpu_m_sdram_awaddr),   .m2_awlen(cpu_m_sdram_awlen),
        .m2_wvalid(cpu_m_sdram_wvalid),   .m2_wready(cpu_m_sdram_wready),
        .m2_wdata(cpu_m_sdram_wdata),     .m2_wstrb(cpu_m_sdram_wstrb),
        .m2_wlast(cpu_m_sdram_wlast),
        .m2_bvalid(cpu_m_sdram_bvalid),   .m2_bresp(cpu_m_sdram_bresp),
        // M3: Bridge (lowest priority)
        .m3_arvalid(bridge_m_arvalid), .m3_arready(bridge_m_arready),
        .m3_araddr(bridge_m_araddr),   .m3_arlen(bridge_m_arlen),
        .m3_rvalid(bridge_m_rvalid),   .m3_rdata(bridge_m_rdata),
        .m3_rresp(bridge_m_rresp),     .m3_rlast(bridge_m_rlast),
        .m3_awvalid(bridge_m_awvalid), .m3_awready(bridge_m_awready),
        .m3_awaddr(bridge_m_awaddr),   .m3_awlen(bridge_m_awlen),
        .m3_wvalid(bridge_m_wvalid),   .m3_wready(bridge_m_wready),
        .m3_wdata(bridge_m_wdata),     .m3_wstrb(bridge_m_wstrb),
        .m3_wlast(bridge_m_wlast),
        .m3_bvalid(bridge_m_bvalid),   .m3_bresp(bridge_m_bresp),
        // Slave output (to axi_sdram_slave)
        .s_arvalid(arb_s_arvalid), .s_arready(arb_s_arready),
        .s_araddr(arb_s_araddr),   .s_arlen(arb_s_arlen),
        .s_rvalid(arb_s_rvalid),   .s_rdata(arb_s_rdata),
        .s_rresp(arb_s_rresp),     .s_rlast(arb_s_rlast),
        .s_awvalid(arb_s_awvalid), .s_awready(arb_s_awready),
        .s_awaddr(arb_s_awaddr),   .s_awlen(arb_s_awlen),
        .s_wvalid(arb_s_wvalid),   .s_wready(arb_s_wready),
        .s_wdata(arb_s_wdata),     .s_wstrb(arb_s_wstrb),
        .s_wlast(arb_s_wlast),
        .s_bvalid(arb_s_bvalid),   .s_bresp(arb_s_bresp)
    );

    // AXI4 slave wrapper: arbiter output → SDRAM word-level → io_sdram (direct)
    axi_sdram_slave sdram_axi_slave (
        .clk(clk_cpu),
        .reset_n(reset_n),
        // AXI4 slave interface (from arbiter)
        .s_axi_arvalid(arb_s_arvalid),
        .s_axi_arready(arb_s_arready),
        .s_axi_araddr(arb_s_araddr),
        .s_axi_arlen(arb_s_arlen),
        .s_axi_rvalid(arb_s_rvalid),
        .s_axi_rready(1'b1),
        .s_axi_rdata(arb_s_rdata),
        .s_axi_rresp(arb_s_rresp),
        .s_axi_rlast(arb_s_rlast),
        .s_axi_awvalid(arb_s_awvalid),
        .s_axi_awready(arb_s_awready),
        .s_axi_awaddr(arb_s_awaddr),
        .s_axi_awlen(arb_s_awlen),
        .s_axi_wvalid(arb_s_wvalid),
        .s_axi_wready(arb_s_wready),
        .s_axi_wdata(arb_s_wdata),
        .s_axi_wstrb(arb_s_wstrb),
        .s_axi_wlast(arb_s_wlast),
        .s_axi_bvalid(arb_s_bvalid),
        .s_axi_bready(1'b1),
        .s_axi_bresp(arb_s_bresp),
        // SDRAM word interface (to pulse adapter → io_sdram)
        .sdram_rd(sdram_slave_rd),
        .sdram_wr(sdram_slave_wr),
        .sdram_addr(sdram_slave_addr),
        .sdram_wdata(sdram_slave_wdata),
        .sdram_wstrb(sdram_slave_wstrb),
        .sdram_burst_len(sdram_slave_burst_len),
        .sdram_rdata(ram1_word_q),
        .sdram_busy(ram1_word_busy),
        .sdram_accepted(sdram_accepted_r),
        .sdram_rdata_valid(ram1_word_q_valid)
    );

    // AXI4 slave wrapper: CPU AXI4 → PSRAM word-level interface
    // Sits between cpu_system AXI4 outputs and the PSRAM mux
    axi_psram_slave cpu_psram_axi (
        .clk(clk_cpu),
        .reset_n(reset_n),
        // AXI4 slave interface (from cpu_system)
        .s_axi_arvalid(cpu_m_psram_arvalid),
        .s_axi_arready(cpu_m_psram_arready),
        .s_axi_araddr(cpu_m_psram_araddr),
        .s_axi_arlen(cpu_m_psram_arlen),
        .s_axi_rvalid(cpu_m_psram_rvalid),
        .s_axi_rready(1'b1),
        .s_axi_rdata(cpu_m_psram_rdata),
        .s_axi_rresp(cpu_m_psram_rresp),
        .s_axi_rlast(cpu_m_psram_rlast),
        .s_axi_awvalid(cpu_m_psram_awvalid),
        .s_axi_awready(cpu_m_psram_awready),
        .s_axi_awaddr(cpu_m_psram_awaddr),
        .s_axi_awlen(cpu_m_psram_awlen),
        .s_axi_wvalid(cpu_m_psram_wvalid),
        .s_axi_wready(cpu_m_psram_wready),
        .s_axi_wdata(cpu_m_psram_wdata),
        .s_axi_wstrb(cpu_m_psram_wstrb),
        .s_axi_wlast(cpu_m_psram_wlast),
        .s_axi_bvalid(cpu_m_psram_bvalid),
        .s_axi_bready(1'b1),
        .s_axi_bresp(cpu_m_psram_bresp),
        // PSRAM word interface (to mux — same signals as before)
        .psram_rd(cpu_psram_rd),
        .psram_wr(cpu_psram_wr),
        .psram_addr(cpu_psram_addr),
        .psram_wdata(cpu_psram_wdata),
        .psram_wstrb(cpu_psram_wstrb),
        .psram_rdata(cpu_psram_rdata),
        .psram_busy(cpu_psram_busy),
        .psram_rdata_valid(cpu_psram_rdata_valid),
        // Sync burst read (to psram_controller via core_top wires)
        .psram_burst_rd(psram_burst_rd),
        .psram_burst_len(psram_burst_len),
        .psram_burst_rdata_valid(psram_burst_rdata_valid),
        .psram_burst_rdata(psram_burst_rdata)
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
        // AXI4 Master interface (to axi_sdram_arbiter M1)
        .m_axi_arvalid(dma_m_arvalid), .m_axi_arready(dma_m_arready),
        .m_axi_araddr(dma_m_araddr),   .m_axi_arlen(dma_m_arlen),
        .m_axi_rvalid(dma_m_rvalid),   .m_axi_rdata(dma_m_rdata),
        .m_axi_rresp(dma_m_rresp),     .m_axi_rlast(dma_m_rlast),
        .m_axi_awvalid(dma_m_awvalid), .m_axi_awready(dma_m_awready),
        .m_axi_awaddr(dma_m_awaddr),   .m_axi_awlen(dma_m_awlen),
        .m_axi_wvalid(dma_m_wvalid),   .m_axi_wready(dma_m_wready),
        .m_axi_wdata(dma_m_wdata),     .m_axi_wstrb(dma_m_wstrb),
        .m_axi_wlast(dma_m_wlast),
        .m_axi_bvalid(dma_m_bvalid),   .m_axi_bresp(dma_m_bresp),
        // Status
        .active(dma_active)
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
        // AXI4 Master interface (to axi_sdram_arbiter M0)
        .m_axi_arvalid(span_m_arvalid), .m_axi_arready(span_m_arready),
        .m_axi_araddr(span_m_araddr),   .m_axi_arlen(span_m_arlen),
        .m_axi_rvalid(span_m_rvalid),   .m_axi_rdata(span_m_rdata),
        .m_axi_rresp(span_m_rresp),     .m_axi_rlast(span_m_rlast),
        .m_axi_awvalid(span_m_awvalid), .m_axi_awready(span_m_awready),
        .m_axi_awaddr(span_m_awaddr),   .m_axi_awlen(span_m_awlen),
        .m_axi_wvalid(span_m_wvalid),   .m_axi_wready(span_m_wready),
        .m_axi_wdata(span_m_wdata),     .m_axi_wstrb(span_m_wstrb),
        .m_axi_wlast(span_m_wlast),
        .m_axi_bvalid(span_m_bvalid),   .m_axi_bresp(span_m_bresp),
        // SRAM interface (z-buffer reads + writes in external SRAM)
        .sram_wr(span_sram_wr),
        .sram_rd(span_sram_rd),
        .sram_addr(span_sram_addr),
        .sram_wdata(span_sram_wdata),
        .sram_wstrb(span_sram_wstrb),
        .sram_busy(span_sram_busy),
        .sram_rdata(span_sram_rdata),
        .sram_rdata_valid(span_sram_rdata_valid),
        // Status
        .active(span_active),
        .fifo_full_out(span_fifo_full),
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

    // periph_sdram_mux removed — Span and DMA now use AXI4 word master
    // wrappers connected to axi_sdram_arbiter (instantiated above cpu_psram_axi).

    // Terminal display (40x30 characters, 320x240 pixels)
    wire [23:0] terminal_pixel_color;

    text_terminal terminal (
        .clk(clk_core_12288),
        .clk_cpu(clk_cpu),  // CPU clock for memory interface (100 MHz)
        .reset_n(reset_n),
        .pixel_x({visible_x[9],visible_x[9:1]}), //RndMnkIII: For CRT I doubled the x resolution
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

    video_CRT_scanout_indexed_BRAM scanout (
        // Video clock domain (12.288 MHz)
        .clk_video(clk_core_12288),
        .reset_n(reset_n),
        .x_count(x_count),
        .y_count(y_count),
        .line_start(line_start),
        .pixel_color(framebuffer_pixel_color),
        .fb_base_addr(fb_display_addr),  // 25-bit SDRAM 16-bit word address
        // SDRAM clock domain (100 MHz)
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



// ---  CRT 15.7kHz / 60Hz Parameters ---
localparam CRT_V_TOTAL  = CRT_V_SYNC + CRT_V_BPORCH + CRT_V_ACTIVE + CRT_V_FPORCH;
localparam CRT_V_SYNC   = 3;
localparam CRT_V_BPORCH = 15;
localparam CRT_V_FPORCH = 4;
localparam CRT_V_ACTIVE = 240;
localparam CRT_H_TOTAL  = CRT_H_SYNC + CRT_H_BPORCH + CRT_H_ACTIVE + CRT_H_FPORCH;
localparam CRT_H_SYNC   = 58;
localparam CRT_H_BPORCH = 62;
localparam CRT_H_FPORCH = 20;
localparam CRT_H_ACTIVE = 640;
reg crt_hs, crt_vs, crt_de;
reg crt_hblank, crt_vblank;
wire crt_csync;
wire crt_blankn;


wire [9:0]  visible_x = x_count - CRT_H_SYNC - CRT_H_BPORCH;
wire [9:0]  visible_y = y_count - CRT_V_SYNC - CRT_V_BPORCH;

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
        if(x_count == CRT_H_TOTAL-1) begin
            x_count <= 0;

            y_count <= y_count + 1'b1;
            if(y_count == CRT_V_TOTAL-1) begin
                y_count <= 0;
            end
        end

        // CRT Blank
        crt_hblank <= x_count < (CRT_H_SYNC + CRT_H_BPORCH) || (x_count >= CRT_H_SYNC + CRT_H_BPORCH + CRT_H_ACTIVE);
        crt_vblank <= y_count < (CRT_V_SYNC + CRT_V_BPORCH) || (y_count >= CRT_V_SYNC + CRT_V_BPORCH + CRT_V_ACTIVE);

        // Generate CRT sync
        // --- Generación de Syncs (Lógica Negativa) ---

        crt_hs <= (x_count >= 0) && (x_count < CRT_H_SYNC);
        crt_vs <= (y_count >= 0) && (y_count < CRT_V_SYNC);


        // Generate Pocket sync
        if(x_count == 0 && y_count == 0) begin
            // sync signal in back porch
            // new frame
            vidout_vs <= 1;
        end

        // we want HS to occur a bit after VS, not on the same cycle
        if(x_count == 3) begin
            // sync signal in back porch
            // new line
            vidout_hs <= 1;
        end

        // inactive screen areas are black
        vidout_rgb <= 24'h0;

        // generate active video, now accounts for CRT specific timings but making compatible with Analogue Pocket video also
        if(x_count >= CRT_H_SYNC + CRT_H_BPORCH  && x_count < CRT_H_SYNC + CRT_H_BPORCH + CRT_H_ACTIVE) begin

            if(y_count >= CRT_V_SYNC + CRT_V_BPORCH && y_count < CRT_V_SYNC + CRT_V_BPORCH + CRT_V_ACTIVE) begin
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

assign crt_csync = ~(crt_hs ^ crt_vs);
assign crt_blankn   = ~(crt_hblank | crt_vblank);

//
// Link MMIO peripheral (FIFO + synchronous SCK/SO/SI PHY)
//
link_mmio #(
    .CLK_HZ(105000000),
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
    wire    clk_core_49152;
    wire    clk_cpu;            // CPU clock (100 MHz)
    wire    clk_ram_controller; // 100 MHz SDRAM controller clock
    wire    clk_ram_chip;       // 100 MHz SDRAM chip clock (phase shifted)

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

    .outclk_2       ( clk_core_49152),       //x4 video freq for SVGA Scandoubler and YC encoder
    .outclk_3       ( ),                    // 66 MHz (unused)
    .outclk_4       ( ),                    // 66 MHz (unused)

    .locked         ( pll_core_locked )
);

mf_pllram_133 mp_ram (
    .refclk         ( clk_74a ),
    .rst            ( 0 ),
    .outclk_0       ( clk_ram_controller ), // 100 MHz for SDRAM controller
    .outclk_1       ( clk_ram_chip ),       // 100 MHz for SDRAM chip (phase shifted)
    .outclk_2       ( clk_cram0 ),          // 105 MHz phase-shifted for CRAM0 sync burst
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
