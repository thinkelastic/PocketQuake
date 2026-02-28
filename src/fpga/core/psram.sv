// MIT License

// Copyright (c) 2022 Adam Gastineau

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

function integer rtoi(input integer x);
  return x;
endfunction

`define CEIL(x) ((rtoi(x) > x) ? rtoi(x) : rtoi(x) + 1)
`define MAX(x, y) ((x > y) ? x : y)

module psram #(
    parameter CLOCK_SPEED = 48.0,  // Clock speed in megahertz

    // -- Shared async --
    parameter MIN_ADV_N_PULSE = 5, // Minimum time (ns) for adv_n to be held low to latch address (t_vp)
    parameter MIN_ADDRESS_SETUP_BEFORE_ADV_HIGH = 5, // Minimum time (ns) for address to be asserted before adv_n goes high again (t_avs)
    parameter MIN_ADDRESS_HOLD_AFTER_ADV_HIGH = 2, // Minimum time (ns) for address to be held after adv_n goes high (t_avh)
    parameter MIN_CE_BEFORE_ADV_HIGH = 7, // Minimum time (ns) for bank to be enabled (ce#_n low) before adv_n goes high (t_cvs)

    // -- Writes --
    parameter MIN_DATA_SETUP_BEFORE_WE_HIGH = 20, // Minimum time (ns) for data to write to be set up before we_n goes high (t_dw)
    parameter MIN_DATA_AFTER_ADDR_UNLATCHED = 8, // Minimum time (ns) until data should be asserted after addr unlatch. This isn't in the spec, so I'm guessing
    parameter MIN_WRITE_PULSE = 45, // Minimum time (ns) for we_n to be held low to latch data (t_wp)
    parameter MIN_WRITE_TIME_FROM_ADV = 70, // Minimum time (ns) for write to complete after adv_n goes low (after setup) (t_aw)

    // -- Async reads (for non-sync-burst instances like CRAM1) --
    parameter MIN_OE_AFTER_ADDR_UNLATCHED = 3, // Minimum time (ns) until oe_n goes low after addr unlatch
    parameter MAX_ACCESS_TIME_FROM_ADV = 70, // Maximum time (ns) for valid data to appear after adv_n goes low

    // -- Sync burst --
    parameter SYNC_LATENCY = 4  // FSM wait cycles: φ=6ns CLK0 latch, code 4, negedge capture
) (
    input wire clk,

    input wire bank_sel,
    input wire [21:0] addr,

    input wire write_en,
    input wire [15:0] data_in,
    input wire write_high_byte,
    input wire write_low_byte,

    input wire read_en,              // Async single-word read (for non-sync-burst instances)

    input wire sync_burst_en,        // Start synchronous burst read (single-cycle pulse)
    input wire [5:0] sync_burst_len, // Number of 16-bit reads minus 1 (max 63)

    input wire config_en,            // Write BCR register (single-cycle pulse)
    input wire [15:0] config_data,   // BCR value to write

    output reg read_avail,
    output reg [15:0] data_out,

    output reg busy,

    // PSRAM signals
    output reg [21:16] cram_a,
    inout wire [15:0] cram_dq,
    input wire cram_wait,
    output reg cram_clk = 0,
    output reg cram_adv_n = 1,
    output reg cram_cre = 0,
    output reg cram_ce0_n = 1,
    output reg cram_ce1_n = 1,
    output reg cram_oe_n = 1,
    output reg cram_we_n = 1,
    output reg cram_ub_n = 1,
    output reg cram_lb_n = 1
);

  localparam PERIOD = 1000.0 / CLOCK_SPEED;  // In nanoseconds

  // -- Shared cycle counts --
  localparam ADV_PULSE_CYCLE_COUNT =
  `CEIL(MIN_ADV_N_PULSE / PERIOD);
  // 2 ns added for setup times. This will vary based on the fitter and hardware, but hopefully is correct
  localparam ADDRESS_SETUP_BEFORE_ADV_CYCLE_COUNT =
  `CEIL((MIN_ADDRESS_SETUP_BEFORE_ADV_HIGH + 2) / PERIOD);

  localparam CE_BEFORE_ADV_CYCLE_COUNT =
  `CEIL((MIN_CE_BEFORE_ADV_HIGH) / PERIOD);

  localparam ADV_CYCLE_COUNT =
  `MAX(`MAX(ADV_PULSE_CYCLE_COUNT, ADDRESS_SETUP_BEFORE_ADV_CYCLE_COUNT),
       CE_BEFORE_ADV_CYCLE_COUNT);
  localparam ADDR_HOLD_AFTER_ADV_CYCLE_COUNT =
  `CEIL(MIN_ADDRESS_HOLD_AFTER_ADV_HIGH / PERIOD);

  // -- Write cycle counts
  localparam DATA_SETUP_BEFORE_WE_ENDS_CYCLE_COUNT =
  `CEIL(MIN_DATA_SETUP_BEFORE_WE_HIGH / PERIOD);

  localparam DATA_AFTER_ADDR_UNLATCH_CYCLE_COUNT =
  `CEIL(MIN_DATA_AFTER_ADDR_UNLATCHED / PERIOD);

  localparam WRITE_PULSE_CYCLE_COUNT =
  `CEIL(MIN_WRITE_PULSE / PERIOD);

  localparam TOTAL_WRITE_CYCLE_COUNT =
  `CEIL(`MAX(MIN_WRITE_TIME_FROM_ADV, MIN_WRITE_PULSE) / PERIOD);

  // -- Async read cycle counts --
  localparam OE_AFTER_ADDR_UNLATCH_CYCLE_COUNT =
  `CEIL(MIN_OE_AFTER_ADDR_UNLATCHED / PERIOD);

  localparam TOTAL_READ_CYCLE_COUNT =
  `CEIL(MAX_ACCESS_TIME_FROM_ADV / PERIOD);

  localparam STATE_NONE = 0;

  // -- Write states --

  localparam WRITE_INITIAL_COUNT = 1;

  localparam STATE_WRITE_ADV_END = WRITE_INITIAL_COUNT - 1 + ADV_CYCLE_COUNT;

  localparam STATE_WRITE_ADDR_LATCH_END = STATE_WRITE_ADV_END + ADDR_HOLD_AFTER_ADV_CYCLE_COUNT;

  localparam STATE_WRITE_DATA_START = STATE_WRITE_ADDR_LATCH_END + DATA_AFTER_ADDR_UNLATCH_CYCLE_COUNT;

  localparam STATE_WRITE_DATA_END = WRITE_INITIAL_COUNT + TOTAL_WRITE_CYCLE_COUNT;

  // -- Async read states (for non-sync-burst instances) --
  localparam READ_INITIAL_COUNT = 20;
  localparam STATE_READ_ADV_END = READ_INITIAL_COUNT - 1 + ADV_CYCLE_COUNT;
  localparam STATE_READ_ADDR_LATCH_END = STATE_READ_ADV_END + ADDR_HOLD_AFTER_ADV_CYCLE_COUNT;
  localparam STATE_READ_DATA_ENABLE = STATE_READ_ADDR_LATCH_END + OE_AFTER_ADDR_UNLATCH_CYCLE_COUNT;
  localparam STATE_READ_DATA_RECEIVED = READ_INITIAL_COUNT + TOTAL_READ_CYCLE_COUNT;

  // -- Config write states (CRE-controlled BCR register write) --
  // CRE must be HIGH ≥20ns before CE# falls (tCRES). We assert CRE two cycles early
  // to guarantee 20ns setup even with IOB register timing differences.
  localparam STATE_CONFIG_CRE_WAIT  = 48;  // Extra CRE hold cycle (auto-increments to 49)
  localparam STATE_CONFIG_CRE_SETUP = 49;  // CE#/ADV#/WE#/address asserted (CRE already high)
  localparam STATE_CONFIG_START = 50;       // CE#, ADV#, WE#, address driven
  localparam STATE_CONFIG_ADV_END = STATE_CONFIG_START + ADV_CYCLE_COUNT - 1;
  localparam STATE_CONFIG_HOLD_END = STATE_CONFIG_START + TOTAL_WRITE_CYCLE_COUNT;

  // -- Sync burst read states (explicit state assignments) --
  localparam STATE_SYNC_SETUP = 60;
  localparam STATE_SYNC_WAIT  = 61;
  localparam STATE_SYNC_DATA  = 62;
  localparam STATE_SYNC_END   = 63;

  initial begin
    $info("Instantiated PSRAM with the following settings:");
    $info("  Clock speed: %f MHz with period %f ns", CLOCK_SPEED, PERIOD);
    $info("  Writes:");
    $info("    STATE_WRITE_ADV_END: %d", STATE_WRITE_ADV_END);
    $info("    STATE_WRITE_ADDR_LATCH_END: %d", STATE_WRITE_ADDR_LATCH_END);
    $info("    STATE_WRITE_DATA_START: %d", STATE_WRITE_DATA_START);
    $info("    STATE_WRITE_DATA_END: %d", STATE_WRITE_DATA_END);
    $info("");
    $info("  Total write time: %d cycles", TOTAL_WRITE_CYCLE_COUNT);
    $info("  Config write:");
    $info("    STATE_CONFIG_START: %d", STATE_CONFIG_START);
    $info("    STATE_CONFIG_ADV_END: %d", STATE_CONFIG_ADV_END);
    $info("    STATE_CONFIG_HOLD_END: %d", STATE_CONFIG_HOLD_END);
    $info("  Sync burst:");
    $info("    SYNC_LATENCY: %d", SYNC_LATENCY);
  end

  reg [7:0] state = STATE_NONE;

  // If 1, route cram_data reg to cram_dq
  reg data_out_en = 0;
  reg [15:0] cram_data;

  reg [15:0] latched_data_in;

  // Sync burst counters
  reg [5:0] latency_counter;
  reg [5:0] burst_counter;

  assign cram_dq = data_out_en ? cram_data : 16'hZZ;

  // Negedge capture register for sync burst read data.
  // At 100 MHz, posedge and CRAM CLK timing make posedge capture impossible
  // across process corners: reliable address latch needs φ≥5ns, but posedge
  // data capture needs φ≤4ns. Negedge capture shifts the window by 5ns,
  // making both work with φ=7ns (2ns margin on all paths).
  reg [15:0] cram_dq_neg;
  always @(negedge clk) begin
    cram_dq_neg <= cram_dq;
  end

  always @(posedge clk) begin
    if (state != STATE_NONE) begin
      // If we are not at STATE_NONE, increment state (overridden by explicit assignments)
      state <= state + 1;
    end

    if (state == STATE_NONE) begin
      // We are only busy when not in STATE_NONE
      busy <= 0;
    end else begin
      busy <= 1;
    end

    // Default: clear read_avail every cycle (pulsed in data states)
    read_avail <= 0;

    case (state)
      STATE_NONE: begin

        cram_clk   <= 0;
        cram_adv_n <= 1;
        cram_cre   <= 0;
        cram_ce0_n <= 1;
        cram_ce1_n <= 1;
        cram_oe_n  <= 1;
        cram_we_n  <= 1;
        cram_ub_n  <= 1;
        cram_lb_n  <= 1;

        if (write_en) begin
          // Enter write_init
          state <= WRITE_INITIAL_COUNT;

          if (bank_sel) cram_ce1_n <= 0;
          else cram_ce0_n <= 0;

          // Set address and output on dq
          cram_a <= addr[21:16];
          cram_data <= addr[15:0];
          data_out_en <= 1;
          // Store data in for future use
          latched_data_in <= data_in;

          // Enable write
          cram_we_n <= 0;

          // Enable address latching
          cram_adv_n <= 0;

          if (write_high_byte) cram_ub_n <= 0;
          if (write_low_byte) cram_lb_n <= 0;

          // Set busy now instead of waiting for the state change
          busy <= 1;
        end else if (config_en) begin
          // BCR config write via CRE — assert CRE two cycles early for ≥20ns tCRES
          // State 48 (CRE_WAIT): CRE high, auto-increments to 49 (CRE_SETUP)
          // State 49 (CRE_SETUP): CE#, ADV#, WE#, address asserted
          state <= STATE_CONFIG_CRE_WAIT;
          cram_cre <= 1;    // CRE high, 20ns before CE# falls (at state 49)
          busy <= 1;
        end else if (read_en) begin
          // Async single-word read
          state <= READ_INITIAL_COUNT;

          if (bank_sel) cram_ce1_n <= 0;
          else cram_ce0_n <= 0;

          cram_a <= addr[21:16];
          cram_data <= addr[15:0];
          data_out_en <= 1;

          cram_adv_n <= 0;
          cram_ub_n <= 0;
          cram_lb_n <= 0;

          busy <= 1;
        end else if (sync_burst_en) begin
          // Synchronous burst read
          state <= STATE_SYNC_SETUP;

          if (bank_sel) cram_ce1_n <= 0;
          else cram_ce0_n <= 0;

          // Drive address
          cram_a <= addr[21:16];
          cram_data <= addr[15:0];
          data_out_en <= 1;

          cram_adv_n <= 0;  // ADV# low to latch address
          cram_we_n <= 1;   // WE# high for read
          cram_oe_n <= 1;   // OE# high during address phase
          cram_ub_n <= 0;
          cram_lb_n <= 0;

          latency_counter <= SYNC_LATENCY[5:0];
          burst_counter <= sync_burst_len;

          busy <= 1;
        end
      end

      // ============================================
      // Async writes (unchanged)
      // ============================================
      STATE_WRITE_ADV_END: begin
        // Continue holding address after setting adv high
        cram_adv_n <= 1;
      end
      STATE_WRITE_ADDR_LATCH_END: begin
        // No longer sending address data on cram_dq
        data_out_en <= 0;
      end
      STATE_WRITE_DATA_START: begin
        // Provide data to write
        data_out_en <= 1;
        cram_data   <= latched_data_in;
      end
      STATE_WRITE_DATA_END: begin
        state <= STATE_NONE;

        data_out_en <= 0;

        // Unlatch write enable and banks
        cram_we_n <= 1;

        cram_ce0_n <= 1;
        cram_ce1_n <= 1;

        cram_ub_n <= 1;
        cram_lb_n <= 1;

        // Clear busy now, so we don't have to wait for the state change
        busy <= 0;
      end

      // ============================================
      // Async reads (for non-sync-burst instances)
      // ============================================
      STATE_READ_ADV_END: begin
        cram_adv_n <= 1;
      end
      STATE_READ_ADDR_LATCH_END: begin
        data_out_en <= 0;
      end
      STATE_READ_DATA_ENABLE: begin
        cram_oe_n <= 0;
      end
      STATE_READ_DATA_RECEIVED: begin
        read_avail <= 1;
        data_out <= cram_dq;

        state <= STATE_NONE;
        cram_ce0_n <= 1;
        cram_ce1_n <= 1;
        cram_ub_n <= 1;
        cram_lb_n <= 1;
        cram_oe_n <= 1;
        busy <= 0;
      end

      // ============================================
      // Config write states (BCR register via CRE)
      // ============================================
      STATE_CONFIG_CRE_SETUP: begin
        // CRE is already HIGH from previous cycle. Now assert CE#, ADV#, WE#, address.
        if (bank_sel) cram_ce1_n <= 0;
        else cram_ce0_n <= 0;

        cram_a <= {2'b00, 2'b10, 2'b00};  // A[21:16] with A[19]=1 (BCR select for 64Mbit die)
        cram_data <= config_data;          // BCR value on DQ[15:0] = A[15:0]
        data_out_en <= 1;

        cram_we_n <= 0;   // WE# low for write
        cram_adv_n <= 0;  // ADV# low to latch address
        // Auto-increment → STATE_CONFIG_START (50) → STATE_CONFIG_ADV_END
      end

      STATE_CONFIG_ADV_END: begin
        // Address latched, deassert ADV#
        cram_adv_n <= 1;
      end

      STATE_CONFIG_HOLD_END: begin
        // Config write complete — release everything
        state <= STATE_NONE;
        data_out_en <= 0;
        cram_we_n <= 1;
        cram_cre <= 0;
        cram_ce0_n <= 1;
        cram_ce1_n <= 1;
        busy <= 0;
      end

      // ============================================
      // Synchronous burst read states
      // ============================================
      STATE_SYNC_SETUP: begin
        // Address was driven in STATE_NONE, ADV# is low.
        // Deassert ADV# (address latched), release DQ, assert OE#
        cram_adv_n <= 1;
        data_out_en <= 0;  // Release DQ bus for CRAM to drive
        cram_oe_n <= 0;    // OE# low for read
        latency_counter <= latency_counter - 6'd1;
        state <= STATE_SYNC_WAIT;
      end

      STATE_SYNC_WAIT: begin
        // Wait for initial access latency
        if (latency_counter == 6'd0) begin
          state <= STATE_SYNC_DATA;
        end else begin
          latency_counter <= latency_counter - 6'd1;
          state <= STATE_SYNC_WAIT;  // Explicit: stay here
        end
      end

      STATE_SYNC_DATA: begin
        read_avail <= 1;
        data_out <= cram_dq_neg;  // Use negedge-captured data for sync burst

        if (burst_counter == 6'd0) begin
          state <= STATE_SYNC_END;
        end else begin
          burst_counter <= burst_counter - 6'd1;
          state <= STATE_SYNC_DATA;  // Explicit: stay here
        end
      end

      STATE_SYNC_END: begin
        // Burst complete — release everything
        state <= STATE_NONE;
        cram_ce0_n <= 1;
        cram_ce1_n <= 1;
        cram_oe_n <= 1;
        cram_ub_n <= 1;
        cram_lb_n <= 1;
        busy <= 0;
      end
    endcase
  end

endmodule
