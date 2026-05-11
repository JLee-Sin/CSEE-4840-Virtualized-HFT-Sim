// symbol_engine.sv - Per-symbol top-level
//
// Wraps everything required for one of the eight symbol slots in the HFT
// pipeline.
//
// Contents:
//   - heap_fsm: two instances, bid (max-heap) and ask (min-heap)
//   - priv_bram: two instances, one 64-node BRAM behind each heap_fsm
//   - trade_ctrl: orchestrates push, peek, decide, pop/update, emit-trade
//   - mmu_mux: 2:1 single-in-flight mux of the two heaps onto the engine's
//     single MMU client port
//
// External contracts:
//   - The MMU port (mmu_*) connects directly to mmu.sv's port ENGINE_ID.
//     VA[31:29] is hard-wired to ENGINE_ID by the heap_fsm instances.
//   - Order ingress is one valid/ready handshake per order; a high
//     order_in_valid indicates the order is destined for this engine.
//   - Trade egress is one valid/ready handshake per executed trade.

module symbol_engine #(
    parameter int               ENGINE_ID  = 0,
    parameter int               NODE_WIDTH = 86,
    parameter logic [20:0]      SYMBOL     =
        (ENGINE_ID == 0) ? {7'd65, 7'd80, 7'd76} :   // APL  (AAPL)
        (ENGINE_ID == 1) ? {7'd66, 7'd83, 7'd88} :   // BSX
        (ENGINE_ID == 2) ? {7'd66, 7'd85, 7'd83} :   // BUS
        (ENGINE_ID == 3) ? {7'd77, 7'd77, 7'd77} :   // MMM
        (ENGINE_ID == 4) ? {7'd83, 7'd70, 7'd84} :   // SFT  (MSFT)
        (ENGINE_ID == 5) ? {7'd66, 7'd85, 7'd88} :   // BUX  (SBUX)
        (ENGINE_ID == 6) ? {7'd84, 7'd85, 7'd83} :   // TUS
        (ENGINE_ID == 7) ? {7'd87, 7'd77, 7'd84} :   // WMT
                           21'd0
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // free-running timestamp counter (shared across all engines by top-level)
    input  logic [31:0]           now_ts,

    // order ingress (from order dispatch). Payload is a 32-bit DISPATCH_ORDER:
    // bit[31] = type, [30:15] = price, [14:0] = quantity.
    input  logic                  order_in_valid,
    input  logic [31:0]           order_in_data,
    output logic                  order_in_ready,

    // trade egress
    output logic                  trade_out_valid,
    output logic [NODE_WIDTH-1:0] trade_out_data,
    input  logic                  trade_out_ready,

    // MMU client port (one of mmu.sv's eight)
    output logic                  mmu_req_valid,
    output logic [31:0]           mmu_req_va,
    output logic                  mmu_req_wr,
    output logic [NODE_WIDTH-1:0] mmu_req_wdata,
    input  logic                  mmu_req_ready,
    input  logic [NODE_WIDTH-1:0] mmu_resp_data,
    input  logic                  mmu_resp_valid,
    input  logic                  mmu_resp_reject,

    // status (to hazard unit / harness)
    output logic [13:0]           bid_size_o,
    output logic [13:0]           ask_size_o
);

    // Node-field helpers (must mirror heap_fsm.sv).
    // MSB-first per the ORDER packed struct in hw/sys_def.svh:
    //   [85] type, [84:69] price, [68:53] amount, [52:32] symbol, [31:0] ts.

    function automatic logic        order_type   (input logic [NODE_WIDTH-1:0] n);
        order_type = n[85];
    endfunction
    function automatic logic [15:0] order_amount (input logic [NODE_WIDTH-1:0] n);
        order_amount = n[68:53];
    endfunction
    function automatic logic [15:0] order_price  (input logic [NODE_WIDTH-1:0] n);
        order_price = n[84:69];
    endfunction
    function automatic logic [NODE_WIDTH-1:0] with_amount (
        input logic [NODE_WIDTH-1:0] n,
        input logic [15:0]           new_amt
    );
        with_amount = {n[85:69], new_amt, n[52:0]};
    endfunction

    // Per-heap virtual-tier buses (muxed onto the single MMU port below)

    logic                  bid_virt_req_valid, ask_virt_req_valid;
    logic [31:0]           bid_virt_req_va,    ask_virt_req_va;
    logic                  bid_virt_req_wr,    ask_virt_req_wr;
    logic [NODE_WIDTH-1:0] bid_virt_req_wdata, ask_virt_req_wdata;
    logic                  bid_virt_req_ready, ask_virt_req_ready;
    logic                  bid_virt_resp_valid,  ask_virt_resp_valid;
    logic [NODE_WIDTH-1:0] bid_virt_resp_data,   ask_virt_resp_data;
    logic                  bid_virt_resp_reject, ask_virt_resp_reject;

    // Per-heap private-tier buses

    logic                  bid_priv_we, bid_priv_re;
    logic [5:0]            bid_priv_addr;
    logic [NODE_WIDTH-1:0] bid_priv_wdata, bid_priv_rdata;
    logic                  ask_priv_we, ask_priv_re;
    logic [5:0]            ask_priv_addr;
    logic [NODE_WIDTH-1:0] ask_priv_wdata, ask_priv_rdata;

    // Per-heap command buses (driven by trade_ctrl)

    logic                  bid_cmd_valid, ask_cmd_valid;
    logic [1:0]            bid_cmd_op,    ask_cmd_op;
    logic [NODE_WIDTH-1:0] bid_cmd_data,  ask_cmd_data;
    logic                  bid_cmd_ready, ask_cmd_ready;
    logic                  bid_cmd_done,  ask_cmd_done;
    logic [NODE_WIDTH-1:0] bid_root,      ask_root;
    logic [13:0]           bid_size,      ask_size;

    // Heap FSMs

    heap_fsm #(
        .HEAP_KIND (0),       // MAX
        .ENGINE_ID (ENGINE_ID)
    ) u_bid (
        .clk             (clk),
        .rst_n           (rst_n),
        .cmd_valid       (bid_cmd_valid),
        .cmd_op          (bid_cmd_op),
        .cmd_data_in     (bid_cmd_data),
        .cmd_ready       (bid_cmd_ready),
        .cmd_done        (bid_cmd_done),
        .cmd_root_out    (bid_root),
        .size_out        (bid_size),
        .priv_we         (bid_priv_we),
        .priv_re         (bid_priv_re),
        .priv_addr       (bid_priv_addr),
        .priv_wdata      (bid_priv_wdata),
        .priv_rdata      (bid_priv_rdata),
        .virt_req_valid  (bid_virt_req_valid),
        .virt_req_va     (bid_virt_req_va),
        .virt_req_wr     (bid_virt_req_wr),
        .virt_req_wdata  (bid_virt_req_wdata),
        .virt_req_ready  (bid_virt_req_ready),
        .virt_resp_valid (bid_virt_resp_valid),
        .virt_resp_data  (bid_virt_resp_data),
        .virt_resp_reject(bid_virt_resp_reject)
    );

    heap_fsm #(
        .HEAP_KIND (1),       // MIN
        .ENGINE_ID (ENGINE_ID)
    ) u_ask (
        .clk             (clk),
        .rst_n           (rst_n),
        .cmd_valid       (ask_cmd_valid),
        .cmd_op          (ask_cmd_op),
        .cmd_data_in     (ask_cmd_data),
        .cmd_ready       (ask_cmd_ready),
        .cmd_done        (ask_cmd_done),
        .cmd_root_out    (ask_root),
        .size_out        (ask_size),
        .priv_we         (ask_priv_we),
        .priv_re         (ask_priv_re),
        .priv_addr       (ask_priv_addr),
        .priv_wdata      (ask_priv_wdata),
        .priv_rdata      (ask_priv_rdata),
        .virt_req_valid  (ask_virt_req_valid),
        .virt_req_va     (ask_virt_req_va),
        .virt_req_wr     (ask_virt_req_wr),
        .virt_req_wdata  (ask_virt_req_wdata),
        .virt_req_ready  (ask_virt_req_ready),
        .virt_resp_valid (ask_virt_resp_valid),
        .virt_resp_data  (ask_virt_resp_data),
        .virt_resp_reject(ask_virt_resp_reject)
    );

    // Shared private BRAM. The trade controller serializes bid and ask
    // access, so one port is enough. Address top bit selects the heap:
    // 0 for bid (lower 64 entries), 1 for ask (upper 64 entries).

    logic                  priv_we, priv_re;
    logic [6:0]            priv_addr;
    logic [NODE_WIDTH-1:0] priv_wdata;
    logic [NODE_WIDTH-1:0] priv_rdata;

    logic ask_active;
    assign ask_active = ask_priv_we | ask_priv_re;

    assign priv_we    = bid_priv_we | ask_priv_we;
    assign priv_re    = bid_priv_re | ask_priv_re;
    assign priv_addr  = ask_active ? {1'b1, ask_priv_addr}
                                   : {1'b0, bid_priv_addr};
    assign priv_wdata = ask_active ? ask_priv_wdata : bid_priv_wdata;

    assign bid_priv_rdata = priv_rdata;
    assign ask_priv_rdata = priv_rdata;

    priv_bram #(.WIDTH(NODE_WIDTH), .DEPTH(128)) u_priv (
        .clk   (clk),
        .we    (priv_we),
        .re    (priv_re),
        .addr  (priv_addr),
        .wdata (priv_wdata),
        .rdata (priv_rdata)
    );

    // MMU port mux (single-in-flight, fixed bid > ask priority)

    typedef enum logic [1:0] { MMU_IDLE, MMU_BID, MMU_ASK } mmu_owner_t;
    mmu_owner_t mmu_owner;

    logic bid_grant, ask_grant;
    assign bid_grant = (mmu_owner == MMU_IDLE) && bid_virt_req_valid;
    assign ask_grant = (mmu_owner == MMU_IDLE) && !bid_virt_req_valid
                                                && ask_virt_req_valid;

    always_comb begin
        mmu_req_valid = 1'b0;
        mmu_req_va    = '0;
        mmu_req_wr    = 1'b0;
        mmu_req_wdata = '0;
        unique case (mmu_owner)
            MMU_IDLE: begin
                if (bid_grant) begin
                    mmu_req_valid = bid_virt_req_valid;
                    mmu_req_va    = bid_virt_req_va;
                    mmu_req_wr    = bid_virt_req_wr;
                    mmu_req_wdata = bid_virt_req_wdata;
                end else if (ask_grant) begin
                    mmu_req_valid = ask_virt_req_valid;
                    mmu_req_va    = ask_virt_req_va;
                    mmu_req_wr    = ask_virt_req_wr;
                    mmu_req_wdata = ask_virt_req_wdata;
                end
            end
            default: ;
        endcase
    end

    assign bid_virt_req_ready = bid_grant && mmu_req_ready;
    assign ask_virt_req_ready = ask_grant && mmu_req_ready;

    assign bid_virt_resp_valid  = (mmu_owner == MMU_BID) && mmu_resp_valid;
    assign bid_virt_resp_reject = (mmu_owner == MMU_BID) && mmu_resp_reject;
    assign bid_virt_resp_data   = mmu_resp_data;
    assign ask_virt_resp_valid  = (mmu_owner == MMU_ASK) && mmu_resp_valid;
    assign ask_virt_resp_reject = (mmu_owner == MMU_ASK) && mmu_resp_reject;
    assign ask_virt_resp_data   = mmu_resp_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mmu_owner <= MMU_IDLE;
        else begin
            unique case (mmu_owner)
                MMU_IDLE: begin
                    if (bid_grant && mmu_req_ready)      mmu_owner <= MMU_BID;
                    else if (ask_grant && mmu_req_ready) mmu_owner <= MMU_ASK;
                end
                MMU_BID, MMU_ASK: begin
                    if (mmu_resp_valid || mmu_resp_reject) mmu_owner <= MMU_IDLE;
                end
                default: mmu_owner <= MMU_IDLE;
            endcase
        end
    end

    // Trade controller
    //
    // For each ingested order the FSM runs:
    //   1. latch the order
    //   2. push it into the bid or ask heap
    //   3. peek both roots
    //   4. decide:
    //        no trade               : back to idle
    //        exact match            : pop bid, pop ask, emit
    //        partial (bid > ask)    : pop ask, update bid, emit
    //        partial (ask > bid)    : pop bid, update ask, emit
    // After a trade emits, the FSM loops back to the peek phase if both
    // heaps remain non-empty (cascade trades).

    typedef enum logic [4:0] {
        T_IDLE,
        T_PUSH_ISSUE,        T_PUSH_WAIT,
        T_PEEK_BID_ISSUE,    T_PEEK_BID_WAIT,
        T_PEEK_ASK_ISSUE,    T_PEEK_ASK_WAIT,
        T_DECIDE,
        T_POP_BID_ISSUE,     T_POP_BID_WAIT,
        T_POP_ASK_ISSUE,     T_POP_ASK_WAIT,
        T_UPDATE_BID_ISSUE,  T_UPDATE_BID_WAIT,
        T_UPDATE_ASK_ISSUE,  T_UPDATE_ASK_WAIT,
        T_EMIT_TRADE
    } tstate_t;

    tstate_t                tstate, tn_state;
    logic [NODE_WIDTH-1:0]  pending_order;
    logic                   pending_is_ask;
    logic [NODE_WIDTH-1:0]  bid_root_snap, ask_root_snap;
    logic [NODE_WIDTH-1:0]  trade_event_data;
    logic                   trade_event_pending;

    // Latched trade decision. partial_bid_remains and partial_ask_remains
    // are gated by trade_match, which drops to 0 once one of the heaps
    // gets popped to empty. The post-pop branches use these latched
    // values instead so the update step still fires.
    logic                   latched_partial_bid, latched_partial_ask;

    localparam logic [1:0] OP_PUSH = 2'd0, OP_POP = 2'd1,
                           OP_PEEK = 2'd2, OP_UPDATE = 2'd3;

    // command-bus drivers (default 0; populated per-state)
    always_comb begin
        bid_cmd_valid = 1'b0; bid_cmd_op = OP_PEEK; bid_cmd_data = '0;
        ask_cmd_valid = 1'b0; ask_cmd_op = OP_PEEK; ask_cmd_data = '0;
        unique case (tstate)
            T_PUSH_ISSUE: begin
                if (pending_is_ask) begin
                    ask_cmd_valid = 1'b1; ask_cmd_op = OP_PUSH; ask_cmd_data = pending_order;
                end else begin
                    bid_cmd_valid = 1'b1; bid_cmd_op = OP_PUSH; bid_cmd_data = pending_order;
                end
            end
            T_PUSH_WAIT: begin
                if (pending_is_ask) ask_cmd_valid = 1'b1;
                else                bid_cmd_valid = 1'b1;
            end
            T_PEEK_BID_ISSUE, T_PEEK_BID_WAIT: begin
                bid_cmd_valid = 1'b1; bid_cmd_op = OP_PEEK;
            end
            T_PEEK_ASK_ISSUE, T_PEEK_ASK_WAIT: begin
                ask_cmd_valid = 1'b1; ask_cmd_op = OP_PEEK;
            end
            T_POP_BID_ISSUE, T_POP_BID_WAIT: begin
                bid_cmd_valid = 1'b1; bid_cmd_op = OP_POP;
            end
            T_POP_ASK_ISSUE, T_POP_ASK_WAIT: begin
                ask_cmd_valid = 1'b1; ask_cmd_op = OP_POP;
            end
            T_UPDATE_BID_ISSUE, T_UPDATE_BID_WAIT: begin
                bid_cmd_valid = 1'b1; bid_cmd_op = OP_UPDATE;
                bid_cmd_data  = with_amount(bid_root_snap,
                                  order_amount(bid_root_snap)
                                - order_amount(ask_root_snap));
            end
            T_UPDATE_ASK_ISSUE, T_UPDATE_ASK_WAIT: begin
                ask_cmd_valid = 1'b1; ask_cmd_op = OP_UPDATE;
                ask_cmd_data  = with_amount(ask_root_snap,
                                  order_amount(ask_root_snap)
                                - order_amount(bid_root_snap));
            end
            default: ;
        endcase
    end

    // trade decision (combinational on snapped roots)
    logic trade_match, partial_bid_remains, partial_ask_remains;
    assign trade_match         = (bid_size > 0) && (ask_size > 0)
                              && (order_price(bid_root_snap)
                                  >= order_price(ask_root_snap));
    assign partial_bid_remains = trade_match
                              && (order_amount(bid_root_snap)
                                  > order_amount(ask_root_snap));
    assign partial_ask_remains = trade_match
                              && (order_amount(ask_root_snap)
                                  > order_amount(bid_root_snap));

    // next-state logic
    always_comb begin
        tn_state = tstate;
        unique case (tstate)
            T_IDLE: if (order_in_valid) tn_state = T_PUSH_ISSUE;

            T_PUSH_ISSUE: tn_state = T_PUSH_WAIT;
            T_PUSH_WAIT:  if ((pending_is_ask && ask_cmd_done)
                           || (!pending_is_ask && bid_cmd_done)) begin
                if (bid_size > 0 && ask_size > 0) tn_state = T_PEEK_BID_ISSUE;
                else                              tn_state = T_IDLE;
            end

            T_PEEK_BID_ISSUE: tn_state = T_PEEK_BID_WAIT;
            T_PEEK_BID_WAIT:  if (bid_cmd_done) tn_state = T_PEEK_ASK_ISSUE;
            T_PEEK_ASK_ISSUE: tn_state = T_PEEK_ASK_WAIT;
            T_PEEK_ASK_WAIT:  if (ask_cmd_done) tn_state = T_DECIDE;

            T_DECIDE: begin
                if (!trade_match)             tn_state = T_IDLE;
                else if (partial_bid_remains) tn_state = T_POP_ASK_ISSUE;
                else if (partial_ask_remains) tn_state = T_POP_BID_ISSUE;
                else                          tn_state = T_POP_BID_ISSUE;
            end

            T_POP_BID_ISSUE: tn_state = T_POP_BID_WAIT;
            T_POP_BID_WAIT:  if (bid_cmd_done) begin
                if (latched_partial_ask) tn_state = T_UPDATE_ASK_ISSUE;
                else                     tn_state = T_POP_ASK_ISSUE;
            end
            T_POP_ASK_ISSUE: tn_state = T_POP_ASK_WAIT;
            T_POP_ASK_WAIT:  if (ask_cmd_done) begin
                if (latched_partial_bid) tn_state = T_UPDATE_BID_ISSUE;
                else                     tn_state = T_EMIT_TRADE;
            end
            T_UPDATE_BID_ISSUE: tn_state = T_UPDATE_BID_WAIT;
            T_UPDATE_BID_WAIT:  if (bid_cmd_done) tn_state = T_EMIT_TRADE;
            T_UPDATE_ASK_ISSUE: tn_state = T_UPDATE_ASK_WAIT;
            T_UPDATE_ASK_WAIT:  if (ask_cmd_done) tn_state = T_EMIT_TRADE;

            T_EMIT_TRADE: if (trade_out_ready) begin
                if (bid_size > 0 && ask_size > 0) tn_state = T_PEEK_BID_ISSUE;
                else                              tn_state = T_IDLE;
            end
            default: tn_state = T_IDLE;
        endcase
    end

    // sequential bookkeeping
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate              <= T_IDLE;
            pending_order       <= '0;
            pending_is_ask      <= 1'b0;
            bid_root_snap       <= '0;
            ask_root_snap       <= '0;
            trade_event_data    <= '0;
            trade_event_pending <= 1'b0;
            latched_partial_bid <= 1'b0;
            latched_partial_ask <= 1'b0;
        end else begin
            tstate <= tn_state;

            if (tstate == T_IDLE && order_in_valid) begin
                // Build the 86-bit in-heap node from the 32-bit dispatched
                // order plus a sampled timestamp and the engine's symbol.
                // MSB-first packing matches sys_def.svh's ORDER struct.
                pending_order <= {order_in_data[31],         // [85]    type
                                  order_in_data[30:15],      // [84:69] price
                                  1'b0, order_in_data[14:0], // [68:53] amount (zero-ext)
                                  SYMBOL,                    // [52:32] symbol
                                  now_ts};                   // [31:0]  timestamp
                pending_is_ask <= order_in_data[31];
            end
            if (tstate == T_PEEK_BID_WAIT && bid_cmd_done) bid_root_snap <= bid_root;
            if (tstate == T_PEEK_ASK_WAIT && ask_cmd_done) ask_root_snap <= ask_root;

            if (tstate == T_DECIDE && trade_match) begin
                trade_event_data <= with_amount(bid_root_snap,
                                       (order_amount(bid_root_snap)
                                        < order_amount(ask_root_snap))
                                       ? order_amount(bid_root_snap)
                                       : order_amount(ask_root_snap));
                trade_event_pending <= 1'b1;
                latched_partial_bid <= partial_bid_remains;
                latched_partial_ask <= partial_ask_remains;
            end
            if (tstate == T_EMIT_TRADE && trade_out_ready) begin
                trade_event_pending <= 1'b0;
            end
        end
    end

    // Outputs

    assign order_in_ready  = (tstate == T_IDLE);
    assign trade_out_valid = (tstate == T_EMIT_TRADE) && trade_event_pending;
    assign trade_out_data  = trade_event_data;
    assign bid_size_o      = bid_size;
    assign ask_size_o      = ask_size;

endmodule


// priv_bram - Single-port BRAM, DEPTH entries by WIDTH bits, one-cycle read latency

module priv_bram #(
    parameter int WIDTH = 86,
    parameter int DEPTH = 64
) (
    input  logic                     clk,
    input  logic                     we,
    input  logic                     re,
    input  logic [$clog2(DEPTH)-1:0] addr,
    input  logic [WIDTH-1:0]         wdata,
    output logic [WIDTH-1:0]         rdata
);
    (* ramstyle = "M10K" *)
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        if (re) rdata     <= mem[addr];
    end
endmodule
