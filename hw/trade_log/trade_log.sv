// trade_log.sv
//
// Stores every NODE_WIDTH-bit trade event the trade_aggregator emits in a
// linear, append-only memory. Software collects trades by reading
// mem[0 .. sw_count-1] and then pulses sw_clear to recycle the log.
//
// Default NODE_WIDTH is 64
//
//   trade_in_ready falls when the log is full. The aggregator stalls
//   until software clears the log. If a trade tries to push while the
//   log is full, sw_overflow latches high so software can detect a
//   missed trade after the fact.

module trade_log #(
    parameter int NODE_WIDTH = 64,
    parameter int LOG_DEPTH  = 8704,
    parameter int CNT_WIDTH  = $clog2(LOG_DEPTH + 1),
    parameter int ADDR_WIDTH = $clog2(LOG_DEPTH)
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // HW write port (from trade_aggregator)
    input  logic                  trade_in_valid,
    input  logic [NODE_WIDTH-1:0] trade_in_data,
    output logic                  trade_in_ready,

    // SW read port (1-cycle registered read latency)
    input  logic                  sw_re,
    input  logic [ADDR_WIDTH-1:0] sw_addr,
    output logic [NODE_WIDTH-1:0] sw_rdata,

    // Status / control
    output logic [CNT_WIDTH-1:0]  sw_count,
    output logic                  sw_overflow,
    input  logic                  sw_clear
);

    (* ramstyle = "M10K", ram_init_file = "trade_log_zero.mif" *)
    logic [NODE_WIDTH-1:0] mem [0:LOG_DEPTH-1];
    logic [ADDR_WIDTH-1:0] wr_ptr;
    logic [CNT_WIDTH-1:0]  count_reg;
    logic                  overflow_reg;

    logic accept_write;
    assign accept_write = trade_in_valid && (count_reg < LOG_DEPTH[CNT_WIDTH-1:0]);

    assign trade_in_ready = (count_reg < LOG_DEPTH[CNT_WIDTH-1:0]);
    assign sw_count       = count_reg;
    assign sw_overflow    = overflow_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr       <= '0;
            count_reg    <= '0;
            overflow_reg <= 1'b0;
            sw_rdata     <= '0;
        end else begin
            if (sw_re) sw_rdata <= mem[sw_addr];

            if (sw_clear) begin
                wr_ptr       <= '0;
                count_reg    <= '0;
                overflow_reg <= 1'b0;
            end else begin
                if (accept_write) begin
                    mem[wr_ptr] <= trade_in_data;
                    wr_ptr      <= wr_ptr + 1'b1;
                    count_reg   <= count_reg + 1'b1;
                end
                if (trade_in_valid && !accept_write) begin
                    overflow_reg <= 1'b1;
                end
            end
        end
    end

endmodule
