//
// Pixel Poke — MMIO bypass for CPU-direct pixel + z-buffer writes
//
// Converts CPU word stores (sw) to byte writes (SDRAM framebuffer) and
// halfword writes (SRAM z-buffer), avoiding VexiiRiscv sb/sh timing issues.
//
// Registers (active on reg_wr pulse):
//   0: POKE_FB_ADDR  — 25-bit SDRAM byte address (framebuffer pixel)
//   1: POKE_Z_ADDR   — 22-bit SRAM byte address (z-buffer entry)
//   2: POKE_PIXEL    — {z_value[15:0], 8'b0, texel[7:0]}
//                       Write triggers SDRAM byte + SRAM halfword write,
//                       auto-increments FB_ADDR (+1) and Z_ADDR (+2).
//   3: POKE_STATUS   — read: bit 0 = busy
//

`default_nettype none

module pixel_poke (
    input wire clk,
    input wire reset_n,

    // Register interface (from axi_periph_slave)
    input wire        reg_wr,
    input wire [1:0]  reg_addr,
    input wire [31:0] reg_wdata,
    output wire [31:0] reg_rdata,

    // AXI4 write-only master (to SDRAM arbiter M1, muxed with DMA)
    output reg         m_axi_awvalid,
    input wire         m_axi_awready,
    output reg  [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output reg         m_axi_wvalid,
    input wire         m_axi_wready,
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    input wire         m_axi_bvalid,

    // SRAM write port (to SRAM mux, 4th priority)
    output reg         sram_wr,
    output reg  [21:0] sram_addr,
    output reg  [31:0] sram_wdata,
    output reg  [3:0]  sram_wstrb,
    input wire         sram_busy
);

// Single-beat writes
assign m_axi_awlen = 8'd0;
assign m_axi_wlast = 1'b1;

// Latched addresses
reg [24:0] fb_addr_r;
reg [21:0] z_addr_r;

// FSM
localparam ST_IDLE     = 3'd0;
localparam ST_SDRAM_AW = 3'd1;
localparam ST_SDRAM_W  = 3'd2;
localparam ST_SDRAM_B  = 3'd3;
localparam ST_SRAM     = 3'd4;

reg [2:0] state;
reg busy;

// Status read
assign reg_rdata = {31'b0, busy};

// Compute byte lane from fb address
wire [1:0] byte_pos = fb_addr_r[1:0];

// Latched pixel data
reg [7:0] texel_r;
reg [15:0] zval_r;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= ST_IDLE;
        busy <= 0;
        fb_addr_r <= 0;
        z_addr_r <= 0;
        texel_r <= 0;
        zval_r <= 0;
        m_axi_awvalid <= 0;
        m_axi_awaddr <= 0;
        m_axi_wvalid <= 0;
        m_axi_wdata <= 0;
        m_axi_wstrb <= 0;
        sram_wr <= 0;
        sram_addr <= 0;
        sram_wdata <= 0;
        sram_wstrb <= 0;
    end else begin
        case (state)
        ST_IDLE: begin
            busy <= 0;
            sram_wr <= 0;
            if (reg_wr) begin
                case (reg_addr)
                2'd0: fb_addr_r <= reg_wdata[24:0];
                2'd1: z_addr_r <= reg_wdata[21:0];
                2'd2: begin
                    // POKE_PIXEL: latch data, start SDRAM write
                    texel_r <= reg_wdata[7:0];
                    zval_r <= reg_wdata[31:16];
                    busy <= 1;
                    state <= ST_SDRAM_AW;

                    // Issue AW immediately
                    m_axi_awvalid <= 1;
                    m_axi_awaddr <= {7'b0, fb_addr_r[24:2], 2'b00};

                    // Pre-compute W channel data
                    case (fb_addr_r[1:0])
                    2'd0: begin m_axi_wdata <= {24'b0, reg_wdata[7:0]};       m_axi_wstrb <= 4'b0001; end
                    2'd1: begin m_axi_wdata <= {16'b0, reg_wdata[7:0], 8'b0}; m_axi_wstrb <= 4'b0010; end
                    2'd2: begin m_axi_wdata <= {8'b0, reg_wdata[7:0], 16'b0}; m_axi_wstrb <= 4'b0100; end
                    2'd3: begin m_axi_wdata <= {reg_wdata[7:0], 24'b0};       m_axi_wstrb <= 4'b1000; end
                    endcase
                end
                default: ;
                endcase
            end
        end

        // SDRAM AW phase: wait for awready
        ST_SDRAM_AW: begin
            if (m_axi_awready) begin
                m_axi_awvalid <= 0;
                m_axi_wvalid <= 1;
                state <= ST_SDRAM_W;
            end
        end

        // SDRAM W phase: wait for wready
        ST_SDRAM_W: begin
            if (m_axi_wready) begin
                m_axi_wvalid <= 0;
                state <= ST_SDRAM_B;
            end
        end

        // SDRAM B phase: wait for bvalid, then start SRAM write
        ST_SDRAM_B: begin
            if (m_axi_bvalid) begin
                // Auto-increment FB address
                fb_addr_r <= fb_addr_r + 1;

                // Start SRAM z-buffer write — hold sram_wr until accepted
                sram_wr <= 1;
                sram_addr <= z_addr_r[21:2];  // Word address
                if (z_addr_r[1]) begin
                    // Upper halfword
                    sram_wdata <= {zval_r, 16'b0};
                    sram_wstrb <= 4'b1100;
                end else begin
                    // Lower halfword
                    sram_wdata <= {16'b0, zval_r};
                    sram_wstrb <= 4'b0011;
                end
                state <= ST_SRAM;
            end
        end

        // SRAM: hold sram_wr high until controller accepts (not busy),
        // then wait for write to complete
        ST_SRAM: begin
            if (sram_wr && !sram_busy) begin
                // Accepted — deassert wr, wait for completion
                sram_wr <= 0;
            end else if (!sram_wr && !sram_busy) begin
                // Write completed
                z_addr_r <= z_addr_r + 2;
                busy <= 0;
                state <= ST_IDLE;
            end
        end

        default: state <= ST_IDLE;
        endcase
    end
end

endmodule
