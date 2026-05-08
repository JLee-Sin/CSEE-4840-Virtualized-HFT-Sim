// heap_fsm_tb.sv - Testbench for heap_fsm
//
// Exercises the four heap operations (push, pop, peek, update) on a max-heap
// with parameters chosen to keep simulation small while still triggering the
// boundary between the private BRAM tier and the MMU-mediated virtual tier.
//
// PRIVATE_NODES is shrunk to 4 so a 5th push spills into virtual memory.
// MAX_NODES is set to 128 

`timescale 1ns/1ps

module heap_fsm_tb;

    parameter int PRIVATE_NODES = 4;
    parameter int MAX_NODES     = 128;
    parameter int NODE_WIDTH    = 86;
    parameter int IDX_WIDTH     = $clog2(MAX_NODES + 1);
    parameter int RD_LATENCY    = 4;

    // Clock and reset

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;   // 100 MHz, 10 ns period

    // DUT-facing signals

    logic                  cmd_valid;
    logic [1:0]            cmd_op;
    logic [NODE_WIDTH-1:0] cmd_data_in;
    logic                  cmd_ready;
    logic                  cmd_done;
    logic [NODE_WIDTH-1:0] cmd_root_out;
    logic [IDX_WIDTH-1:0]  size_out;

    logic                  priv_we, priv_re;
    logic [5:0]            priv_addr;
    logic [NODE_WIDTH-1:0] priv_wdata, priv_rdata;

    logic                  virt_req_valid;
    logic [31:0]           virt_req_va;
    logic                  virt_req_wr;
    logic [NODE_WIDTH-1:0] virt_req_wdata;
    logic                  virt_req_ready;
    logic                  virt_resp_valid;
    logic [NODE_WIDTH-1:0] virt_resp_data;
    logic                  virt_resp_reject;

    // DUT and private BRAM

    heap_fsm #(
        .HEAP_KIND     (0),                // MAX-heap (bids)
        .ENGINE_ID     (0),
        .NODE_WIDTH    (NODE_WIDTH),
        .PRIVATE_NODES (PRIVATE_NODES),
        .MAX_NODES     (MAX_NODES)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .cmd_valid       (cmd_valid),
        .cmd_op          (cmd_op),
        .cmd_data_in     (cmd_data_in),
        .cmd_ready       (cmd_ready),
        .cmd_done        (cmd_done),
        .cmd_root_out    (cmd_root_out),
        .size_out        (size_out),
        .priv_we         (priv_we),
        .priv_re         (priv_re),
        .priv_addr       (priv_addr),
        .priv_wdata      (priv_wdata),
        .priv_rdata      (priv_rdata),
        .virt_req_valid  (virt_req_valid),
        .virt_req_va     (virt_req_va),
        .virt_req_wr     (virt_req_wr),
        .virt_req_wdata  (virt_req_wdata),
        .virt_req_ready  (virt_req_ready),
        .virt_resp_valid (virt_resp_valid),
        .virt_resp_data  (virt_resp_data),
        .virt_resp_reject(virt_resp_reject)
    );

    priv_bram #(.WIDTH(NODE_WIDTH)) priv_mem (
        .clk   (clk),
        .we    (priv_we),
        .re    (priv_re),
        .addr  (priv_addr),
        .wdata (priv_wdata),
        .rdata (priv_rdata)
    );


    // Indexed by the low 8 bits of the flat node ID. Collision-free for
    // the parameter set used here (virt_idx fits in 8 bits, heap_kind=0).

    assign virt_req_ready   = 1'b1;
    assign virt_resp_reject = 1'b0;

    localparam int MMU_DEPTH = 2048;
    logic [NODE_WIDTH-1:0] mmu_mem [MMU_DEPTH];
    logic                  rd_pending;
    logic [3:0]            rd_counter;
    logic [NODE_WIDTH-1:0] rd_data_q;

    function automatic int mmu_idx (input logic [31:0] va);
        mmu_idx = va[10:0];
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pending      <= 1'b0;
            rd_counter      <= '0;
            rd_data_q       <= '0;
            virt_resp_valid <= 1'b0;
            virt_resp_data  <= '0;
            for (int i = 0; i < MMU_DEPTH; i++) mmu_mem[i] <= '0;
        end else begin
            virt_resp_valid <= 1'b0;

            if (virt_req_valid && virt_req_wr)
                mmu_mem[mmu_idx(virt_req_va)] <= virt_req_wdata;

            if (virt_req_valid && !virt_req_wr && !rd_pending) begin
                rd_pending <= 1'b1;
                rd_counter <= RD_LATENCY[3:0];
                rd_data_q  <= mmu_mem[mmu_idx(virt_req_va)];
            end

            if (rd_pending) begin
                if (rd_counter > 0) begin
                    rd_counter <= rd_counter - 4'd1;
                end else begin
                    virt_resp_valid <= 1'b1;
                    virt_resp_data  <= rd_data_q;
                    rd_pending      <= 1'b0;
                end
            end
        end
    end

    // Op-code aliases (must match heap_fsm)

    localparam logic [1:0] OP_PUSH   = 2'd0;
    localparam logic [1:0] OP_POP    = 2'd1;
    localparam logic [1:0] OP_PEEK   = 2'd2;
    localparam logic [1:0] OP_UPDATE = 2'd3;

    // Node helpers
    //
    // Field layout matches heap_fsm:
    //   [0]      type
    //   [16:1]   price
    //   [32:17]  amount
    //   [53:33]  symbol
    //   [85:54]  timestamp

    function automatic logic [NODE_WIDTH-1:0] build_node (
        input logic [15:0] price,
        input logic [15:0] amount,
        input logic        type_bit,
        input logic [31:0] ts
    );
        build_node = {ts, 21'd0, amount, price, type_bit};
    endfunction

    function automatic logic [15:0] node_price_f  (input logic [NODE_WIDTH-1:0] n);
        node_price_f = n[16:1];
    endfunction
    function automatic logic [15:0] node_amount_f (input logic [NODE_WIDTH-1:0] n);
        node_amount_f = n[32:17];
    endfunction

    // Stimulus tasks

    int ts_counter = 32'd1;
    int errors     = 0;

    task automatic do_cmd (
        input  logic [1:0]            op,
        input  logic [NODE_WIDTH-1:0] data,
        output logic [NODE_WIDTH-1:0] root_out
    );
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_valid   <= 1'b1;
        cmd_op      <= op;
        cmd_data_in <= data;
        @(posedge clk);
        while (!cmd_done) @(posedge clk);
        root_out = cmd_root_out;
        cmd_valid <= 1'b0;
        @(posedge clk);
    endtask

    task automatic push (input logic [15:0] price, input logic [15:0] amount);
        logic [NODE_WIDTH-1:0] node, dummy;
        node = build_node(price, amount, 1'b0, ts_counter[31:0]);
        ts_counter++;
        do_cmd(OP_PUSH, node, dummy);
    endtask

    task automatic pop (output logic [15:0] price_out, output logic [15:0] amount_out);
        logic [NODE_WIDTH-1:0] root;
        do_cmd(OP_POP, '0, root);
        price_out  = node_price_f(root);
        amount_out = node_amount_f(root);
    endtask

    task automatic peek (output logic [15:0] price_out);
        logic [NODE_WIDTH-1:0] root;
        do_cmd(OP_PEEK, '0, root);
        price_out = node_price_f(root);
    endtask

    // Updates must preserve the root's price + timestamp (heap-order keys).
    // We peek the current root and rebuild the node with only the amount changed.
    task automatic update_root (input logic [15:0] amount);
        logic [NODE_WIDTH-1:0] root, node, dummy;
        do_cmd(OP_PEEK, '0, root);
        node = {root[NODE_WIDTH-1:33], amount, root[16:0]};
        do_cmd(OP_UPDATE, node, dummy);
    endtask

    // Self-checking helper

    task automatic check (input string label, input integer got, input integer expected);
        if (got !== expected) begin
            $display("[FAIL] %s: got=%0d expected=%0d", label, got, expected);
            errors++;
        end else begin
            $display("[ OK ] %s = %0d", label, got);
        end
    endtask

    // Test sequence

    initial begin
        logic [15:0] p, a;

        $display("=== heap_fsm_tb starting (PRIVATE_NODES=%0d, MAX_NODES=%0d) ===",
                 PRIVATE_NODES, MAX_NODES);

        cmd_valid   = 1'b0;
        cmd_op      = 2'd0;
        cmd_data_in = '0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Test 1: single push then pop
        push(16'd100, 16'd5);
        check("size after 1 push", size_out, 1);
        pop(p, a);
        check("pop price (single)",  p, 100);
        check("pop amount (single)", a, 5);
        check("size after 1 pop",    size_out, 0);

        // Test 2: five pushes with distinct prices, pop in descending order
        push(16'd50,  16'd1);
        push(16'd200, 16'd2);
        push(16'd75,  16'd3);
        push(16'd300, 16'd4);
        push(16'd125, 16'd5);
        check("size after 5 pushes", size_out, 5);

        pop(p, a); check("max pop 1", p, 300);
        pop(p, a); check("max pop 2", p, 200);
        pop(p, a); check("max pop 3", p, 125);
        pop(p, a); check("max pop 4", p, 75);
        pop(p, a); check("max pop 5", p, 50);
        check("size after 5 pops", size_out, 0);

        // Test 3: peek on a single-element heap
        push(16'd42, 16'd7);
        peek(p);
        check("peek price", p, 42);
        check("size after peek", size_out, 1);

        // Test 4: update root in place, then pop to verify
        update_root(16'd99);
        pop(p, a);
        check("post-update pop price",  p, 42);
        check("post-update pop amount", a, 99);
        check("size after pop",         size_out, 0);

        // Test 5: boundary crossing - push enough to spill into virtual tier
        // Prices ascending so each new push climbs to the root and the most
        // recent leaf lives in virtual memory.
        for (int i = 0; i < 8; i++) begin
            push(16'(100 + i*10), 16'(i + 1));
        end
        check("size after 8 pushes", size_out, 8);

        pop(p, a); check("boundary pop 1", p, 170);
        pop(p, a); check("boundary pop 2", p, 160);
        pop(p, a); check("boundary pop 3", p, 150);
        pop(p, a); check("boundary pop 4", p, 140);
        pop(p, a); check("boundary pop 5", p, 130);
        pop(p, a); check("boundary pop 6", p, 120);
        pop(p, a); check("boundary pop 7", p, 110);
        pop(p, a); check("boundary pop 8", p, 100);
        check("size after 8 pops", size_out, 0);

        // Test 6: descending pushes (none needs to sift up past index 0)
        push(16'd500, 16'd1);
        push(16'd400, 16'd2);
        push(16'd300, 16'd3);
        push(16'd200, 16'd4);
        push(16'd100, 16'd5);
        pop(p, a); check("descending pop 1", p, 500);
        pop(p, a); check("descending pop 2", p, 400);
        pop(p, a); check("descending pop 3", p, 300);
        pop(p, a); check("descending pop 4", p, 200);
        pop(p, a); check("descending pop 5", p, 100);

        $display("=== heap_fsm_tb finished: %0d error(s) ===", errors);
        if (errors == 0) $display(">>> ALL TESTS PASSED <<<");
        else             $display(">>> TESTS FAILED <<<");

        $finish;
    end

    // Watchdog

    initial begin
        #200000;
        $display("[FAIL] heap_fsm_tb timed out");
        $finish;
    end

endmodule
