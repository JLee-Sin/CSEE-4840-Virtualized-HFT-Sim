//////////////////////////////////////////////////////////////////////////////////
// Engineers: Carlos Espinoza
// Create Date: 04/07/2026
// Project Name: Virtualized High Frequence Trading (HFT) Simulator
// Design Name: FIFO BRAM
// Description:
//      FIFO BRAM module for storing dispatch orders in BRAM.
//
// Revision: 05/11/2026
//////////////////////////////////////////////////////////////////////////////////

module dispatch_fifo_bram #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 1660,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    input  logic             clk,
    input  logic             rst_n,

    // Write Interface
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    output logic             full,

    // Dispatche/Read Interface
    input  logic             dispatch_en,
    input  logic             out_ready,
    output logic             out_valid,
    output logic [WIDTH-1:0] out_data,
    output logic             empty,

    // Clear batch
    input  logic             clear
);
    // One BRAM-backed storage array per lane
    (* ramstyle = "no_rw_check, M10K" *)
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    
    // Pointers:
    // wr_ptr = next location to write
    // rd_ptr = next location still in RAM (not prefetched)
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    
    // Number of entries still resident in RAM only
    logic [CNT_W-1:0] mem_count;
    
    // One read has been launched; data will appear in out_data after the BRAM read
    logic rd_pending;
    logic [CNT_W-1:0] occupancy;
    logic             do_write, do_launch_read, do_consume;

    // Total logical occupancy includes:
    //   - entries still in RAM
    //   - one buffered output word (out_valid)
    //   - one in-flight BRAM read (rd_pending)
    assign occupancy = mem_count
                     + {{CNT_W-1{1'b0}}, out_valid}
                     + {{CNT_W-1{1'b0}}, rd_pending};
    assign empty = (occupancy == CNT_W'(0));
    assign full  = (occupancy == CNT_W'(DEPTH));
    assign do_write = wr_en && !full;

    // Hold current output stable while consumer is not ready.
    assign do_consume = dispatch_en && out_valid && out_ready;

    // Launch a BRAM read when:
    //   - we are dispatching
    //   - no read already in flight
    //   - there is still data in RAM
    //   - output register is free now, or will be freed this cycle by consume
    assign do_launch_read = dispatch_en && !rd_pending
                         && (mem_count != CNT_W'(0))
                         && (!out_valid || out_ready);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr     <= '0;
            rd_ptr     <= '0;
            mem_count  <= '0;
            rd_pending <= 1'b0;
            out_valid  <= 1'b0;
            out_data   <= '0;
        end else if (clear) begin
            wr_ptr     <= '0;
            rd_ptr     <= '0;
            mem_count  <= '0;
            rd_pending <= 1'b0;
            out_valid  <= 1'b0;
            out_data   <= '0;
        end else begin
            // Write
            if (do_write) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= wr_ptr + PTR_W'(1);
            end
            
            // Do synchronous BRAM read
            if (do_launch_read) begin
                out_data   <= mem[rd_ptr];
                rd_ptr     <= rd_ptr + PTR_W'(1);
                rd_pending <= 1'b1;
            end
            
            // Place data in out_data register after the cycle wait
            if (rd_pending) begin
                out_valid  <= 1'b1;
                rd_pending <= 1'b0;
            end
            
            // Indicate data is not yet ready after engine takes it.
            if (do_consume) begin
                out_valid <= 1'b0;
            end
            // Count of entries still inside RAM storage
            unique case ({do_write, do_launch_read})
                2'b10:   mem_count <= mem_count + CNT_W'(1);
                2'b01:   mem_count <= mem_count - CNT_W'(1);
                default: mem_count <= mem_count;
            endcase
        end
    end
endmodule