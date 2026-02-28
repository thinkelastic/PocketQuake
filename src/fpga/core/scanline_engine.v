/*
 * Scanline Engine - Hardware GenSpan accelerator
 *
 * Replaces R_GenerateSpans_Array: CPU feeds sorted edges per scanline,
 * hardware maintains surface stack in registers, emits spans to BRAM.
 *
 * Register Map (offset from base 0x60000000):
 *   0x00  SCAN_EDGE_HEAD_U   [W]  background start x (u >> 20)
 *   0x04  SCAN_EDGE_TAIL_U   [W]  background end x (u >> 20)
 *   0x08  SCAN_SCANLINE_V    [W]  current scanline number (unused by HW)
 *   0x0C  SCAN_EDGE_COUNT    [W]  number of edges this scanline
 *   0x10  SCAN_EDGE_DATA     [W]  packed edge word (auto-inc write to BRAM)
 *   0x14  SCAN_SURFACE_KEY   [W]  pre-load surface key BRAM
 *   0x18  SCAN_CONTROL       [W]  bit0=start, bit1=backward mode
 *   0x1C  SCAN_STATUS        [R]  bit0=busy, bit1=done
 *   0x20  SCAN_SPAN_COUNT    [R]  number of spans emitted
 *   0x24  SCAN_SPAN_DATA     [R]  pop one span (auto-increment read ptr)
 *   0x28  SCAN_FRAME_INIT    [W]  write 1 to clear spanstate BRAM
 */

module scanline_engine (
    input  wire        clk,
    input  wire        reset_n,

    // Register interface (from axi_periph_slave)
    input  wire        reg_wr,
    input  wire        reg_rd,
    input  wire [3:0]  reg_addr,    // byte_offset[5:2]
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata
);

// ============================================
// Configuration registers
// ============================================
reg [9:0]  edge_head_u;
reg [9:0]  edge_tail_u;
reg [9:0]  edge_count;
reg        backward_mode;

// ============================================
// Edge Buffer BRAM (256 x 32 bits, 1 M10K)
// CPU writes edges here before starting processing.
// HW reads sequentially during processing.
// ============================================
reg [31:0] edgebuf_mem [0:255];
reg [31:0] edgebuf_rd_reg;
reg [7:0]  edgebuf_wr_ptr;
reg [7:0]  edgebuf_rd_addr;

