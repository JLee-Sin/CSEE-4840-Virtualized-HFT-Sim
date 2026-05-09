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

    typedef enum logic [1:0] {
        IDLE,
        PHASE_01,
        PHASE_2,
        DONE_READ
    } state_t;

    state_t state, next_state;

    logic        latched_is_write;
    logic [5:0]  latched_page;
    logic [5:0]  latched_node;
    logic [85:0] latched_wdata;

    always_comb begin
        next_state = state;
        unique case (state)
            IDLE: begin
                if (mem_re || mem_we)
                    next_state = PHASE_01;
            end
            PHASE_01:  next_state = PHASE_2;
            PHASE_2:   next_state = latched_is_write ? IDLE : DONE_READ;
            DONE_READ: next_state = IDLE;
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
            state <= next_state;
            if (state == IDLE && (mem_re || mem_we)) begin
                latched_is_write <= mem_we;
                latched_page     <= local_page_idx;
                latched_node     <= node_idx;
                latched_wdata    <= mem_wdata;
            end
        end
    end

    logic [7:0]  bram_addr_a, bram_addr_b;
    logic [31:0] bram_wdata_a, bram_wdata_b;

    always_comb begin
        bram_addr_a  = '0;
        bram_addr_b  = '0;
        bram_wdata_a = 32'd0;
        bram_wdata_b = 32'd0;

        unique case (state)
            PHASE_01: begin
                bram_addr_a  = {latched_node, 2'd0};
                bram_addr_b  = {latched_node, 2'd1};
                bram_wdata_a = latched_wdata[31:0];
                bram_wdata_b = latched_wdata[63:32];
            end
            PHASE_2: begin
                bram_addr_a  = {latched_node, 2'd2};
                bram_wdata_a = {10'd0, latched_wdata[85:64]};
            end
            default: ;
        endcase
    end

    logic [59:0] bram_we_a, bram_we_b;
    logic [59:0] bram_re_a, bram_re_b;
    logic [31:0] bram_rdata_a [60];
    logic [31:0] bram_rdata_b [60];

    always_comb begin
        bram_we_a = '0;
        bram_we_b = '0;
        bram_re_a = '0;
        bram_re_b = '0;

        unique case (state)
            PHASE_01: begin
                if (latched_is_write) begin
                    bram_we_a[latched_page] = 1'b1;
                    bram_we_b[latched_page] = 1'b1;
                end else begin
                    bram_re_a[latched_page] = 1'b1;
                    bram_re_b[latched_page] = 1'b1;
                end
            end
            PHASE_2: begin
                if (latched_is_write) bram_we_a[latched_page] = 1'b1;
                else                  bram_re_a[latched_page] = 1'b1;
            end
            default: ;
        endcase
    end

    logic [31:0] active_rdata_a;
    logic [31:0] active_rdata_b;
    assign active_rdata_a = bram_rdata_a[latched_page];
    assign active_rdata_b = bram_rdata_b[latched_page];

    logic [85:0] read_assemble;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_assemble <= 86'd0;
        end else if (!latched_is_write) begin
            if (state == PHASE_2) begin
                read_assemble[31:0]  <= active_rdata_a;
                read_assemble[63:32] <= active_rdata_b;
            end
            if (state == DONE_READ) begin
                read_assemble[85:64] <= active_rdata_a[21:0];
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
                mem_rdata       <= {active_rdata_a[21:0], read_assemble[63:0]};
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

                .we_a    (bram_we_a[p]),
                .re_a    (bram_re_a[p]),
                .addr_a  (bram_addr_a),
                .wdata_a (bram_wdata_a),
                .rdata_a (bram_rdata_a[p]),
				   
                .we_b    (bram_we_b[p]),
                .re_b    (bram_re_b[p]),
                .addr_b  (bram_addr_b),
                .wdata_b (bram_wdata_b),
                .rdata_b (bram_rdata_b[p])
            );
        end
    endgenerate

endmodule


module bram_dp_256x32 (
    input  logic        clk,

    input  logic        we_a,
    input  logic        re_a,
    input  logic [7:0]  addr_a,
    input  logic [31:0] wdata_a,
    output logic [31:0] rdata_a,

    input  logic        we_b,
    input  logic        re_b,
    input  logic [7:0]  addr_b,
    input  logic [31:0] wdata_b,
    output logic [31:0] rdata_b
);

    logic [31:0] mem [256];

    always_ff @(posedge clk) begin
        if (we_a) mem[addr_a] <= wdata_a;
        if (re_a) rdata_a     <= mem[addr_a];
    end

    always_ff @(posedge clk) begin
        if (we_b) mem[addr_b] <= wdata_b;
        if (re_b) rdata_b     <= mem[addr_b];
    end

endmodule
