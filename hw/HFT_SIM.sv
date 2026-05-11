// HFT_SIM.sv - System top-level
//
// Wires the full HFT pipeline:
// includes the following...
//   - 1 order_dispatcher
//   - 8 symbol_engines
//   - 1 mmu
//   - 4 mem_banks
//   - 1 trade_aggregator
//   - 1 trade_log
//   - 1 free-running 32-bit timestamp

`include "sys_def.svh"

module HFT_SIM #(
    parameter int TRADE_LOG_DEPTH = 1024
) (
    input  logic                                    clk,
    input  logic                                    rst_n,

    // Avalon Bus Interface
    // This will be the only way to communicate with the Linux core
    input  logic                                    chipselect,
    input  logic                                    write,
    input  logic                                    read,
    input  logic [4:0]                              address,
    input  logic [31:0]                             writedata,
    output logic [31:0]                             readdata
);

    // Free-running timestamp counter
    logic [31:0] now_ts;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) now_ts <= 32'd0;
        else        now_ts <= now_ts + 32'd1;
    end

    // Avalon/software wrapper -> dispatcher
    logic                     avl_disp_begin_write_pulse;
    logic                     avl_disp_begin_dispatch_pulse;
    logic                     avl_disp_clear_done_pulse;
    logic [`N-1:0]            avl_disp_push_en;
    logic [`N-1:0]            avl_disp_push_ready;
    DISPATCH_ORDER [`N-1:0]   avl_disp_push_data;
    logic [`N-1:0]            avl_disp_fifo_empty;
    logic [`N-1:0]            avl_disp_fifo_full;
    logic [1:0]               avl_disp_state;

    // Avalon/software wrapper -> trade_log
    localparam int LOG_IDX_W   = $clog2(TRADE_LOG_DEPTH);
    localparam int LOG_IDX_W_BUS  = (LOG_IDX_W > 30) ? 30 : LOG_IDX_W; // max index bits in [31:2]
    localparam int LOG_COUNT_W = $clog2(TRADE_LOG_DEPTH + 1);

    logic                      avl_log_read_pulse;
    logic [LOG_IDX_W-1:0]      avl_log_read_index;
    logic [`ORDER_WIDTH-1:0]   avl_log_read_data;
    logic [LOG_COUNT_W-1:0]    avl_log_count;
    logic                      avl_log_overflow;
    logic                      avl_log_clear_pulse;

    // Shadow register for software-visible log data
    logic [`ORDER_WIDTH-1:0]   avl_log_data_shadow;
    logic                      avl_log_data_valid;

    // trade_log read is registered:
    // write LOG_CMD(read_req+index) -> pulse sw_re
    // -> trade_log updates sw_rdata next cycle
    // -> capture sw_rdata the cycle after that
    logic [1:0]                avl_log_read_pipe;
    
    // Dispatcher to engines bus
    logic           [`N-1:0] order_in_valid;
    logic           [`N-1:0] order_in_ready;
    DISPATCH_ORDER  [`N-1:0] order_in_data;

    // Engines to MMU ports
    logic                       mmu_req_valid   [`N];
    logic [31:0]                mmu_req_va      [`N];
    logic                       mmu_req_wr      [`N];
    logic [`ORDER_WIDTH-1:0]    mmu_req_wdata   [`N];
    logic                       mmu_req_ready   [`N];
    logic [`ORDER_WIDTH-1:0]    mmu_resp_data   [`N];
    logic                       mmu_resp_valid  [`N];
    logic                       mmu_resp_reject [`N];

    // Engines to trade aggregator. valid and ready are packed bit-vectors
    // so per-element assignments propagate through the port boundary on
    // older simulators (notably iverilog 11). Data stays as an unpacked
    // array because each element is `ORDER_WIDTH bits.
    logic [`N-1:0]              eng_trade_valid;
    logic [`ORDER_WIDTH-1:0]    eng_trade_data  [`N];
    logic [`N-1:0]              eng_trade_ready;

    // MMU to mem_bank ports
    logic [31:0]                mem_addr        [4];
    logic                       mem_we          [4];
    logic                       mem_re          [4];
    logic [`ORDER_WIDTH-1:0]    mem_wdata       [4];
    logic [`ORDER_WIDTH-1:0]    mem_rdata       [4];
    logic                       mem_rdata_valid [4];
    logic                       mem_busy        [4];

    ///////////////////////////////////////////////////////////////////////
    // Translation Wrapper 
    // 
    // This decodes or encodes information so that we can communicate with 
    // the Linux core over the Avalon bus.  
    ///////////////////////////////////////////////////////////////////////
    
    // Register Map
    localparam int ADDR_CONTROL   = 5'd0;  // 0x00
    localparam int ADDR_STATUS    = 5'd1;  // 0x04
    localparam int ADDR_PUSH0     = 5'd2;  // 0x08
    localparam int ADDR_PUSH1     = 5'd3;  // 0x0C
    localparam int ADDR_PUSH2     = 5'd4;  // 0x10
    localparam int ADDR_PUSH3     = 5'd5;  // 0x14
    localparam int ADDR_PUSH4     = 5'd6;  // 0x18
    localparam int ADDR_PUSH5     = 5'd7;  // 0x1C
    localparam int ADDR_PUSH6     = 5'd8;  // 0x20
    localparam int ADDR_PUSH7     = 5'd9;  // 0x24
    localparam int ADDR_LOG_INFO  = 5'd10; // 0x28
    localparam int ADDR_LOG_CMD   = 5'd11; // 0x2C
    localparam int ADDR_LOG_DATA0 = 5'd12; // 0x30
    localparam int ADDR_LOG_DATA1 = 5'd13; // 0x34
    localparam int ADDR_LOG_DATA2 = 5'd14; // 0x38

    // Decode Avalon writes into dispatcher and trade-log controls
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avl_disp_begin_write_pulse    <= 1'b0;
            avl_disp_begin_dispatch_pulse <= 1'b0;
            avl_disp_clear_done_pulse     <= 1'b0;
            avl_disp_push_en              <= '0;

            avl_log_read_pulse            <= 1'b0;
            avl_log_read_index            <= '0;
            avl_log_clear_pulse           <= 1'b0;
            avl_log_data_shadow           <= '0;
            avl_log_data_valid            <= 1'b0;
            avl_log_read_pipe             <= 2'b00;

            for (int i = 0; i < `N; i++) begin
                avl_disp_push_data[i] <= '0;
            end

        end else begin
            // Default pulse behavior: one cycle only
            avl_disp_begin_write_pulse    <= 1'b0;
            avl_disp_begin_dispatch_pulse <= 1'b0;
            avl_disp_clear_done_pulse     <= 1'b0;
            avl_disp_push_en              <= '0;

            avl_log_read_pulse            <= 1'b0;
            avl_log_clear_pulse           <= 1'b0;

            // trade_log registered read timing:
            // 01 -> read request launched
            // 10 -> capture returned data
            if (avl_log_read_pipe[0]) begin
                avl_log_read_pipe <= 2'b10;
            end else if (avl_log_read_pipe[1]) begin
                avl_log_read_pipe   <= 2'b00;
                avl_log_data_shadow <= avl_log_read_data;
                avl_log_data_valid  <= 1'b1;
            end

            if (chipselect && write) begin
                unique case (address)
                    ADDR_CONTROL: begin
                        avl_disp_begin_write_pulse    <= writedata[0];
                        avl_disp_begin_dispatch_pulse <= writedata[1];
                        avl_disp_clear_done_pulse     <= writedata[2];
                    end
                    ADDR_PUSH0: begin
                        if (avl_disp_push_ready[0]) begin
                            avl_disp_push_en[0]   <= 1'b1;
                            avl_disp_push_data[0] <= DISPATCH_ORDER'(writedata);
                        end
                    end
                    ADDR_PUSH1: begin
                        if (avl_disp_push_ready[1]) begin
                            avl_disp_push_en[1]   <= 1'b1;
                            avl_disp_push_data[1] <= DISPATCH_ORDER'(writedata);
                        end
                    end
                    ADDR_PUSH2: begin
                        if (avl_disp_push_ready[2]) begin
                            avl_disp_push_en[2]   <= 1'b1;
                            avl_disp_push_data[2] <= DISPATCH_ORDER'(writedata);
                        end
                    end
                    ADDR_PUSH3: begin
                        if (avl_disp_push_ready[3]) begin
                            avl_disp_push_en[3]   <= 1'b1;
                            avl_disp_push_data[3] <= DISPATCH_ORDER'(writedata);
                        end
                    end
                    ADDR_PUSH4: begin
                        if (avl_disp_push_ready[4]) begin
                            avl_disp_push_en[4]   <= 1'b1;
                            avl_disp_push_data[4] <= DISPATCH_ORDER'(writedata);
                        end
                    end
                    ADDR_PUSH5: begin
                        if (avl_disp_push_ready[5]) begin
                            avl_disp_push_en[5]   <= 1'b1;
                            avl_disp_push_data[5] <= DISPATCH_ORDER'(writedata);
                        end
                    end
                    ADDR_PUSH6: begin
                        if (avl_disp_push_ready[6]) begin
                            avl_disp_push_en[6]   <= 1'b1;
                            avl_disp_push_data[6] <= DISPATCH_ORDER'(writedata);
                        end
                    end
                    ADDR_PUSH7: begin
                        if (avl_disp_push_ready[7]) begin
                            avl_disp_push_en[7]   <= 1'b1;
                            avl_disp_push_data[7] <= DISPATCH_ORDER'(writedata);
                        end
                    end
                    ADDR_LOG_CMD: begin
                        // bit 0 = clear
                        // bit 1 = read_req
                        // bits [LOG_IDX_W+1:2] = read_index
                        if (writedata[0]) begin
                            avl_log_clear_pulse <= 1'b1;
                            avl_log_data_shadow <= '0;
                            avl_log_data_valid  <= 1'b0;
                            avl_log_read_pipe   <= 2'b00;
                        end else if (writedata[1]) begin
                            avl_log_read_index  <= writedata[LOG_IDX_W_BUS+1:2];
                            avl_log_read_pulse  <= 1'b1;
                            avl_log_data_valid  <= 1'b0;
                            avl_log_read_pipe   <= 2'b01;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    // Decode Avalon reads from dispatcher and trade-log status/data
    always_comb begin
        readdata = 32'd0;

        if (chipselect && read) begin
            unique case (address)
                ADDR_STATUS: readdata = {6'd0,
                                avl_disp_fifo_full,
                                avl_disp_fifo_empty,
                                avl_disp_push_ready,
                                avl_disp_state};
                ADDR_LOG_INFO: begin
                    // [0] = overflow
                    // [1] = selected log entry valid in DATA0/1/2
                    // [2 +: LOG_COUNT_W] = number of valid entries in trade_log
                    readdata = {{(32-(LOG_COUNT_W+2)){1'b0}},
                                avl_log_count,
                                avl_log_data_valid,
                                avl_log_overflow};
                end
                ADDR_LOG_DATA0: readdata = avl_log_data_shadow[31:0];
                ADDR_LOG_DATA1: readdata = avl_log_data_shadow[63:32];
                ADDR_LOG_DATA2: readdata = {10'd0, avl_log_data_shadow[85:64]};
                default: ;
            endcase
        end
    end

    /////////////////////////////////////////////////////////////////////// 
    // Module Instantiation & Connection 
    ///////////////////////////////////////////////////////////////////////
    
    // Order Dispatcher
    order_dispatcher u_dispatcher (
        .clk              (clk),
        .rst_n            (rst_n),

        // Avalon/software wrapper controls
        .sw_begin_write    (avl_disp_begin_write_pulse),
        .sw_begin_dispatch (avl_disp_begin_dispatch_pulse),
        .sw_clear_done     (avl_disp_clear_done_pulse),
        .sw_wr_en          (avl_disp_push_en),
        .sw_wr_data        (avl_disp_push_data),
        .sw_wr_ready       (avl_disp_push_ready),

        // FIFO state visible to Avalon/software
        .state_out         (avl_disp_state),
        .fifo_empty        (avl_disp_fifo_empty),
        .fifo_full         (avl_disp_fifo_full),

        // Heap Engine communication
        .order_in_ready    (order_in_ready),
        .order_out_valid   (order_in_valid),
        .order_out         (order_in_data)
    );

    // 8 Symbol Engines (one per symbol slot, ENGINE_ID = 0..7).
    // SYMBOL parameter defaults to the right ASCII for the dataset.
    genvar e;
    generate
        for (e = 0; e < `N; e++) begin : g_engines
            symbol_engine #(.ENGINE_ID(e)) u_engine (
                .clk             (clk),
                .rst_n           (rst_n),
                .now_ts          (now_ts),
                .order_in_valid  (order_in_valid[e]),
                .order_in_data   (order_in_data[e]),
                .order_in_ready  (order_in_ready[e]),
                .trade_out_valid (eng_trade_valid[e]),
                .trade_out_data  (eng_trade_data[e]),
                .trade_out_ready (eng_trade_ready[e]),
                .mmu_req_valid   (mmu_req_valid[e]),
                .mmu_req_va      (mmu_req_va[e]),
                .mmu_req_wr      (mmu_req_wr[e]),
                .mmu_req_wdata   (mmu_req_wdata[e]),
                .mmu_req_ready   (mmu_req_ready[e]),
                .mmu_resp_data   (mmu_resp_data[e]),
                .mmu_resp_valid  (mmu_resp_valid[e]),
                .mmu_resp_reject (mmu_resp_reject[e]),
                .bid_size_o      (), // Leave disconnected for now
                .ask_size_o      ()
            );
        end
    endgenerate

    // MMU (8 individual client ports, 4 mem_bank ports)
    mmu u_mmu (
        .clk    (clk),
        .rst_n  (rst_n),

        .req_valid_0(mmu_req_valid[0]), .req_valid_1(mmu_req_valid[1]),
        .req_valid_2(mmu_req_valid[2]), .req_valid_3(mmu_req_valid[3]),
        .req_valid_4(mmu_req_valid[4]), .req_valid_5(mmu_req_valid[5]),
        .req_valid_6(mmu_req_valid[6]), .req_valid_7(mmu_req_valid[7]),

        .req_va_0(mmu_req_va[0]), .req_va_1(mmu_req_va[1]),
        .req_va_2(mmu_req_va[2]), .req_va_3(mmu_req_va[3]),
        .req_va_4(mmu_req_va[4]), .req_va_5(mmu_req_va[5]),
        .req_va_6(mmu_req_va[6]), .req_va_7(mmu_req_va[7]),

        .req_wr_0(mmu_req_wr[0]), .req_wr_1(mmu_req_wr[1]),
        .req_wr_2(mmu_req_wr[2]), .req_wr_3(mmu_req_wr[3]),
        .req_wr_4(mmu_req_wr[4]), .req_wr_5(mmu_req_wr[5]),
        .req_wr_6(mmu_req_wr[6]), .req_wr_7(mmu_req_wr[7]),

        .req_wdata_0(mmu_req_wdata[0]), .req_wdata_1(mmu_req_wdata[1]),
        .req_wdata_2(mmu_req_wdata[2]), .req_wdata_3(mmu_req_wdata[3]),
        .req_wdata_4(mmu_req_wdata[4]), .req_wdata_5(mmu_req_wdata[5]),
        .req_wdata_6(mmu_req_wdata[6]), .req_wdata_7(mmu_req_wdata[7]),

        .req_ready_0(mmu_req_ready[0]), .req_ready_1(mmu_req_ready[1]),
        .req_ready_2(mmu_req_ready[2]), .req_ready_3(mmu_req_ready[3]),
        .req_ready_4(mmu_req_ready[4]), .req_ready_5(mmu_req_ready[5]),
        .req_ready_6(mmu_req_ready[6]), .req_ready_7(mmu_req_ready[7]),

        .resp_data_0(mmu_resp_data[0]), .resp_data_1(mmu_resp_data[1]),
        .resp_data_2(mmu_resp_data[2]), .resp_data_3(mmu_resp_data[3]),
        .resp_data_4(mmu_resp_data[4]), .resp_data_5(mmu_resp_data[5]),
        .resp_data_6(mmu_resp_data[6]), .resp_data_7(mmu_resp_data[7]),

        .resp_valid_0(mmu_resp_valid[0]), .resp_valid_1(mmu_resp_valid[1]),
        .resp_valid_2(mmu_resp_valid[2]), .resp_valid_3(mmu_resp_valid[3]),
        .resp_valid_4(mmu_resp_valid[4]), .resp_valid_5(mmu_resp_valid[5]),
        .resp_valid_6(mmu_resp_valid[6]), .resp_valid_7(mmu_resp_valid[7]),

        .resp_reject_0(mmu_resp_reject[0]), .resp_reject_1(mmu_resp_reject[1]),
        .resp_reject_2(mmu_resp_reject[2]), .resp_reject_3(mmu_resp_reject[3]),
        .resp_reject_4(mmu_resp_reject[4]), .resp_reject_5(mmu_resp_reject[5]),
        .resp_reject_6(mmu_resp_reject[6]), .resp_reject_7(mmu_resp_reject[7]),

        .mem_addr_0(mem_addr[0]), .mem_addr_1(mem_addr[1]),
        .mem_addr_2(mem_addr[2]), .mem_addr_3(mem_addr[3]),

        .mem_we_0(mem_we[0]), .mem_we_1(mem_we[1]),
        .mem_we_2(mem_we[2]), .mem_we_3(mem_we[3]),

        .mem_re_0(mem_re[0]), .mem_re_1(mem_re[1]),
        .mem_re_2(mem_re[2]), .mem_re_3(mem_re[3]),

        .mem_wdata_0(mem_wdata[0]), .mem_wdata_1(mem_wdata[1]),
        .mem_wdata_2(mem_wdata[2]), .mem_wdata_3(mem_wdata[3]),

        .mem_rdata_0(mem_rdata[0]), .mem_rdata_1(mem_rdata[1]),
        .mem_rdata_2(mem_rdata[2]), .mem_rdata_3(mem_rdata[3]),

        .mem_rdata_valid_0(mem_rdata_valid[0]), .mem_rdata_valid_1(mem_rdata_valid[1]),
        .mem_rdata_valid_2(mem_rdata_valid[2]), .mem_rdata_valid_3(mem_rdata_valid[3]),

        .mem_busy_0(mem_busy[0]), .mem_busy_1(mem_busy[1]),
        .mem_busy_2(mem_busy[2]), .mem_busy_3(mem_busy[3])
    );

    // 4 Memory Banks
    genvar b;
    generate
        for (b = 0; b < 4; b++) begin : g_banks
            mem_bank #(.BANK_ID(b)) u_bank (
                .clk             (clk),
                .rst_n           (rst_n),
                .mem_addr        (mem_addr[b]),
                .mem_we          (mem_we[b]),
                .mem_re          (mem_re[b]),
                .mem_wdata       (mem_wdata[b]),
                .mem_rdata       (mem_rdata[b]),
                .mem_rdata_valid (mem_rdata_valid[b]),
                .mem_busy        (mem_busy[b])
            );
        end
    endgenerate

    // Trade Output Aggregator (round-robin between 8 engines) feeds Trade Log
    logic                  agg_trade_valid;
    logic [`ORDER_WIDTH-1:0] agg_trade_data;
    logic                  agg_trade_ready;

    trade_aggregator #(.N(`N), .NODE_WIDTH(`ORDER_WIDTH)) u_trade_agg (
        .clk             (clk),
        .rst_n           (rst_n),
        .eng_trade_valid (eng_trade_valid),
        .eng_trade_data  (eng_trade_data),
        .eng_trade_ready (eng_trade_ready),
        .trade_out_valid (agg_trade_valid),
        .trade_out_data  (agg_trade_data),
        .trade_out_ready (agg_trade_ready)
    );

    trade_log #(
        .NODE_WIDTH (`ORDER_WIDTH),
        .LOG_DEPTH  (TRADE_LOG_DEPTH)
    ) u_trade_log (
        .clk            (clk),
        .rst_n          (rst_n),
        .trade_in_valid (agg_trade_valid),
        .trade_in_data  (agg_trade_data),
        .trade_in_ready (agg_trade_ready),
        .sw_re          (avl_log_read_pulse),
        .sw_addr        (avl_log_read_index),
        .sw_rdata       (avl_log_read_data),
        .sw_count       (avl_log_count),
        .sw_overflow    (avl_log_overflow),
        .sw_clear       (avl_log_clear_pulse)
    );

endmodule
