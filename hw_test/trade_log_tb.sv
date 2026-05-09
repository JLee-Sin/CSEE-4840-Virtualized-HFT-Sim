// trade_log_tb.sv - Testbench for trade_log
//
// Pushes a small number of trade events, reads them back through the
// SW port, verifies count, exercises the full -> overflow -> clear path.

`timescale 1ns/1ps

module trade_log_tb;

    parameter int NODE_WIDTH = 86;
    parameter int LOG_DEPTH  = 8;       // shrunk for fast overflow
    localparam int CNT_WIDTH  = $clog2(LOG_DEPTH + 1);
    localparam int ADDR_WIDTH = $clog2(LOG_DEPTH);

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    logic                  trade_in_valid;
    logic [NODE_WIDTH-1:0] trade_in_data;
    logic                  trade_in_ready;

    logic                  sw_re;
    logic [ADDR_WIDTH-1:0] sw_addr;
    logic [NODE_WIDTH-1:0] sw_rdata;
    logic [CNT_WIDTH-1:0]  sw_count;
    logic                  sw_overflow;
    logic                  sw_clear;

    trade_log #(
        .NODE_WIDTH (NODE_WIDTH),
        .LOG_DEPTH  (LOG_DEPTH)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .trade_in_valid (trade_in_valid),
        .trade_in_data  (trade_in_data),
        .trade_in_ready (trade_in_ready),
        .sw_re          (sw_re),
        .sw_addr        (sw_addr),
        .sw_rdata       (sw_rdata),
        .sw_count       (sw_count),
        .sw_overflow    (sw_overflow),
        .sw_clear       (sw_clear)
    );

    int errors = 0;

    task automatic check (input string label, input integer got, input integer expected);
        if (got !== expected) begin
            $display("[FAIL] %s: got=%0d expected=%0d", label, got, expected);
            errors++;
        end else begin
            $display("[ OK ] %s = %0d", label, got);
        end
    endtask

    task automatic push_trade (input logic [NODE_WIDTH-1:0] data);
        @(posedge clk);
        trade_in_valid <= 1'b1;
        trade_in_data  <= data;
        @(posedge clk);
        trade_in_valid <= 1'b0;
    endtask

    task automatic read_trade (input int addr, output logic [NODE_WIDTH-1:0] data);
        @(posedge clk);
        sw_re   <= 1'b1;
        sw_addr <= addr[ADDR_WIDTH-1:0];
        @(posedge clk);
        sw_re   <= 1'b0;
        @(posedge clk);
        data = sw_rdata;
    endtask

    initial begin
        logic [NODE_WIDTH-1:0] d;

        $display("=== trade_log_tb starting (LOG_DEPTH=%0d) ===", LOG_DEPTH);

        trade_in_valid = 1'b0;
        trade_in_data  = '0;
        sw_re          = 1'b0;
        sw_addr        = '0;
        sw_clear       = 1'b0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        check("ready after reset",    trade_in_ready, 1);
        check("count after reset",    sw_count,       0);
        check("overflow after reset", sw_overflow,    0);

        // Push 3 trades, verify count, read them back
        push_trade(86'h111111111111111111111);
        push_trade(86'h222222222222222222222);
        push_trade(86'h333333333333333333333);
        @(posedge clk);
        check("count after 3 pushes", sw_count, 3);

        read_trade(0, d);
        check("read[0] low bits",  d[31:0], 32'h11111111);
        read_trade(1, d);
        check("read[1] low bits",  d[31:0], 32'h22222222);
        read_trade(2, d);
        check("read[2] low bits",  d[31:0], 32'h33333333);

        // Fill the remaining slots
        push_trade(86'h444444444444444444444);
        push_trade(86'h555555555555555555555);
        push_trade(86'h666666666666666666666);
        push_trade(86'h777777777777777777777);
        push_trade(86'h888888888888888888888);
        @(posedge clk);
        check("count when full",      sw_count,       LOG_DEPTH);
        check("ready when full",      trade_in_ready, 0);
        check("overflow before drop", sw_overflow,    0);

        // Try to push when full -> overflow latches, count stays
        push_trade(86'h999999999999999999999);
        @(posedge clk);
        check("count after dropped",  sw_count,    LOG_DEPTH);
        check("overflow after drop",  sw_overflow, 1);

        // Clear -> count and overflow reset
        @(posedge clk);
        sw_clear <= 1'b1;
        @(posedge clk);
        sw_clear <= 1'b0;
        @(posedge clk);
        check("count after clear",    sw_count,    0);
        check("overflow after clear", sw_overflow, 0);
        check("ready after clear",    trade_in_ready, 1);

        // Push fresh data after clear, verify it lands at slot 0
        push_trade(86'hAAAAAAAAAAAAAAAAAAAAA);
        @(posedge clk);
        check("count after post-clear push", sw_count, 1);
        read_trade(0, d);
        check("post-clear read[0]", d[31:0], 32'hAAAAAAAA);

        $display("=== trade_log_tb finished: %0d error(s) ===", errors);
        if (errors == 0) $display(">>> ALL TESTS PASSED <<<");
        else             $display(">>> TESTS FAILED <<<");

        $finish;
    end

    initial begin
        #50000;
        $display("[FAIL] trade_log_tb timed out");
        $finish;
    end

endmodule
