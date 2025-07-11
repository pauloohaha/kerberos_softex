// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Andrea Belano <andrea.belano@studio.unibo.it>
// Yvan Tortorella <yvan.tortorella@unibo.it>
//

`include "hci_helpers.svh"

import hci_package::*;
import hwpe_stream_package::*;
import softex_pkg::*;

module softex_top #(
    parameter fpnew_pkg::fp_format_e    FPFORMAT    = FPFORMAT_IN   ,
    parameter int unsigned              INT_WIDTH   = INT_W         ,
    parameter int unsigned              N_CORES     = 2,
    parameter hci_size_parameter_t `HCI_SIZE_PARAM(Tcdm) = '0
) (
    input   logic                           clk_i   ,
    input   logic                           rst_ni  ,

    output  logic                           busy_o  ,
    output  logic [N_CORES - 1 : 0] [1 : 0] evt_o   ,

    hci_core_intf.initiator                 tcdm    ,
    hwpe_ctrl_intf_periph.slave             periph  
);

    localparam int unsigned WIDTH       = fpnew_pkg::fp_width(FPFORMAT);
    localparam int unsigned ACTUAL_DW   = `HCI_SIZE_GET_DW(Tcdm);

    hci_streamer_flags_t    stream_in_flgs;
    hci_streamer_flags_t    stream_out_flgs;
    hci_streamer_flags_t    slot_in_flgs;
    hci_streamer_flags_t    slot_out_flgs;

    hci_streamer_ctrl_t     stream_in_ctrl;
    hci_streamer_ctrl_t     stream_out_ctrl;
    hci_streamer_ctrl_t     slot_in_ctrl;
    hci_streamer_ctrl_t     slot_out_ctrl;

    cast_ctrl_t             in_cast_ctrl;
    cast_ctrl_t             out_cast_ctrl;

    datapath_ctrl_t         [NUM_LANES-1:0] datapath_ctrl;
    datapath_flags_t        [NUM_LANES-1:0] datapath_flgs;

    slot_regfile_ctrl_t     slot_regfile_ctrl;

    slot_t                  state_slot;

    hwpe_stream_intf_stream #(.DATA_WIDTH(ACTUAL_DW)) in_stream        (.clk(clk_i));
    hwpe_stream_intf_stream #(.DATA_WIDTH(ACTUAL_DW)) out_stream       (.clk(clk_i));
    hwpe_stream_intf_stream #(.DATA_WIDTH(NUM_LANES*(3*WIDTH))) slot_in_stream   (.clk(clk_i));
    hwpe_stream_intf_stream #(.DATA_WIDTH(NUM_LANES*(3*WIDTH))) slot_out_stream  (.clk(clk_i));

    hwpe_stream_intf_stream #(.DATA_WIDTH(ACTUAL_DW)) out_fifo_d (.clk(clk_i));
    hwpe_stream_intf_stream #(.DATA_WIDTH(ACTUAL_DW)) in_fifo_q (.clk(clk_i));

    logic   clear;

    // Declare the interfaces
    hwpe_stream_intf_stream #(.DATA_WIDTH(LANE_WIDTH)) lane_in[NUM_LANES] (.clk(clk_i));
    hwpe_stream_intf_stream #(.DATA_WIDTH(LANE_WIDTH)) lane_out[NUM_LANES] (.clk(clk_i));


    softex_ctrl #(
        .N_CORES    (   N_CORES     ),
        .DATA_WIDTH (   ACTUAL_DW   )
    ) i_ctrl (
        .clk_i              (   clk_i               ),
        .rst_ni             (   rst_ni              ),
        .enable_i           (   '1                  ),
        .in_stream_flags_i  (   stream_in_flgs      ),
        .out_stream_flags_i (   stream_out_flgs     ),
        .datapath_flgs_i    (   datapath_flgs       ),
        .state_slot_i       (   state_slot          ),
        .clear_o            (   clear               ),
        .busy_o             (   busy_o              ),
        .evt_o              (   evt_o               ),
        .in_stream_ctrl_o   (   stream_in_ctrl      ),
        .out_stream_ctrl_o  (   stream_out_ctrl     ),
        .datapath_ctrl_o    (   datapath_ctrl       ),
        .slot_ctrl_o        (   slot_regfile_ctrl   ),
        .in_cast_ctrl_o     (   in_cast_ctrl        ),
        .out_cast_ctrl_o    (   out_cast_ctrl       ),
        .periph             (   periph              )
    );

    softex_slot_regfile #(
        .DATA_WIDTH (   ACTUAL_DW  )
    ) i_slot_regfile (
        .clk_i          (   clk_i               ),
        .rst_ni         (   rst_ni              ),
        .clear_i        (   clear               ),
        .ctrl_i         (   slot_regfile_ctrl   ),
        .slot_o         (   state_slot          ),
        .store_ctrl_o   (   slot_out_ctrl       ),
        .load_ctrl_o    (   slot_in_ctrl        ),
        .store_o        (   slot_out_stream     ),
        .load_i         (   slot_in_stream      )
    );

    hwpe_stream_fifo #(
        .DATA_WIDTH (   ACTUAL_DW  ),
        .FIFO_DEPTH (   2          )
    ) i_in_fifo (
        .clk_i      (   clk_i       ),
        .rst_ni     (   rst_ni      ),
        .clear_i    (   clear       ),
        .flags_o    (               ),
        .push_i     (   in_stream   ),
        .pop_o      (   in_fifo_q   )
    );

    hwpe_stream_fifo #(
        .DATA_WIDTH (   ACTUAL_DW  ),
        .FIFO_DEPTH (   2           )
    ) i_out_fifo (
        .clk_i      (   clk_i       ),
        .rst_ni     (   rst_ni      ),
        .clear_i    (   clear       ),
        .flags_o    (               ),
        .push_i     (   out_fifo_d  ),
        .pop_o      (   out_stream  )
    );

    softex_streamer #(
        .`HCI_SIZE_PARAM(Tcdm) ( `HCI_SIZE_PARAM(Tcdm)),
        .ACTUAL_DW ( ACTUAL_DW )
    ) i_streamer (
        .clk_i              (   clk_i           ),
        .rst_ni             (   rst_ni          ),
        .clear_i            (   clear           ),  
        .enable_i           (   '1              ), 
        .in_stream_ctrl_i   (   stream_in_ctrl  ), 
        .out_stream_ctrl_i  (   stream_out_ctrl ),
        .slot_in_ctrl_i     (   slot_in_ctrl    ), 
        .slot_out_ctrl_i    (   slot_out_ctrl   ),
        .in_cast_i          (   in_cast_ctrl    ),
        .out_cast_i         (   out_cast_ctrl   ),
        .in_stream_flags_o  (   stream_in_flgs  ),
        .out_stream_flags_o (   stream_out_flgs ),
        .slot_in_flags_o    (   slot_in_flgs    ),
        .slot_out_flags_o   (   slot_out_flgs   ),
        .in_stream_o        (   in_stream       ),  
        .out_stream_i       (   out_stream      ),
        .slot_in_stream_o   (   slot_in_stream  ),  
        .slot_out_stream_i  (   slot_out_stream ), 
        .tcdm               (   tcdm            ) 
    );

    hwpe_stream_intf_stream #(.DATA_WIDTH(LANE_WIDTH)) pre_lane_in_fifo (.clk(clk_i));

    hwpe_stream_split_stride #(
        .NB_OUT_STREAMS(NUM_LANES),
        .DATA_WIDTH_IN(ACTUAL_DW),
        .ELEMENT_WIDTH(WIDTH)
    ) i_lane_splitter (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .clear_i (clear),

        .push_i  (in_fifo_q.sink),
        .pop_o   (lane_in.source)
    );

    hwpe_stream_merge_stride #(
            .NB_IN_STREAMS(NUM_LANES),
            .DATA_WIDTH_IN(LANE_WIDTH),
            .ELEMENT_WIDTH(WIDTH)
    ) i_lane_merge (
            .clk_i(clk_i),
            .rst_ni(rst_ni),
            .clear_i(clear),

            .push_i(lane_out.sink),
            .pop_o(out_fifo_d.source)
    );


    for (genvar i = 0; i < NUM_LANES; i++) begin : gen_datapath_lanes
        softex_datapath #(
            .DATA_WIDTH     (LANE_WIDTH),
            .IN_FPFORMAT    (FPFORMAT),
            .VECT_WIDTH     (LANE_WIDTH / WIDTH)
        ) i_datapath_lane (
            .clk_i     (clk_i),
            .rst_ni    (rst_ni),
            .clear_i   (clear),
            .ctrl_i    (datapath_ctrl[i]),
            .flags_o   (datapath_flgs[i]),
            .stream_i  (lane_in[i].sink),
            .stream_o  (lane_out[i].source)
        );
    end

endmodule