always @(posedge clk) begin
    if (reg_wr && reg_addr == 4'd4)
        edgebuf_mem[edgebuf_wr_ptr] <= reg_wdata;
    edgebuf_rd_reg <= edgebuf_mem[edgebuf_rd_addr];
end

// ============================================
// Surface Key BRAM (1024 x 16 bits, 2 M10K)
// Indexed by surface index, content: {insubmodel[15], key[14:0]}
// ============================================
reg  [9:0]  surfkey_wr_addr;
reg  [15:0] surfkey_wr_data;
reg         surfkey_wr_en;
reg  [9:0]  surfkey_rd_addr;

reg [15:0] surfkey_mem [0:1023];
reg [15:0] surfkey_rd_reg;
always @(posedge clk) begin
    if (surfkey_wr_en)
        surfkey_mem[surfkey_wr_addr] <= surfkey_wr_data;
    surfkey_rd_reg <= surfkey_mem[surfkey_rd_addr];
end

// ============================================
// Spanstate BRAM (1024 x 8 bits, 1 M10K)
// Indexed by surface index, content: spanstate counter
// ============================================
reg  [9:0] spanstate_wr_addr;
reg  [7:0] spanstate_wr_data;
reg        spanstate_wr_en;
reg  [9:0] spanstate_rd_addr;

reg [7:0] spanstate_mem [0:1023];
reg [7:0] spanstate_rd_reg;
always @(posedge clk) begin
    if (spanstate_wr_en)
        spanstate_mem[spanstate_wr_addr] <= spanstate_wr_data;
    spanstate_rd_reg <= spanstate_mem[spanstate_rd_addr];
end

// Frame init clear counter
reg [9:0]  frame_clear_addr;

// ============================================
// Span Output BRAM (512 x 32 bits, 2 M10K)
// Format: {2'b0, count[29:20], u[19:10], surf_idx[9:0]}
// ============================================
reg  [8:0]  span_wr_ptr;
reg  [8:0]  span_rd_ptr;
reg  [31:0] span_wr_data;
reg         span_wr_en;

reg [31:0] span_mem [0:511];
reg [31:0] span_rd_reg;
always @(posedge clk) begin
    if (span_wr_en)
        span_mem[span_wr_ptr] <= span_wr_data;
    span_rd_reg <= span_mem[span_rd_ptr];
end

// ============================================
// Surface Stack Register File (16 entries)
// Position 0 = top (highest priority / closest to viewer)
// ============================================
localparam STACK_DEPTH = 16;

reg [15:0] stack_key   [0:STACK_DEPTH-1];
reg [9:0]  stack_surf  [0:STACK_DEPTH-1];
reg [9:0]  stack_lastu [0:STACK_DEPTH-1];
reg [4:0]  stack_count;  // 0-16

// Background last_u (separate from stack)
reg [9:0]  bg_last_u;

// ============================================
// FSM
// ============================================
localparam ST_IDLE          = 4'd0;
localparam ST_FRAME_CLEAR   = 4'd1;
localparam ST_EDGE_FETCH    = 4'd2;  // issue edge BRAM read
localparam ST_EDGE_DECODE   = 4'd3;  // edge BRAM data available
localparam ST_TRAILING_RD   = 4'd4;  // wait for spanstate BRAM
localparam ST_TRAILING_PROC = 4'd5;  // process trailing edge
localparam ST_LEADING_RD    = 4'd6;  // wait for spanstate + surfkey BRAMs
localparam ST_LEADING_PROC  = 4'd7;  // process leading edge
localparam ST_LEADING_EXEC  = 4'd8;  // execute stack insert with registered insert_pos
localparam ST_CLEANUP       = 4'd9;  // emit final span
localparam ST_CLEANUP_WR    = 4'd10; // clear spanstates
localparam ST_DONE          = 4'd11;

reg [3:0]  state;
reg        busy;
reg        done;

// Current edge being processed
reg [9:0]  cur_iu;       // edge x position
reg [9:0]  cur_surfs0;   // trailing surface index
reg [9:0]  cur_surfs1;   // leading surface index
reg [7:0]  edge_idx;     // current edge index in buffer
reg [4:0]  cleanup_idx;

// ============================================
// Parallel stack search: find surf_idx for removal
// ============================================
reg [4:0]  find_surf_pos;
reg        find_surf_valid;

always @(*) begin
    find_surf_pos = 5'd0;
    find_surf_valid = 1'b0;
    if      (stack_count > 0  && stack_surf[0]  == cur_surfs0) begin find_surf_pos = 5'd0;  find_surf_valid = 1'b1; end
    else if (stack_count > 1  && stack_surf[1]  == cur_surfs0) begin find_surf_pos = 5'd1;  find_surf_valid = 1'b1; end
    else if (stack_count > 2  && stack_surf[2]  == cur_surfs0) begin find_surf_pos = 5'd2;  find_surf_valid = 1'b1; end
    else if (stack_count > 3  && stack_surf[3]  == cur_surfs0) begin find_surf_pos = 5'd3;  find_surf_valid = 1'b1; end
    else if (stack_count > 4  && stack_surf[4]  == cur_surfs0) begin find_surf_pos = 5'd4;  find_surf_valid = 1'b1; end
    else if (stack_count > 5  && stack_surf[5]  == cur_surfs0) begin find_surf_pos = 5'd5;  find_surf_valid = 1'b1; end
    else if (stack_count > 6  && stack_surf[6]  == cur_surfs0) begin find_surf_pos = 5'd6;  find_surf_valid = 1'b1; end
    else if (stack_count > 7  && stack_surf[7]  == cur_surfs0) begin find_surf_pos = 5'd7;  find_surf_valid = 1'b1; end
    else if (stack_count > 8  && stack_surf[8]  == cur_surfs0) begin find_surf_pos = 5'd8;  find_surf_valid = 1'b1; end
    else if (stack_count > 9  && stack_surf[9]  == cur_surfs0) begin find_surf_pos = 5'd9;  find_surf_valid = 1'b1; end
    else if (stack_count > 10 && stack_surf[10] == cur_surfs0) begin find_surf_pos = 5'd10; find_surf_valid = 1'b1; end
    else if (stack_count > 11 && stack_surf[11] == cur_surfs0) begin find_surf_pos = 5'd11; find_surf_valid = 1'b1; end
    else if (stack_count > 12 && stack_surf[12] == cur_surfs0) begin find_surf_pos = 5'd12; find_surf_valid = 1'b1; end
    else if (stack_count > 13 && stack_surf[13] == cur_surfs0) begin find_surf_pos = 5'd13; find_surf_valid = 1'b1; end
    else if (stack_count > 14 && stack_surf[14] == cur_surfs0) begin find_surf_pos = 5'd14; find_surf_valid = 1'b1; end
    else if (stack_count > 15 && stack_surf[15] == cur_surfs0) begin find_surf_pos = 5'd15; find_surf_valid = 1'b1; end
end

// ============================================
// Parallel stack search: find insertion position for leading edge
// Uses surfkey_rd_reg (BRAM output, valid in LEADING_PROC)
// Forward: smaller key = higher priority. Insert before first entry with larger key.
// Backward: larger key = higher priority. Insert before first entry with smaller key.
// Equal keys with insubmodel: insert in front. Without: skip past.
// ============================================
reg [4:0]  insert_pos;
reg [4:0]  insert_pos_r;  // registered insert_pos for timing closure
wire [14:0] ins_key_val = surfkey_rd_reg[14:0];
wire        ins_insubmodel = surfkey_rd_reg[15];

always @(*) begin : find_insert_pos
    integer k;
    insert_pos = stack_count[4:0]; // default: append at end
    for (k = STACK_DEPTH - 1; k >= 0; k = k - 1) begin
        if (k[4:0] < stack_count) begin
            if (!backward_mode) begin
                if (ins_key_val < stack_key[k][14:0])
                    insert_pos = k[4:0];
                else if (ins_key_val == stack_key[k][14:0] && (ins_insubmodel || stack_key[k][15]))
                    insert_pos = k[4:0];
            end else begin
                if (ins_key_val > stack_key[k][14:0])
                    insert_pos = k[4:0];
                else if (ins_key_val == stack_key[k][14:0] && (ins_insubmodel || stack_key[k][15]))
                    insert_pos = k[4:0];
            end
        end
    end
end

// ============================================
// Debug registers
// ============================================
reg [31:0] dbg_first_edge;   // first edge data read from BRAM
reg [8:0]  dbg_spans_tried;  // count of span_wr_en assertions
reg        dbg_edge_captured; // have we captured the first edge?
reg [15:0] dbg_wr_count;     // count of reg_wr assertions

// ============================================
// Register read mux (combinatorial)
// ============================================
always @(*) begin
    case (reg_addr)
        4'd7:    reg_rdata = {30'b0, done, busy};              // 0x1C STATUS
        4'd8:    reg_rdata = {23'b0, span_wr_ptr};  // 0x20 SPAN_COUNT
        4'd9:    reg_rdata = span_rd_reg;            // 0x24 SPAN_DATA
        4'd11:   reg_rdata = dbg_first_edge;         // 0x2C DBG_FIRST_EDGE
        4'd12:   reg_rdata = {dbg_wr_count, edge_count, dbg_spans_tried[5:0]};
                                                      // 0x30 DBG_STATE: {wr_count[31:16], ecount[15:6], spans_tried[5:0]}
        4'd13:   reg_rdata = {12'hDEA, edge_tail_u, edge_head_u};
                                                      // 0x34 DBG_EDGES: {0xDEA[31:20], tail[19:10], head[9:0]}
        default: reg_rdata = 32'd0;
    endcase
