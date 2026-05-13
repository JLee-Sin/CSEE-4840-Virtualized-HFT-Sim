// hft_sim_csv_tb.sv
//
// End-to-end CSV-driven testbench for HFT_SIM. Mirrors what the C harness
// does at runtime: open per-lane CSVs, push orders through the Avalon
// slave, run the dispatch + matching engines, read back the trade log.
//
// CSV format (header skipped): Type,Price,Quantity   (Type = "BID" or "ASK")
//
// Lane mapping (matches sw/HFT_harness.c):
//   0: AAPL.csv  1: BSX.csv  2: BUS.csv  3: MMM.csv
//   4: MSFT.csv  5: SBUX.csv 6: TUS.csv  7: WMT.csv
//
// Run with iverilog. To keep sim time bounded, MAX_ORDERS_PER_LANE caps
// how many orders we read from each CSV (set small for smoke test).

`timescale 1ns/100ps
`include "sys_def.svh"

module hft_sim_csv_tb;

    // Log file (iverilog's vvp buffers stdout when redirected; writing to a
    // real file via $fdisplay + closing on $finish guarantees we see output).
    integer logfp;
    initial logfp = $fopen("/tmp/csv_tb.out", "w");

    // ------------------------------------------------------------------
    // Knobs
    // ------------------------------------------------------------------
    localparam int MAX_ORDERS_PER_LANE = 1660;  // full CSV
    localparam int MAX_LOG_ENTRIES     = 8704;   // matches new TRADE_LOG_DEPTH
    localparam int CYCLE_TIMEOUT       = 10_000_000;

    string CSV_PATH [8];
    initial begin
        CSV_PATH[0] = "../data/AAPL.csv";
        CSV_PATH[1] = "../data/BSX.csv";
        CSV_PATH[2] = "../data/BUS.csv";
        CSV_PATH[3] = "../data/MMM.csv";
        CSV_PATH[4] = "../data/MSFT.csv";
        CSV_PATH[5] = "../data/SBUX.csv";
        CSV_PATH[6] = "../data/TUS.csv";
        CSV_PATH[7] = "../data/WMT.csv";
    end

    // ------------------------------------------------------------------
    // Clock + reset
    // ------------------------------------------------------------------
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;   // 10 ns period in sim time

    int cycle_count = 0;
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > CYCLE_TIMEOUT) begin
            $fdisplay(logfp,"ERROR: CYCLE_TIMEOUT (%0d) exceeded -- forcing $finish", CYCLE_TIMEOUT);
            $finish;
        end
    end

    // ------------------------------------------------------------------
    // Avalon slave wires
    // ------------------------------------------------------------------
    logic        chipselect;
    logic        write_en;
    logic        read_en;
    logic [4:0]  address;
    logic [31:0] writedata;
    logic [31:0] readdata;

    // DUT
    HFT_SIM #(.TRADE_LOG_DEPTH(MAX_LOG_ENTRIES)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .chipselect (chipselect),
        .write      (write_en),
        .read       (read_en),
        .address    (address),
        .writedata  (writedata),
        .readdata   (readdata)
    );

    // Register map (mirror HFT_SIM.sv)
    localparam [4:0] R_CONTROL   = 5'd0;
    localparam [4:0] R_STATUS    = 5'd1;
    localparam [4:0] R_PUSH0     = 5'd2;
    localparam [4:0] R_LOG_INFO  = 5'd10;
    localparam [4:0] R_LOG_CMD   = 5'd11;
    localparam [4:0] R_LOG_DATA0 = 5'd12;
    localparam [4:0] R_LOG_DATA1 = 5'd13;

    // Dispatcher FSM states (mirror sys_def.svh)
    localparam [1:0] S_IDLE     = 2'd0;
    localparam [1:0] S_WRITE    = 2'd1;
    localparam [1:0] S_DISPATCH = 2'd2;
    localparam [1:0] S_DONE     = 2'd3;

    // ------------------------------------------------------------------
    // Avalon master tasks
    // ------------------------------------------------------------------
    task automatic avl_write(input [4:0] a, input [31:0] d);
        @(posedge clk);
        chipselect <= 1'b1; write_en <= 1'b1; read_en <= 1'b0;
        address    <= a;    writedata <= d;
        @(posedge clk);
        chipselect <= 1'b0; write_en <= 1'b0;
    endtask

    task automatic avl_read(input [4:0] a, output [31:0] d);
        @(posedge clk);
        chipselect <= 1'b1; write_en <= 1'b0; read_en <= 1'b1;
        address    <= a;
        @(posedge clk);
        // Capture readdata while chipselect/read are still asserted
        // (readdata is combinational on chipselect && read in HFT_SIM).
        d = readdata;
        chipselect <= 1'b0; read_en  <= 1'b0;
    endtask

    function automatic [1:0] status_state(input [31:0] st);
        status_state = st[1:0];
    endfunction

    function automatic [7:0] status_ready_mask(input [31:0] st);
        status_ready_mask = st[9:2];
    endfunction

    function automatic [7:0] status_full_mask(input [31:0] st);
        status_full_mask = st[25:18];
    endfunction

    // ------------------------------------------------------------------
    // CSV reader: parse one line into a 32-bit order word
    // Layout matches sw pack: {type[31], price[30:15], qty[14:0]}
    // Returns 1 if parsed, 0 on EOF.
    // ------------------------------------------------------------------
    task automatic parse_csv_line(input string line, output int ok, output logic [31:0] word);
        // Manually parse: "BID,<price>,<qty>\n" or "ASK,<price>,<qty>\n".
        // iverilog 11 lacks $sscanf("%[^,]") so we do it by hand.
        int    price, qty;
        int    rc;
        logic  is_bid;
        string rest;
        begin
            ok   = 0;
            word = 32'd0;
            if (line.len() < 5) begin
                ok = 0;
            end else if (line.substr(0, 4) == "Type,") begin
                ok = 0;
            end else if (line[0] == "B" && line.substr(0, 3) == "BID,") begin
                is_bid = 1'b1;
                rest = line.substr(4, line.len()-1);
                rc = $sscanf(rest, "%d,%d", price, qty);
                if (rc == 2) begin
                    word = {is_bid, price[15:0], qty[14:0]};
                    ok   = 1;
                end
            end else if (line[0] == "A" && line.substr(0, 3) == "ASK,") begin
                is_bid = 1'b0;
                rest = line.substr(4, line.len()-1);
                rc = $sscanf(rest, "%d,%d", price, qty);
                if (rc == 2) begin
                    word = {is_bid, price[15:0], qty[14:0]};
                    ok   = 1;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Load all CSVs at sim time
    // ------------------------------------------------------------------
    logic [31:0] csv_orders [8][MAX_ORDERS_PER_LANE];
    int          csv_count  [8];

    task load_csvs;
        int fp;
        reg [8*128-1:0] line_buf;   // 128-byte line buffer
        string line;
        int rc;
        logic [31:0] w;
        begin
            for (int lane = 0; lane < 8; lane++) begin
                csv_count[lane] = 0;
                fp = $fopen(CSV_PATH[lane], "r");
                if (fp == 0) begin
                    $fdisplay(logfp,"WARN: lane %0d: could not open %s", lane, CSV_PATH[lane]);
                end else begin
                    while (!$feof(fp) && csv_count[lane] < MAX_ORDERS_PER_LANE) begin
                        int ok;
                        line_buf = '0;
                        rc = $fgets(line_buf, fp);
                        if (rc > 0) begin
                            line = $sformatf("%0s", line_buf);
                            parse_csv_line(line, ok, w);
                            if (ok != 0) begin
                                csv_orders[lane][csv_count[lane]] = w;
                                csv_count[lane]++;
                            end
                        end
                    end
                    $fclose(fp);
                end
                $fdisplay(logfp,"LOAD: lane %0d (%s) -> %0d orders", lane, CSV_PATH[lane], csv_count[lane]);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Push orders round-robin until all lanes are exhausted
    // ------------------------------------------------------------------
    task push_orders_round_robin;
        int   lane_idx [8];
        logic lane_done [8];
        int   all_done;
        logic [31:0] st;
        logic [7:0]  ready_mask, full_mask;
        int   loop_iter, pushed_total;
        begin
            int  done_loop;
            loop_iter    = 0;
            pushed_total = 0;
            for (int i = 0; i < 8; i++) begin
                lane_idx[i]  = 0;
                lane_done[i] = 1'b0;
            end

            done_loop = 0;
            while (done_loop == 0) begin
                all_done = 1;
                for (int i = 0; i < 8; i++) if (!lane_done[i]) all_done = 0;
                if (all_done) begin
                    done_loop = 1;
                end else begin
                    avl_read(R_STATUS, st);
                    if (status_state(st) != S_WRITE) begin
                        $fdisplay(logfp,"ERROR: expected WRITE state, got %0d", status_state(st));
                        done_loop = 1;
                    end else begin
                        ready_mask = status_ready_mask(st);
                        full_mask  = status_full_mask(st);
                        for (int lane = 0; lane < 8; lane++) begin
                            if (!lane_done[lane]) begin
                                if (lane_idx[lane] >= csv_count[lane]) begin
                                    // done with this lane; FIFO state doesn't matter.
                                    lane_done[lane] = 1'b1;
                                end else if (!full_mask[lane] && ready_mask[lane]) begin
                                    avl_write(R_PUSH0 + lane[4:0], csv_orders[lane][lane_idx[lane]]);
                                    lane_idx[lane]++;
                                    pushed_total++;
                                end
                            end
                        end
                        loop_iter++;
                        if ((loop_iter % 500) == 0) begin
                            $fdisplay(logfp,
                                "PROGRESS iter=%0d cycle=%0d pushed=%0d ready=%02x full=%02x lane_idx=[%0d %0d %0d %0d %0d %0d %0d %0d]",
                                loop_iter, cycle_count, pushed_total, ready_mask, full_mask,
                                lane_idx[0], lane_idx[1], lane_idx[2], lane_idx[3],
                                lane_idx[4], lane_idx[5], lane_idx[6], lane_idx[7]);
                            $fflush(logfp);
                        end
                    end
                end
            end
            $fdisplay(logfp,"PUSH: round-robin complete after %0d iter, %0d pushed", loop_iter, pushed_total);
        end
    endtask

    // ------------------------------------------------------------------
    // Wait for dispatcher state == DONE (or timeout)
    // ------------------------------------------------------------------
    task wait_for_done(input int max_polls);
        logic [31:0] st;
        logic [31:0] li;
        int polls;
        begin
            int done_flag;
            polls = 0;
            done_flag = 0;
            while (done_flag == 0) begin
                avl_read(R_STATUS, st);
                if (status_state(st) == S_DONE) begin
                    $fdisplay(logfp,"DONE: dispatcher reached DONE after %0d polls", polls);
                    done_flag = 1;
                end else begin
                    polls++;
                    if (polls > max_polls) begin
                        $fdisplay(logfp,"WARN: wait_for_done timed out after %0d polls (state=%0d)", polls, status_state(st));
                        done_flag = 1;
                    end else begin
                        repeat (50) @(posedge clk);
                    end
                end
            end
            // Dispatcher DONE only means orders pushed; engines may still
            // be cascading. Wait for trade_done (bit 26 of LOG_INFO).
            polls = 0;
            done_flag = 0;
            while (done_flag == 0) begin
                avl_read(R_LOG_INFO, li);
                if (li[26]) begin
                    $fdisplay(logfp,"TRADE_DONE: engines settled after %0d polls", polls);
                    done_flag = 1;
                end else begin
                    polls++;
                    if (polls > max_polls) begin
                        $fdisplay(logfp,"WARN: trade_done timed out after %0d polls", polls);
                        done_flag = 1;
                    end else begin
                        repeat (50) @(posedge clk);
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Read all trade log entries and print.
    // 64-bit TRADE_LOG_ENTRY layout (mirror sys_def.svh):
    //   word0 = [31:0]  timestamp
    //   word1 = [63:32] {engine_id[7:0], amount[7:0], price[15:0]}
    // (Old ORDER-shaped entry + LOG_DATA2 are gone.)
    // ------------------------------------------------------------------
    task read_and_print_log(output int trade_count);
        logic [31:0] info;
        logic [31:0] d0, d1;
        int    count;
        int    poll;
        begin
            avl_read(R_LOG_INFO, info);
            count = (info >> 2) & 32'h7FFF;
            trade_count = count;
            $fdisplay(logfp,"LOG: %0d trade(s) recorded (overflow=%0d)", count, info[0]);

            for (int i = 0; i < count; i++) begin
                // bit 1 = read_req, index shifted up by 2
                avl_write(R_LOG_CMD, 32'h2 | (i << 2));

                poll = 0;
                begin
                    int got_valid;
                    got_valid = 0;
                    while (got_valid == 0 && poll <= 100) begin
                        avl_read(R_LOG_INFO, info);
                        if (info[1]) got_valid = 1;
                        else         poll++;
                    end
                    if (got_valid == 0) begin
                        $fdisplay(logfp,"ERROR: log entry %0d data_valid never asserted", i);
                    end
                end

                avl_read(R_LOG_DATA0, d0);
                avl_read(R_LOG_DATA1, d1);

                begin
                    logic [2:0]  e_eng;
                    logic [6:0]  e_amt;
                    logic [15:0] e_prc;
                    logic [31:0] e_ts;
                    e_eng = d1[26:24];
                    e_amt = d1[22:16];
                    e_prc = d1[15:0];
                    e_ts  = d0;
                    $fdisplay(logfp,"  trade[%0d] eng=%0d price=%0d qty=%0d ts=%0d raw=%08x_%08x",
                             i, e_eng, e_prc, e_amt, e_ts, d1, d0);
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    int trades_seen;

    initial begin
        $fdisplay(logfp,"=== hft_sim_csv_tb starting (MAX_ORDERS_PER_LANE=%0d) ===", MAX_ORDERS_PER_LANE);
        chipselect = 0;
        write_en   = 0;
        read_en    = 0;
        address    = 0;
        writedata  = 0;
        rst_n      = 0;

        // Reset
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // Load CSV files
        load_csvs();

        // 1. Clear trade log
        avl_write(R_LOG_CMD, 32'h1);
        repeat (5) @(posedge clk);

        // 2. Enter WRITE state
        $fdisplay(logfp,"DEBUG: before CONTROL write, dispatcher state=%0d, begin_pulse=%b",
                 dut.avl_disp_state, dut.avl_disp_begin_write_pulse);
        avl_write(R_CONTROL, 32'h1);
        @(posedge clk);
        $fdisplay(logfp,"DEBUG: +1 cycle after avl_write, begin_pulse=%b state=%0d",
                 dut.avl_disp_begin_write_pulse, dut.avl_disp_state);
        @(posedge clk);
        $fdisplay(logfp,"DEBUG: +2 cycle after avl_write, begin_pulse=%b state=%0d",
                 dut.avl_disp_begin_write_pulse, dut.avl_disp_state);
        @(posedge clk);
        $fdisplay(logfp,"DEBUG: +3 cycle after avl_write, begin_pulse=%b state=%0d",
                 dut.avl_disp_begin_write_pulse, dut.avl_disp_state);
        repeat (20) @(posedge clk);
        begin
            logic [31:0] dbg_st;
            avl_read(R_STATUS, dbg_st);
            $fdisplay(logfp,"DEBUG: after CONTROL=1, state=%0d full=%02x ready=%02x",
                     dbg_st[1:0], dbg_st[25:18], dbg_st[9:2]);
            $fdisplay(logfp,"DEBUG: dispatcher state=%0d fifo_full_i=%b sw_wr_ready=%b",
                     dut.u_dispatcher.state,
                     dut.u_dispatcher.fifo_full_i,
                     dut.u_dispatcher.sw_wr_ready);
            $fdisplay(logfp,"DEBUG: avl_disp_state=%0d avl_disp_push_ready=%b avl_disp_fifo_full=%b",
                     dut.avl_disp_state,
                     dut.avl_disp_push_ready,
                     dut.avl_disp_fifo_full);
        end

        // 3. Push all orders
        push_orders_round_robin();
        repeat (5) @(posedge clk);

        // 4. Enter DISPATCH state
        avl_write(R_CONTROL, 32'h2);
        repeat (5) @(posedge clk);

        // 5. Wait for DONE
        wait_for_done(10000);

        // 6. Read out the trade log
        read_and_print_log(trades_seen);

        // 7. Clear-done -> back to IDLE
        avl_write(R_CONTROL, 32'h4);
        repeat (10) @(posedge clk);

        $fdisplay(logfp,"=== hft_sim_csv_tb finished: trades=%0d ===", trades_seen);
        $fclose(logfp);
        $finish;
    end

endmodule
