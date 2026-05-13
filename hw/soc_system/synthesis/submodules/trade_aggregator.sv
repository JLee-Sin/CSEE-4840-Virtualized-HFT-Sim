// trade_aggregator - Round-robin merge of N engine trade streams.
//
// Each engine drives its own valid/data/ready handshake. The aggregator
// scans engines starting from a round-robin pointer; the first engine
// found with a valid trade wins this cycle. The selected engine sees
// trade_out_ready propagated back to it as ready; all others see ready=0.
// On a successful handshake, the RR pointer advances to the engine after
// the winner so no engine starves.
//
// Compaction:
//   Engines emit full 86-bit ORDER nodes on their trade outputs (type,
//   price, amount, symbol, timestamp). For the trade log we only keep:
//     - engine_id   (the winning engine's index, 3b -> low byte)
//     - amount      (low 7b of the ORDER's amount field; trades cap <128)
//     - price       (16b)
//     - timestamp   (32b)
//   The aggregator does this compaction inline and outputs a 64-bit
//   TRADE_LOG_ENTRY (see hw/sys_def.svh).

module trade_aggregator #(
    parameter int N           = 8,
    parameter int NODE_WIDTH  = 86,  // engine-side trade width (ORDER struct)
    parameter int TRADE_WIDTH = 64   // aggregator-output / trade_log width
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // valid and ready are packed bit-vectors so iverilog 11 propagates
    // index-assignments through the port boundary; data stays as an
    // unpacked array because each element is NODE_WIDTH bits.
    input  logic [N-1:0]           eng_trade_valid,
    input  logic [NODE_WIDTH-1:0]  eng_trade_data  [N],
    output logic [N-1:0]           eng_trade_ready,

    output logic                   trade_out_valid,
    output logic [TRADE_WIDTH-1:0] trade_out_data,
    input  logic                   trade_out_ready
);

    localparam int PTR_W = $clog2(N);

    logic [PTR_W-1:0] rr_ptr;

    logic [PTR_W-1:0] selected;
    logic             any_valid;

    // Combinational: scan engines round-robin from rr_ptr; first valid wins.
    always_comb begin
        selected  = rr_ptr;
        any_valid = 1'b0;
        for (int i = 0; i < N; i++) begin
            logic [PTR_W-1:0] idx;
            idx = rr_ptr + i[PTR_W-1:0];
            if (eng_trade_valid[idx] && !any_valid) begin
                selected  = idx;
                any_valid = 1'b1;
            end
        end
    end

    // Compact the winner's ORDER into a 64-bit TRADE_LOG_ENTRY.
    // ORDER layout (NODE_WIDTH=86): [85]=type, [84:69]=price,
    //   [68:53]=amount(16b), [52:32]=symbol, [31:0]=timestamp.
    // TRADE_LOG_ENTRY layout (64b): {engine_id[7:0], amount[7:0],
    //   price[15:0], timestamp[31:0]}.
    logic [NODE_WIDTH-1:0] winner_order;
    assign winner_order   = eng_trade_data[selected];

    assign trade_out_valid = any_valid;
    assign trade_out_data  = { {(8-PTR_W){1'b0}}, selected,           // [63:56] engine_id
                               1'b0, winner_order[59:53],             // [55:48] amount[6:0]
                               winner_order[84:69],                   // [47:32] price
                               winner_order[31:0] };                  // [31:0]  timestamp

    always_comb begin
        eng_trade_ready = '0;
        if (any_valid) eng_trade_ready[selected] = trade_out_ready;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rr_ptr <= '0;
        else if (any_valid && trade_out_ready)
            rr_ptr <= selected + 1'b1;
    end

endmodule
