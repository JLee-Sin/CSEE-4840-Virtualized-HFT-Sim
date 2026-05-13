module arbiter(
	input logic 	    clk,
	input logic 	    rst_n,

        input logic 	    ptw0_valid,
	input logic [31:0]  ptw0_va,
	input logic [31:0]  ptw0_pa,
	input logic [1:0]   ptw0_bank_id,
	input logic 	    ptw0_wr,
	input logic [85:0]  ptw0_wdata,

	input logic 	    ptw1_valid,
	input logic [31:0]  ptw1_va,
	input logic [31:0]  ptw1_pa,
	input logic [1:0]   ptw1_bank_id,
	input logic 	    ptw1_wr,
	input logic [85:0]  ptw1_wdata,

	output logic 	    ptw0_accept,
	output logic 	    ptw0_reject,
	output logic 	    ptw1_accept,
	output logic 	    ptw1_reject,

	output logic [85:0] rdata_0,
	output logic [31:0] rdata_va_0,
	output logic 	    rdata_valid_0,
 
	output logic [85:0] rdata_1,
	output logic [31:0] rdata_va_1,
	output logic 	    rdata_valid_1,
 
	output logic [85:0] rdata_2,
	output logic [31:0] rdata_va_2,
	output logic 	    rdata_valid_2,
 
	output logic [85:0] rdata_3,
	output logic [31:0] rdata_va_3,
	output logic 	    rdata_valid_3,

	output logic [31:0] mem_addr_0,
	output logic 	    mem_we_0,
	output logic 	    mem_re_0,
	output logic [85:0] mem_wdata_0,
	input logic  [85:0] mem_rdata_0,
	input logic 	    mem_rdata_valid_0,
	input logic	    mem_wdone_0,
	input logic 	    mem_busy_0,

	output logic [31:0] mem_addr_1,
	output logic 	    mem_we_1,
	output logic 	    mem_re_1,
	output logic [85:0] mem_wdata_1,
	input logic [85:0]  mem_rdata_1,
	input logic 	    mem_rdata_valid_1,
	input logic	    mem_wdone_1,
	input logic 	    mem_busy_1,

	output logic [31:0] mem_addr_2,
	output logic 	    mem_we_2,
	output logic 	    mem_re_2,
	output logic [85:0] mem_wdata_2,
	input logic  [85:0] mem_rdata_2,
	input logic 	    mem_rdata_valid_2,
	input logic 	    mem_wdone_2,
	input logic 	    mem_busy_2,

	output logic [31:0] mem_addr_3,
	output logic 	    mem_we_3,
	output logic 	    mem_re_3,
	output logic [85:0] mem_wdata_3,
	input logic  [85:0] mem_rdata_3,
	input logic 	    mem_rdata_valid_3,
	input logic	    mem_wdone_3,
	input logic 	    mem_busy_3
);

    logic [2:0]   fifo_count   [4];
    logic [3:0]   fifo_full;
    logic [3:0]   fifo_almost_full;
    logic [3:0]   fifo_empty;
    logic [150:0] fifo_rd_data [4];
    logic [3:0]   fifo_rd_en;
 
    assign fifo_full[0]        = (fifo_count[0] == 3'd4);
    assign fifo_full[1]        = (fifo_count[1] == 3'd4);
    assign fifo_full[2]        = (fifo_count[2] == 3'd4);
    assign fifo_full[3]        = (fifo_count[3] == 3'd4);
 
    assign fifo_almost_full[0] = (fifo_count[0] == 3'd3);
    assign fifo_almost_full[1] = (fifo_count[1] == 3'd3);
    assign fifo_almost_full[2] = (fifo_count[2] == 3'd3);
    assign fifo_almost_full[3] = (fifo_count[3] == 3'd3);

    logic same_bank_collision;
    assign same_bank_collision = ptw0_valid && ptw1_valid && (ptw0_bank_id == ptw1_bank_id);
 
    logic rr_priority;
    always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
            rr_priority <= 1'b0;
    	end else if (same_bank_collision && fifo_almost_full[ptw0_bank_id]) begin
            rr_priority <= ~rr_priority;
        end
    end

    logic ptw0_target_full;
    logic ptw1_target_full;
    logic shared_target_almost_full;
 
    assign ptw0_target_full          = fifo_full[ptw0_bank_id];
    assign ptw1_target_full          = fifo_full[ptw1_bank_id];
    assign shared_target_almost_full = fifo_almost_full[ptw0_bank_id];
 
    logic ptw0_can_enqueue, ptw1_can_enqueue;
 
    always_comb begin
        ptw0_can_enqueue = 1'b0;
        ptw1_can_enqueue = 1'b0;
 
        if (same_bank_collision) begin
            if (ptw0_target_full) begin
                ptw0_can_enqueue = 1'b0;
                ptw1_can_enqueue = 1'b0;
            end else if (shared_target_almost_full) begin
                ptw0_can_enqueue = (rr_priority == 1'b0);
                ptw1_can_enqueue = (rr_priority == 1'b1);
            end else begin
                ptw0_can_enqueue = 1'b1;
                ptw1_can_enqueue = 1'b1;
            end
        end else begin
            ptw0_can_enqueue = ptw0_valid && !ptw0_target_full;
            ptw1_can_enqueue = ptw1_valid && !ptw1_target_full;
        end
    end
 
    assign ptw0_accept = ptw0_can_enqueue;
    assign ptw0_reject = ptw0_valid && !ptw0_can_enqueue;
    assign ptw1_accept = ptw1_can_enqueue;
    assign ptw1_reject = ptw1_valid && !ptw1_can_enqueue;
   
    logic [150:0] entry_from_ptw0;
    logic [150:0] entry_from_ptw1;
    assign entry_from_ptw0 = {ptw0_va, ptw0_wr, ptw0_pa, ptw0_wdata};
    assign entry_from_ptw1 = {ptw1_va, ptw1_wr, ptw1_pa, ptw1_wdata};
 
    logic ptw0_writes_b0, ptw1_writes_b0;
    logic ptw0_writes_b1, ptw1_writes_b1;
    logic ptw0_writes_b2, ptw1_writes_b2;
    logic ptw0_writes_b3, ptw1_writes_b3;
 
    assign ptw0_writes_b0 = ptw0_can_enqueue && (ptw0_bank_id == 2'd0);
    assign ptw1_writes_b0 = ptw1_can_enqueue && (ptw1_bank_id == 2'd0);
    assign ptw0_writes_b1 = ptw0_can_enqueue && (ptw0_bank_id == 2'd1);
    assign ptw1_writes_b1 = ptw1_can_enqueue && (ptw1_bank_id == 2'd1);
    assign ptw0_writes_b2 = ptw0_can_enqueue && (ptw0_bank_id == 2'd2);
    assign ptw1_writes_b2 = ptw1_can_enqueue && (ptw1_bank_id == 2'd2);
    assign ptw0_writes_b3 = ptw0_can_enqueue && (ptw0_bank_id == 2'd3);
    assign ptw1_writes_b3 = ptw1_can_enqueue && (ptw1_bank_id == 2'd3);
 
    dual_write_fifo #(.WIDTH(151), .DEPTH(4)) u_fifo_0 (
        .clk(clk), .rst_n(rst_n),
        .wr0_en(ptw0_writes_b0), .wr0_data(entry_from_ptw0),
        .wr1_en(ptw1_writes_b0), .wr1_data(entry_from_ptw1),
        .rd_en(fifo_rd_en[0]),    .rd_data(fifo_rd_data[0]),
        .empty(fifo_empty[0]),    .full(),
        .count(fifo_count[0])
    );
 
    dual_write_fifo #(.WIDTH(151), .DEPTH(4)) u_fifo_1 (
        .clk(clk), .rst_n(rst_n),
        .wr0_en(ptw0_writes_b1), .wr0_data(entry_from_ptw0),
        .wr1_en(ptw1_writes_b1), .wr1_data(entry_from_ptw1),
        .rd_en(fifo_rd_en[1]),    .rd_data(fifo_rd_data[1]),
        .empty(fifo_empty[1]),    .full(),
        .count(fifo_count[1])
    );
 
    dual_write_fifo #(.WIDTH(151), .DEPTH(4)) u_fifo_2 (
        .clk(clk), .rst_n(rst_n),
        .wr0_en(ptw0_writes_b2), .wr0_data(entry_from_ptw0),
        .wr1_en(ptw1_writes_b2), .wr1_data(entry_from_ptw1),
        .rd_en(fifo_rd_en[2]),    .rd_data(fifo_rd_data[2]),
        .empty(fifo_empty[2]),    .full(),
        .count(fifo_count[2])
    );
 
    dual_write_fifo #(.WIDTH(151), .DEPTH(4)) u_fifo_3 (
        .clk(clk), .rst_n(rst_n),
        .wr0_en(ptw0_writes_b3), .wr0_data(entry_from_ptw0),
        .wr1_en(ptw1_writes_b3), .wr1_data(entry_from_ptw1),
        .rd_en(fifo_rd_en[3]),    .rd_data(fifo_rd_data[3]),
        .empty(fifo_empty[3]),    .full(),
        .count(fifo_count[3])
    );
 
    logic [31:0] e_va_0,  e_va_1,  e_va_2,  e_va_3;
    logic        e_wr_0,  e_wr_1,  e_wr_2,  e_wr_3;
    logic [31:0] e_pa_0,  e_pa_1,  e_pa_2,  e_pa_3;
    logic [85:0] e_wd_0,  e_wd_1,  e_wd_2,  e_wd_3;
 
    assign {e_va_0, e_wr_0, e_pa_0, e_wd_0} = fifo_rd_data[0];
    assign {e_va_1, e_wr_1, e_pa_1, e_wd_1} = fifo_rd_data[1];
    assign {e_va_2, e_wr_2, e_pa_2, e_wd_2} = fifo_rd_data[2];
    assign {e_va_3, e_wr_3, e_pa_3, e_wd_3} = fifo_rd_data[3];
 
    logic [85:0] resp_buf_data [4];
    logic [31:0] resp_buf_va   [4];
    logic [3:0]  resp_buf_valid;
    
    logic        va_full  [4];
    logic        va_empty [4];
    logic [31:0] va_dout  [4];
    logic        va_pop   [4];
 
    logic  dispatch_0, dispatch_1, dispatch_2, dispatch_3;
    assign dispatch_0 = !fifo_empty[0] && !mem_busy_0 && !resp_buf_valid[0] && !va_full[0];
    assign dispatch_1 = !fifo_empty[1] && !mem_busy_1 && !resp_buf_valid[1] && !va_full[1];
    assign dispatch_2 = !fifo_empty[2] && !mem_busy_2 && !resp_buf_valid[2] && !va_full[2];
    assign dispatch_3 = !fifo_empty[3] && !mem_busy_3 && !resp_buf_valid[3] && !va_full[3];
 
    assign fifo_rd_en[0] = dispatch_0;
    assign fifo_rd_en[1] = dispatch_1;
    assign fifo_rd_en[2] = dispatch_2;
    assign fifo_rd_en[3] = dispatch_3;
 
    assign mem_addr_0  = e_pa_0;
    assign mem_wdata_0 = e_wd_0;
    assign mem_we_0    = dispatch_0 &&  e_wr_0;
    assign mem_re_0    = dispatch_0 && !e_wr_0;
 
    assign mem_addr_1  = e_pa_1;
    assign mem_wdata_1 = e_wd_1;
    assign mem_we_1    = dispatch_1 &&  e_wr_1;
    assign mem_re_1    = dispatch_1 && !e_wr_1;
 
    assign mem_addr_2  = e_pa_2;
    assign mem_wdata_2 = e_wd_2;
    assign mem_we_2    = dispatch_2 &&  e_wr_2;
    assign mem_re_2    = dispatch_2 && !e_wr_2;
 
    assign mem_addr_3  = e_pa_3;
    assign mem_wdata_3 = e_wd_3;
    assign mem_we_3    = dispatch_3 &&  e_wr_3;
    assign mem_re_3    = dispatch_3 && !e_wr_3;
 
    assign va_pop[0] = (mem_rdata_valid_0 || mem_wdone_0) && !resp_buf_valid[0];
    assign va_pop[1] = (mem_rdata_valid_1 || mem_wdone_1) && !resp_buf_valid[1];
    assign va_pop[2] = (mem_rdata_valid_2 || mem_wdone_2) && !resp_buf_valid[2];
    assign va_pop[3] = (mem_rdata_valid_3 || mem_wdone_3) && !resp_buf_valid[3];

    tracking_fifo #(.WIDTH(32), .DEPTH(8)) u_va_fifo_0 (
        .clk(clk), .rst_n(rst_n),
        .push(dispatch_0), .din(e_va_0),
        .pop(va_pop[0]),   .dout(va_dout[0]),
        .full(va_full[0]), .empty(va_empty[0])
    );

    tracking_fifo #(.WIDTH(32), .DEPTH(8)) u_va_fifo_1 (
        .clk(clk), .rst_n(rst_n),
        .push(dispatch_1), .din(e_va_1),
        .pop(va_pop[1]),   .dout(va_dout[1]),
        .full(va_full[1]), .empty(va_empty[1])
    );

    tracking_fifo #(.WIDTH(32), .DEPTH(8)) u_va_fifo_2 (
        .clk(clk), .rst_n(rst_n),
        .push(dispatch_2), .din(e_va_2),
        .pop(va_pop[2]),   .dout(va_dout[2]),
        .full(va_full[2]), .empty(va_empty[2])
    );

    tracking_fifo #(.WIDTH(32), .DEPTH(8)) u_va_fifo_3 (
        .clk(clk), .rst_n(rst_n),
        .push(dispatch_3), .din(e_va_3),
        .pop(va_pop[3]),   .dout(va_dout[3]),
        .full(va_full[3]), .empty(va_empty[3])
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_buf_data[0]  <= 86'd0;
            resp_buf_va[0]    <= 32'd0;
            resp_buf_valid[0] <= 1'b0;
            resp_buf_data[1]  <= 86'd0;
            resp_buf_va[1]    <= 32'd0;
            resp_buf_valid[1] <= 1'b0;
            resp_buf_data[2]  <= 86'd0;
            resp_buf_va[2]    <= 32'd0;
            resp_buf_valid[2] <= 1'b0;
            resp_buf_data[3]  <= 86'd0;
            resp_buf_va[3]    <= 32'd0;
            resp_buf_valid[3] <= 1'b0;
        end else begin
            if ((mem_rdata_valid_0 || mem_wdone_0) && !resp_buf_valid[0]) begin
                resp_buf_data[0]  <= mem_rdata_valid_0 ? mem_rdata_0 : 86'd0;
                resp_buf_va[0]    <= va_dout[0]; // Fetch the oldest VA from tracking FIFO
                resp_buf_valid[0] <= 1'b1;
            end else if (resp_buf_valid[0]) begin
                resp_buf_valid[0] <= 1'b0;
            end

            if ((mem_rdata_valid_1 || mem_wdone_1) && !resp_buf_valid[1]) begin
                resp_buf_data[1]  <= mem_rdata_valid_1 ? mem_rdata_1 : 86'd0;
                resp_buf_va[1]    <= va_dout[1]; // Fetch the oldest VA from tracking FIFO
                resp_buf_valid[1] <= 1'b1;
            end else if (resp_buf_valid[1]) begin
                resp_buf_valid[1] <= 1'b0;
            end

            if ((mem_rdata_valid_2 || mem_wdone_2) && !resp_buf_valid[2]) begin
                resp_buf_data[2]  <= mem_rdata_valid_2 ? mem_rdata_2 : 86'd0;
                resp_buf_va[2]    <= va_dout[2]; // Fetch the oldest VA from tracking FIFO
                resp_buf_valid[2] <= 1'b1;
            end else if (resp_buf_valid[2]) begin
                resp_buf_valid[2] <= 1'b0;
            end

            if ((mem_rdata_valid_3 || mem_wdone_3) && !resp_buf_valid[3]) begin
                resp_buf_data[3]  <= mem_rdata_valid_3 ? mem_rdata_3 : 86'd0;
                resp_buf_va[3]    <= va_dout[3]; // Fetch the oldest VA from tracking FIFO
                resp_buf_valid[3] <= 1'b1;
            end else if (resp_buf_valid[3]) begin
                resp_buf_valid[3] <= 1'b0;
            end
        end
    end
 
    assign rdata_0       = resp_buf_data[0];
    assign rdata_va_0    = resp_buf_va[0];
    assign rdata_valid_0 = resp_buf_valid[0];
 
    assign rdata_1       = resp_buf_data[1];
    assign rdata_va_1    = resp_buf_va[1];
    assign rdata_valid_1 = resp_buf_valid[1];
 
    assign rdata_2       = resp_buf_data[2];
    assign rdata_va_2    = resp_buf_va[2];
    assign rdata_valid_2 = resp_buf_valid[2];
 
    assign rdata_3       = resp_buf_data[3];
    assign rdata_va_3    = resp_buf_va[3];
    assign rdata_valid_3 = resp_buf_valid[3];
   
endmodule

module dual_write_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 4
) (
    input  logic                          clk,
    input  logic                          rst_n,
 
    input  logic                          wr0_en,
    input  logic [WIDTH-1:0]              wr0_data,
 
    input  logic                          wr1_en,
    input  logic [WIDTH-1:0]              wr1_data,
 
    input  logic                          rd_en,
    output logic [WIDTH-1:0]              rd_data,
 
    output logic                          empty,
    output logic                          full,
    output logic [$clog2(DEPTH+1)-1:0]    count
);
 
    localparam int PTR_WIDTH = $clog2(DEPTH);
    localparam int CNT_WIDTH = $clog2(DEPTH + 1);
 
    logic [WIDTH-1:0]     mem [DEPTH];
    logic [PTR_WIDTH-1:0] wr_ptr, rd_ptr;
    logic [CNT_WIDTH-1:0] count_reg;
 
    assign empty   = (count_reg == 0);
    assign full    = (count_reg == DEPTH);
    assign count   = count_reg;
    assign rd_data = mem[rd_ptr];
 
    logic do_wr0, do_wr1, do_read;
    assign do_wr0  = wr0_en && (count_reg < DEPTH);
    assign do_wr1  = wr1_en && ((count_reg + (do_wr0 ? 1 : 0)) < DEPTH);
    assign do_read = rd_en && !empty;
 
    logic [1:0] num_writes;
    assign num_writes = {1'b0, do_wr0} + {1'b0, do_wr1};
 
    logic [PTR_WIDTH-1:0] wr_ptr_p1, wr_ptr_p2;
    assign wr_ptr_p1 = (wr_ptr == DEPTH-1) ? '0 : wr_ptr + 1'b1;
    assign wr_ptr_p2 = (wr_ptr == DEPTH-1) ? 1'b1 :
                       (wr_ptr == DEPTH-2) ? '0   :
                                             wr_ptr + 2'd2;
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr    <= '0;
            rd_ptr    <= '0;
            count_reg <= '0;
        end else begin
	    if (do_wr0) begin
		       	mem[wr_ptr] <= wr0_data;
	    end

            if (do_wr1) begin
                if (do_wr0) mem[wr_ptr_p1] <= wr1_data;
                else        mem[wr_ptr]    <= wr1_data;
            end
 
            unique case (num_writes)
                2'd0: wr_ptr <= wr_ptr;
                2'd1: wr_ptr <= wr_ptr_p1;
                2'd2: wr_ptr <= wr_ptr_p2;
                default: wr_ptr <= wr_ptr;
            endcase
 
            if (do_read) begin
                rd_ptr <= (rd_ptr == DEPTH-1) ? '0 : rd_ptr + 1'b1;
            end
 
            count_reg <= count_reg + num_writes - {1'b0, do_read};
        end
    end
 
endmodule

module tracking_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic             push,
    input  logic [WIDTH-1:0] din,

    input  logic             pop,
    output logic [WIDTH-1:0] dout,

    output logic             full,
    output logic             empty
);

    localparam int PTR_WIDTH = $clog2(DEPTH);
    localparam int CNT_WIDTH = $clog2(DEPTH + 1);

    logic [WIDTH-1:0]     mem [DEPTH];
    logic [PTR_WIDTH-1:0] wr_ptr, rd_ptr;
    logic [CNT_WIDTH-1:0] count;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);
    assign dout  = mem[rd_ptr];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (push && !full) begin
                mem[wr_ptr] <= din;
                wr_ptr <= (wr_ptr == DEPTH-1) ? '0 : wr_ptr + 1'b1;
            end
            
            if (pop && !empty) begin
                rd_ptr <= (rd_ptr == DEPTH-1) ? '0 : rd_ptr + 1'b1;
            end
            
            case ({push && !full, pop && !empty})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
