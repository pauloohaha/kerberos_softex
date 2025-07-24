// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Andrea Belano <andrea.belano@studio.unibo.it>
//

import hci_package::*;
import hwpe_stream_package::*;
import softex_pkg::*;

module softex_ctrl #(
    parameter int unsigned              N_CORES         = 2                     ,
    parameter int unsigned              N_CONTEXT       = N_CTRL_CNTX           ,
    parameter int unsigned              IO_REGS         = N_CTRL_REGS           ,
    parameter int unsigned              ID_WIDTH        = 2                     ,
    parameter int unsigned              N_STATE_SLOTS   = N_CTRL_STATE_SLOTS    ,
    parameter int unsigned              DATA_WIDTH      = DATA_W - 64           ,
    parameter int unsigned              INT_WIDTH       = INT_W                 ,
    parameter fpnew_pkg::fp_format_e    IN_FPFORMAT     = FPFORMAT_IN           ,
    parameter fpnew_pkg::fp_format_e    ACC_FPFORMAT    = FPFORMAT_ACC          
) (
    input   logic                           clk_i               ,
    input   logic                           rst_ni              ,
    input   logic                           enable_i            ,
    input   hci_streamer_flags_t            in_stream_flags_i   ,
    input   hci_streamer_flags_t            out_stream_flags_i  ,
    input   softex_pkg::datapath_flags_t [NUM_LANES-1:0]datapath_flgs_i         ,
    input   softex_pkg::slot_t              state_slot_i        ,
    output  logic                           clear_o             ,
    output  logic                           busy_o              ,
    output  logic [N_CORES - 1 : 0] [1 : 0] evt_o               ,
    output  hci_streamer_ctrl_t             in_stream_ctrl_o    ,
    output  hci_streamer_ctrl_t             out_stream_ctrl_o   ,
    output  softex_pkg::datapath_ctrl_t     [NUM_LANES-1:0]datapath_ctrl_o     ,
    output  softex_pkg::slot_regfile_ctrl_t slot_ctrl_o         ,
    output  softex_pkg::cast_ctrl_t         in_cast_ctrl_o      ,
    output  softex_pkg::cast_ctrl_t         out_cast_ctrl_o     ,

    hwpe_ctrl_intf_periph.slave             periph
);

    localparam int unsigned IN_WIDTH    = fpnew_pkg::fp_width(IN_FPFORMAT);
    localparam int unsigned ACC_WIDTH   = fpnew_pkg::fp_width(ACC_FPFORMAT);

    // The number of bits read when the input is integer
    localparam int unsigned DATA_WIDTH_INT  = INT_WIDTH * DATA_WIDTH / IN_WIDTH > DATA_WIDTH ? DATA_WIDTH : INT_WIDTH * DATA_WIDTH / IN_WIDTH;

    typedef enum logic [2:0] {
        IDLE,
        WAIT_SLOT_VALID,
        ACCUMULATION,
        WAIT_DATAPATH_EMPTY,
        WAIT_ACCUMULATION,
        WAIT_INVERSION,
        DIVIDING,
        FINISHED
    } softex_state_t;

    typedef struct packed {
        logic                       valid;
        logic [IN_WIDTH - 1 : 0]    max;
        logic [ACC_WIDTH - 1 : 0]   denominator;
    } state_slot_t;

    softex_state_t current_state,
                next_state;

    logic   in_start,
            out_start;

    logic   dp_acc_finished,
            dp_dividing,
            dp_disable_max,
            dp_load_max,
            dp_load_denominator,
            dp_load_reciprocal;

    logic   clear,
            clear_regs;

    logic   slave_done;

    logic   acc_only,
            div_only,
            last,
            set_cache_addr,
            acquire_slot,
            no_operation,
            cast_input,
            cast_output;

    logic [31 : 0]  slot_cache_base_addr;
    logic   cache_base_addr_en;

    logic   state_slot_en,
            state_slot_clear;

    logic [16 : 0]   current_slot;

    logic [$clog2(DATA_WIDTH / 8) - 1 : 0]  length_lftovr,
                                            int_length_lftovr;

    logic   lftovr_inc,
            int_lftovr_inc;

    // Parameterizable helper signals for checking all lanes
    logic   all_datapaths_idle;
    logic   all_accumulators_done;
    logic   all_inverters_done;

    hwpe_ctrl_package::ctrl_regfile_t   reg_file;
    hwpe_ctrl_package::ctrl_slave_t     ctrl_slave;
    hwpe_ctrl_package::flags_slave_t    flgs_slave;

    hwpe_ctrl_slave  #(
        .REGFILE_SCM    (   CTRL_REGFILE_SCM    ),
        .N_CORES        (   N_CORES             ),
        .N_CONTEXT      (   N_CONTEXT           ),
        .N_IO_REGS      (   IO_REGS             ),
        .N_GENERIC_REGS (   0                   ),
        .ID_WIDTH       (   ID_WIDTH            )
    ) i_slave (
        .clk_i      (   clk_i       ),
        .rst_ni     (   rst_ni      ),
        .clear_o    (   clear       ),
        .cfg        (   periph      ),
        .ctrl_i     (   ctrl_slave  ),
        .flags_o    (   flgs_slave  ),
        .reg_file   (   reg_file    )
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            slot_cache_base_addr <= '0;
        end else begin
            if (clear) begin
                slot_cache_base_addr <= '0;
            end else if (cache_base_addr_en) begin
                slot_cache_base_addr <= reg_file.hwpe_params [CACHE_BASE_ADDR];
            end
        end
    end
    

    always_ff @(posedge clk_i or negedge rst_ni) begin : state_register
        if (~rst_ni) begin
            current_state <= IDLE;
        end else begin
            if (clear) begin
                current_state <= IDLE;
            end else begin
                current_state <= next_state;
            end
        end
    end

    assign length_lftovr        = reg_file.hwpe_params [TOT_LEN] [$clog2(DATA_WIDTH / 8) - 1 : 0];

    // If the total length of the vector is not a multiple of the data width we need to increse the number of loads / stores by one
    assign lftovr_inc           = length_lftovr != '0;

    // Same as before but with integer inputs
    assign int_length_lftovr    = reg_file.hwpe_params [TOT_LEN] [$clog2(DATA_WIDTH_INT / 8) - 1 : 0];

    assign int_lftovr_inc       = int_length_lftovr != '0;

    // Parameterizable logic for checking all lanes
    generate
        genvar lane_check;
        logic [NUM_LANES-1:0] datapath_busy_lanes;
        logic [NUM_LANES-1:0] accumulator_done_lanes;
        logic [NUM_LANES-1:0] inverter_done_lanes;
        
        for (lane_check = 0; lane_check < NUM_LANES; lane_check++) begin : gen_lane_checks
            assign datapath_busy_lanes[lane_check] = datapath_flgs_i[lane_check].datapath_busy;
            assign accumulator_done_lanes[lane_check] = datapath_flgs_i[lane_check].accumulator_flags.acc_done;
            assign inverter_done_lanes[lane_check] = datapath_flgs_i[lane_check].accumulator_flags.inv_done;
        end
    endgenerate
    
    logic [NUM_LANES-1:0] accumulator_done_lanes_q;
    logic [NUM_LANES-1:0] inverter_done_lanes_q;

    assign all_datapaths_idle = ~(|datapath_busy_lanes);
    assign all_accumulators_done = &accumulator_done_lanes_q;
    assign all_inverters_done   = &inverter_done_lanes_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            accumulator_done_lanes_q <= '0;
            inverter_done_lanes_q    <= '0;
        end else begin
            // If all lanes are done, reset the latches. Otherwise, latch incoming done signals.
            if (all_accumulators_done) begin
                accumulator_done_lanes_q <= '0;
            end else begin
                accumulator_done_lanes_q <= accumulator_done_lanes_q | accumulator_done_lanes;
            end

            if (all_inverters_done) begin
                inverter_done_lanes_q <= '0;
            end else begin
                inverter_done_lanes_q <= inverter_done_lanes_q | inverter_done_lanes;
            end
        end
    end

    assign in_stream_ctrl_o.req_start                       = in_start;
    assign in_stream_ctrl_o.addressgen_ctrl.base_addr       = reg_file.hwpe_params [IN_ADDR];
    assign in_stream_ctrl_o.addressgen_ctrl.tot_len         = cast_input ? reg_file.hwpe_params [TOT_LEN] / (DATA_WIDTH_INT / 8) + int_length_lftovr : reg_file.hwpe_params [TOT_LEN] / (DATA_WIDTH / 8) + lftovr_inc;
    assign in_stream_ctrl_o.addressgen_ctrl.d0_len          = reg_file.hwpe_params [TOT_LEN];   // Used by the strobe generator
    //MARIUS: do it TOT_LEN dependent here. Now 24, before it was 4.
    assign in_stream_ctrl_o.addressgen_ctrl.d0_stride       = cast_input ? DATA_WIDTH_INT / 8 : DATA_WIDTH / 8; //MARIUS TODO: reg parameter. //This should skip one "row" of elements. 4 in our case as 4 tcdm requests per row.
    assign in_stream_ctrl_o.addressgen_ctrl.d1_len          = '0;
    assign in_stream_ctrl_o.addressgen_ctrl.d1_stride       = '0;
    assign in_stream_ctrl_o.addressgen_ctrl.d2_stride       = '0;
    assign in_stream_ctrl_o.addressgen_ctrl.dim_enable_1h   = '0;

    assign out_stream_ctrl_o.req_start                      = out_start;
    assign out_stream_ctrl_o.addressgen_ctrl.base_addr      = reg_file.hwpe_params [OUT_ADDR];
    assign out_stream_ctrl_o.addressgen_ctrl.tot_len        = cast_output ? reg_file.hwpe_params [TOT_LEN] / (DATA_WIDTH_INT / 8) + int_length_lftovr : reg_file.hwpe_params [TOT_LEN] / (DATA_WIDTH / 8) + lftovr_inc;
    assign out_stream_ctrl_o.addressgen_ctrl.d0_len         = reg_file.hwpe_params [TOT_LEN];   // Used by the strobe generator
    assign out_stream_ctrl_o.addressgen_ctrl.d0_stride      = cast_output ? DATA_WIDTH_INT / 8 : DATA_WIDTH / 8;
    assign out_stream_ctrl_o.addressgen_ctrl.d1_len         = '0;
    assign out_stream_ctrl_o.addressgen_ctrl.d1_stride      = '0;
    assign out_stream_ctrl_o.addressgen_ctrl.d2_stride      = '0;
    assign out_stream_ctrl_o.addressgen_ctrl.dim_enable_1h  = '0;

    for (genvar i = 0; i < NUM_LANES; i++) begin : update_dpctrl
        assign datapath_ctrl_o[i].accumulator_ctrl.acc_finished    = dp_acc_finished;
        assign datapath_ctrl_o[i].accumulator_ctrl.acc_only        = acc_only & ~last;
        assign datapath_ctrl_o[i].accumulator_ctrl.load_reciprocal = dp_load_reciprocal;

        assign datapath_ctrl_o[i].dividing                        = dp_dividing;
        assign datapath_ctrl_o[i].disable_max                     = dp_disable_max;
        assign datapath_ctrl_o[i].clear_regs                      = clear_regs;
        assign datapath_ctrl_o[i].load_max                        = dp_load_max;
        assign datapath_ctrl_o[i].load_denominator                = dp_load_denominator;

        assign datapath_ctrl_o[i].max                         = state_slot_i.maximum[i];
        assign datapath_ctrl_o[i].denominator                 = state_slot_i.denominator[i];
        assign datapath_ctrl_o[i].accumulator_ctrl.reciprocal = state_slot_i.denominator[i];
    end

    assign acc_only                                         = reg_file.hwpe_params [COMMANDS] [CMD_ACC_ONLY];       // We stop as soon as the denominator is valid, no inversion is performed
    assign div_only                                         = reg_file.hwpe_params [COMMANDS] [CMD_DIV_ONLY];       // Only perform the normalisation step. The maximum and the denominator are recovered from the state slot
    assign last                                             = reg_file.hwpe_params [COMMANDS] [CMD_LAST];           // We are performing the last partial accumulation / normalisation
    assign set_cache_addr                                   = reg_file.hwpe_params [COMMANDS] [CMD_SET_CACHE_ADDR]; // Sets the base address of the state slot cache
    assign acquire_slot                                     = reg_file.hwpe_params [COMMANDS] [CMD_ACQUIRE_SLOT];   // This is the first partial iteration of a new operation
    assign no_operation                                     = reg_file.hwpe_params [COMMANDS] [CMD_NO_OP];          // No operation has to be performed; currently used to update the cache address without necessarily starting an operation 
    assign cast_input                                       = reg_file.hwpe_params [COMMANDS] [CMD_INT_INPUT];      // Cast the input from fixed point to floating point
    assign cast_output                                      = reg_file.hwpe_params [COMMANDS] [CMD_INT_OUTPUT];     // Cast the output from floating point to fixed point

    assign current_slot                                     = reg_file.hwpe_params [COMMANDS] [31 -: 16];

    assign in_cast_ctrl_o.int_bits                          = reg_file.hwpe_params [CAST_CTRL] [6 : 0];
    assign in_cast_ctrl_o.is_signed                         = reg_file.hwpe_params [CAST_CTRL] [7];
    assign in_cast_ctrl_o.enable                            = cast_input;
    
    assign out_cast_ctrl_o.int_bits                         = reg_file.hwpe_params [CAST_CTRL] [14 : 8];
    assign out_cast_ctrl_o.is_signed                        = reg_file.hwpe_params [CAST_CTRL] [15];
    assign out_cast_ctrl_o.enable                           = cast_output;    

    assign ctrl_slave.done                                  = slave_done;
    assign ctrl_slave.evt                                   = '0;

    assign slot_ctrl_o.cache_base_addr                      = slot_cache_base_addr;
    assign slot_ctrl_o.addr                                 = current_slot;

    // "request" commands are pushed as soon a partial operation is detected  
    assign slot_ctrl_o.req_valid                            = periph.req & periph.gnt & (periph.add [ID_WIDTH - 1 : 0] == (COMMANDS * 4 + 32)) & (periph.data [CMD_ACC_ONLY] | periph.data [CMD_DIV_ONLY]);
    assign slot_ctrl_o.req_op.addr                          = periph.data [31 -: 16];
    assign slot_ctrl_o.req_op.op                            = periph.data [CMD_ACQUIRE_SLOT] ? ALLOC : LOAD;


    assign slot_ctrl_o.update_valid                         = state_slot_en;
    assign slot_ctrl_o.update_op.addr                       = current_slot;
    assign slot_ctrl_o.update_op.op                         = last & div_only ? FREE : UPDATE;   
    for (genvar i = 0; i < NUM_LANES; i++) begin : update_assign
        assign slot_ctrl_o.update_op.maximum[i]               = datapath_flgs_i[i].max;
        assign slot_ctrl_o.update_op.denominator[i]           = (acc_only & ~last) ? datapath_flgs_i[i].accumulator_flags.denominator : datapath_flgs_i[i].accumulator_flags.reciprocal;
    end

    always_comb begin : ctrl_sfm
        next_state          = current_state;
        out_start           = '0;
        in_start            = '0;
        dp_acc_finished     = '0;
        dp_disable_max      = '0;
        dp_dividing         = '0;
        slave_done          = '0;
        busy_o              = '1;
        clear_regs          = '0;
        state_slot_en       = '0;
        state_slot_clear    = '0;
        dp_load_max         = '0;
        dp_load_denominator = '0;
        dp_load_reciprocal  = '0;
        cache_base_addr_en  = '0;

        case (current_state)
            IDLE: begin
                busy_o = '0;

                if (flgs_slave.start) begin
                    if (set_cache_addr) begin
                        cache_base_addr_en = '1;
                    end

                    if (~no_operation) begin
                        if (~state_slot_i.valid & (acc_only | div_only)) begin
                            next_state = WAIT_SLOT_VALID;
                        end else begin
                            casex ({div_only, acc_only})
                                2'b00:  next_state  = ACCUMULATION;
                                2'b01:  next_state  = ACCUMULATION;
                                2'b1?:  next_state  = DIVIDING;
                            endcase

                            if ((acc_only | div_only) & ~acquire_slot) begin
                                dp_load_max = '1;

                                if (acc_only) begin
                                    dp_load_denominator = '1;
                                end else begin
                                    dp_load_reciprocal  = '1;
                                end
                            end

                            if (~div_only) begin
                                in_start    = '1;
                            end else begin
                                out_start   = '1;
                                in_start    = '1;
                            end  
                        end
                    end else begin
                        slave_done = '1;
                    end
                end
            end

            WAIT_SLOT_VALID: begin
                if (state_slot_i.valid) begin
                    if (~acquire_slot) begin
                        dp_load_max = '1;
                    end

                    if (acc_only) begin
                        next_state          = ACCUMULATION;
                        in_start            = '1;

                        if (~acquire_slot) begin
                            dp_load_denominator = '1;
                        end
                    end else begin
                        next_state          = DIVIDING;
                        out_start           = '1;
                        in_start            = '1;

                        if (~acquire_slot) begin
                            dp_load_reciprocal  = '1;
                        end
                    end
                end
            end

            ACCUMULATION: begin
                if (in_stream_flags_i.done) begin
                    next_state = WAIT_DATAPATH_EMPTY;
                end
            end

            WAIT_DATAPATH_EMPTY: begin
                if (all_datapaths_idle) begin
                    next_state      = WAIT_ACCUMULATION;
                    dp_acc_finished = '1;
                end
            end

            WAIT_ACCUMULATION: begin
                dp_acc_finished = '1;
                dp_disable_max  = '1;

                if (all_accumulators_done) begin
                    if (acc_only & ~last) begin
                        next_state          = FINISHED;
                    end else begin
                        if (~acc_only) begin
                            dp_acc_finished = '0;
                            out_start       = '1;
                            in_start        = '1;
                        end

                        next_state      = WAIT_INVERSION;
                    end
                end
            end

            WAIT_INVERSION: begin
                dp_dividing     = '1;
                dp_disable_max  = '1;

                if (all_inverters_done) begin
                    if (acc_only) begin
                        next_state = FINISHED;
                    end else begin
                        next_state = DIVIDING;
                    end
                end
            end

            DIVIDING: begin
                dp_dividing     = '1;
                dp_disable_max  = '1;

                if (out_stream_flags_i.done) begin
                    next_state  = FINISHED;
                end
            end

            FINISHED: begin
                dp_dividing = '0;
                slave_done  = '1;
                busy_o      = '0;
                clear_regs  = '1;

                // The slot only needs to be updated if we are accumulating or if this is the last normalisation iteration
                if (acc_only | (div_only & last)) begin
                    state_slot_en = '1;
                end

                next_state      = IDLE;
            end
        endcase
    end

    assign clear_o  = clear;

    assign  evt_o   = flgs_slave.evt;

endmodule