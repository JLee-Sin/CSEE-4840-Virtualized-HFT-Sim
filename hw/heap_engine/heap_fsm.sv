// heap_fsm.sv - Single-heap FSM with tiered storage
//
// Drives one priority-ordered heap (max or min) for one symbol slot.
// Used in pairs by symbol_engine: a max-heap for bids, a min-heap for asks.
//
// Storage tier:
//   Indices [0 .. PRIVATE_NODES-1] live in a single-cycle private BRAM
//   accessed directly through the priv_* port group. Indices
//   [PRIVATE_NODES .. MAX_NODES-1] live in MMU-mediated virtual memory
//   accessed through the virt_* port group, which the parent module
//   multiplexes onto its MMU client port. ENGINE_ID is hard-wired into
//   VA[31:29] per the engine/MMU contract.
//
// Operations (cmd_op):
//   OP_PUSH    Insert cmd_data_in at the next leaf and sift up.
//   OP_POP     Extract the root, replace it with the last leaf, sift down.
//              The extracted root is presented on cmd_root_out.
//   OP_PEEK    Return the root on cmd_root_out (uses an internal cache).
//   OP_UPDATE  Overwrite the root with cmd_data_in. The caller is
//              responsible for preserving heap order (price + timestamp
//              unchanged); used for partial-fill amount edits.
//
//
// Command handshake: cmd_valid is held by the caller until cmd_done is
// observed. cmd_ready is high only while the FSM is in S_IDLE.

