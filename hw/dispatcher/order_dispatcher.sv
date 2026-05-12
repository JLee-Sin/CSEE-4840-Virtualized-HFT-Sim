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
    input logic 	              clk,
	input logic 	              rst_n,

	// Interface with software harness
	input logic                   sw_begin_write,     // Enables transition to WRITE state
	input logic                   sw_begin_dispatch,  // Enables transition to DISPATCH state
	input logic                   sw_clear_done,      // Enable transition to IDLE after its done
	input logic [`N-1:0]          sw_wr_en,           // Enable writing to FIFO tails
	input DISPATCH_ORDER [`N-1:0] sw_wr_data,         // Order to write to FIFO tails
	output logic [`N-1:0]         sw_wr_ready,        // Signal that FIDO is ready to write

	// FIFO state (per symbol/lane)
	output logic [1:0]            state_out,          // Current state of Dispatcher
	output logic [`N-1:0]         fifo_empty,         // Per FIFO empty signals
	output logic [`N-1:0]         fifo_full,          // Per FIFO full signals

	// Communication with Heap Engines
	input  logic [`N-1:0]         order_in_ready,     // Per-lane ready from each engine: high when they can accept order
	output logic [`N-1:0]         order_out_valid,    // High when order_out holds a real order (not trash)
	output DISPATCH_ORDER [`N-1:0]order_out          // Order presented to engine (consumed when ready)
);
    //////////////////////////////////////////////////////////////////////////////////
    // FSM Controller
    //////////////////////////////////////////////////////////////////////////////////

    // States
    DISPATCH_STATE state, next_state;

    // Next State Logic
    always_comb begin
        // Defaults
        next_state = state;

        // Transitions
        // Note: tansitions to DISPATCH is SW controlled to enable dipatching
        // when FIFOS have less than FIFO_SZ orders.
        unique case (state)
        IDLE:     next_state = sw_begin_write ?  WRITE:IDLE;
        WRITE:    next_state = sw_begin_dispatch ? DISPATCH:WRITE;
        DISPATCH: next_state = (&fifo_empty_i) ? DONE:DISPATCH;
        DONE:     next_state = sw_clear_done ? IDLE : DONE;
        default:; //Handled
        endcase
    end

    // Update State & FIFOs
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end
    
    assign state_out  = state;
    assign fifo_empty = fifo_empty_i;
    assign fifo_full  = fifo_full_i;

    //////////////////////////////////////////////////////////////////////////////////
    // FIFOs
    // There are N number of FIFOs (i.e. 8), one per symbol/stock
    //  - No need to store symbol since each fifo stores only for one fifo.
    //  - No to store the timestamp since the FIFO
    // Note that FIFOs are in BRAM now, so there is a 1 cycle read delay.
    //////////////////////////////////////////////////////////////////////////////////
    localparam int DISP_W = $bits(DISPATCH_ORDER);

    // Connection wires to FIFOs
    logic [`N-1:0] fifo_empty_i;
    logic [`N-1:0] fifo_full_i;
    logic [`N-1:0] fifo_out_valid_i;
    logic [DISP_W-1:0] fifo_out_bits [`N-1:0];
    
    genvar s;
    generate
        for (s = 0; s < `N; s++) begin : g_dispatch_fifo
            dispatch_fifo_bram #(.WIDTH (DISP_W),.DEPTH (`FIFO_SZ)) u_fifo (
                .clk         (clk),
                .rst_n       (rst_n),
                .wr_en       ((state == WRITE) && sw_wr_en[s]),
                .wr_data     (sw_wr_data[s]),
                .full        (fifo_full_i[s]),
                .dispatch_en (state == DISPATCH),
                .out_ready   ((state == DISPATCH) && order_in_ready[s]),
                .out_valid   (fifo_out_valid_i[s]),
                .out_data    (fifo_out_bits[s]),
                .empty       (fifo_empty_i[s]),
                .clear       ((state == DONE) && sw_clear_done)
            );
            
            assign sw_wr_ready[s]   = (state == WRITE)    && !fifo_full_i[s];
            assign order_out_valid[s] = (state == DISPATCH) && fifo_out_valid_i[s];
            assign order_out[s] = DISPATCH_ORDER'(fifo_out_bits[s]);
        end
    endgenerate
endmodule