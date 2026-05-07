module HPTW #(
	parameter PAGE_SIZE 		= 6144,
	parameter VISIBLE_PAGES 	= 240,
	parameter RESERVED_PAGES 	= 16,
	parameter TOTAL_PAGES		= 256,
	parameter PT_BASE		= 32'h80000000
) (
	input logic clk,
	input logic rst_n,

	input logic [31:0] va,
	input logic va_valid,

	input logic [VISIBLE_PAGES-1:0] bitmap_in

	output logic [31:0] pa,
	output logic [1:0] bank_id,
	output logic valid,
	output logic fault,
	output logic busy
);

	localparam PAGE_OFFSET_WIDTH 	= $clog2(VISIBLE_PAGES);
	localparam PAGE_IDX_WIDTH	= VA_WIDTH - PAGE_OFFSET_WIDTH;

	typedef enum logic [1:0] {
		IDLE,
		BUSY,
		DONE,
		FAULT
	} state_t;

	state_t state;
	state_t n_state;
	
	reg [31:0] va_reg;
	reg [PAGE_IDX_WIDTH-1:0] page_idx;
	reg [31:0] pa_reg;
	reg valid_reg;
	reg fault_reg;
	reg [31:0] pt_entry;

	logic [1:0] bank_id_reg;
	logic [1:0] bank_id_latched;

	reg [PA_IDX_WIDTH-1:0] page_table [0:2**PAGE_IDX_WIDTH-1];

	wire [PAGE_IDX_WIDTH-1:0] va_page_idx 		= va[31:PAGE_OFFSET_WIDTH];
	wire [PAGE_OFFSET_WIDTH-1:0] va_page_offset 	= va[PAGE_OFFSET_WIDTH-1:0];

	wire [7:0] pa_page_num 	= pa_reg[PA_WIDTH-1:PAGE_OFFSET_WIDTH];
	
	wire [7:0] bitmap_idx   = pa_page_num - RESERVED_PAGES;
	wire is_visible		= (pa_page_num >= RESERVED_PAGES) && (pa_page_num < TOTAL_PAGES);

	assign pa 	= pa_reg;
	assign bank_id  = bank_id_latched;
	assign valid	= valid_reg;
	assign fault	= fault_reg;
	assign busy	= (state != IDLE);

	always_comb begin
		if(bitmap_idx < 60) begin
			bank_id_reg = 2'd0;
		end else if(bitmap_idx < 120) begin
			bank_id_reg = 2'd1;
		end else if(bitmap_idx < 180) begin
			bank_id_reg = 2'd2;
		end else begin
			bank_id_reg = 2'd3;
		end
	end

	always_comb @(*) begin
		n_state = state;

		case(state)
			IDLE: begin
				if(va_valid) begin
					n_state = BUSY;
				end
			end

			BUSY: begin
				if(is_visible && bitmap_in[bitmap_idx]) begin
					n_state = DONE;
				end else begin
					n_state = FAULT;
				end
			end

			DONE, FAULT: begin
				if(va_valid) begin
					n_state = BUSY;
				end else begin
					n_state = IDLE;
				end
			end
		endcase
	end

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state  		<= IDLE;
			va_reg 		<= 0;
			page_idx	<= 0;
			pa_reg		<= 0;
			valid_reg	<= 1'b0;
			fault_reg	<= 1'b0;
		end else begin
			state <= n_state;

			case(state)
				IDLE: begin
					valid_reg <= 1'b0;
					fault_reg <= 1'b0;

					if(va_valid) begin
						va_reg 		<= va;
						page_idx	<= va_page_idx;
					end
				end

				BUSY: begin
					pt_entry 	<= page_table[page_idx];
					pa_reg		<= page_table[page_idx] + {va_page_offset, 1'b0};
					bank_id_latched <= bank_id_reg;
				end

				DONE: begin
					valid_reg	<= 1'b1;
					fault_reg	<= 1'b0;
				end

				FAULT: begin
					valid_reg	<= 1'b0;
					fault_reg	<= 1'b1;
				end
			endcase
		end
	end

	initial begin
		for(int i = 0; i < 2**PAGE_IDX_WIDTH; i = i + 1) begin
			page_table[i] = ((i + RESERVED_PAGES) << PAGE_OFFSET_WIDTH);
		end
	end

endmodule
