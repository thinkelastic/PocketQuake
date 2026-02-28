//
// Word-level SDRAM Master → AXI4 Master Adapter
//
// Converts word-level SDRAM protocol (rd/wr/addr/busy/accepted/rdata_valid)
// into AXI4 master transactions (AR/R, AW/W/B).
//
// Used to wrap span_rasterizer and dma_clear_blit for the AXI4 SDRAM arbiter.
// These wrappers are temporary — Phase 4 will convert span/DMA to native AXI4.
//
// Protocol mapping:
//   word_rd pulse → AXI4 AR, wait for R (burst via word_burst_len → ARLEN)
//   word_wr pulse → AXI4 AW+W, wait for B
//   word_busy ← HIGH while AXI4 transaction in progress
//   word_accepted ← pulse when AXI4 AR/AW accepted (for span rasterizer)
//   word_rdata_valid ← pulse per AXI4 R beat
//

`default_nettype none

module axi_word_master (
    input wire clk,
    input wire reset_n,

    // Word-level master interface (from span_rasterizer or dma_clear_blit)
    input  wire        word_rd,
    input  wire        word_wr,
    input  wire [23:0] word_addr,       // 24-bit word address
    input  wire [31:0] word_wdata,
    input  wire [3:0]  word_wstrb,
    input  wire [2:0]  word_burst_len,  // 0=1 word, N=N+1 words
    output wire [31:0] word_rdata,
    output reg         word_busy,
    output reg         word_rdata_valid,
    output reg         word_accepted,

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
    output reg  [7:0]  m_axi_awlen,

    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output reg         m_axi_wlast,

    input  wire        m_axi_bvalid,
    input  wire [1:0]  m_axi_bresp
);

wire reset = ~reset_n;

// Read data pass-through (combinational for zero latency)
assign word_rdata = m_axi_rdata;

// FSM states
localparam S_IDLE = 3'd0;
localparam S_AR   = 3'd1;  // Issue AXI4 AR, wait for arready
localparam S_R    = 3'd2;  // Wait for AXI4 R beats
localparam S_AW   = 3'd3;  // Issue AXI4 AW, wait for awready
localparam S_W    = 3'd4;  // Issue AXI4 W, wait for wready
localparam S_B    = 3'd5;  // Wait for AXI4 B response

reg [2:0] state;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state <= S_IDLE;
        word_busy <= 0;
        word_rdata_valid <= 0;
        word_accepted <= 0;
        m_axi_arvalid <= 0;
        m_axi_araddr <= 0;
        m_axi_arlen <= 0;
        m_axi_awvalid <= 0;
        m_axi_awaddr <= 0;
        m_axi_awlen <= 0;
        m_axi_wvalid <= 0;
        m_axi_wdata <= 0;
        m_axi_wstrb <= 0;
        m_axi_wlast <= 0;
    end else begin
        // Defaults: deassert single-cycle signals
        word_rdata_valid <= 0;
        word_accepted <= 0;

        case (state)

        S_IDLE: begin
            word_busy <= 0;
            m_axi_arvalid <= 0;
            m_axi_awvalid <= 0;
            m_axi_wvalid <= 0;
            if (word_rd) begin
                // Capture read request
                m_axi_arvalid <= 1;
                m_axi_araddr <= {6'b0, word_addr, 2'b00};
                m_axi_arlen <= {5'b0, word_burst_len};
                word_busy <= 1;
                state <= S_AR;
            end else if (word_wr) begin
                // Capture write request — issue AW and W simultaneously
                m_axi_awvalid <= 1;
                m_axi_awaddr <= {6'b0, word_addr, 2'b00};
                m_axi_awlen <= 8'd0;  // Single-beat writes only
                m_axi_wvalid <= 1;
                m_axi_wdata <= word_wdata;
                m_axi_wstrb <= word_wstrb;
                m_axi_wlast <= 1;
                word_busy <= 1;
                state <= S_AW;
            end
        end

        // ============================================
        // Read path: AR → R
        // ============================================
        S_AR: begin
            if (m_axi_arready) begin
                m_axi_arvalid <= 0;
                word_accepted <= 1;
                state <= S_R;
            end
            // else: hold arvalid asserted
        end

        S_R: begin
            if (m_axi_rvalid) begin
                word_rdata_valid <= 1;
                if (m_axi_rlast) begin
                    word_busy <= 0;
                    state <= S_IDLE;
                end
            end
        end

        // ============================================
        // Write path: AW → W → B
        // ============================================
        S_AW: begin
            // AW and W issued simultaneously from S_IDLE.
            // Track acceptance of each independently.
            if (m_axi_awready && m_axi_wready) begin
                // Both accepted same cycle
                m_axi_awvalid <= 0;
                m_axi_wvalid <= 0;
                word_accepted <= 1;
                state <= S_B;
            end else if (m_axi_awready) begin
                // AW accepted, W still pending
                m_axi_awvalid <= 0;
                word_accepted <= 1;
                state <= S_W;
            end else if (m_axi_wready) begin
                // W accepted, AW still pending — keep awvalid
                m_axi_wvalid <= 0;
                // Stay in S_AW, wait for awready
            end
            // else: hold both awvalid and wvalid
        end

        S_W: begin
            if (m_axi_wready) begin
                m_axi_wvalid <= 0;
                state <= S_B;
            end
        end

        S_B: begin
            if (m_axi_bvalid) begin
                word_busy <= 0;
                state <= S_IDLE;
            end
        end

        default: state <= S_IDLE;

        endcase
    end
end

endmodule
