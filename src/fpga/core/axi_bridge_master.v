//
// AXI4 Bridge Master — Bridge FIFO Drains + Bridge Reads → AXI4
//
// Converts bridge FIFO drain writes and bridge SDRAM reads into
// single-beat AXI4 transactions.  Lowest priority (M3) on the
// SDRAM arbiter.
//
// Pure register/LUT — 0 M10K.
//

`default_nettype none

module axi_bridge_master (
    input wire clk,
    input wire reset_n,

    // Bridge write FIFO interface (dcfifo output, clk_ram_controller domain)
    input  wire [55:0] fifo_q,       // {addr[23:0], wdata[31:0]}
    input  wire        fifo_empty,
    output reg         fifo_rdreq,

    // Bridge read interface (sync'd to clk_ram_controller)
    input  wire        bridge_rd_req,     // Level: high while read pending
    input  wire [23:0] bridge_rd_addr,    // Word address [25:2]
    output reg  [31:0] bridge_rd_data,    // Captured read data
    output reg         bridge_rd_done,    // Pulse: read complete

    // AXI4 Master interface
    // AR channel
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    output reg  [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,

    // R channel
    input  wire        m_axi_rvalid,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,

    // AW channel
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output reg  [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,

    // W channel
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    output reg  [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,

    // B channel
    input  wire        m_axi_bvalid,
    input  wire [1:0]  m_axi_bresp,

    // Status
    output wire        idle,
    output wire        wr_idle   // No write transaction in flight and FIFO empty
);

wire reset = ~reset_n;

// All transactions are single-beat
assign m_axi_arlen = 8'd0;
assign m_axi_awlen = 8'd0;
assign m_axi_wstrb = 4'b1111;
assign m_axi_wlast = 1'b1;

// FSM states
localparam S_IDLE  = 3'd0;
localparam S_RD_AR = 3'd1;  // Assert arvalid, wait arready
localparam S_RD_R  = 3'd2;  // Wait rvalid, capture rdata
localparam S_WR    = 3'd3;  // Assert awvalid+wvalid, wait both accepted
localparam S_WR_B  = 3'd4;  // Wait bvalid

reg [2:0] state;
reg       aw_accepted;  // Track AW/W acceptance independently in S_WR
reg       w_accepted;
reg       rd_done_sent; // Prevent re-issuing read for same request

assign idle = (state == S_IDLE) && fifo_empty && !bridge_rd_req;
assign wr_idle = (state != S_WR) && (state != S_WR_B) && fifo_empty;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state <= S_IDLE;
        m_axi_arvalid <= 0;
        m_axi_araddr <= 0;
        m_axi_awvalid <= 0;
        m_axi_awaddr <= 0;
        m_axi_wvalid <= 0;
        m_axi_wdata <= 0;
        aw_accepted <= 0;
        w_accepted <= 0;
        fifo_rdreq <= 0;
        bridge_rd_data <= 0;
        bridge_rd_done <= 0;
        rd_done_sent <= 0;
    end else begin
        // Defaults
        fifo_rdreq <= 0;
        bridge_rd_done <= 0;

        // Clear rd_done_sent when request goes away
        if (!bridge_rd_req)
            rd_done_sent <= 0;

        case (state)
        S_IDLE: begin
            // Priority: bridge read > FIFO drain write
            if (bridge_rd_req && !rd_done_sent) begin
                m_axi_arvalid <= 1;
                m_axi_araddr <= {6'b0, bridge_rd_addr, 2'b0};
                state <= S_RD_AR;
            end else if (!fifo_empty) begin
                // Latch FIFO data and pop
                fifo_rdreq <= 1;
                m_axi_awvalid <= 1;
                m_axi_awaddr <= {6'b0, fifo_q[55:32], 2'b0};
                m_axi_wvalid <= 1;
                m_axi_wdata <= fifo_q[31:0];
                aw_accepted <= 0;
                w_accepted <= 0;
                state <= S_WR;
            end
        end

        S_RD_AR: begin
            if (m_axi_arready) begin
                m_axi_arvalid <= 0;
                state <= S_RD_R;
            end
        end

        S_RD_R: begin
            if (m_axi_rvalid) begin
                bridge_rd_data <= m_axi_rdata;
                bridge_rd_done <= 1;
                rd_done_sent <= 1;
                state <= S_IDLE;
            end
        end

        S_WR: begin
            // Track AW and W acceptance independently
            if (m_axi_awready && !aw_accepted) begin
                aw_accepted <= 1;
                m_axi_awvalid <= 0;
            end
            if (m_axi_wready && !w_accepted) begin
                w_accepted <= 1;
                m_axi_wvalid <= 0;
            end
            // Both accepted: wait for B
            if ((aw_accepted || m_axi_awready) && (w_accepted || m_axi_wready)) begin
                m_axi_awvalid <= 0;
                m_axi_wvalid <= 0;
                state <= S_WR_B;
            end
        end

        S_WR_B: begin
            if (m_axi_bvalid) begin
                state <= S_IDLE;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
