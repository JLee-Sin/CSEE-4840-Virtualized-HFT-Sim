//////////////////////////////////////////////////////////////////////////////////
// Engineers: Carlos Espinoza
// Create Date: 04/07/2026
// Project Name: Virtualized High Frequence Trading (HFT) Simulator
// Design Name: Input Interface & Order Dispatcher
// Description:
//      This is a simple file to define parameters and structs that will be used
//      across the various modules in this project.
//
// Revision: 05/08/2026
//////////////////////////////////////////////////////////////////////////////////
`include "../sys_def.svh"

module order_dispatcher(
    input logic 	                    clk,
	input logic 	                    rst_n,

	// Interface with software harness
	input logic                         sw_begin_write,     // Enables transition to WRITE state
	input logic                         sw_begin_dispatch,  // Enables transition to DISPATCH state
	input logic                         sw_clear_done,      // Enable transition to IDLE after its done
	input logic [`N-1:0]          sw_wr_en,           // Enable writing to FIFO tails
	input DISPATCH_ORDER [`N-1:0] sw_wr_data,         // Order to write to FIFO tails
	output logic [`N-1:0]         sw_wr_ready,        // Signal that FIDO is ready to write

	// FIFO state (per symbol/lane)
	output logic [1:0]                  state_out,          // Current state of Dispatcher
	output logic [`N-1:0]         fifo_empty,         // Per FIFO empty signals
	output logic [`N-1:0]         fifo_full,          // Per FIFO full signals

	// Communication with Heap Engines
	input  logic [`N-1:0]         order_in_ready,     // Per-lane ready from each engine: high when they can accept order
	output logic [`N-1:0]         order_out_valid,    // High when order_out holds a real order (not trash)
	output DISPATCH_ORDER [`N-1:0] order_out          // Order presented to engine (consumed when ready)
);

    //////////////////////////////////////////////////////////////////////////////////
    // FIFOs
    // There are N number of FIFOs (i.e. 8), one per symbol/stock
    //  - No need to store symbol since each fifo stores only for one fifo.
    //  - No to sotre the timestamp since the FIFO
    //////////////////////////////////////////////////////////////////////////////////

    // FIFOs
    //  - fifo[s][i] : entry i of FIFO for symbol/lane s
    (* ramstyle = "M10K" *)
    DISPATCH_ORDER fifo [`N-1:0][`FIFO_SZ-1:0];

    // FIFO pointers
    localparam int FIFO_PTR_W = $clog2(`FIFO_SZ + 1);
    logic [FIFO_PTR_W-1:0] fifo_tail [`N-1:0];    // Write index
    logic [FIFO_PTR_W-1:0] fifo_head [`N-1:0];    // Read index

    //////////////////////////////////////////////////////////////////////////////////
    // FSM Controller
    //////////////////////////////////////////////////////////////////////////////////

    DISPATCH_STATE state, next_state;

    // Next State Logic
    always_comb begin
        // Defaults
        next_state = state;

        // Transitions
        // Note: tansitions to DISPATCH is SW controll to enable dipatching
        // when FIFOS have less than FIFO_SZ orders.
        unique case (state)
        IDLE:     next_state = sw_begin_write ?  WRITE:IDLE;
        WRITE:    next_state = sw_begin_dispatch ? DISPATCH:WRITE;
        DISPATCH: next_state = (&fifo_empty) ? DONE:DISPATCH;
        DONE:     next_state = sw_clear_done ? IDLE : DONE;
        default:; //Handled
        endcase
    end

    // Update State & FIFOs
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset state
            state <= IDLE;
            // Clear Pointers
            for (int s = 0; s < `N; s++) begin
                fifo_tail[s] <= '0; // write index
                fifo_head[s] <= '0; // read index
            end

        end else begin
            // Update State
            state <= next_state;

            // Write: software writes into FIFOs and advance tail
            if (state == WRITE) begin
                for (int s = 0; s < `N; s++) begin
                    if (sw_wr_en[s] && (fifo_tail[s] < `FIFO_SZ)) begin
                        fifo[s][fifo_tail[s]] <= sw_wr_data[s];
                        fifo_tail[s] <= fifo_tail[s] + 1'b1;
                    end
                end
            end

            // Dispatch: advance head pointer only when an order is actually accepted:
            // FIFO non-empty and corresponding engine asserts ready).
            if (state == DISPATCH) begin
                for (int s = 0; s < `N; s++) begin
                    if ((fifo_head[s] != fifo_tail[s]) && order_in_ready[s]) begin
                        fifo_head[s] <= fifo_head[s] + 1'b1;
                    end
                end
            end

            // Reset pointers when done
            // Helpful if we decide to do multiple batches of orders
            if (state == DONE && sw_clear_done) begin
                for (int s = 0; s < `N; s++) begin
                    fifo_tail[s] <= '0;
                    fifo_head[s] <= '0;
                end
            end

        end // else
    end // always_ff

    // Output Logic
    always_comb begin
        // Defaults
        state_out        = state;
        order_out_valid  = '0;
        order_out        = '0;
        fifo_empty       = '0;
        fifo_full        = '0;
        sw_wr_ready      = '0;

        for (int s = 0; s < `N; s++) begin
            // Update empty, full, and ready signals
            fifo_empty[s]  = (fifo_head[s] == fifo_tail[s]);
            fifo_full[s]   = (fifo_tail[s] == `FIFO_SZ);
            sw_wr_ready[s] = (state == WRITE) && !fifo_full[s];

            // Only issue orders during DISPATCH and not empty
            if ((state == DISPATCH) && (fifo_head[s] != fifo_tail[s])) begin
                order_out_valid[s] = 1'b1;
                order_out[s]       = fifo[s][fifo_head[s]];
            end
        end
    end
endmodule
