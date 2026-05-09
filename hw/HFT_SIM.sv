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

`include "hw/sys_def.svh"

module HFT_SIM #(
    parameter int TRADE_LOG_DEPTH = 1024
) (
    input  logic                                    clk,
    input  logic                                    rst_n,

    // Harness to dispatcher (write path)
    input  logic                                    chipselect,
    input  logic                                    write,
    input  logic                                    read,
    input  logic [4:0]                              address,
    input  logic [31:0]                             writedata,
    output logic [31:0]                             readdata,
    output logic [`SYM_NUM-1:0]                     fifo_empty,
    output logic [`SYM_NUM-1:0]                     fifo_full,
    output logic [1:0]                              dispatcher_state,

    // Trade log Signals
    input  logic                                    trade_log_re,
    input  logic [$clog2(TRADE_LOG_DEPTH)-1:0]      trade_log_addr,
    output logic [85:0]                             trade_log_rdata,
    output logic [$clog2(TRADE_LOG_DEPTH+1)-1:0]    trade_log_count,
    output logic                                    trade_log_overflow,
    input  logic                                    trade_log_clear,

    // Per-engine status (debug / hazard unit)
    output logic [13:0]                             bid_size [8],
    output logic [13:0]                             ask_size [8]
);

    localparam int N          = 8;
    localparam int NODE_WIDTH = 86;

    // Free-running timestamp counter
    logic [31:0] now_ts;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) now_ts <= 32'd0;
        else        now_ts <= now_ts + 32'd1;
    end

    // Top module wrapper to dispatcher
    logic                     sw_begin_write;
    logic                     sw_begin_dispatch;
    logic                     sw_clear_done;
    logic [N-1:0]             sw_wr_en;
    logic [N-1:0]             sw_wr_ready;
    DISPATCH_ORDER            sw_wr_data [N];
    
    // Dispatcher to engines bus
    logic                  [N-1:0] order_in_valid;
    logic                  [N-1:0] order_in_ready;
    DISPATCH_ORDER         [N-1:0] order_in_data;

    // Engines to MMU ports
    logic                          mmu_req_valid   [N];
    logic [31:0]                   mmu_req_va      [N];
    logic                          mmu_req_wr      [N];
    logic [NODE_WIDTH-1:0]         mmu_req_wdata   [N];
    logic                          mmu_req_ready   [N];
    logic [NODE_WIDTH-1:0]         mmu_resp_data   [N];
    logic                          mmu_resp_valid  [N];
    logic                          mmu_resp_reject [N];

    // Engines to trade aggregator. valid and ready are packed bit-vectors
    // so per-element assignments propagate through the port boundary on
    // older simulators (notably iverilog 11). Data stays as an unpacked
    // array because each element is NODE_WIDTH bits.
    logic [N-1:0]                  eng_trade_valid;
    logic [NODE_WIDTH-1:0]         eng_trade_data  [N];
    logic [N-1:0]                  eng_trade_ready;

    // MMU to mem_bank ports
    logic [31:0]                   mem_addr        [4];
    logic                          mem_we          [4];
    logic                          mem_re          [4];
    logic [NODE_WIDTH-1:0]         mem_wdata       [4];
    logic [NODE_WIDTH-1:0]         mem_rdata       [4];
    logic                          mem_rdata_valid [4];
    logic                          mem_busy        [4];

    // Order Dispatcher
    order_dispatcher u_dispatcher (
        .clk              (clk),
        .rst_n            (rst_n),

        // SW harness controls 
        .sw_begin_write    (sw_begin_write),
        .sw_begin_dispatch (sw_begin_dispatch),
        .sw_clear_done     (sw_clear_done),
        .sw_wr_en          (sw_wr_en),
        .sw_wr_data        (sw_wr_data),
        .sw_wr_ready       (sw_wr_ready),

        // FIFO state (per lane)
        .state_out        (dispatcher_state),
        .fifo_empty       (fifo_empty),
        .fifo_full        (fifo_full),

        // Heap Engine communication
        .order_in_ready   (order_in_ready), // Backpressure from engines (ready/valid handshake)
        .order_out_valid  (order_in_valid),
        .order_out        (order_in_data)
    );

    // 8 Symbol Engines (one per symbol slot, ENGINE_ID = 0..7).
    // SYMBOL parameter defaults to the right ASCII for the dataset.
    genvar e;
    generate
        for (e = 0; e < N; e++) begin : g_engines
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
                .bid_size_o      (bid_size[e]),
                .ask_size_o      (ask_size[e])
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
    logic [NODE_WIDTH-1:0] agg_trade_data;
    logic                  agg_trade_ready;

    trade_aggregator #(.N(N), .NODE_WIDTH(NODE_WIDTH)) u_trade_agg (
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
        .NODE_WIDTH (NODE_WIDTH),
        .LOG_DEPTH  (TRADE_LOG_DEPTH)
    ) u_trade_log (
        .clk            (clk),
        .rst_n          (rst_n),
        .trade_in_valid (agg_trade_valid),
        .trade_in_data  (agg_trade_data),
        .trade_in_ready (agg_trade_ready),
        .sw_re          (trade_log_re),
        .sw_addr        (trade_log_addr),
        .sw_rdata       (trade_log_rdata),
        .sw_count       (trade_log_count),
        .sw_overflow    (trade_log_overflow),
        .sw_clear       (trade_log_clear)
    );

endmodule
