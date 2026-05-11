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
    // 0 for bid (lower 32 entries), 1 for ask (upper 32 entries).
    // Total depth = 2 * PRIVATE_NODES = 64, fits in 1 M10K block.

    logic                  priv_we, priv_re;
    logic [5:0]            priv_addr;
    logic [NODE_WIDTH-1:0] priv_wdata;
    logic [NODE_WIDTH-1:0] priv_rdata;

    logic ask_active;
    assign ask_active = ask_priv_we | ask_priv_re;

    assign priv_we    = bid_priv_we | ask_priv_we;
    assign priv_re    = bid_priv_re | ask_priv_re;
    assign priv_addr  = ask_active ? {1'b1, ask_priv_addr[4:0]}
                                   : {1'b0, bid_priv_addr[4:0]};
    assign priv_wdata = ask_active ? ask_priv_wdata : bid_priv_wdata;

    assign bid_priv_rdata = priv_rdata;
    assign ask_priv_rdata = priv_rdata;

    priv_bram #(.WIDTH(NODE_WIDTH), .DEPTH(64)) u_priv (
        .clk   (clk),
        .we    (priv_we),
        .re    (priv_re),
        .addr  (priv_addr),
        .wdata (priv_wdata),
        .rdata (priv_rdata)
    );

    // MMU port mux (single-in-flight, fixed bid > ask priority)
    //
    // Replaces the original 3-state mmu_owner_t enum FSM with two flops:
    // mmu_busy (set/reset) tracks whether a transaction is in flight;
    // mmu_busy_is_ask records which heap owns the port (0 = bid, 1 = ask).
    // Two 1-bit flops do not form an enum-FSM pattern, so Quartus's SMP
    // state-machine processing pass should not engage cone analysis here.

    logic mmu_busy;
    logic mmu_busy_is_ask;

    logic bid_grant, ask_grant;
    assign bid_grant = !mmu_busy && bid_virt_req_valid;
    assign ask_grant = !mmu_busy && !bid_virt_req_valid && ask_virt_req_valid;

    assign mmu_req_valid = bid_grant ? bid_virt_req_valid
                         : ask_grant ? ask_virt_req_valid
                                     : 1'b0;
    assign mmu_req_va    = bid_grant ? bid_virt_req_va
                         : ask_grant ? ask_virt_req_va
                                     : '0;
    assign mmu_req_wr    = bid_grant ? bid_virt_req_wr
                         : ask_grant ? ask_virt_req_wr
                                     : 1'b0;
    assign mmu_req_wdata = bid_grant ? bid_virt_req_wdata
                         : ask_grant ? ask_virt_req_wdata
                                     : '0;

    assign bid_virt_req_ready = bid_grant && mmu_req_ready;
    assign ask_virt_req_ready = ask_grant && mmu_req_ready;

    assign bid_virt_resp_valid  = mmu_busy && !mmu_busy_is_ask && mmu_resp_valid;
    assign bid_virt_resp_reject = mmu_busy && !mmu_busy_is_ask && mmu_resp_reject;
    assign bid_virt_resp_data   = mmu_resp_data;
    assign ask_virt_resp_valid  = mmu_busy &&  mmu_busy_is_ask && mmu_resp_valid;
    assign ask_virt_resp_reject = mmu_busy &&  mmu_busy_is_ask && mmu_resp_reject;
    assign ask_virt_resp_data   = mmu_resp_data;

    wire mmu_grant_accept = (bid_grant || ask_grant) && mmu_req_ready;
    wire mmu_release      = mmu_busy && (mmu_resp_valid || mmu_resp_reject);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mmu_busy        <= 1'b0;
            mmu_busy_is_ask <= 1'b0;
        end else begin
            if (mmu_grant_accept) begin
                mmu_busy        <= 1'b1;
                mmu_busy_is_ask <= ask_grant;
            end else if (mmu_release) begin
                mmu_busy        <= 1'b0;
            end
        end
    end

    // Trade controller
    //
    // For each ingested order we run:
    //   1. latch the order
    //   2. push it into the bid or ask heap
    //   3. peek both roots
    //   4. decide:
    //        no trade               : back to idle
    //        exact match            : pop bid, pop ask, emit
    //        partial (bid > ask)    : pop ask, update bid, emit
    //        partial (ask > bid)    : pop bid, update ask, emit
    // After a trade emits, we loop back to the peek phase if both heaps
    // remain non-empty (cascade trades).
    //
    // Replaces the original 17-state tstate_t FSM with one 1-bit "pending"
    // flop per operation plus a 1-cycle "decide_armed" flop. The
    // start/done wire chain is purely combinational. No state register
    // with a multi-valued enum domain, so Quartus's SMP pass should not
    // run cone analysis here.

    logic [NODE_WIDTH-1:0] pending_order;
    logic                  pending_is_ask;
    logic [NODE_WIDTH-1:0] bid_root_snap, ask_root_snap;
    logic [NODE_WIDTH-1:0] trade_event_data;
    logic                  trade_event_pending;

    // Per-operation pending flops (set on start, cleared on done)
    logic push_pending;
    logic peek_bid_pending,    peek_ask_pending;
    logic decide_armed;
    logic pop_bid_pending,     pop_ask_pending;
    logic update_bid_pending,  update_ask_pending;
    logic emit_pending;

    // Mode latches (held from decide_pulse through emit_done)
    logic mode_partial_bid, mode_partial_ask;

    localparam logic [1:0] OP_PUSH = 2'd0, OP_POP = 2'd1,
                           OP_PEEK = 2'd2, OP_UPDATE = 2'd3;

    // Combinational decision (unchanged from original; on snapped roots)
    logic trade_match, dec_partial_bid, dec_partial_ask, dec_exact;
    assign trade_match     = (bid_size > 0) && (ask_size > 0)
                          && (order_price(bid_root_snap)
                              >= order_price(ask_root_snap));
    assign dec_partial_bid = trade_match
                          && (order_amount(bid_root_snap)
                              >  order_amount(ask_root_snap));
    assign dec_partial_ask = trade_match
                          && (order_amount(ask_root_snap)
                              >  order_amount(bid_root_snap));
    assign dec_exact       = trade_match
                          && (order_amount(bid_root_snap)
                              == order_amount(ask_root_snap));

    // Done wires (per-operation cmd_done observation)
    wire push_done       = push_pending
                        && (pending_is_ask ? ask_cmd_done : bid_cmd_done);
    wire peek_bid_done   = peek_bid_pending   && bid_cmd_done;
    wire peek_ask_done   = peek_ask_pending   && ask_cmd_done;
    wire pop_bid_done    = pop_bid_pending    && bid_cmd_done;
    wire pop_ask_done    = pop_ask_pending    && ask_cmd_done;
    wire update_bid_done = update_bid_pending && bid_cmd_done;
    wire update_ask_done = update_ask_pending && ask_cmd_done;
    wire emit_done       = emit_pending       && trade_out_ready;

    // decide_pulse: high for one cycle, equivalent to the original T_DECIDE
    wire decide_pulse = decide_armed;

    // any_pending: high while any operation is outstanding. Drives
    // order_in_ready externally; no internal feedback on push_start.
    wire any_pending = push_pending     | peek_bid_pending | peek_ask_pending
                     | decide_armed
                     | pop_bid_pending  | pop_ask_pending
                     | update_bid_pending | update_ask_pending
                     | emit_pending;

    // Start wires (combinational)
    wire push_start       = order_in_valid && !any_pending;
    wire peek_bid_start   = (push_done || emit_done)
                         && (bid_size > 0) && (ask_size > 0);
    wire peek_ask_start   = peek_bid_done;
    wire pop_bid_start    = decide_pulse && (dec_partial_ask || dec_exact);
    wire pop_ask_start    = (decide_pulse && dec_partial_bid)
                         || (pop_bid_done && !mode_partial_ask);
    wire update_bid_start = pop_ask_done && mode_partial_bid;
    wire update_ask_start = pop_bid_done && mode_partial_ask;
    wire emit_start       = (pop_ask_done && !mode_partial_bid)
                         || update_bid_done || update_ask_done;

    // Command-bus drivers (combinational; mutex per heap by construction)
    always_comb begin
        bid_cmd_valid = 1'b0; bid_cmd_op = OP_PEEK; bid_cmd_data = '0;
        ask_cmd_valid = 1'b0; ask_cmd_op = OP_PEEK; ask_cmd_data = '0;

        if (push_pending && !pending_is_ask) begin
            bid_cmd_valid = 1'b1; bid_cmd_op = OP_PUSH; bid_cmd_data = pending_order;
        end else if (peek_bid_pending) begin
            bid_cmd_valid = 1'b1; bid_cmd_op = OP_PEEK;
        end else if (pop_bid_pending) begin
            bid_cmd_valid = 1'b1; bid_cmd_op = OP_POP;
        end else if (update_bid_pending) begin
            bid_cmd_valid = 1'b1; bid_cmd_op = OP_UPDATE;
            bid_cmd_data  = with_amount(bid_root_snap,
                              order_amount(bid_root_snap)
                            - order_amount(ask_root_snap));
        end

        if (push_pending && pending_is_ask) begin
            ask_cmd_valid = 1'b1; ask_cmd_op = OP_PUSH; ask_cmd_data = pending_order;
        end else if (peek_ask_pending) begin
            ask_cmd_valid = 1'b1; ask_cmd_op = OP_PEEK;
        end else if (pop_ask_pending) begin
            ask_cmd_valid = 1'b1; ask_cmd_op = OP_POP;
        end else if (update_ask_pending) begin
            ask_cmd_valid = 1'b1; ask_cmd_op = OP_UPDATE;
            ask_cmd_data  = with_amount(ask_root_snap,
                              order_amount(ask_root_snap)
                            - order_amount(bid_root_snap));
        end
    end

    // Sequential bookkeeping
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            push_pending        <= 1'b0;
            peek_bid_pending    <= 1'b0;
            peek_ask_pending    <= 1'b0;
            decide_armed        <= 1'b0;
            pop_bid_pending     <= 1'b0;
            pop_ask_pending     <= 1'b0;
            update_bid_pending  <= 1'b0;
            update_ask_pending  <= 1'b0;
            emit_pending        <= 1'b0;
            mode_partial_bid    <= 1'b0;
            mode_partial_ask    <= 1'b0;
            pending_order       <= '0;
            pending_is_ask      <= 1'b0;
            bid_root_snap       <= '0;
            ask_root_snap       <= '0;
            trade_event_data    <= '0;
            trade_event_pending <= 1'b0;
        end else begin
            // Per-operation pending flops: set on *_start, cleared on *_done.
            if      (push_start)       push_pending       <= 1'b1;
            else if (push_done)        push_pending       <= 1'b0;

            if      (peek_bid_start)   peek_bid_pending   <= 1'b1;
            else if (peek_bid_done)    peek_bid_pending   <= 1'b0;

            if      (peek_ask_start)   peek_ask_pending   <= 1'b1;
            else if (peek_ask_done)    peek_ask_pending   <= 1'b0;

            // decide_armed mirrors the original T_DECIDE cycle: it latches
            // peek_ask_done for exactly one cycle.
            decide_armed <= peek_ask_done;

            if      (pop_bid_start)    pop_bid_pending    <= 1'b1;
            else if (pop_bid_done)     pop_bid_pending    <= 1'b0;

            if      (pop_ask_start)    pop_ask_pending    <= 1'b1;
            else if (pop_ask_done)     pop_ask_pending    <= 1'b0;

            if      (update_bid_start) update_bid_pending <= 1'b1;
            else if (update_bid_done)  update_bid_pending <= 1'b0;

            if      (update_ask_start) update_ask_pending <= 1'b1;
            else if (update_ask_done)  update_ask_pending <= 1'b0;

            if      (emit_start)       emit_pending       <= 1'b1;
            else if (emit_done)        emit_pending       <= 1'b0;

            // Mode latches: written on decide_pulse, cleared on emit_done.
            // mode_partial_bid means "bid amount > ask amount" - pop ask, update bid.
            // mode_partial_ask means "ask amount > bid amount" - pop bid, update ask.
            if (decide_pulse) begin
                mode_partial_bid <= dec_partial_bid;
                mode_partial_ask <= dec_partial_ask;
            end else if (emit_done) begin
                mode_partial_bid <= 1'b0;
                mode_partial_ask <= 1'b0;
            end

            // Data latches.
            if (push_start) begin
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

            if (peek_bid_done) bid_root_snap <= bid_root;
            if (peek_ask_done) ask_root_snap <= ask_root;

            if (decide_pulse && trade_match) begin
                trade_event_data <= with_amount(bid_root_snap,
                                       (order_amount(bid_root_snap)
                                        < order_amount(ask_root_snap))
                                       ? order_amount(bid_root_snap)
                                       : order_amount(ask_root_snap));
                trade_event_pending <= 1'b1;
            end
            if (emit_done) trade_event_pending <= 1'b0;
        end
    end

    // Outputs
    assign order_in_ready  = !any_pending;
    assign trade_out_valid = emit_pending && trade_event_pending;
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
    logic [WIDTH-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        if (re) rdata     <= mem[addr];
    end
endmodule