module heap_fsm #(
    parameter int  HEAP_KIND     = 0,        // 0 = MAX-heap (bids)
                                             // 1 = MIN-heap (asks)
    parameter int  ENGINE_ID     = 0,        // 0..7, drives VA[31:29]
    parameter int  NODE_WIDTH    = 86,
    parameter int  PRIVATE_NODES = 64,       // size of the private BRAM tier
    parameter int  MAX_NODES     = 1088,     // 64 private + 1024 virtual; 1024 cap
                                             // is set by the MMU's pt_key width
    parameter int  IDX_WIDTH     = $clog2(MAX_NODES + 1)
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // command interface (from the per-symbol trade controller)
    input  logic                  cmd_valid,
    input  logic [1:0]            cmd_op,
    input  logic [NODE_WIDTH-1:0] cmd_data_in,
    output logic                  cmd_ready,
    output logic                  cmd_done,
    output logic [NODE_WIDTH-1:0] cmd_root_out,
    output logic [IDX_WIDTH-1:0]  size_out,

    // private memory tier (single-cycle BRAM)
    output logic                  priv_we,
    output logic                  priv_re,
    output logic [5:0]            priv_addr,
    output logic [NODE_WIDTH-1:0] priv_wdata,
    input  logic [NODE_WIDTH-1:0] priv_rdata,

    // virtual memory tier (engine's MMU client port)
    output logic                  virt_req_valid,
    output logic [31:0]           virt_req_va,
    output logic                  virt_req_wr,
    output logic [NODE_WIDTH-1:0] virt_req_wdata,
    input  logic                  virt_req_ready,
    input  logic                  virt_resp_valid,
    input  logic [NODE_WIDTH-1:0] virt_resp_data,
    input  logic                  virt_resp_reject
);

    // Op-code constants and heap-kind aliases

    localparam int MAX_HEAP = 0;
    localparam int MIN_HEAP = 1;

    localparam logic [1:0] OP_PUSH   = 2'd0;
    localparam logic [1:0] OP_POP    = 2'd1;
    localparam logic [1:0] OP_PEEK   = 2'd2;
    localparam logic [1:0] OP_UPDATE = 2'd3;

    // Node-field layout inside the 86-bit payload (MSB-first, matches the
    // ORDER packed struct in hw/sys_def.svh):
    //   [85]     type
    //   [84:69]  price
    //   [68:53]  amount
    //   [52:32]  symbol  (3 x 7-bit ASCII)
    //   [31:0]   timestamp
    //
    // Per-register field wires are declared after the working registers
    // below. Keeping the bit selects in continuous-assign land prevents
    // simulators that don't optimize constant selects inside always_*
    // blocks from blowing up the comparator into 86-bit-wide compares.

    // Comparator (operates on pre-extracted fields). Returns 1 iff the
    // operand identified by the "a" fields should sit closer to the root
    // than the "b" operand. Ordering: price (max or min per HEAP_KIND),
    // older timestamp, larger amount.

    function automatic logic a_wins_fields (
        input logic [15:0] ap, input logic [31:0] at, input logic [15:0] aa,
        input logic [15:0] bp, input logic [31:0] bt, input logic [15:0] ba
    );
        if (ap != bp)
            a_wins_fields = (HEAP_KIND == MAX_HEAP) ? (ap > bp) : (ap < bp);
        else if (at != bt)
            // signed difference handles the 32-bit timestamp wrap correctly
            a_wins_fields = ($signed(at - bt) < 0);
        else
            a_wins_fields = (aa > ba);
    endfunction

    // Virtual-address construction
    //
    // VA layout:
    //   [31:29]  engine_id     (hard-wired, used by MMU for routing)
    //   [28:11]  reserved / zero (ignored by MMU)
    //   [10]     heap_kind     (0 = bid, 1 = ask)
    //   [9:0]    heap-relative virtual node index (idx - PRIVATE_NODES)
    //
    // The MMU's page table is keyed on {va[31:29], va[10:0]}, so heap_kind
    // must live in the low 11 bits to keep bid and ask separate.

    function automatic logic [31:0] make_va (input logic [IDX_WIDTH-1:0] idx);
        logic [9:0] virt_idx;
        virt_idx = idx - PRIVATE_NODES;
        make_va = {ENGINE_ID[2:0], 18'd0, HEAP_KIND[0], virt_idx};
    endfunction

    function automatic logic is_private (input logic [IDX_WIDTH-1:0] idx);
        is_private = (idx < PRIVATE_NODES);
    endfunction

    // State enumeration

    typedef enum logic [4:0] {
        S_IDLE,
        // PUSH (sift up)
        S_PUSH_LAUNCH,
        S_PUSH_RD_PARENT_ISSUE,
        S_PUSH_RD_PARENT_WAIT,
        S_PUSH_DECIDE,
        S_PUSH_WR_DOWN_ISSUE,
        S_PUSH_WR_DOWN_WAIT,
        S_PUSH_WR_FINAL_ISSUE,
        S_PUSH_WR_FINAL_WAIT,
        // POP (extract root + sift down)
        S_POP_LAUNCH,
        S_POP_RD_ROOT_ISSUE,
        S_POP_RD_ROOT_WAIT,
        S_POP_RD_LAST_ISSUE,
        S_POP_RD_LAST_WAIT,
        S_POP_SIFT_RD_LEFT_ISSUE,
        S_POP_SIFT_RD_LEFT_WAIT,
        S_POP_SIFT_RD_RIGHT_ISSUE,
        S_POP_SIFT_RD_RIGHT_WAIT,
        S_POP_SIFT_DECIDE,
        S_POP_SIFT_WR_UP_ISSUE,
        S_POP_SIFT_WR_UP_WAIT,
        S_POP_SIFT_WR_FINAL_ISSUE,
        S_POP_SIFT_WR_FINAL_WAIT,
        // PEEK
        S_PEEK_RD_ISSUE,
        S_PEEK_RD_WAIT,
        // UPDATE
        S_UPDATE_WR_ISSUE,
        S_UPDATE_WR_WAIT,
        // common terminator
        S_DONE
    } state_t;

    state_t state, n_state;

    // Working registers

    logic [IDX_WIDTH-1:0]  size;
    logic [IDX_WIDTH-1:0]  target_idx;     // current "hole" being filled
    logic [IDX_WIDTH-1:0]  parent_idx;     // (target_idx-1) >> 1 cache
    logic [IDX_WIDTH-1:0]  left_idx, right_idx;
    logic [NODE_WIDTH-1:0] cur_node;       // node being placed
    logic [NODE_WIDTH-1:0] parent_node;    // last parent read (push)
    logic [NODE_WIDTH-1:0] left_node, right_node;
    logic                  has_right;

    logic [NODE_WIDTH-1:0] root_cache;
    logic                  root_cache_valid;

    logic [NODE_WIDTH-1:0] saved_op_data;
    logic [1:0]            saved_op;
    logic [NODE_WIDTH-1:0] popped_root;

    // Pre-extracted field wires and comparator outputs. Continuous assigns
    // keep the constant bit selects out of the always_* blocks below.

    wire [15:0] cur_price     = cur_node[84:69];
    wire [15:0] cur_amount    = cur_node[68:53];
    wire [31:0] cur_ts        = cur_node[31:0];
    wire [15:0] parent_price  = parent_node[84:69];
    wire [15:0] parent_amount = parent_node[68:53];
    wire [31:0] parent_ts     = parent_node[31:0];
    wire [15:0] left_price    = left_node[84:69];
    wire [15:0] left_amount   = left_node[68:53];
    wire [31:0] left_ts       = left_node[31:0];
    wire [15:0] right_price   = right_node[84:69];
    wire [15:0] right_amount  = right_node[68:53];
    wire [31:0] right_ts      = right_node[31:0];

    wire cur_wins_parent = a_wins_fields(cur_price,    cur_ts,    cur_amount,
                                         parent_price, parent_ts, parent_amount);
    wire left_wins_cur   = a_wins_fields(left_price,   left_ts,   left_amount,
                                         cur_price,    cur_ts,    cur_amount);
    wire right_wins_left = a_wins_fields(right_price,  right_ts,  right_amount,
                                         left_price,   left_ts,   left_amount);
    wire right_wins_cur  = a_wins_fields(right_price,  right_ts,  right_amount,
                                         cur_price,    cur_ts,    cur_amount);

    // UPDATE guard: the new node must preserve the root's price + timestamp
    // (heap order is established by those two fields). Mismatch => reject.
    wire [15:0] root_cache_price = root_cache[84:69];
    wire [31:0] root_cache_ts    = root_cache[31:0];
    wire [15:0] cmd_in_price     = cmd_data_in[84:69];
    wire [31:0] cmd_in_ts        = cmd_data_in[31:0];
    wire        update_keys_ok   = (cmd_in_price == root_cache_price)
                                && (cmd_in_ts    == root_cache_ts);

    // Sift-down child selector (combinational)

    typedef enum logic [1:0] { BEST_CUR, BEST_LEFT, BEST_RIGHT } best_t;
    best_t best;
    always_comb begin
        best = BEST_CUR;
        if (left_idx < size && left_wins_cur)
            best = BEST_LEFT;
        if (has_right && right_idx < size) begin
            // right against whichever of {left, cur} is currently best
            if ((best == BEST_LEFT) ? right_wins_left : right_wins_cur)
                best = BEST_RIGHT;
        end
    end

    // Memory-issue decode (combinational)
    //
    // Each ISSUE state contributes a {do_read, do_write, idx, wdata} bundle.
    // This block centralizes the bundle and routes it to either the private
    // or the virtual interface based on idx.

    logic                  mem_do_read;
    logic                  mem_do_write;
    logic [IDX_WIDTH-1:0]  mem_idx;
    logic [NODE_WIDTH-1:0] mem_wdata;

    always_comb begin
        mem_do_read  = 1'b0;
        mem_do_write = 1'b0;
        mem_idx      = '0;
        mem_wdata    = '0;
        unique case (state)
            S_PUSH_RD_PARENT_ISSUE:    begin mem_do_read  = 1'b1; mem_idx = parent_idx; end
            S_PUSH_WR_DOWN_ISSUE:      begin mem_do_write = 1'b1; mem_idx = target_idx; mem_wdata = parent_node; end
            S_PUSH_WR_FINAL_ISSUE:     begin mem_do_write = 1'b1; mem_idx = target_idx; mem_wdata = cur_node;    end
            S_POP_RD_ROOT_ISSUE:       begin mem_do_read  = 1'b1; mem_idx = '0;          end
            S_POP_RD_LAST_ISSUE:       begin mem_do_read  = 1'b1; mem_idx = size - 1'b1; end
            S_POP_SIFT_RD_LEFT_ISSUE:  begin mem_do_read  = 1'b1; mem_idx = left_idx;    end
            S_POP_SIFT_RD_RIGHT_ISSUE: begin mem_do_read  = 1'b1; mem_idx = right_idx;   end
            S_POP_SIFT_WR_UP_ISSUE:    begin mem_do_write = 1'b1; mem_idx = target_idx;
                mem_wdata = (best == BEST_LEFT) ? left_node : right_node;
            end
            S_POP_SIFT_WR_FINAL_ISSUE: begin mem_do_write = 1'b1; mem_idx = target_idx; mem_wdata = cur_node; end
            S_PEEK_RD_ISSUE:           begin mem_do_read  = 1'b1; mem_idx = '0; end
            S_UPDATE_WR_ISSUE:         begin mem_do_write = 1'b1; mem_idx = '0; mem_wdata = saved_op_data; end
            default: ;
        endcase
    end

    logic mem_target_priv;
    assign mem_target_priv = is_private(mem_idx);

    // private interface drivers
    assign priv_re    = (mem_do_read  && mem_target_priv);
    assign priv_we    = (mem_do_write && mem_target_priv);
    assign priv_addr  = mem_idx[5:0];
    assign priv_wdata = mem_wdata;

    // virtual interface drivers
    assign virt_req_valid = (mem_do_read || mem_do_write) && !mem_target_priv;
    assign virt_req_wr    = mem_do_write && !mem_target_priv;
    assign virt_req_va    = make_va(mem_idx);
    assign virt_req_wdata = mem_wdata;

    // WAIT-state completion signals
    //
    // Private read:  one-cycle latency, tracked by a one-cycle delay flop.
    // Private write: one-cycle latency, tracked the same way.
    // Virtual read:  completes on virt_resp_valid.
    // Virtual write: completes on virt_resp_valid (the MMU pulses resp_valid
    //                for both reads and writes; for writes resp_data is 0).
    // virt_retry:    one-cycle pulse asserted when the MMU rejects the
    //                request; the FSM falls back to the matching ISSUE
    //                state to retry on the next cycle.

    logic priv_read_done;
    logic priv_write_done;
    logic virt_read_done;
    logic virt_write_done;
    logic virt_retry;

    logic priv_re_d1, priv_we_d1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            priv_re_d1 <= 1'b0;
            priv_we_d1 <= 1'b0;
        end else begin
            priv_re_d1 <= priv_re;
            priv_we_d1 <= priv_we;
        end
    end
    assign priv_read_done  = priv_re_d1;
    assign priv_write_done = priv_we_d1;
    assign virt_read_done  = virt_resp_valid;
    assign virt_write_done = virt_resp_valid;
    assign virt_retry      = virt_resp_reject;

    // Next-state logic

    always_comb begin
        n_state = state;
        unique case (state)
            // IDLE
            S_IDLE: begin
                if (cmd_valid) begin
                    unique case (cmd_op)
                        OP_PUSH:   n_state = S_PUSH_LAUNCH;
                        OP_POP:    n_state = S_POP_LAUNCH;
                        OP_PEEK:   begin
                            if (root_cache_valid) n_state = S_DONE;
                            else                  n_state = S_PEEK_RD_ISSUE;
                        end
                        OP_UPDATE: begin
                            // Reject if root cache is cold or the new node's
                            // price/timestamp don't match the current root.
                            if (root_cache_valid && update_keys_ok) n_state = S_UPDATE_WR_ISSUE;
                            else                                    n_state = S_DONE;
                        end
                        default:   n_state = S_DONE;
                    endcase
                end
            end

            // PUSH
            S_PUSH_LAUNCH: begin
                if (size == 0) n_state = S_PUSH_WR_FINAL_ISSUE;
                else           n_state = S_PUSH_RD_PARENT_ISSUE;
            end
            S_PUSH_RD_PARENT_ISSUE: begin
                if (mem_target_priv)         n_state = S_PUSH_RD_PARENT_WAIT;
                else if (virt_req_ready)     n_state = S_PUSH_RD_PARENT_WAIT;
            end
            S_PUSH_RD_PARENT_WAIT: begin
                if (priv_read_done || virt_read_done) n_state = S_PUSH_DECIDE;
                else if (virt_retry)                  n_state = S_PUSH_RD_PARENT_ISSUE;
            end
            S_PUSH_DECIDE: begin
                if (cur_wins_parent) n_state = S_PUSH_WR_DOWN_ISSUE;
                else                 n_state = S_PUSH_WR_FINAL_ISSUE;
            end
            S_PUSH_WR_DOWN_ISSUE: begin
                if (mem_target_priv)         n_state = S_PUSH_WR_DOWN_WAIT;
                else if (virt_req_ready)     n_state = S_PUSH_WR_DOWN_WAIT;
            end
            S_PUSH_WR_DOWN_WAIT: begin
                if (priv_write_done || virt_write_done) begin
                    if (parent_idx == 0) n_state = S_PUSH_WR_FINAL_ISSUE;
                    else                 n_state = S_PUSH_RD_PARENT_ISSUE;
                end else if (virt_retry) begin
                    n_state = S_PUSH_WR_DOWN_ISSUE;
                end
            end
            S_PUSH_WR_FINAL_ISSUE: begin
                if (mem_target_priv)         n_state = S_PUSH_WR_FINAL_WAIT;
                else if (virt_req_ready)     n_state = S_PUSH_WR_FINAL_WAIT;
            end
            S_PUSH_WR_FINAL_WAIT: begin
                if (priv_write_done || virt_write_done) n_state = S_DONE;
                else if (virt_retry) n_state = S_PUSH_WR_FINAL_ISSUE;
            end

            // POP
            S_POP_LAUNCH: begin
                if (size == 0)              n_state = S_DONE;
                else if (root_cache_valid) begin
                    if (size == 1) n_state = S_DONE;
                    else           n_state = S_POP_RD_LAST_ISSUE;
                end
                else                        n_state = S_POP_RD_ROOT_ISSUE;
            end
            S_POP_RD_ROOT_ISSUE: begin
                if (mem_target_priv)         n_state = S_POP_RD_ROOT_WAIT;
                else if (virt_req_ready)     n_state = S_POP_RD_ROOT_WAIT;
            end
            S_POP_RD_ROOT_WAIT: begin
                if (priv_read_done || virt_read_done) begin
                    if (size == 1) n_state = S_DONE;
                    else           n_state = S_POP_RD_LAST_ISSUE;
                end else if (virt_retry) n_state = S_POP_RD_ROOT_ISSUE;
            end
            S_POP_RD_LAST_ISSUE: begin
                if (mem_target_priv)         n_state = S_POP_RD_LAST_WAIT;
                else if (virt_req_ready)     n_state = S_POP_RD_LAST_WAIT;
            end
            S_POP_RD_LAST_WAIT: begin
                if (priv_read_done || virt_read_done)
                    n_state = S_POP_SIFT_RD_LEFT_ISSUE;
                else if (virt_retry) n_state = S_POP_RD_LAST_ISSUE;
            end
            S_POP_SIFT_RD_LEFT_ISSUE: begin
                if (left_idx >= size)        n_state = S_POP_SIFT_WR_FINAL_ISSUE;
                else if (mem_target_priv)    n_state = S_POP_SIFT_RD_LEFT_WAIT;
                else if (virt_req_ready)     n_state = S_POP_SIFT_RD_LEFT_WAIT;
            end
            S_POP_SIFT_RD_LEFT_WAIT: begin
                if (priv_read_done || virt_read_done) n_state = S_POP_SIFT_RD_RIGHT_ISSUE;
                else if (virt_retry) n_state = S_POP_SIFT_RD_LEFT_ISSUE;
            end
            S_POP_SIFT_RD_RIGHT_ISSUE: begin
                if (right_idx >= size)       n_state = S_POP_SIFT_DECIDE;
                else if (mem_target_priv)    n_state = S_POP_SIFT_RD_RIGHT_WAIT;
                else if (virt_req_ready)     n_state = S_POP_SIFT_RD_RIGHT_WAIT;
            end
            S_POP_SIFT_RD_RIGHT_WAIT: begin
                if (priv_read_done || virt_read_done) n_state = S_POP_SIFT_DECIDE;
                else if (virt_retry) n_state = S_POP_SIFT_RD_RIGHT_ISSUE;
            end
            S_POP_SIFT_DECIDE: begin
                if (best == BEST_CUR) n_state = S_POP_SIFT_WR_FINAL_ISSUE;
                else                  n_state = S_POP_SIFT_WR_UP_ISSUE;
            end
            S_POP_SIFT_WR_UP_ISSUE: begin
                if (mem_target_priv)         n_state = S_POP_SIFT_WR_UP_WAIT;
                else if (virt_req_ready)     n_state = S_POP_SIFT_WR_UP_WAIT;
            end
            S_POP_SIFT_WR_UP_WAIT: begin
                if (priv_write_done || virt_write_done) n_state = S_POP_SIFT_RD_LEFT_ISSUE;
                else if (virt_retry) n_state = S_POP_SIFT_WR_UP_ISSUE;
            end
            S_POP_SIFT_WR_FINAL_ISSUE: begin
                if (mem_target_priv)         n_state = S_POP_SIFT_WR_FINAL_WAIT;
                else if (virt_req_ready)     n_state = S_POP_SIFT_WR_FINAL_WAIT;
            end
            S_POP_SIFT_WR_FINAL_WAIT: begin
                if (priv_write_done || virt_write_done) n_state = S_DONE;
                else if (virt_retry) n_state = S_POP_SIFT_WR_FINAL_ISSUE;
            end

            // PEEK
            S_PEEK_RD_ISSUE: begin
                if (mem_target_priv)         n_state = S_PEEK_RD_WAIT;
                else if (virt_req_ready)     n_state = S_PEEK_RD_WAIT;
            end
            S_PEEK_RD_WAIT: begin
                if (priv_read_done || virt_read_done) n_state = S_DONE;
                else if (virt_retry) n_state = S_PEEK_RD_ISSUE;
            end

            // UPDATE
            S_UPDATE_WR_ISSUE: begin
                if (mem_target_priv)         n_state = S_UPDATE_WR_WAIT;
                else if (virt_req_ready)     n_state = S_UPDATE_WR_WAIT;
            end
            S_UPDATE_WR_WAIT: begin
                if (priv_write_done || virt_write_done) n_state = S_DONE;
                else if (virt_retry) n_state = S_UPDATE_WR_ISSUE;
            end

            // DONE
            S_DONE: n_state = S_IDLE;

            default: n_state = S_IDLE;
        endcase
    end

    // Sequential state and register updates

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            size             <= '0;
            target_idx       <= '0;
            parent_idx       <= '0;
            left_idx         <= '0;
            right_idx        <= '0;
            has_right        <= 1'b0;
            cur_node         <= '0;
            parent_node      <= '0;
            left_node        <= '0;
            right_node       <= '0;
            saved_op_data    <= '0;
            saved_op         <= 2'd0;
            popped_root      <= '0;
            root_cache       <= '0;
            root_cache_valid <= 1'b0;
        end else begin
            state <= n_state;

            unique case (state)
                S_IDLE: if (cmd_valid) begin
                    saved_op      <= cmd_op;
                    saved_op_data <= cmd_data_in;
                    if (cmd_op == OP_PUSH) begin
                        cur_node   <= cmd_data_in;
                        target_idx <= size;
                        parent_idx <= (size == 0) ? '0 : (size - 1) >> 1;
                    end
                    if (cmd_op == OP_POP) begin
                        target_idx <= '0;
                        if (root_cache_valid) popped_root <= root_cache;
                    end
                end

                // PUSH bookkeeping
                S_PUSH_RD_PARENT_WAIT: begin
                    if (priv_read_done || virt_read_done) begin
                        if (priv_read_done) parent_node <= priv_rdata;
                        else                parent_node <= virt_resp_data;
                    end
                end
                S_PUSH_WR_DOWN_WAIT: if (priv_write_done || virt_write_done) begin
                    target_idx <= parent_idx;
                    parent_idx <= (parent_idx == 0) ? '0 : (parent_idx - 1) >> 1;
                end
                S_PUSH_WR_FINAL_WAIT: if (priv_write_done || virt_write_done) begin
                    size <= size + 1'b1;
                    if (target_idx == 0) begin
                        root_cache       <= cur_node;
                        root_cache_valid <= 1'b1;
                    end
                end

                // POP bookkeeping
                S_POP_LAUNCH: begin
                    // size=1 with cached root jumps straight to S_DONE.
                    // Do the cleanup that S_POP_RD_LAST_WAIT would have done.
                    if (size == 1 && root_cache_valid) begin
                        size             <= '0;
                        root_cache_valid <= 1'b0;
                    end
                end
                S_POP_RD_ROOT_WAIT: begin
                    if (priv_read_done || virt_read_done) begin
                        if (priv_read_done) popped_root <= priv_rdata;
                        else                popped_root <= virt_resp_data;
                        // size=1 uncached jumps to S_DONE after the root read.
                        if (size == 1) begin
                            size             <= '0;
                            root_cache_valid <= 1'b0;
                        end
                    end
                end
                S_POP_RD_LAST_WAIT: begin
                    if (priv_read_done || virt_read_done) begin
                        if (priv_read_done) cur_node <= priv_rdata;
                        else                cur_node <= virt_resp_data;
                        target_idx       <= '0;
                        left_idx         <= 1;
                        right_idx        <= 2;
                        size             <= size - 1'b1;
                        root_cache_valid <= 1'b0;
                    end
                end
                S_POP_SIFT_RD_LEFT_WAIT: begin
                    if (priv_read_done || virt_read_done) begin
                        if (priv_read_done) left_node <= priv_rdata;
                        else                left_node <= virt_resp_data;
                    end
                end
                S_POP_SIFT_RD_RIGHT_WAIT: begin
                    if (priv_read_done || virt_read_done) begin
                        if (priv_read_done) right_node <= priv_rdata;
                        else                right_node <= virt_resp_data;
                        has_right <= 1'b1;
                    end
                end
                S_POP_SIFT_RD_RIGHT_ISSUE: begin
                    if (right_idx >= size) has_right <= 1'b0;
                end
                S_POP_SIFT_WR_UP_WAIT: if (priv_write_done || virt_write_done) begin
                    if (best == BEST_LEFT) begin
                        target_idx <= left_idx;
                        left_idx   <= (left_idx  << 1) + 1'b1;
                        right_idx  <= (left_idx  << 1) + 2'd2;
                    end else begin
                        target_idx <= right_idx;
                        left_idx   <= (right_idx << 1) + 1'b1;
                        right_idx  <= (right_idx << 1) + 2'd2;
                    end
                end
                S_POP_SIFT_WR_FINAL_WAIT: if (priv_write_done || virt_write_done) begin
                    if (target_idx == 0) begin
                        root_cache       <= cur_node;
                        root_cache_valid <= 1'b1;
                    end
                end

                // PEEK bookkeeping
                S_PEEK_RD_WAIT: begin
                    if (priv_read_done || virt_read_done) begin
                        if (priv_read_done) root_cache <= priv_rdata;
                        else                root_cache <= virt_resp_data;
                        root_cache_valid <= 1'b1;
                    end
                end

                // UPDATE bookkeeping
                S_UPDATE_WR_WAIT: if (priv_write_done || virt_write_done) begin
                    root_cache       <= saved_op_data;
                    root_cache_valid <= 1'b1;
                end

                default: ;
            endcase
        end
    end

    // Outputs

    assign cmd_ready    = (state == S_IDLE);
    assign cmd_done     = (state == S_DONE);
    assign size_out     = size;
    assign cmd_root_out = (saved_op == OP_PEEK)
                          ? (root_cache_valid ? root_cache : '0)
                          : popped_root;

endmodule
