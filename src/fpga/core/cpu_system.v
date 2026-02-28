//
// VexRiscv CPU System — AXI4 bus routing
// - VexRiscv RISC-V CPU with AXI4 interface
// - iBus/dBus arbitration → address decode → {SDRAM, PSRAM, Local} AXI4 masters
//
// All peripheral/local logic (BRAM, colormap, system registers, CDC, terminal,
// DMA/Span/ATM/Audio/Link dispatch) lives in axi_periph_slave.v.
//

`default_nettype none

module cpu_system (
    input wire clk,           // CPU clock (100 MHz)
    input wire reset_n,

    // SDRAM AXI4 master interface (to axi_sdram_slave via core_top)
    output reg         m_sdram_arvalid,
    input  wire        m_sdram_arready,
    output reg  [31:0] m_sdram_araddr,
    output reg  [7:0]  m_sdram_arlen,

    input  wire        m_sdram_rvalid,
    input  wire [31:0] m_sdram_rdata,
    input  wire [1:0]  m_sdram_rresp,
    input  wire        m_sdram_rlast,

    output reg         m_sdram_awvalid,
    input  wire        m_sdram_awready,
    output reg  [31:0] m_sdram_awaddr,
    output reg  [7:0]  m_sdram_awlen,

    output reg         m_sdram_wvalid,
    input  wire        m_sdram_wready,
    output reg  [31:0] m_sdram_wdata,
    output reg  [3:0]  m_sdram_wstrb,
    output reg         m_sdram_wlast,

    input  wire        m_sdram_bvalid,
    input  wire [1:0]  m_sdram_bresp,

    // PSRAM AXI4 master interface (to axi_psram_slave via core_top)
    output reg         m_psram_arvalid,
    input  wire        m_psram_arready,
    output reg  [31:0] m_psram_araddr,
    output reg  [7:0]  m_psram_arlen,

    input  wire        m_psram_rvalid,
    input  wire [31:0] m_psram_rdata,
    input  wire [1:0]  m_psram_rresp,
    input  wire        m_psram_rlast,

    output reg         m_psram_awvalid,
    input  wire        m_psram_awready,
    output reg  [31:0] m_psram_awaddr,
    output reg  [7:0]  m_psram_awlen,

    output reg         m_psram_wvalid,
    input  wire        m_psram_wready,
    output reg  [31:0] m_psram_wdata,
    output reg  [3:0]  m_psram_wstrb,
    output reg         m_psram_wlast,

    input  wire        m_psram_bvalid,
    input  wire [1:0]  m_psram_bresp,

    // Local peripheral AXI4 master interface (to axi_periph_slave via core_top)
    output reg         m_local_arvalid,
    input  wire        m_local_arready,
    output reg  [31:0] m_local_araddr,
    output reg  [7:0]  m_local_arlen,

    input  wire        m_local_rvalid,
    input  wire [31:0] m_local_rdata,
    input  wire [1:0]  m_local_rresp,
    input  wire        m_local_rlast,

    output reg         m_local_awvalid,
    input  wire        m_local_awready,
    output reg  [31:0] m_local_awaddr,
    output reg  [7:0]  m_local_awlen,

    output reg         m_local_wvalid,
    input  wire        m_local_wready,
    output reg  [31:0] m_local_wdata,
    output reg  [3:0]  m_local_wstrb,
    output reg         m_local_wlast,

    input  wire        m_local_bvalid,
    input  wire [1:0]  m_local_bresp
);

// ============================================
// VexRiscv AXI4 signals
// ============================================

// iBus AXI4 (read-only): AR + R channels
wire        ibus_ar_valid;
reg         ibus_ar_ready;
wire [31:0] ibus_ar_addr;
wire [7:0]  ibus_ar_len;
wire [1:0]  ibus_ar_burst;
wire [3:0]  ibus_ar_cache;
wire [2:0]  ibus_ar_prot;

reg         ibus_r_valid;
wire        ibus_r_ready;
reg  [31:0] ibus_r_data;
reg  [1:0]  ibus_r_resp;
reg         ibus_r_last;

// dBus AXI4 (full): AW + W + B + AR + R channels
wire        dbus_aw_valid;
reg         dbus_aw_ready;
wire [31:0] dbus_aw_addr;
wire [7:0]  dbus_aw_len;
wire [2:0]  dbus_aw_size;
wire [3:0]  dbus_aw_cache;
wire [2:0]  dbus_aw_prot;

wire        dbus_w_valid;
reg         dbus_w_ready;
wire [31:0] dbus_w_data;
wire [3:0]  dbus_w_strb;
wire        dbus_w_last;

reg         dbus_b_valid;
wire        dbus_b_ready;
reg  [1:0]  dbus_b_resp;

wire        dbus_ar_valid;
reg         dbus_ar_ready;
wire [31:0] dbus_ar_addr;
wire [7:0]  dbus_ar_len;
wire [2:0]  dbus_ar_size;
wire [3:0]  dbus_ar_cache;
wire [2:0]  dbus_ar_prot;

reg         dbus_r_valid;
wire        dbus_r_ready;
reg  [31:0] dbus_r_data;
reg  [1:0]  dbus_r_resp;
reg         dbus_r_last;

// Active-high reset for VexRiscv
wire reset = ~reset_n;

// Instantiate VexRiscv CPU
VexRiscv cpu (
    .clk(clk),
    .reset(reset),

    .externalResetVector(32'h00000000),
    .timerInterrupt(1'b0),
    .softwareInterrupt(1'b0),
    .externalInterrupt(1'b0),

    // iBus AXI4 (read-only)
    .iBusAxi_ar_valid(ibus_ar_valid),
    .iBusAxi_ar_ready(ibus_ar_ready),
    .iBusAxi_ar_payload_addr(ibus_ar_addr),
    .iBusAxi_ar_payload_len(ibus_ar_len),
    .iBusAxi_ar_payload_burst(ibus_ar_burst),
    .iBusAxi_ar_payload_cache(ibus_ar_cache),
    .iBusAxi_ar_payload_prot(ibus_ar_prot),

    .iBusAxi_r_valid(ibus_r_valid),
    .iBusAxi_r_ready(ibus_r_ready),
    .iBusAxi_r_payload_data(ibus_r_data),
    .iBusAxi_r_payload_resp(ibus_r_resp),
    .iBusAxi_r_payload_last(ibus_r_last),

    // dBus AXI4 (full)
    .dBusAxi_aw_valid(dbus_aw_valid),
    .dBusAxi_aw_ready(dbus_aw_ready),
    .dBusAxi_aw_payload_addr(dbus_aw_addr),
    .dBusAxi_aw_payload_len(dbus_aw_len),
    .dBusAxi_aw_payload_size(dbus_aw_size),
    .dBusAxi_aw_payload_cache(dbus_aw_cache),
    .dBusAxi_aw_payload_prot(dbus_aw_prot),

    .dBusAxi_w_valid(dbus_w_valid),
    .dBusAxi_w_ready(dbus_w_ready),
    .dBusAxi_w_payload_data(dbus_w_data),
    .dBusAxi_w_payload_strb(dbus_w_strb),
    .dBusAxi_w_payload_last(dbus_w_last),

    .dBusAxi_b_valid(dbus_b_valid),
    .dBusAxi_b_ready(dbus_b_ready),
    .dBusAxi_b_payload_resp(dbus_b_resp),

    .dBusAxi_ar_valid(dbus_ar_valid),
    .dBusAxi_ar_ready(dbus_ar_ready),
    .dBusAxi_ar_payload_addr(dbus_ar_addr),
    .dBusAxi_ar_payload_len(dbus_ar_len),
    .dBusAxi_ar_payload_size(dbus_ar_size),
    .dBusAxi_ar_payload_cache(dbus_ar_cache),
    .dBusAxi_ar_payload_prot(dbus_ar_prot),

    .dBusAxi_r_valid(dbus_r_valid),
    .dBusAxi_r_ready(dbus_r_ready),
    .dBusAxi_r_payload_data(dbus_r_data),
    .dBusAxi_r_payload_resp(dbus_r_resp),
    .dBusAxi_r_payload_last(dbus_r_last)
);

// ============================================
// Request arbitration (AXI4)
// ============================================
localparam BUS_NONE  = 2'd0;
localparam BUS_IBUS  = 2'd1;
localparam BUS_DBUS  = 2'd2;

reg last_grant_dbus;

wire ibus_req = ibus_ar_valid;
wire dbus_rd_req = dbus_ar_valid;
wire dbus_wr_req = dbus_aw_valid;
wire dbus_req = dbus_rd_req | dbus_wr_req;

wire dbus_grant = dbus_req & (~ibus_req | ~last_grant_dbus);
wire ibus_grant = ibus_req & ~dbus_grant;
wire dbus_rd_grant = dbus_grant & dbus_rd_req;
wire dbus_wr_grant = dbus_grant & ~dbus_rd_req;

// Muxed request address for address decode
wire [31:0] grant_addr = dbus_grant ?
                          (dbus_rd_grant ? dbus_ar_addr : dbus_aw_addr) :
                          ibus_ar_addr;

// ============================================
// Simplified address decode — 3 targets
// ============================================
wire dec_sdram = (grant_addr[31:26] == 6'b000100) || (grant_addr[31:26] == 6'b010100);
wire dec_psram = (grant_addr[31:24] == 8'h30);
wire dec_local = ~dec_sdram & ~dec_psram;

// ============================================
// Memory access FSM
// ============================================
localparam FSM_IDLE       = 3'd0;
localparam FSM_MEM_AR     = 3'd1;
localparam FSM_MEM_R      = 3'd2;
localparam FSM_MEM_AW     = 3'd3;
localparam FSM_MEM_W      = 3'd4;
localparam FSM_MEM_B      = 3'd5;
localparam FSM_WRITE_NEXT = 3'd6;

reg [2:0] fsm_state;

// Latched request fields
reg [31:0] req_addr_r;
reg [31:0] req_wdata_r;
reg [3:0]  req_wstrb_r;
reg [1:0]  active_bus;
reg        is_write_r;

// Burst tracking
reg [7:0]  burst_len_r;
reg [7:0]  burst_count;

// Memory target for AXI4 forwarding (3-way)
localparam TGT_SDRAM = 2'd0;
localparam TGT_PSRAM = 2'd1;
localparam TGT_LOCAL = 2'd2;
reg [1:0] target_mem;

// Whether this beat is the last of a burst
wire beat_is_last = (burst_count == burst_len_r);

// AXI4 master target mux (3-way)
wire mem_arready = (target_mem == TGT_SDRAM) ? m_sdram_arready :
                   (target_mem == TGT_PSRAM) ? m_psram_arready :
                                               m_local_arready;
wire mem_rvalid  = (target_mem == TGT_SDRAM) ? m_sdram_rvalid :
                   (target_mem == TGT_PSRAM) ? m_psram_rvalid :
                                               m_local_rvalid;
wire [31:0] mem_rdata = (target_mem == TGT_SDRAM) ? m_sdram_rdata :
                        (target_mem == TGT_PSRAM) ? m_psram_rdata :
                                                    m_local_rdata;
wire mem_rlast   = (target_mem == TGT_SDRAM) ? m_sdram_rlast :
                   (target_mem == TGT_PSRAM) ? m_psram_rlast :
                                               m_local_rlast;
wire mem_awready = (target_mem == TGT_SDRAM) ? m_sdram_awready :
                   (target_mem == TGT_PSRAM) ? m_psram_awready :
                                               m_local_awready;
wire mem_wready  = (target_mem == TGT_SDRAM) ? m_sdram_wready :
                   (target_mem == TGT_PSRAM) ? m_psram_wready :
                                               m_local_wready;
wire mem_bvalid  = (target_mem == TGT_SDRAM) ? m_sdram_bvalid :
                   (target_mem == TGT_PSRAM) ? m_psram_bvalid :
                                               m_local_bvalid;

// ============================================
// Main FSM
// ============================================
always @(posedge clk or posedge reset) begin
    if (reset) begin
        fsm_state <= FSM_IDLE;
        active_bus <= BUS_NONE;
        is_write_r <= 0;
        req_addr_r <= 0;
        req_wdata_r <= 0;
        req_wstrb_r <= 0;
        burst_len_r <= 0;
        burst_count <= 0;
        last_grant_dbus <= 0;

        target_mem <= TGT_SDRAM;

        ibus_ar_ready <= 0;
        ibus_r_valid <= 0;
        ibus_r_data <= 0;
        ibus_r_resp <= 0;
        ibus_r_last <= 0;

        dbus_aw_ready <= 0;
        dbus_w_ready <= 0;
        dbus_ar_ready <= 0;
        dbus_r_valid <= 0;
        dbus_r_data <= 0;
        dbus_r_resp <= 0;
        dbus_r_last <= 0;
        dbus_b_valid <= 0;
        dbus_b_resp <= 0;

        m_sdram_arvalid <= 0;
        m_sdram_araddr <= 0;
        m_sdram_arlen <= 0;
        m_sdram_awvalid <= 0;
        m_sdram_awaddr <= 0;
        m_sdram_awlen <= 0;
        m_sdram_wvalid <= 0;
        m_sdram_wdata <= 0;
        m_sdram_wstrb <= 0;
        m_sdram_wlast <= 0;

        m_psram_arvalid <= 0;
        m_psram_araddr <= 0;
        m_psram_arlen <= 0;
        m_psram_awvalid <= 0;
        m_psram_awaddr <= 0;
        m_psram_awlen <= 0;
        m_psram_wvalid <= 0;
        m_psram_wdata <= 0;
        m_psram_wstrb <= 0;
        m_psram_wlast <= 0;

        m_local_arvalid <= 0;
        m_local_araddr <= 0;
        m_local_arlen <= 0;
        m_local_awvalid <= 0;
        m_local_awaddr <= 0;
        m_local_awlen <= 0;
        m_local_wvalid <= 0;
        m_local_wdata <= 0;
        m_local_wstrb <= 0;
        m_local_wlast <= 0;
    end else begin
        // Defaults: deassert single-cycle pulses
        ibus_ar_ready <= 0;
        ibus_r_valid <= 0;
        dbus_aw_ready <= 0;
        dbus_w_ready <= 0;
        dbus_ar_ready <= 0;
        dbus_r_valid <= 0;
        dbus_b_valid <= 0;

        case (fsm_state)

        // ============================================
        // IDLE: Accept new AXI4 request, decode target
        // ============================================
        FSM_IDLE: begin
            // Deassert AXI4 master valids
            m_sdram_arvalid <= 0;
            m_sdram_awvalid <= 0;
            m_sdram_wvalid <= 0;
            m_psram_arvalid <= 0;
            m_psram_awvalid <= 0;
            m_psram_wvalid <= 0;
            m_local_arvalid <= 0;
            m_local_awvalid <= 0;
            m_local_wvalid <= 0;

            if (ibus_grant) begin
                // Accept iBus read (AR channel)
                ibus_ar_ready <= 1;
                active_bus <= BUS_IBUS;
                is_write_r <= 0;
                req_addr_r <= ibus_ar_addr;
                burst_len_r <= ibus_ar_len;
                burst_count <= 0;
                last_grant_dbus <= 0;

                // Issue AR to target slave
                fsm_state <= FSM_MEM_AR;
                if (ibus_ar_addr[31:26] == 6'b000100 || ibus_ar_addr[31:26] == 6'b010100) begin
                    target_mem <= TGT_SDRAM;
                    m_sdram_arvalid <= 1;
                    m_sdram_araddr <= ibus_ar_addr;
                    m_sdram_arlen <= ibus_ar_len;
                end else if (ibus_ar_addr[31:24] == 8'h30) begin
                    target_mem <= TGT_PSRAM;
                    m_psram_arvalid <= 1;
                    m_psram_araddr <= ibus_ar_addr;
                    m_psram_arlen <= ibus_ar_len;
                end else begin
                    target_mem <= TGT_LOCAL;
                    m_local_arvalid <= 1;
                    m_local_araddr <= ibus_ar_addr;
                    m_local_arlen <= ibus_ar_len;
                end

            end else if (dbus_rd_grant) begin
                // Accept dBus read (AR channel)
                dbus_ar_ready <= 1;
                active_bus <= BUS_DBUS;
                is_write_r <= 0;
                req_addr_r <= dbus_ar_addr;
                burst_len_r <= dbus_ar_len;
                burst_count <= 0;
                last_grant_dbus <= 1;

                // Issue AR to target slave
                fsm_state <= FSM_MEM_AR;
                if (dbus_ar_addr[31:26] == 6'b000100 || dbus_ar_addr[31:26] == 6'b010100) begin
                    target_mem <= TGT_SDRAM;
                    m_sdram_arvalid <= 1;
                    m_sdram_araddr <= dbus_ar_addr;
                    m_sdram_arlen <= dbus_ar_len;
                end else if (dbus_ar_addr[31:24] == 8'h30) begin
                    target_mem <= TGT_PSRAM;
                    m_psram_arvalid <= 1;
                    m_psram_araddr <= dbus_ar_addr;
                    m_psram_arlen <= dbus_ar_len;
                end else begin
                    target_mem <= TGT_LOCAL;
                    m_local_arvalid <= 1;
                    m_local_araddr <= dbus_ar_addr;
                    m_local_arlen <= dbus_ar_len;
                end

            end else if (dbus_wr_grant) begin
                // Accept dBus write address (AW channel)
                dbus_aw_ready <= 1;
                active_bus <= BUS_DBUS;
                is_write_r <= 1;
                req_addr_r <= dbus_aw_addr;
                burst_len_r <= dbus_aw_len;
                burst_count <= 0;
                last_grant_dbus <= 1;

                // Determine target
                if (dbus_aw_addr[31:26] == 6'b000100 || dbus_aw_addr[31:26] == 6'b010100)
                    target_mem <= TGT_SDRAM;
                else if (dbus_aw_addr[31:24] == 8'h30)
                    target_mem <= TGT_PSRAM;
                else
                    target_mem <= TGT_LOCAL;

                // Also accept W if valid on same cycle
                if (dbus_w_valid) begin
                    dbus_w_ready <= 1;
                    req_wdata_r <= dbus_w_data;
                    req_wstrb_r <= dbus_w_strb;

                    // Issue AW to target slave
                    fsm_state <= FSM_MEM_AW;
                    if (dbus_aw_addr[31:26] == 6'b000100 || dbus_aw_addr[31:26] == 6'b010100) begin
                        m_sdram_awvalid <= 1;
                        m_sdram_awaddr <= dbus_aw_addr;
                        m_sdram_awlen <= dbus_aw_len;
                    end else if (dbus_aw_addr[31:24] == 8'h30) begin
                        m_psram_awvalid <= 1;
                        m_psram_awaddr <= dbus_aw_addr;
                        m_psram_awlen <= dbus_aw_len;
                    end else begin
                        m_local_awvalid <= 1;
                        m_local_awaddr <= dbus_aw_addr;
                        m_local_awlen <= dbus_aw_len;
                    end
                end else begin
                    // W not ready yet - wait for it
                    fsm_state <= FSM_WRITE_NEXT;
                end
            end
        end

        // ============================================
        // MEM_AR: Wait for target arready
        // ============================================
        FSM_MEM_AR: begin
            if (mem_arready) begin
                m_sdram_arvalid <= 0;
                m_psram_arvalid <= 0;
                m_local_arvalid <= 0;
                fsm_state <= FSM_MEM_R;
            end
        end

        // ============================================
        // MEM_R: Forward R beats to VexRiscv
        // ============================================
        FSM_MEM_R: begin
            if (mem_rvalid) begin
                if (active_bus == BUS_IBUS) begin
                    ibus_r_valid <= 1;
                    ibus_r_data <= mem_rdata;
                    ibus_r_resp <= 2'b00;
                    ibus_r_last <= beat_is_last;
                end else begin
                    dbus_r_valid <= 1;
                    dbus_r_data <= mem_rdata;
                    dbus_r_resp <= 2'b00;
                    dbus_r_last <= beat_is_last;
                end
                burst_count <= burst_count + 1;
                if (beat_is_last)
                    fsm_state <= FSM_IDLE;
            end
        end

        // ============================================
        // MEM_AW: Wait for target awready, then send W
        // ============================================
        FSM_MEM_AW: begin
            if (mem_awready) begin
                m_sdram_awvalid <= 0;
                m_psram_awvalid <= 0;
                m_local_awvalid <= 0;
                // Send W beat
                fsm_state <= FSM_MEM_W;
                if (target_mem == TGT_SDRAM) begin
                    m_sdram_wvalid <= 1;
                    m_sdram_wdata <= req_wdata_r;
                    m_sdram_wstrb <= req_wstrb_r;
                    m_sdram_wlast <= beat_is_last;
                end else if (target_mem == TGT_PSRAM) begin
                    m_psram_wvalid <= 1;
                    m_psram_wdata <= req_wdata_r;
                    m_psram_wstrb <= req_wstrb_r;
                    m_psram_wlast <= beat_is_last;
                end else begin
                    m_local_wvalid <= 1;
                    m_local_wdata <= req_wdata_r;
                    m_local_wstrb <= req_wstrb_r;
                    m_local_wlast <= beat_is_last;
                end
            end
        end

        // ============================================
        // MEM_W: Wait for target wready
        // ============================================
        FSM_MEM_W: begin
            if (mem_wready) begin
                m_sdram_wvalid <= 0;
                m_psram_wvalid <= 0;
                m_local_wvalid <= 0;
                burst_count <= burst_count + 1;
                if (beat_is_last) begin
                    fsm_state <= FSM_MEM_B;
                end else begin
                    req_addr_r <= req_addr_r + 32'd4;
                    fsm_state <= FSM_WRITE_NEXT;
                end
            end
        end

        // ============================================
        // MEM_B: Wait for target bvalid, forward to VexRiscv
        // ============================================
        FSM_MEM_B: begin
            if (mem_bvalid) begin
                dbus_b_valid <= 1;
                dbus_b_resp <= 2'b00;
                fsm_state <= FSM_IDLE;
            end
        end

        // ============================================
        // WRITE_NEXT: Accept next W beat from VexRiscv, forward to target
        // ============================================
        FSM_WRITE_NEXT: begin
            if (dbus_w_valid) begin
                dbus_w_ready <= 1;
                req_wdata_r <= dbus_w_data;
                req_wstrb_r <= dbus_w_strb;

                // Issue AW if we haven't yet (first beat case where W wasn't ready)
                // or send W beat for subsequent beats
                if (burst_count == 0 && !m_sdram_awvalid && !m_psram_awvalid && !m_local_awvalid) begin
                    // First beat: we accepted AW from VexRiscv but haven't issued AW to target yet
                    fsm_state <= FSM_MEM_AW;
                    if (target_mem == TGT_SDRAM) begin
                        m_sdram_awvalid <= 1;
                        m_sdram_awaddr <= req_addr_r;
                        m_sdram_awlen <= burst_len_r;
                    end else if (target_mem == TGT_PSRAM) begin
                        m_psram_awvalid <= 1;
                        m_psram_awaddr <= req_addr_r;
                        m_psram_awlen <= burst_len_r;
                    end else begin
                        m_local_awvalid <= 1;
                        m_local_awaddr <= req_addr_r;
                        m_local_awlen <= burst_len_r;
                    end
                end else begin
                    // Subsequent beat: send W to target
                    fsm_state <= FSM_MEM_W;
                    if (target_mem == TGT_SDRAM) begin
                        m_sdram_wvalid <= 1;
                        m_sdram_wdata <= dbus_w_data;
                        m_sdram_wstrb <= dbus_w_strb;
                        m_sdram_wlast <= (burst_count == burst_len_r);
                    end else if (target_mem == TGT_PSRAM) begin
                        m_psram_wvalid <= 1;
                        m_psram_wdata <= dbus_w_data;
                        m_psram_wstrb <= dbus_w_strb;
                        m_psram_wlast <= (burst_count == burst_len_r);
                    end else begin
                        m_local_wvalid <= 1;
                        m_local_wdata <= dbus_w_data;
                        m_local_wstrb <= dbus_w_strb;
                        m_local_wlast <= (burst_count == burst_len_r);
                    end
                end
            end
        end

        default: fsm_state <= FSM_IDLE;

        endcase
    end
end

endmodule
