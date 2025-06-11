/*
 * hwpe_stream_merge.sv
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
 * The **hwpe_stream_merge** module is used to merge `NB_IN_STREAMS`
 * input streams into a single, bigger stream. The *data* and *strb*
 * channels from the input streams are bound in order and the *valid* is
 * generated as the AND of all *valid*'s from input streams. The *ready*
 * is broadcasted from the output stream to all input streams.
 *
 * A typical use of this module is to take `NB_IN_STREAMS` 32-bit streams
 * coming from a TCDM load interface to be merged into a single bigger
 * stream.
 *
 * The following shows an example of the **hwpe_stream_merge** operation:
 *
 * .. _wavedrom_hwpe_stream_merge:
 * .. wavedrom:: wavedrom/hwpe_stream_merge.json
 *   :width: 85 %
 *   :caption: Example of **hwpe_stream_merge** operation.
 *
 * .. tabularcolumns:: |l|l|J|
 * .. _hwpe_stream_merge_params:
 * .. table:: **hwpe_stream_merge** design-time parameters.
 *
 *   +------------------+-------------+---------------------------------------------+
 *   | **Name**         | **Default** | **Description**                             |
 *   +------------------+-------------+---------------------------------------------+
 *   | *NB_IN_STREAMS*  | 2           | Number of input HWPE-Stream streams.        |
 *   +------------------+-------------+---------------------------------------------+
 *   | *DATA_WIDTH_IN*  | 32          | Width of the input HWPE-Stream streams.     |
 *   +------------------+-------------+---------------------------------------------+
 */

import hwpe_stream_package::*;

module hwpe_stream_merge_stride #(
  parameter int unsigned NB_IN_STREAMS = 4,
  parameter int unsigned DATA_WIDTH_IN = 64,
  parameter int unsigned ELEMENT_WIDTH = 16
)
(
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic                   clear_i,

  hwpe_stream_intf_stream.sink   push_i [NB_IN_STREAMS-1:0],
  hwpe_stream_intf_stream.source pop_o
);

  parameter STRB_WIDTH_IN = DATA_WIDTH_IN / 8;

  logic [NB_IN_STREAMS-1:0] stream_valid;
  logic all_valid;


  generate

    for(genvar ii=0; ii<NB_IN_STREAMS; ii++) begin : stream_binding


      for(genvar jj=0; jj<DATA_WIDTH_IN/ELEMENT_WIDTH; jj++) begin : element_binding
        assign pop_o.data[(((jj*NB_IN_STREAMS + ii) + 1)*ELEMENT_WIDTH)-1 : (jj*NB_IN_STREAMS + ii)*ELEMENT_WIDTH] = push_i[ii].data[(jj+1)*ELEMENT_WIDTH-1:jj*ELEMENT_WIDTH];
      end


      for(genvar mm=0; mm<DATA_WIDTH_IN/8; mm++) begin
          assign pop_o.strb[mm*NB_IN_STREAMS+ii] = push_i[ii].strb[mm];
      end

      // split ready is brodcast to all incoming streams
      assign push_i[ii].ready = pop_o.ready & all_valid;

      // auxiliary for ready generation
      assign stream_valid[ii] = push_i[ii].valid;   

    end

  endgenerate

  // valid only when all divergent streams are valid
  assign all_valid = & stream_valid;
  assign pop_o.valid = all_valid;

endmodule // hwpe_stream_merge_stride
