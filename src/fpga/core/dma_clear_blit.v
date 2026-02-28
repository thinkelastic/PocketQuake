//
// DMA Clear/Blit Engine
// Fast SDRAM fill and copy operations for framebuffer/zbuffer clearing
//
// Register map (active_addr[4:2] selects register):
//   0x00: DMA_SRC_ADDR   (RW) - Source SDRAM byte address (for copy mode)
//   0x04: DMA_DST_ADDR   (RW) - Destination SDRAM byte address
//   0x08: DMA_LENGTH     (RW) - Transfer length in bytes (must be 4-byte aligned)
//   0x0C: DMA_FILL_DATA  (RW) - 32-bit fill pattern
//   0x10: DMA_CONTROL    (W)  - bit0=start, bit1=mode (0=fill, 1=copy)
//   0x14: DMA_STATUS     (R)  - bit0=busy
//

`default_nettype none

module dma_clear_blit (
    input wire        clk,
    input wire        reset_n,

    // CPU register interface
    input wire        reg_wr,          // Write strobe (active for 1 cycle)
    input wire [4:0]  reg_addr,        // Register address = byte_offset[6:2]
    input wire [31:0] reg_wdata,       // Write data
    output reg [31:0] reg_rdata,       // Read data (active same cycle)

    // AXI4 Master interface (to axi_sdram_arbiter)
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    output reg  [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,     // Always 0 (single-beat reads)

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

    // Status
    output wire       active           // DMA is running (blocks CPU SDRAM access)
);

// Static AXI4 ties — single-beat only
assign m_axi_arlen = 8'd0;
assign m_axi_awlen = 8'd0;
assign m_axi_wlast = 1'b1;

// Configuration registers
reg [31:0] src_addr_reg;    // Source byte address
reg [31:0] dst_addr_reg;    // Destination byte address
reg [31:0] length_reg;      // Length in bytes
reg [31:0] fill_data_reg;   // Fill pattern
reg        copy_mode;       // 0=fill, 1=copy

// DMA state machine
localparam ST_IDLE       = 3'd0;
localparam ST_FILL_ISSUE = 3'd1;
localparam ST_FILL_WAIT  = 3'd2;
localparam ST_COPY_READ  = 3'd3;
localparam ST_COPY_RWAIT = 3'd4;
localparam ST_COPY_WRITE = 3'd5;
localparam ST_COPY_WWAIT = 3'd6;

reg [2:0]  state;
reg [31:0] cur_src;         // Current source byte address
reg [31:0] cur_dst;         // Current destination byte address
reg [31:0] remaining;       // Remaining bytes to transfer
reg [31:0] copy_buf;        // Temporary buffer for copy read data

assign active = (state != ST_IDLE);

// Register read mux (active same cycle)
always @(*) begin
    case (reg_addr[2:0])
        3'd0: reg_rdata = src_addr_reg;
        3'd1: reg_rdata = dst_addr_reg;
        3'd2: reg_rdata = length_reg;
        3'd3: reg_rdata = fill_data_reg;
        3'd4: reg_rdata = 32'd0;           // CONTROL is write-only
        3'd5: reg_rdata = {31'd0, active};  // STATUS
        default: reg_rdata = 32'd0;
    endcase
end

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        src_addr_reg <= 32'd0;
        dst_addr_reg <= 32'd0;
        length_reg <= 32'd0;
        fill_data_reg <= 32'd0;
        copy_mode <= 1'b0;
        state <= ST_IDLE;
        cur_src <= 32'd0;
        cur_dst <= 32'd0;
        remaining <= 32'd0;
        copy_buf <= 32'd0;
        m_axi_arvalid <= 1'b0;
        m_axi_araddr <= 32'd0;
        m_axi_awvalid <= 1'b0;
        m_axi_awaddr <= 32'd0;
        m_axi_wvalid <= 1'b0;
        m_axi_wdata <= 32'd0;
        m_axi_wstrb <= 4'b0;
    end else begin
        // AXI4 valid/ready handshake: deassert valid when ready fires
        if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 1'b0;
        if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 1'b0;
        if (m_axi_wvalid && m_axi_wready)   m_axi_wvalid <= 1'b0;

        // Register writes (only when idle)
        if (reg_wr && !active) begin
            case (reg_addr[2:0])
                3'd0: src_addr_reg <= reg_wdata;
                3'd1: dst_addr_reg <= reg_wdata;
                3'd2: length_reg <= reg_wdata;
                3'd3: fill_data_reg <= reg_wdata;
                3'd4: begin
                    // CONTROL: start transfer
                    if (reg_wdata[0] && length_reg != 0) begin
                        copy_mode <= reg_wdata[1];
                        cur_src <= src_addr_reg;
                        cur_dst <= dst_addr_reg;
                        remaining <= length_reg;
                        if (reg_wdata[1])
                            state <= ST_COPY_READ;
                        else
                            state <= ST_FILL_ISSUE;
                    end
                end
                default: ;
            endcase
        end

        // DMA state machine
        case (state)
            ST_IDLE: begin
                // Nothing to do
            end

            // ---- Fill mode ----
            ST_FILL_ISSUE: begin
                // Assert AW+W simultaneously for single-beat write
                m_axi_awvalid <= 1'b1;
                m_axi_awaddr  <= {6'b0, cur_dst[25:2], 2'b00};
                m_axi_wvalid  <= 1'b1;
                m_axi_wdata   <= fill_data_reg;
                m_axi_wstrb   <= 4'b1111;
                state <= ST_FILL_WAIT;
            end

            ST_FILL_WAIT: begin
                // Wait for B response (write complete)
                if (m_axi_bvalid) begin
                    cur_dst <= cur_dst + 32'd4;
                    remaining <= remaining - 32'd4;
                    if (remaining <= 32'd4)
                        state <= ST_IDLE;
                    else
                        state <= ST_FILL_ISSUE;
                end
            end

            // ---- Copy mode ----
            ST_COPY_READ: begin
                // Assert AR for single-beat read
                m_axi_arvalid <= 1'b1;
                m_axi_araddr  <= {6'b0, cur_src[25:2], 2'b00};
                state <= ST_COPY_RWAIT;
            end

            ST_COPY_RWAIT: begin
                // Wait for R data
                if (m_axi_rvalid) begin
                    copy_buf <= m_axi_rdata;
                    state <= ST_COPY_WRITE;
                end
            end

            ST_COPY_WRITE: begin
                // Assert AW+W simultaneously for single-beat write
                m_axi_awvalid <= 1'b1;
                m_axi_awaddr  <= {6'b0, cur_dst[25:2], 2'b00};
                m_axi_wvalid  <= 1'b1;
                m_axi_wdata   <= copy_buf;
                m_axi_wstrb   <= 4'b1111;
                state <= ST_COPY_WWAIT;
            end

            ST_COPY_WWAIT: begin
                // Wait for B response (write complete)
                if (m_axi_bvalid) begin
                    cur_src <= cur_src + 32'd4;
                    cur_dst <= cur_dst + 32'd4;
                    remaining <= remaining - 32'd4;
                    if (remaining <= 32'd4)
                        state <= ST_IDLE;
                    else
                        state <= ST_COPY_READ;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
