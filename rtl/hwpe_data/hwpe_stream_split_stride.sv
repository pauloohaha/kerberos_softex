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
  parameter int unsigned DATA_WIDTH_OUT = DATA_WIDTH_IN/NB_OUT_STREAMS;
  parameter int unsigned STRB_WIDTH_OUT = DATA_WIDTH_OUT/8;
  parameter int unsigned STROBE_STRIDE = ELEMENT_STRIDE*8;


  // Track which output streams have already accepted (ready && valid) the word.
  logic [NB_OUT_STREAMS-1:0] stream_served;
  
  // Intermediate signals to avoid non-constant indexing into interface arrays
  logic [NB_OUT_STREAMS-1:0] pop_ready;

  logic transaction_pending;
  logic [DATA_WIDTH_IN-1:0]   data_reg;
  logic [(DATA_WIDTH_IN/8)-1:0] strb_reg;

// Extract ready signals from interface array
generate
  for (genvar i = 0; i < NB_OUT_STREAMS; i++) begin : gen_ready_extract
    assign pop_ready[i] = pop_o[i].ready;
  end
endgenerate

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (~rst_ni) begin
    transaction_pending <= 1'b0;
    stream_served       <= '0;
  end
  else if (clear_i) begin
      transaction_pending <= 1'b0;
      stream_served       <= '0;
  end else begin

    // Start a new transaction once the previous one is finished.
    if (!transaction_pending) begin
      if (push_i.valid) begin
        data_reg           <= push_i.data;
        strb_reg           <= push_i.strb;
        transaction_pending <= 1'b1;
        stream_served       <= '0; // none of the outputs have consumed the word yet
      end
    end else begin
      // While a transaction is pending, record which outputs have accepted it
      for (int i = 0; i < NB_OUT_STREAMS; i++) begin
        if (!stream_served[i] && pop_ready[i]) begin
          stream_served[i] <= 1'b1;
        end
      end

      // When every stream has accepted the word we can finish the transaction
      if (&stream_served) begin
        transaction_pending <= 1'b0;
      end
    end
  end
end

for (genvar ii = 0; ii < NB_OUT_STREAMS; ii++) begin : stream_binding
  
  for (genvar jj = 0; jj < ELEMENT_STRIDE; jj++) begin
    assign pop_o[ii].data[(jj+1)*ELEMENT_WIDTH-1:jj*ELEMENT_WIDTH] = data_reg[(ii + jj*ELEMENT_STRIDE + 1)*ELEMENT_WIDTH - 1 : (ii + jj*ELEMENT_STRIDE)*ELEMENT_WIDTH];
  end

  for (genvar mm = 0; mm < DATA_WIDTH_OUT/8; mm++) begin
    assign pop_o[ii].strb[mm] = strb_reg[(mm*NB_OUT_STREAMS)+ii];
  end

  // Assert valid only until the specific output has taken the word.
  assign pop_o[ii].valid = transaction_pending && !stream_served[ii];
end

// The input can accept a new word whenever there is no transaction in
// progress.
// We do not  need to wait for a simultaneous `ready` from all
// outputs because acceptance is tracked with `stream_served`.
assign push_i.ready = !transaction_pending;

endmodule // hwpe_stream_split_stride
