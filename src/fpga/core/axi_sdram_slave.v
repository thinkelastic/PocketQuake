//
// AXI4 Slave Wrapper for SDRAM (io_sdram word interface)
//
// Converts AXI4 transactions to the io_sdram word-level protocol:
//   word_rd/wr pulse → accepted → busy → rdata_valid (reads)
//
// Features:
//   - Burst reads: ARLEN → word_burst_len (0=1 word, 7=8 words)
//   - Single and burst writes: each W beat → word_wr
//   - Single outstanding transaction
//   - 0 M10K (pure register/LUT)
//

`default_nettype none

module axi_sdram_slave (
    input wire clk,
    input wire reset_n,

    // AXI4 Slave interface
    // AR channel (read address)
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    input  wire [31:0] s_axi_araddr,
    input  wire [7:0]  s_axi_arlen,

    // R channel (read data)
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rlast,

    // AW channel (write address)
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,

    // W channel (write data)
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wlast,

    // B channel (write response)
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    output reg  [1:0]  s_axi_bresp,

    // SDRAM word interface (directly to arbiter in core_top.v)
    output reg         sdram_rd,
    output reg         sdram_wr,
    output reg  [23:0] sdram_addr,
    output reg  [31:0] sdram_wdata,
    output reg  [3:0]  sdram_wstrb,
    output reg  [3:0]  sdram_burst_len,
    input  wire [31:0] sdram_rdata,
    input  wire        sdram_busy,
    input  wire        sdram_accepted,
    input  wire        sdram_rdata_valid
);

wire reset = ~reset_n;

// FSM states
localparam S_IDLE     = 3'd0;
localparam S_RD_CMD   = 3'd1;  // Issue word_rd, wait for accepted
localparam S_RD_DAT   = 3'd2;  // Wait for rdata_valid, send R beats
localparam S_WR_CMD   = 3'd3;  // Issue word_wr, wait for accepted
localparam S_WR_DON   = 3'd4;  // Wait for write completion (!busy)
localparam S_WR_NEXT  = 3'd5;  // Accept next W beat in burst write

reg [2:0] state;

// Transaction tracking
reg [7:0]  burst_len;    // ARLEN/AWLEN
reg [7:0]  beat_count;   // Beats completed
reg [31:0] addr_r;       // Current address (advances per beat)
reg        cmd_issued;   // word_rd/wr issued, waiting for accepted
reg        started;      // accepted seen, waiting for completion

wire beat_is_last = (beat_count == burst_len);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state <= S_IDLE;
        burst_len <= 0;
        beat_count <= 0;
        addr_r <= 0;
        cmd_issued <= 0;
        started <= 0;

        s_axi_arready <= 0;
        s_axi_rvalid <= 0;
        s_axi_rdata <= 0;
        s_axi_rresp <= 0;
        s_axi_rlast <= 0;
        s_axi_awready <= 0;
        s_axi_wready <= 0;
        s_axi_bvalid <= 0;
        s_axi_bresp <= 0;

        sdram_rd <= 0;
        sdram_wr <= 0;
        sdram_addr <= 0;
        sdram_wdata <= 0;
        sdram_wstrb <= 0;
        sdram_burst_len <= 0;
    end else begin
        // Defaults: deassert single-cycle signals
        s_axi_arready <= 0;
        s_axi_awready <= 0;
        s_axi_wready <= 0;
        s_axi_rvalid <= 0;
        s_axi_bvalid <= 0;
        sdram_rd <= 0;
        sdram_wr <= 0;
        sdram_burst_len <= 0;

        case (state)

        S_IDLE: begin
            cmd_issued <= 0;
            started <= 0;
            // Reads have priority over writes
            if (s_axi_arvalid) begin
                s_axi_arready <= 1;
                addr_r <= s_axi_araddr;
                burst_len <= s_axi_arlen;
                beat_count <= 0;
                // Early command issue: if SDRAM idle, start read 1 cycle sooner
                if (!sdram_busy) begin
                    sdram_rd <= 1;
                    sdram_addr <= s_axi_araddr[25:2];
                    sdram_burst_len <= s_axi_arlen[3:0];
                    cmd_issued <= 1;
                end
                state <= S_RD_CMD;
            end else if (s_axi_awvalid) begin
                s_axi_awready <= 1;
                addr_r <= s_axi_awaddr;
                burst_len <= s_axi_awlen;
                beat_count <= 0;
                // Also accept W if valid (common case: AW and W arrive together)
                if (s_axi_wvalid) begin
                    s_axi_wready <= 1;
                    sdram_wdata <= s_axi_wdata;
                    sdram_wstrb <= s_axi_wstrb;
                    // Early command issue for writes too
                    if (!sdram_busy) begin
                        sdram_wr <= 1;
                        sdram_addr <= s_axi_awaddr[25:2];
                        cmd_issued <= 1;
                    end
                    state <= S_WR_CMD;
                end else begin
                    state <= S_WR_NEXT;
                end
            end
        end

        // ============================================
        // Read path
        // ============================================
        S_RD_CMD: begin
            // Issue read to SDRAM, hold until accepted
            if (!cmd_issued) begin
                if (!sdram_busy) begin
                    sdram_rd <= 1;
                    sdram_addr <= addr_r[25:2];
                    sdram_burst_len <= burst_len[3:0];
                    cmd_issued <= 1;
                    started <= 0;
                end
            end else begin
                // Hold read request until arbiter accepts
                sdram_rd <= 1;
                sdram_addr <= addr_r[25:2];
                sdram_burst_len <= burst_len[3:0];
                if (sdram_accepted) begin
                    started <= 1;
                    state <= S_RD_DAT;
                end
            end
        end

        S_RD_DAT: begin
            // Wait for read data. Gate with started to prevent
            // capturing peripheral data before our command was accepted.
            if (started && sdram_rdata_valid) begin
                s_axi_rvalid <= 1;
                s_axi_rdata <= sdram_rdata;
                s_axi_rresp <= 2'b00;  // OKAY
                s_axi_rlast <= beat_is_last;
                beat_count <= beat_count + 1;
                if (beat_is_last) begin
                    state <= S_IDLE;
                    cmd_issued <= 0;
                    started <= 0;
                end
                // For burst: SDRAM controller sends subsequent words automatically
            end
        end

        // ============================================
        // Write path
        // ============================================
        S_WR_CMD: begin
            // Issue write to SDRAM, hold until accepted
            if (!cmd_issued) begin
                if (!sdram_busy) begin
                    sdram_wr <= 1;
                    sdram_addr <= addr_r[25:2];
                    cmd_issued <= 1;
                    started <= 0;
                end
            end else begin
                sdram_wr <= 1;
                sdram_addr <= addr_r[25:2];
                if (sdram_accepted) begin
                    started <= 1;
                    state <= S_WR_DON;
                end
            end
        end

        S_WR_DON: begin
            // Wait for write completion (accepted and not busy)
            if (started && !sdram_busy) begin
                beat_count <= beat_count + 1;
                cmd_issued <= 0;
                started <= 0;
                if (beat_is_last) begin
                    // All beats written - send B response
                    s_axi_bvalid <= 1;
                    s_axi_bresp <= 2'b00;  // OKAY
                    state <= S_IDLE;
                end else begin
                    // More beats: advance address, get next W
                    addr_r <= addr_r + 32'd4;
                    state <= S_WR_NEXT;
                end
            end
        end

        S_WR_NEXT: begin
            // Accept next W beat
            if (s_axi_wvalid) begin
                s_axi_wready <= 1;
                sdram_wdata <= s_axi_wdata;
                sdram_wstrb <= s_axi_wstrb;
                state <= S_WR_CMD;
            end
        end

        default: state <= S_IDLE;

        endcase
    end
end

endmodule
