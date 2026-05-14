module HPTW #(
    parameter LOW_FIRST = 1'b1
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         va_valid,
    input  logic [31:0]  va,

    output logic         pa_valid,
    output logic [31:0]  pa,
    output logic [1:0]   bank_id,
    output logic         fault,
    output logic         busy,

    output logic [13:0]  pt_raddr,
    input  logic [14:0]  pt_rdata,

    output logic         pt_we,
    output logic [13:0]  pt_waddr,
    output logic [14:0]  pt_wdata,

    input  logic         alloc_avail,
    input  logic [7:0]   alloc_page_in,
    input  logic [5:0]   alloc_node_in,

    output logic         alloc,
    output logic [7:0]   alloc_page_idx,
    output logic [5:0]   alloc_node_idx
);
    logic [13:0] pt_key;
    assign pt_key = {va[31:29], va[10:0]};

    typedef enum logic [2:0] {
        IDLE,
        LOOKUP,
        ALLOCATE,
        DONE,
        FAULT
    } state_t;

    state_t state, n_state;

    logic [13:0] latched_key;

    logic       lookup_valid_bit;
    logic [7:0] lookup_page_idx;
    logic [5:0] lookup_node_idx;
    assign lookup_valid_bit = pt_rdata[14];
    assign lookup_page_idx  = pt_rdata[13:6];
    assign lookup_node_idx  = pt_rdata[5:0];

    logic [7:0] selected_visible_page;
    logic [5:0] selected_node;
    always_comb begin
        if (state == LOOKUP) begin
            selected_visible_page = lookup_page_idx;
            selected_node         = lookup_node_idx;
        end else begin
            selected_visible_page = alloc_page_in;
            selected_node         = alloc_node_in;
        end
    end

    logic [7:0] selected_pa_page;
    assign selected_pa_page = selected_visible_page + 8'd16;

    logic [31:0] computed_pa;
    assign computed_pa = {11'd0, selected_pa_page, 3'd0, selected_node, 4'd0};

    logic [1:0] computed_bank_id;
    always_comb begin
        if      (selected_visible_page < 8'd60)  computed_bank_id = 2'd0;
        else if (selected_visible_page < 8'd120) computed_bank_id = 2'd1;
        else if (selected_visible_page < 8'd180) computed_bank_id = 2'd2;
        else                                     computed_bank_id = 2'd3;
    end

    always_comb begin
        n_state = state;
        unique case (state)
            IDLE:     if (va_valid) n_state = LOOKUP;
            LOOKUP:   if (lookup_valid_bit) n_state = DONE; else n_state = ALLOCATE;
            ALLOCATE: if (alloc_avail) n_state = DONE; else n_state = FAULT;
            DONE:     n_state = IDLE;
            FAULT:    n_state = IDLE;
        endcase
    end

    logic [31:0] pa_reg;
    logic        pa_valid_reg;
    logic [1:0]  bank_id_reg;
    logic        fault_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            latched_key  <= 14'd0;
            pa_reg       <= 32'd0;
            pa_valid_reg <= 1'b0;
            bank_id_reg  <= 2'd0;
            fault_reg    <= 1'b0;
        end else begin
            state        <= n_state;
            pa_valid_reg <= 1'b0;
            fault_reg    <= 1'b0;

            if (state == IDLE && va_valid)
                latched_key <= pt_key;

            if (n_state == DONE) begin
                pa_reg       <= computed_pa;
                bank_id_reg  <= computed_bank_id;
                pa_valid_reg <= 1'b1;
            end

            if (n_state == FAULT)
                fault_reg <= 1'b1;
        end
    end

    always_comb begin
        if (state == IDLE && va_valid) pt_raddr = pt_key;
        else                           pt_raddr = latched_key;
    end

    assign pt_we    = (state == ALLOCATE) && alloc_avail;
    assign pt_waddr = latched_key;
    assign pt_wdata = {1'b1, alloc_page_in, alloc_node_in};

    assign alloc          = (state == ALLOCATE) && alloc_avail;
    assign alloc_page_idx = alloc_page_in;
    assign alloc_node_idx = alloc_node_in;

    assign pa       = pa_reg;
    assign pa_valid = pa_valid_reg;
    assign bank_id  = bank_id_reg;
    assign fault    = fault_reg;
    assign busy     = (state != IDLE);

endmodule
