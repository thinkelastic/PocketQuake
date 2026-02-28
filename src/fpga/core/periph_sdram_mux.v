//
// Peripheral SDRAM Mux
// Multiplexes SDRAM access from multiple accelerator peripherals onto a single
// SDRAM port. Only one peripheral may be active at a time (firmware ensures this).
//
// Priority: DMA > Span Rasterizer > (future Surface Combine)
// (But only one should ever be active simultaneously)
//

`default_nettype none

module periph_sdram_mux (
    input wire clk,

    // DMA port
    input wire        dma_rd,
    input wire        dma_wr,
    input wire [23:0] dma_addr,
    input wire [31:0] dma_wdata,
    input wire [3:0]  dma_wstrb,
    input wire        dma_active,

    // Span rasterizer port
    input wire        span_rd,
    input wire        span_wr,
    input wire [23:0] span_addr,
    input wire [31:0] span_wdata,
    input wire [3:0]  span_wstrb,
    input wire [2:0]  span_burst_len,
    input wire        span_active,

    // Muxed output to core_top SDRAM arbiter
    output wire        mux_rd,
    output wire        mux_wr,
    output wire [23:0] mux_addr,
    output wire [31:0] mux_wdata,
    output wire [3:0]  mux_wstrb,
    output wire [2:0]  mux_burst_len,
    output wire        mux_active,      // Any peripheral is active

    // Accepted feedback from arbiter (active-high pulse)
    input wire         accepted,
    output wire        span_accepted    // Forwarded to span rasterizer
);

// DMA has priority, but only one should be active at a time.
// If both are somehow active, DMA wins.
assign mux_rd    = dma_active ? dma_rd    : span_rd;
assign mux_wr    = dma_active ? dma_wr    : span_wr;
assign mux_addr  = dma_active ? dma_addr  : span_addr;
assign mux_wdata = dma_active ? dma_wdata : span_wdata;
assign mux_wstrb     = dma_active ? dma_wstrb : span_wstrb;
assign mux_burst_len = dma_active ? 3'd0      : span_burst_len;
assign mux_active = dma_active | span_active;

// Route accepted back to span only when DMA is not active
assign span_accepted = accepted & ~dma_active;

endmodule
