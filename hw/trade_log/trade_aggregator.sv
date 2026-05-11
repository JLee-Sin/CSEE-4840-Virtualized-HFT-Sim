// trade_aggregator - Round-robin merge of N engine trade streams.
//
// Each engine drives its own valid/data/ready handshake. The aggregator
// scans engines starting from a round-robin pointer; the first engine
// found with a valid trade wins this cycle. The selected engine sees
// trade_out_ready propagated back to it as ready; all others see ready=0.
// On a successful handshake, the RR pointer advances to the engine after
// the winner so no engine starves.

module trade_aggregator #(
    parameter int N          = 8,
    parameter int NODE_WIDTH = 86
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
    output logic [NODE_WIDTH-1:0]  trade_out_data,
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

    assign trade_out_valid = any_valid;
    assign trade_out_data  = eng_trade_data[selected];

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
