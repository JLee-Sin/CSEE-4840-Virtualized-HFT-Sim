module mem_bank #(
    parameter int BANK_ID = 0
) (
    input logic 	clk,
    input logic 	rst_n,

    input logic [31:0] 	mem_addr,
    input logic 	mem_we,
    input logic 	mem_re,
    input logic [85:0] 	mem_wdata,
   
    output logic [85:0] mem_rdata,
    output logic 	mem_rdata_valid,
    output logic	mem_wdone,
    output logic 	mem_busy
);
    localparam int FIRST_PAGE_FOR_BANK = 16 + BANK_ID * 60;

    logic [18:0] global_page;
    logic [5:0]  local_page_idx;
    logic [5:0]  node_idx;

    assign global_page    = mem_addr[31:13];
    assign local_page_idx = global_page[5:0] - FIRST_PAGE_FOR_BANK[5:0];
    assign node_idx       = mem_addr[9:4];

    typedef enum logic [2:0] {
        IDLE,
	PHASE_0,
        PHASE_1,
        PHASE_2,
        DONE_READ
    } state_t;

    state_t state, n_state;

    logic        latched_is_write;
    logic [5:0]  latched_page;
    logic [5:0]  latched_node;
    logic [85:0] latched_wdata;

    always_comb begin
        n_state = state;
        unique case (state)
            IDLE: begin
                if (mem_re || mem_we)
                    n_state = PHASE_0;
            end
	    PHASE_0:   n_state = PHASE_1;
            PHASE_1:   n_state = PHASE_2;
            PHASE_2:   n_state = latched_is_write ? IDLE : DONE_READ;
            DONE_READ: n_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            latched_is_write <= 1'b0;
            latched_page     <= 6'd0;
            latched_node     <= 6'd0;
            latched_wdata    <= 86'd0;
        end else begin
            state <= n_state;
            if (state == IDLE && (mem_re || mem_we)) begin
                latched_is_write <= mem_we;
                latched_page     <= local_page_idx;
                latched_node     <= node_idx;
                latched_wdata    <= mem_wdata;
            end
        end
    end

    logic [7:0]  bram_waddr, bram_raddr;
    logic [31:0] bram_wdata;

    always_comb begin
        bram_waddr  = '0;
        bram_raddr  = '0;
        bram_wdata  = 32'd0;

        unique case (state)
	    PHASE_0: begin
	       bram_waddr  = {latched_node, 2'd0};
	       bram_raddr  = {latched_node, 2'd0};
	       bram_wdata  = latched_wdata[31:0];
	    end
            PHASE_1: begin
                bram_waddr = {latched_node, 2'd1};
                bram_raddr = {latched_node, 2'd1};
                bram_wdata = latched_wdata[63:32];
            end
            PHASE_2: begin
                bram_waddr = {latched_node, 2'd2};
	        bram_raddr = {latched_node, 2'd2};
                bram_wdata = {10'd0, latched_wdata[85:64]};
            end
            default: ;
        endcase
    end

    logic [59:0] bram_we;
    logic [59:0] bram_re;
    logic [31:0] bram_rdata [60];

    always_comb begin
        bram_we = '0;
        bram_re = '0;

        if((state == PHASE_0) || (state == PHASE_1) || (state == PHASE_2)) begin
	   if (latched_is_write) begin
	       bram_we[latched_page] = 1'b1;
	   end else begin
	       bram_re[latched_page] = 1'b1; 
	   end
	end
    end

    logic [31:0] active_rdata;
    assign active_rdata = bram_rdata[latched_page];

    logic [85:0] read_assemble;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_assemble <= 86'd0;
        end else if (!latched_is_write) begin
	    if (state == PHASE_1) begin
		read_assemble[31:0] <= active_rdata;
	    end
            if (state == PHASE_2) begin
                read_assemble[63:32]  <= active_rdata;
            end
            if (state == DONE_READ) begin
                read_assemble[85:64] <= active_rdata[21:0];
            end
        end
    end

    assign mem_busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rdata       <= 86'd0;
            mem_rdata_valid <= 1'b0;
	    mem_wdone	    <= 1'b0;
        end else begin
            mem_rdata_valid <= 1'b0;
	    mem_wdone	    <= 1'b0;
            
	    if (state == DONE_READ && !latched_is_write) begin
                mem_rdata       <= {active_rdata[21:0], read_assemble[63:0]};
                mem_rdata_valid <= 1'b1;
            end

	    if (state == PHASE_2 && latched_is_write) begin
		mem_wdone <= 1'b1;
	    end
        end
    end

    genvar p;
    generate
        for (p = 0; p < 60; p++) begin : gen_brams
            bram_dp_256x32 u_bram (
                .clk     (clk),

                .we    (bram_we[p]),
                .re    (bram_re[p]),
		.waddr (bram_waddr),
                .raddr (bram_raddr),
                .wdata (bram_wdata),
                .rdata (bram_rdata[p])
            );
        end
    endgenerate

endmodule


module bram_dp_256x32 (
    input  logic        clk,

    input  logic        we,
    input  logic        re,
    input  logic [7:0]  waddr,
    input  logic [7:0]  raddr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata
);
    (* ramstyle = "no_rw_check, M10K" *)
    logic [31:0] mem [0:255];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata      <= mem[raddr];
    end

endmodule
