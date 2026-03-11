//
// AXI4 Slave Wrapper for PSRAM (psram_controller word interface)
//
// Converts AXI4 transactions to the psram_controller word-level protocol.
// Reads use sync burst mode for entire AXI burst (1 hardware burst per AXI read).
// Writes still use single-word async operations (PSRAM has no burst write).
//
// Protocol:
//   Reads:  burst_rd pulse → burst_rdata_valid pulses for each 32-bit word
//   Writes: psram_wr pulse → busy goes HIGH → wait → !busy (write done)
//

`default_nettype none

module axi_psram_slave (
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

    // PSRAM word interface (single-word reads/writes, to psram_controller via mux)
    output reg         psram_rd,
    output reg         psram_wr,
    output reg  [21:0] psram_addr,
    output reg  [31:0] psram_wdata,
    output reg  [3:0]  psram_wstrb,
    input  wire [31:0] psram_rdata,
    input  wire        psram_busy,
    input  wire        psram_rdata_valid,

    // PSRAM sync burst read interface (to psram_controller)
    output reg         psram_burst_rd,
    output reg  [5:0]  psram_burst_len,
    input  wire        psram_burst_rdata_valid,
    input  wire [31:0] psram_burst_rdata
);

wire reset = ~reset_n;

// FSM states
localparam S_IDLE       = 4'd0;
localparam S_RD_BURST   = 4'd1;  // Issue burst_rd, wait for data
localparam S_RD_STREAM  = 4'd2;  // Stream burst data to AXI R channel
localparam S_WR_CMD     = 4'd4;  // Issue word_wr, wait for busy
localparam S_WR_WAIT    = 4'd5;  // Wait for !busy (write done)
localparam S_WR_NEXT    = 4'd6;  // Accept next W beat

reg [3:0] state;

// Transaction tracking
reg [7:0]  burst_len;
reg [7:0]  beat_count;
reg [31:0] addr_r;
reg        cmd_issued;
reg        psram_started;   // busy was seen after issuing command
reg [7:0]  issue_wait;      // Timeout counter for missed commands

wire beat_is_last = (beat_count == burst_len);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state <= S_IDLE;
        burst_len <= 0;
        beat_count <= 0;
        addr_r <= 0;
        cmd_issued <= 0;
        psram_started <= 0;
        issue_wait <= 0;

        s_axi_arready <= 0;
        s_axi_rvalid <= 0;
        s_axi_rdata <= 0;
        s_axi_rresp <= 0;
        s_axi_rlast <= 0;
        s_axi_awready <= 0;
        s_axi_wready <= 0;
        s_axi_bvalid <= 0;
        s_axi_bresp <= 0;

        psram_rd <= 0;
        psram_wr <= 0;
        psram_addr <= 0;
        psram_wdata <= 0;
        psram_wstrb <= 0;
        psram_burst_rd <= 0;
        psram_burst_len <= 0;
    end else begin
        // Defaults
        s_axi_arready <= 0;
        s_axi_awready <= 0;
        s_axi_wready <= 0;
        s_axi_rvalid <= 0;
        s_axi_bvalid <= 0;
        psram_rd <= 0;
        psram_wr <= 0;
        psram_burst_rd <= 0;
        case (state)

        S_IDLE: begin
            cmd_issued <= 0;
            psram_started <= 0;
            issue_wait <= 0;
            if (s_axi_arvalid) begin
                s_axi_arready <= 1;
                addr_r <= s_axi_araddr;
                burst_len <= s_axi_arlen;
                beat_count <= 0;
                state <= S_RD_BURST;
            end else if (s_axi_awvalid) begin
                s_axi_awready <= 1;
                addr_r <= s_axi_awaddr;
                burst_len <= s_axi_awlen;
                beat_count <= 0;
                if (s_axi_wvalid) begin
                    s_axi_wready <= 1;
                    psram_wdata <= s_axi_wdata;
                    psram_wstrb <= s_axi_wstrb;
                    state <= S_WR_CMD;
                end else begin
                    state <= S_WR_NEXT;
                end
            end
        end

        // ============================================
        // Read path — sync burst
        // Issues one psram_controller burst_rd for the entire AXI burst.
        // psram_controller assembles halfwords into 32-bit words and
        // pulses burst_rdata_valid for each word.
        // ============================================
        S_RD_BURST: begin
            if (!cmd_issued) begin
                if (!psram_busy) begin
                    psram_burst_rd <= 1;
                    psram_addr <= addr_r[23:2];
                    psram_burst_len <= burst_len[5:0];  // Max 32 words (6-bit → 64 halfwords). I$/D$ use 16.
                    cmd_issued <= 1;
                    state <= S_RD_STREAM;
                end
            end
        end

        S_RD_STREAM: begin
            // AXI4 compliant: hold rvalid until rready acknowledges.
            // PSRAM data arrives every 2 cycles; rready should respond
            // within 1 cycle, so no buffering needed.
            if (s_axi_rvalid && s_axi_rready) begin
                // Handshake complete — beat consumed by master
                beat_count <= beat_count + 1;
                if (beat_is_last) begin
                    cmd_issued <= 0;
                    state <= S_IDLE;
                end else if (psram_burst_rdata_valid) begin
                    // Pipeline: next data already available
                    s_axi_rvalid <= 1;
                    s_axi_rdata <= psram_burst_rdata;
                    s_axi_rresp <= 2'b00;
                    s_axi_rlast <= ((beat_count + 8'd1) == burst_len);
                end
                // else: rvalid cleared by default, wait for next psram data
            end else if (s_axi_rvalid) begin
                // rvalid asserted but rready not yet — hold (AXI compliance)
                s_axi_rvalid <= 1;
            end else if (psram_burst_rdata_valid) begin
                // New data from PSRAM, no pending handshake
                s_axi_rvalid <= 1;
                s_axi_rdata <= psram_burst_rdata;
                s_axi_rresp <= 2'b00;
                s_axi_rlast <= beat_is_last;
            end
        end

        // ============================================
        // Write path (single word per PSRAM access, unchanged)
        // ============================================
        S_WR_CMD: begin
            if (!cmd_issued) begin
                if (!psram_busy) begin
                    psram_wr <= 1;
                    psram_addr <= addr_r[23:2];
                    cmd_issued <= 1;
                    psram_started <= 0;
                    issue_wait <= 0;
                end
            end else begin
                if (!psram_started && psram_busy) begin
                    psram_started <= 1;
                    issue_wait <= 0;
                end else if (!psram_started) begin
                    issue_wait <= issue_wait + 1;
                    if (&issue_wait) begin
                        cmd_issued <= 0;
                        issue_wait <= 0;
                    end
                end else if (psram_started && !psram_busy) begin
                    // Write complete
                    state <= S_WR_WAIT;
                end
            end
        end

        S_WR_WAIT: begin
            // Write beat done
            beat_count <= beat_count + 1;
            cmd_issued <= 0;
            psram_started <= 0;
            if (beat_is_last) begin
                s_axi_bvalid <= 1;
                s_axi_bresp <= 2'b00;
                state <= S_IDLE;
            end else begin
                addr_r <= addr_r + 32'd4;
                state <= S_WR_NEXT;
            end
        end

        S_WR_NEXT: begin
            if (s_axi_wvalid) begin
                s_axi_wready <= 1;
                psram_wdata <= s_axi_wdata;
                psram_wstrb <= s_axi_wstrb;
                state <= S_WR_CMD;
            end
        end

        default: state <= S_IDLE;

        endcase
    end
end

endmodule