end

// ============================================
// Main FSM
// ============================================
integer si;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= ST_IDLE;
        busy <= 0;
        done <= 0;
        edge_head_u <= 0;
        edge_tail_u <= 0;
        edge_count <= 0;
        backward_mode <= 0;
        edgebuf_wr_ptr <= 0;
        edgebuf_rd_addr <= 0;
        span_wr_ptr <= 0;
        span_rd_ptr <= 0;
        span_wr_en <= 0;
        span_wr_data <= 0;
        stack_count <= 0;
        bg_last_u <= 0;
        surfkey_wr_en <= 0;
        surfkey_wr_addr <= 0;
        surfkey_wr_data <= 0;
        surfkey_rd_addr <= 0;
        spanstate_wr_en <= 0;
        spanstate_wr_addr <= 0;
        spanstate_wr_data <= 0;
        spanstate_rd_addr <= 0;
        edge_idx <= 0;
        frame_clear_addr <= 0;
        cur_iu <= 0;
        cur_surfs0 <= 0;
        cur_surfs1 <= 0;
        cleanup_idx <= 0;
        dbg_first_edge <= 0;
        dbg_spans_tried <= 0;
        dbg_edge_captured <= 0;
        dbg_wr_count <= 0;
    end else begin
        // Defaults: deassert write enables
        surfkey_wr_en <= 0;
        spanstate_wr_en <= 0;
        span_wr_en <= 0;

        // Delayed span write pointer increment: fires 1 cycle after span_wr_en
        // is set, same cycle as the BRAM write fires. Both use the old pointer.
        if (span_wr_en) begin
            span_wr_ptr <= span_wr_ptr + 1;
            dbg_spans_tried <= dbg_spans_tried + 1;
        end

        // Debug: count any write assertion
        if (reg_wr)
            dbg_wr_count <= dbg_wr_count + 1;

        // ============================================
        // Register writes (active in any state for setup regs)
        // ============================================
        if (reg_wr) begin
            case (reg_addr)
                4'd0: edge_head_u <= reg_wdata[9:0];        // 0x00
                4'd1: edge_tail_u <= reg_wdata[9:0];        // 0x04
                // 4'd2: scanline_v (unused by HW)           // 0x08
                4'd3: begin                                   // 0x0C EDGE_COUNT
                    edge_count <= reg_wdata[9:0];
                    edgebuf_wr_ptr <= 0;  // reset write pointer for new edge batch
                end
                4'd4: begin                                   // 0x10 EDGE_DATA
                    // BRAM write handled by separate always block
                    edgebuf_wr_ptr <= edgebuf_wr_ptr + 1;
                end
                4'd5: begin                                   // 0x14 SURFACE_KEY
                    surfkey_wr_en <= 1;
                    surfkey_wr_addr <= reg_wdata[25:16];
                    surfkey_wr_data <= reg_wdata[15:0];
                end
                4'd6: begin                                   // 0x18 CONTROL
                    if (reg_wdata[0] && (state == ST_IDLE || state == ST_DONE)) begin
                        busy <= 1;
                        done <= 0;
                        backward_mode <= reg_wdata[1];
                        edge_idx <= 0;
                        span_wr_ptr <= 0;
                        span_rd_ptr <= 0;
                        stack_count <= 0;
                        bg_last_u <= edge_head_u;
                        dbg_spans_tried <= 0;
                        dbg_edge_captured <= 0;
                        // Start reading first edge from BRAM
                        edgebuf_rd_addr <= 0;
                        if (edge_count == 0)
                            state <= ST_CLEANUP;
                        else
                            state <= ST_EDGE_FETCH;
                    end
                end
                4'd10: begin                                  // 0x28 FRAME_INIT
                    if (reg_wdata[0]) begin
                        busy <= 1;
                        done <= 0;
                        frame_clear_addr <= 0;
                        state <= ST_FRAME_CLEAR;
                    end
                end
            endcase
        end

        // Auto-increment span read pointer on read of SPAN_DATA
        if (reg_rd && reg_addr == 4'd9)
            span_rd_ptr <= span_rd_ptr + 1;

        // ============================================
        // FSM
        // ============================================
        case (state)

        ST_IDLE: begin
            // Register writes handle transitions
        end

        // ----------------------------------------
        // FRAME_CLEAR: Clear spanstate BRAM (1024 entries)
        // ----------------------------------------
        ST_FRAME_CLEAR: begin
            spanstate_wr_en <= 1;
            spanstate_wr_addr <= frame_clear_addr;
            spanstate_wr_data <= 8'd0;
            if (frame_clear_addr == 10'd1023) begin
                busy <= 0;
                done <= 1;
                state <= ST_IDLE;
            end else begin
                frame_clear_addr <= frame_clear_addr + 1;
            end
        end

        // ----------------------------------------
        // EDGE_FETCH: Wait for edge buffer BRAM read (1-cycle latency)
        // edgebuf_rd_addr was set by previous state
        // ----------------------------------------
        ST_EDGE_FETCH: begin
            state <= ST_EDGE_DECODE;
        end

        // ----------------------------------------
        // EDGE_DECODE: Edge BRAM data available, extract fields
        // ----------------------------------------
        ST_EDGE_DECODE: begin
            cur_iu     <= {1'b0, edgebuf_rd_reg[31:23]};  // 9-bit iu → 10-bit
            cur_surfs1 <= edgebuf_rd_reg[19:10];           // leading
            cur_surfs0 <= edgebuf_rd_reg[9:0];             // trailing

            // Debug: capture first edge data
            if (!dbg_edge_captured) begin
                dbg_first_edge <= edgebuf_rd_reg;
                dbg_edge_captured <= 1;
            end

            if (edgebuf_rd_reg[9:0] != 0) begin
                // Has trailing edge — read its spanstate
                spanstate_rd_addr <= edgebuf_rd_reg[9:0];
                state <= ST_TRAILING_RD;
            end else if (edgebuf_rd_reg[19:10] != 0) begin
                // No trailing, but has leading
                spanstate_rd_addr <= edgebuf_rd_reg[19:10];
                surfkey_rd_addr <= edgebuf_rd_reg[19:10];
                state <= ST_LEADING_RD;
            end else begin
                // Both zero — advance to next edge
                edge_idx <= edge_idx + 1;
                if (edge_idx + 1 >= edge_count) begin
                    state <= ST_CLEANUP;
                end else begin
                    edgebuf_rd_addr <= edge_idx + 1;
                    state <= ST_EDGE_FETCH;
                end
            end
        end

        // ----------------------------------------
        // TRAILING_RD: Wait for spanstate BRAM read
        // ----------------------------------------
        ST_TRAILING_RD: begin
            state <= ST_TRAILING_PROC;
        end

        // ----------------------------------------
        // TRAILING_PROC: Process trailing edge
        // spanstate_rd_reg is now valid for cur_surfs0
        // ----------------------------------------
        ST_TRAILING_PROC: begin
            if (spanstate_rd_reg > 8'd1) begin
                // Decrement spanstate, surface stays in stack
                spanstate_wr_en <= 1;
                spanstate_wr_addr <= cur_surfs0;
                spanstate_wr_data <= spanstate_rd_reg - 8'd1;
            end else if (spanstate_rd_reg == 8'd1) begin
                // spanstate 1→0: remove from stack
                spanstate_wr_en <= 1;
                spanstate_wr_addr <= cur_surfs0;
                spanstate_wr_data <= 8'd0;

                if (find_surf_valid) begin
                    if (find_surf_pos == 5'd0) begin
                        // Top of stack going away — emit span
                        if (cur_iu > stack_lastu[0]) begin
                            span_wr_en <= 1;
                            span_wr_data <= {2'b0, cur_iu - stack_lastu[0], stack_lastu[0], stack_surf[0]};
                        end

                        // Shift stack up (remove entry 0)
                        for (si = 0; si < STACK_DEPTH - 1; si = si + 1) begin
                            if (si < stack_count - 1) begin
                                stack_key[si]   <= stack_key[si + 1];
                                stack_surf[si]  <= stack_surf[si + 1];
                                stack_lastu[si] <= stack_lastu[si + 1];
                            end
                        end
                        stack_count <= stack_count - 1;

                        // New top's last_u = cur_iu (last NBA wins over shift)
                        if (stack_count > 5'd1)
                            stack_lastu[0] <= cur_iu;
                        else
                            bg_last_u <= cur_iu;
                    end else begin
                        // Not top — just remove (shift up from found_pos)
                        for (si = 0; si < STACK_DEPTH - 1; si = si + 1) begin
                            if (si[4:0] >= find_surf_pos && si < stack_count - 1) begin
                                stack_key[si]   <= stack_key[si + 1];
                                stack_surf[si]  <= stack_surf[si + 1];
                                stack_lastu[si] <= stack_lastu[si + 1];
                            end
                        end
                        stack_count <= stack_count - 1;
                    end
                end
            end
            // else spanstate == 0: nothing to do

            // Next: leading edge or next edge
            if (cur_surfs1 != 0) begin
                spanstate_rd_addr <= cur_surfs1;
                surfkey_rd_addr <= cur_surfs1;
                state <= ST_LEADING_RD;
            end else begin
                edge_idx <= edge_idx + 1;
                if (edge_idx + 1 >= edge_count)
                    state <= ST_CLEANUP;
                else begin
                    edgebuf_rd_addr <= edge_idx + 1;
                    state <= ST_EDGE_FETCH;
                end
            end
        end

        // ----------------------------------------
        // LEADING_RD: Wait for spanstate + surfkey BRAM reads
        // ----------------------------------------
        ST_LEADING_RD: begin
            state <= ST_LEADING_PROC;
        end

        // ----------------------------------------
        // LEADING_PROC: Process leading edge (phase 1: spanstate + register insert_pos)
        // spanstate_rd_reg and surfkey_rd_reg are now valid for cur_surfs1
        // insert_pos is combinatorially valid from surfkey_rd_reg — register it
        // to break critical timing path (BRAM → comparators → stack shift)
        // ----------------------------------------
        ST_LEADING_PROC: begin
            // Increment spanstate
            spanstate_wr_en <= 1;
            spanstate_wr_addr <= cur_surfs1;
            spanstate_wr_data <= spanstate_rd_reg + 8'd1;

            if (spanstate_rd_reg == 8'd0) begin
                // Surface entering for first time — register insert_pos, execute next cycle
                insert_pos_r <= insert_pos;
                state <= ST_LEADING_EXEC;
            end else begin
                // Surface already active, just increment. Advance to next edge.
                edge_idx <= edge_idx + 1;
                if (edge_idx + 1 >= edge_count)
                    state <= ST_CLEANUP;
                else begin
                    edgebuf_rd_addr <= edge_idx + 1;
                    state <= ST_EDGE_FETCH;
                end
            end
        end

        // ----------------------------------------
        // LEADING_EXEC: Execute stack insert using registered insert_pos_r
        // surfkey_rd_reg still valid (BRAM addr unchanged)
        // ----------------------------------------
        ST_LEADING_EXEC: begin
            if (insert_pos_r == 5'd0) begin
                // New top surface — emit span for old top (or background)
                if (stack_count > 0) begin
                    if (cur_iu > stack_lastu[0]) begin
                        span_wr_en <= 1;
                        span_wr_data <= {2'b0, cur_iu - stack_lastu[0], stack_lastu[0], stack_surf[0]};
                    end
                end else begin
                    if (cur_iu > bg_last_u) begin
                        span_wr_en <= 1;
                        span_wr_data <= {2'b0, cur_iu - bg_last_u, bg_last_u, 10'd1};
                    end
                end

                // Shift stack down from position 0
                for (si = STACK_DEPTH - 1; si > 0; si = si - 1) begin
                    if (si[4:0] <= stack_count) begin
                        stack_key[si]   <= stack_key[si - 1];
                        stack_surf[si]  <= stack_surf[si - 1];
                        stack_lastu[si] <= stack_lastu[si - 1];
                    end
                end

                // Insert at position 0 (last NBA wins)
                stack_key[0]   <= surfkey_rd_reg;
                stack_surf[0]  <= cur_surfs1;
                stack_lastu[0] <= cur_iu;
                stack_count <= stack_count + 1;

            end else if (insert_pos_r < STACK_DEPTH[4:0]) begin
                // Insert at position P (not top — no span emission)
                for (si = STACK_DEPTH - 1; si > 0; si = si - 1) begin
                    if (si[4:0] > insert_pos_r && si[4:0] <= stack_count) begin
                        stack_key[si]   <= stack_key[si - 1];
                        stack_surf[si]  <= stack_surf[si - 1];
                        stack_lastu[si] <= stack_lastu[si - 1];
                    end
                end

                stack_key[insert_pos_r]   <= surfkey_rd_reg;
                stack_surf[insert_pos_r]  <= cur_surfs1;
                stack_lastu[insert_pos_r] <= cur_iu;
                stack_count <= stack_count + 1;
            end

            // Advance to next edge
            edge_idx <= edge_idx + 1;
            if (edge_idx + 1 >= edge_count)
                state <= ST_CLEANUP;
            else begin
                edgebuf_rd_addr <= edge_idx + 1;
                state <= ST_EDGE_FETCH;
            end
        end

        // ----------------------------------------
        // CLEANUP: Emit span for top surface to edge_tail_u
        // ----------------------------------------
        ST_CLEANUP: begin
            if (stack_count > 0) begin
                if (edge_tail_u > stack_lastu[0]) begin
                    span_wr_en <= 1;
                    span_wr_data <= {2'b0, edge_tail_u - stack_lastu[0], stack_lastu[0], stack_surf[0]};
                end
            end else begin
                if (edge_tail_u > bg_last_u) begin
                    span_wr_en <= 1;
                    span_wr_data <= {2'b0, edge_tail_u - bg_last_u, bg_last_u, 10'd1};
                end
            end

            cleanup_idx <= 0;
            if (stack_count > 0)
                state <= ST_CLEANUP_WR;
            else begin
                busy <= 0;
                done <= 1;
                state <= ST_DONE;
            end
        end

        // ----------------------------------------
        // CLEANUP_WR: Clear spanstate for each stack entry
        // ----------------------------------------
        ST_CLEANUP_WR: begin
            spanstate_wr_en <= 1;
            spanstate_wr_addr <= stack_surf[cleanup_idx];
            spanstate_wr_data <= 8'd0;

            if (cleanup_idx >= stack_count - 1) begin
                stack_count <= 0;
                busy <= 0;
                done <= 1;
                state <= ST_DONE;
            end else begin
                cleanup_idx <= cleanup_idx + 1;
            end
        end

        // ----------------------------------------
        // DONE: Wait for CPU to read spans, then return to IDLE
        // ----------------------------------------
        ST_DONE: begin
            if (reg_wr && reg_addr == 4'd3) begin
                // CPU writing EDGE_COUNT for next scanline → go idle
                done <= 0;
                state <= ST_IDLE;
            end
            // CONTROL (reg_addr 4'd6) handled by register write block
        end

        endcase
    end
end

endmodule
