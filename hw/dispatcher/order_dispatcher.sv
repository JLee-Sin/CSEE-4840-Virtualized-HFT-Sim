//////////////////////////////////////////////////////////////////////////////////
// Engineers: Carlos Espinoza
// Create Date: 04/07/2026
// Project Name: Virtualized High Frequence Trading (HFT) Simulator
// Design Name: Input Interface & Order Dispatcher 
// Module:  steer_logic 
// Description:
//      This is a simple file to define parameters and structs that will be used 
//      across the various modules in this project. 
//
// Revision: 05/08/2026
//////////////////////////////////////////////////////////////////////////////////
`include "verilog/sys_defs.svh"

module order_dispatcher(
    input logic 	                    clk,
	input logic 	                    rst_n,

	// Interface with software harness
	input logic  [95:0]                 bus_in,
	output logic [`WORD_WIDTH-1:0]      fifo_tail_addr, // address (TODO)

	// FIFO state
	output logic                        fifo_empty,     // When all the FIFOs are filled
	output logic                        fifo_full,      // When all the FIFOs are empty (tail = head)

	// Dispatcher state
	output logic [1:0]                  state_out,
	
	// Output to Heap Engines
	output logic [`SYM_NUM-1:0]          order_out_valid,    // High when order_out is a valid order
	output DISPATCH_ORDER [`SYM_NUM-1:0] order_out          // Order being pop from front of FIFO
);

//////////////////////////////////////////////////////////////////////////////////
// FIFOs
// There are 8 FIFO, one per symbol/stock
//  - No need to store symbol since each fifo stores only for one fifo.
//  - No to sotre the timestamp since the FIFO
//////////////////////////////////////////////////////////////////////////////////

// FIFOs (aka Shift Registers)
//  - fifo[s][i] : entry i of FIFO for symbol/lane s
DISPATCH_ORDER fifo [`SYM_NUM-1:0][`FIFO_SZ-1:0];
localparam int FIFO_PTR_W = $clog2(`FIFO_SZ + 1);
logic [FIFO_PTR_W-1:0] fifo_tail [`SYM_NUM-1:0];

//////////////////////////////////////////////////////////////////////////////////
// FSM Controller
//////////////////////////////////////////////////////////////////////////////////

DISPATCH_STATE state, next_state;

// Next State Logic 
always_comb begin
    // Defaults
    next_state = IDLE;

    unique case (state)
      IDLE: ; // Wait for signal from 
      WRITE: next_state = fifo_full ? DISPATCH:WRITE;
      DISPATCH: next_state = fifo_empty ? DONE:DISPATCH;
      DONE: ; // Wait for the rest of things to finish
      default:; //Handled
    endcase
end

// Update State
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      for (int s = 0; s < `SYM_NUM; s++) fifo_tail[s] <= '0; // Reset tails
      
    end else begin
      state <= next_state;

      // Issue heads of FIFOs
      if (state == DISPATCH) begin
        for (int s = 0; s < `SYM_NUM; s++) begin
          if (fifo_tail[s] != '0) begin
            // Shift everything below and at tail 
            for (int i = 0; i < (`FIFO_SZ-1); i++) begin
              if (i < (fifo_tail[s]-1))
                fifo[s][i] <= fifo[s][i+1];
            end

            // Update tail pointer 
            fifo_tail[s] <= fifo_tail[s] - 1'b1;
          end
        end
      end
    end
  end

// Output Logic 
always_comb begin
    // Defaults
    state_out        = state;
    order_out_valid  = '0;
    order_out        = '0;

    fifo_tail_addr   = '0; // TODO: driven by write path
    fifo_empty       = 1'b1;
    fifo_full        = 1'b1;

    // Compute aggregate empty/full
    for (int s = 0; s < `SYM_NUM; s++) begin
        fifo_empty &= (fifo_tail[s] == '0);
        fifo_full  &= (fifo_tail[s] == `FIFO_SZ);
    end

    unique case (state)
      IDLE: begin
        // Doing nothing
      end

      WRITE: begin
        // Writing path not implemented yet
      end

      DISPATCH: begin
        // Issue one order per lane per cycle (if available)
        for (int s = 0; s < `SYM_NUM; s++) begin
            if (fifo_tail[s] != '0) begin
                order_out_valid[s] = 1'b1;
                order_out[s]       = fifo[s][0];
            end
        end
      end

      DONE: begin
        // Done dispatching
      end

      default:; //Handled
    endcase
  end

endmodule
