// Author: Marius Siebenaller, <sieben@stanford.edu>
// Adapted from:
/*
 * hwpe_stream_split.sv
 * Francesco Conti <f.conti@unibo.it>
 *
 * Copyright (C) 2014-2018 ETH Zurich, University of Bologna
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the "License"); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 */

/**
 * The **hwpe_stream_split** module is used to split a single stream into
 * `NB_OUT_STREAMS`, 32-bit output streams. The *data* and *strb* channel
 * from the input stream is split in ordered output streams, and the
 * *valid* is broadcast to all outgoing streams. The *ready* is generated
 * as the AND of all *ready*\ ’s from output streams.
 *
 * A typical use of this module is to take a multiple-of-32-bit stream
 * coming from within the HWPE and split it into multiple 32-bit streams
 * that feed a TCDM store interface.
 *
 * The following shows an example of the **hwpe_stream_split** operation:
 *
 * .. _wavedrom_hwpe_stream_split:
 * .. wavedrom:: wavedrom/hwpe_stream_split.json
 *   :width: 85 %
 *   :caption: Example of **hwpe_stream_split** operation.
 *
 * .. tabularcolumns:: |l|l|J|
 * .. _hwpe_stream_split_params:
 * .. table:: **hwpe_stream_split** design-time parameters.
 *
 *   +------------------+-------------+---------------------------------------------+
 *   | **Name**         | **Default** | **Description**                             |
 *   +------------------+-------------+---------------------------------------------+
 *   | *NB_OUT_STREAMS* | 2           | Number of output HWPE-Stream streams.       |
 *   +------------------+-------------+---------------------------------------------+
 *   | *DATA_WIDTH_IN*  | 128         | Width of the input HWPE-Stream stream.      |
 *   +------------------+-------------+---------------------------------------------+
 */

import hwpe_stream_package::*;

module hwpe_stream_split_stride #(
  parameter int unsigned NB_OUT_STREAMS = 4,
  parameter int unsigned DATA_WIDTH_IN = 256,
  parameter int unsigned ELEMENT_WIDTH = 16
)
(
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic                   clear_i,

  hwpe_stream_intf_stream.sink   push_i,
  hwpe_stream_intf_stream.source pop_o [NB_OUT_STREAMS-1:0]
);
  parameter int unsigned ELEMENT_STRIDE = DATA_WIDTH_IN/NB_OUT_STREAMS/ELEMENT_WIDTH;
  parameter int unsigned STROBE_STRIDE = ELEMENT_STRIDE*8;
  parameter int unsigned DATA_WIDTH_OUT = DATA_WIDTH_IN/NB_OUT_STREAMS;
  parameter int unsigned STRB_WIDTH_OUT = DATA_WIDTH_OUT/8;

  // FSM states
  typedef enum logic [0:0] {BYPASS, LATCHING} state_e;
  state_e state_q, state_d;

  // Track which output streams have already accepted (ready && valid) the word.
  logic [NB_OUT_STREAMS-1:0] stream_served_q, stream_served_d;

  // Intermediate signals
  logic [NB_OUT_STREAMS-1:0] pop_ready;
  logic                      all_pops_ready;
  logic                      some_pops_ready;

  // Registered data
  logic [DATA_WIDTH_IN-1:0]     data_q;
  logic [(DATA_WIDTH_IN/8)-1:0] strb_q;

  // Extract ready signals from interface array
  generate
    for (genvar i = 0; i < NB_OUT_STREAMS; i++) begin : gen_ready_extract
      assign pop_ready[i] = pop_o[i].ready;
    end
  endgenerate

  // Combinational Logic
  always_comb begin
    // Default assignments
    state_d         = state_q;
    stream_served_d = stream_served_q;
    push_i.ready    = 1'b0;

    all_pops_ready = &pop_ready;
    some_pops_ready = |pop_ready;

    case (state_q)
      BYPASS: begin
        // If all outputs are ready, we are in bypass mode.
        // The input is ready, and we can accept a new transaction immediately.
        if (all_pops_ready) begin
          push_i.ready = 1'b1;
          // If the input is valid, we stay in BYPASS (bypass)
          // otherwise we stay in BYPASS and wait.
          state_d = BYPASS;
        end
        // If only some outputs are ready, we enter the LATCHING state to register the transaction.
        else if (some_pops_ready && push_i.valid) begin
          state_d         = LATCHING;
          stream_served_d = pop_ready;
        end
      end

      LATCHING: begin
        // Update which streams have been served in this cycle
        stream_served_d = stream_served_q | pop_ready;
        push_i.ready = &stream_served_d;
        // If the transaction is done, we can go back to BYPASS.
        if (&stream_served_d) begin
          state_d      = BYPASS;
        end
      end

      default: begin
        state_d      = BYPASS;
        push_i.ready = 1'b0;
      end
    endcase
  end

  // Sequential Logic (State and Data Registers)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q         <= BYPASS;
      stream_served_q <= '0;
      data_q          <= '0;
      strb_q          <= '0;
    end
    else if (clear_i) begin
      state_q         <= BYPASS;
      stream_served_q <= '0;
    end
    else begin
      state_q <= state_d;
      stream_served_q <= stream_served_d;
      // Latch input data only when a new transaction starts (transition from BYPASS to LATCHING)
      if (state_q == BYPASS && state_d == LATCHING) begin
        data_q <= push_i.data;
        strb_q <= push_i.strb;
      end
    end
  end

  // Output Logic
  for (genvar ii = 0; ii < NB_OUT_STREAMS; ii++) begin : stream_binding
    // In BYPASS (bypass mode), data comes directly from the input.
    // In LATCHING (registered mode), data comes from the registers.
    for (genvar jj = 0; jj < ELEMENT_STRIDE; jj++) begin
      assign pop_o[ii].data[(jj+1)*ELEMENT_WIDTH-1:jj*ELEMENT_WIDTH] = (state_q == BYPASS) ? push_i.data[(ii + jj*ELEMENT_STRIDE + 1)*ELEMENT_WIDTH - 1 : (ii + jj*ELEMENT_STRIDE)*ELEMENT_WIDTH] : data_q[(ii + jj*ELEMENT_STRIDE + 1)*ELEMENT_WIDTH - 1 : (ii + jj*ELEMENT_STRIDE)*ELEMENT_WIDTH];
    end

    for (genvar mm = 0; mm < DATA_WIDTH_OUT/8; mm++) begin
      assign pop_o[ii].strb[mm] = (state_q == BYPASS) ? push_i.strb[(mm*NB_OUT_STREAMS)+ii] : strb_q[(mm*NB_OUT_STREAMS)+ii];
    end

    // Output is valid if we are in bypass (BYPASS and input is valid) or if we are in registered mode (LATCHING) and this stream has not been served yet.
    assign pop_o[ii].valid = (state_q == BYPASS && push_i.valid) || (state_q == LATCHING && !stream_served_q[ii]);
  end

endmodule // hwpe_stream_split_stride
