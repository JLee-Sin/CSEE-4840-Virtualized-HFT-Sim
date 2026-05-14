// symbol_engine_tb.sv: Testbench for symbol_engine
//
// Drives orders into one symbol_engine (ENGINE_ID=0) and verifies the
// trade-controller behavior: no trade on non-overlapping prices, exact
// matches, partial fills in both directions, and that the heap sizes
// reflect what the trade controller pops.

`timescale 1ns/1ps

module symbol_engine_tb;

    parameter int NODE_WIDTH = 86;
    parameter int RD_LATENCY = 4;

    // Clock and reset

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;   // 100 MHz

    // DUT-facing signals

    logic                  order_in_valid;
    logic [31:0]           order_in_data;   // DISPATCH_ORDER: {type[1], price[16], quantity[15]}
    logic                  order_in_ready;
    logic [31:0]           now_ts;          // free-running timestamp counter

    logic                  trade_out_valid;
    logic [NODE_WIDTH-1:0] trade_out_data;
    logic                  trade_out_ready;

    logic                  mmu_req_valid;
    logic [31:0]           mmu_req_va;
    logic                  mmu_req_wr;
    logic [NODE_WIDTH-1:0] mmu_req_wdata;
    logic                  mmu_req_ready;
    logic [NODE_WIDTH-1:0] mmu_resp_data;
    logic                  mmu_resp_valid;
    logic                  mmu_resp_reject;

    logic [13:0]           bid_size_o;
    logic [13:0]           ask_size_o;

    // DUT

    symbol_engine #(
        .ENGINE_ID  (0),
        .NODE_WIDTH (NODE_WIDTH),
        .SYMBOL     (21'd0)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .now_ts          (now_ts),
        .order_in_valid  (order_in_valid),
        .order_in_data   (order_in_data),
        .order_in_ready  (order_in_ready),
        .trade_out_valid (trade_out_valid),
        .trade_out_data  (trade_out_data),
        .trade_out_ready (trade_out_ready),
        .mmu_req_valid   (mmu_req_valid),
        .mmu_req_va      (mmu_req_va),
        .mmu_req_wr      (mmu_req_wr),
        .mmu_req_wdata   (mmu_req_wdata),
        .mmu_req_ready   (mmu_req_ready),
        .mmu_resp_data   (mmu_resp_data),
        .mmu_resp_valid  (mmu_resp_valid),
        .mmu_resp_reject (mmu_resp_reject),
        .bid_size_o      (bid_size_o),
        .ask_size_o      (ask_size_o)
    );

    // MMU stub needed encase future test touch virtual memory

    assign mmu_req_ready   = 1'b1;
    assign mmu_resp_reject = 1'b0;

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
            rd_pending     <= 1'b0;
            rd_counter     <= '0;
            rd_data_q      <= '0;
            mmu_resp_valid <= 1'b0;
            mmu_resp_data  <= '0;
            for (int i = 0; i < MMU_DEPTH; i++) mmu_mem[i] <= '0;
        end else begin
            mmu_resp_valid <= 1'b0;

            if (mmu_req_valid && mmu_req_wr)
                mmu_mem[mmu_idx(mmu_req_va)] <= mmu_req_wdata;

            if (mmu_req_valid && !mmu_req_wr && !rd_pending) begin
                rd_pending <= 1'b1;
                rd_counter <= RD_LATENCY[3:0];
                rd_data_q  <= mmu_mem[mmu_idx(mmu_req_va)];
            end

            if (rd_pending) begin
                if (rd_counter > 0) begin
                    rd_counter <= rd_counter - 4'd1;
                end else begin
                    mmu_resp_valid <= 1'b1;
                    mmu_resp_data  <= rd_data_q;
                    rd_pending     <= 1'b0;
                end
            end
        end
    end

    // Trade-event capture

    int trade_count;
    logic [NODE_WIDTH-1:0] last_trade;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trade_count <= 0;
            last_trade  <= '0;
        end else if (trade_out_valid && trade_out_ready) begin
            trade_count <= trade_count + 1;
            last_trade  <= trade_out_data;
            $display("  [trade] price=%0d amount=%0d (count now %0d)",
                     trade_out_data[84:69], trade_out_data[68:53], trade_count + 1);
        end
    end

    // DISPATCH_ORDER builder: {type[1], price[16], quantity[15]} MSB-first
    function automatic logic [31:0] build_dispatch (
        input logic [15:0] price,
        input logic [14:0] amount,
        input logic        type_bit
    );
        build_dispatch = {type_bit, price, amount};
    endfunction

    function automatic logic [15:0] np (input logic [NODE_WIDTH-1:0] n);
        np = n[84:69];
    endfunction
    function automatic logic [15:0] na (input logic [NODE_WIDTH-1:0] n);
        na = n[68:53];
    endfunction


    int errors = 0;

    task automatic submit_order (
        input logic [15:0] price,
        input logic [15:0] amount,    // upper bit dropped; quantity is 15 bits
        input logic        is_ask
    );
        @(posedge clk);
        while (!order_in_ready) @(posedge clk);
        order_in_valid <= 1'b1;
        order_in_data  <= build_dispatch(price, amount[14:0], !is_ask);
        @(posedge clk);
        order_in_valid <= 1'b0;
        order_in_data  <= '0;
        // Block until the trade controller is back to idle so the next
        // submit_order doesn't race the cascade trade loop.
        @(posedge clk);
        while (!order_in_ready) @(posedge clk);
    endtask

    task automatic check (input string label, input integer got, input integer expected);
        if (got !== expected) begin
            $display("[FAIL] %s: got=%0d expected=%0d", label, got, expected);
            errors++;
        end else begin
            $display("[ OK ] %s = %0d", label, got);
        end
    endtask


    // Test sequence

    // free-running timestamp counter
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) now_ts <= 32'd0;
        else        now_ts <= now_ts + 32'd1;
    end

    initial begin
        $display("=== symbol_engine_tb starting ===");

        order_in_valid  = 1'b0;
        order_in_data   = '0;
        trade_out_ready = 1'b1;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Test 1: lone bid does not trade
        $display("-- T1: lone bid 100 x 5");
        submit_order(16'd100, 16'd5, 1'b0);
        check("trades after lone bid", trade_count, 0);
        check("bid size after lone bid", bid_size_o, 1);
        check("ask size after lone bid", ask_size_o, 0);

        // Test 2: ask above best bid does not trade
        $display("-- T2: ask 250 x 5 (does not match bid 100)");
        submit_order(16'd250, 16'd5, 1'b1);
        check("trades after non-matching ask", trade_count, 0);
        check("ask size after non-matching ask", ask_size_o, 1);

        // Test 3: bid that matches the best ask exactly
        $display("-- T3: bid 250 x 5 (exact match with ask 250 x 5)");
        submit_order(16'd250, 16'd5, 1'b0);
        check("trades after exact match", trade_count, 1);
        check("trade price",  np(last_trade), 250);
        check("trade amount", na(last_trade), 5);
        check("bid size after exact match",  bid_size_o, 1);   // bid 100 still in book
        check("ask size after exact match",  ask_size_o, 0);

        // Test 4: ask above best bid - still no match
        $display("-- T4: ask 300 x 8 (above best bid 100)");
        submit_order(16'd300, 16'd8, 1'b1);
        check("trades after high ask", trade_count, 1);
        check("ask size", ask_size_o, 1);

        // Test 5: bid larger than the ask amount - partial fill, bid remains
        $display("-- T5: bid 300 x 12 (matches ask 300 x 8, bid remains x 4)");
        submit_order(16'd300, 16'd12, 1'b0);
        check("trades after partial bid", trade_count, 2);
        check("partial trade price",  np(last_trade), 300);
        check("partial trade amount", na(last_trade), 8);
        check("bid size after partial",  bid_size_o, 2);   // bid 100 + bid 300x4
        check("ask size after partial",  ask_size_o, 0);

        // Test 6: ask smaller than the leftover bid - exact-fill cleanup
        $display("-- T6: ask 300 x 4 (matches leftover bid 300 x 4 exactly)");
        submit_order(16'd300, 16'd4, 1'b1);
        check("trades after cleanup", trade_count, 3);
        check("cleanup trade amount", na(last_trade), 4);
        check("bid size after cleanup", bid_size_o, 1);   // only bid 100 left
        check("ask size after cleanup", ask_size_o, 0);

        // Test 7: ask smaller than bid amount - partial fill, ask remains
        $display("-- T7: bid 200 x 3, then ask 200 x 5 (ask remains x 2)");
        submit_order(16'd200, 16'd3, 1'b0);   // bid 200 x 3, no ask, no trade
        check("trades after lone bid 200", trade_count, 3);
        submit_order(16'd200, 16'd5, 1'b1);   // ask 200 x 5, partial fill
        check("trades after partial ask", trade_count, 4);
        check("partial-ask trade amount", na(last_trade), 3);
        check("ask size after partial ask", ask_size_o, 1);

        $display("=== symbol_engine_tb finished: %0d error(s) ===", errors);
        if (errors == 0) $display(">>> ALL TESTS PASSED <<<");
        else             $display(">>> TESTS FAILED <<<");

        $finish;
    end

    // Watchdog

    initial begin
        #500000;
        $display("[FAIL] symbol_engine_tb timed out");
        $finish;
    end

endmodule
