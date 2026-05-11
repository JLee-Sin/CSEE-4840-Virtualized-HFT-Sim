module mmu (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        req_valid_0, req_valid_1, req_valid_2, req_valid_3,
                        req_valid_4, req_valid_5, req_valid_6, req_valid_7,
    input  logic [31:0] req_va_0, req_va_1, req_va_2, req_va_3,
                        req_va_4, req_va_5, req_va_6, req_va_7,
    input  logic        req_wr_0, req_wr_1, req_wr_2, req_wr_3,
                        req_wr_4, req_wr_5, req_wr_6, req_wr_7,
    input  logic [85:0] req_wdata_0, req_wdata_1, req_wdata_2, req_wdata_3,
                        req_wdata_4, req_wdata_5, req_wdata_6, req_wdata_7,

    output logic        req_ready_0, req_ready_1, req_ready_2, req_ready_3,
                        req_ready_4, req_ready_5, req_ready_6, req_ready_7,

    output logic [85:0] resp_data_0, resp_data_1, resp_data_2, resp_data_3,
                        resp_data_4, resp_data_5, resp_data_6, resp_data_7,
    output logic        resp_valid_0, resp_valid_1, resp_valid_2, resp_valid_3,
                        resp_valid_4, resp_valid_5, resp_valid_6, resp_valid_7,
    output logic        resp_reject_0, resp_reject_1, resp_reject_2, resp_reject_3,
                        resp_reject_4, resp_reject_5, resp_reject_6, resp_reject_7,

    output logic [31:0] mem_addr_0, mem_addr_1, mem_addr_2, mem_addr_3,
    output logic        mem_we_0,   mem_we_1,   mem_we_2,   mem_we_3,
    output logic        mem_re_0,   mem_re_1,   mem_re_2,   mem_re_3,
    output logic [85:0] mem_wdata_0, mem_wdata_1, mem_wdata_2, mem_wdata_3,
    input  logic [85:0] mem_rdata_0, mem_rdata_1, mem_rdata_2, mem_rdata_3,
    input  logic        mem_rdata_valid_0, mem_rdata_valid_1,
                        mem_rdata_valid_2, mem_rdata_valid_3,
    input  logic        mem_busy_0, mem_busy_1, mem_busy_2, mem_busy_3,
    input  logic        mem_wdone_0, mem_wdone_1, mem_wdone_2, mem_wdone_3
);

    logic        req_valid [8];
    logic [31:0] req_va    [8];
    logic        req_wr    [8];
    logic [85:0] req_wdata [8];
    logic        req_ready [8];

    assign req_valid[0] = req_valid_0; assign req_valid[1] = req_valid_1;
    assign req_valid[2] = req_valid_2; assign req_valid[3] = req_valid_3;
    assign req_valid[4] = req_valid_4; assign req_valid[5] = req_valid_5;
    assign req_valid[6] = req_valid_6; assign req_valid[7] = req_valid_7;

    assign req_va[0] = req_va_0; assign req_va[1] = req_va_1;
    assign req_va[2] = req_va_2; assign req_va[3] = req_va_3;
    assign req_va[4] = req_va_4; assign req_va[5] = req_va_5;
    assign req_va[6] = req_va_6; assign req_va[7] = req_va_7;

    assign req_wr[0] = req_wr_0; assign req_wr[1] = req_wr_1;
    assign req_wr[2] = req_wr_2; assign req_wr[3] = req_wr_3;
    assign req_wr[4] = req_wr_4; assign req_wr[5] = req_wr_5;
    assign req_wr[6] = req_wr_6; assign req_wr[7] = req_wr_7;

    assign req_wdata[0] = req_wdata_0; assign req_wdata[1] = req_wdata_1;
    assign req_wdata[2] = req_wdata_2; assign req_wdata[3] = req_wdata_3;
    assign req_wdata[4] = req_wdata_4; assign req_wdata[5] = req_wdata_5;
    assign req_wdata[6] = req_wdata_6; assign req_wdata[7] = req_wdata_7;

    assign req_ready_0 = req_ready[0]; assign req_ready_1 = req_ready[1];
    assign req_ready_2 = req_ready[2]; assign req_ready_3 = req_ready[3];
    assign req_ready_4 = req_ready[4]; assign req_ready_5 = req_ready[5];
    assign req_ready_6 = req_ready[6]; assign req_ready_7 = req_ready[7];

    logic [2:0] rr_pointer;

    logic [3:0] fifo_in_count [2];
    logic       fifo_in_full  [2];
    logic       fifo_in_empty [2];

    assign fifo_in_full[0] = (fifo_in_count[0] >= 4'd7);
    assign fifo_in_full[1] = (fifo_in_count[1] >= 4'd7);

    logic [2:0] first_winner_idx, second_winner_idx;
    logic       first_winner_found, second_winner_found;

    always_comb begin
        first_winner_found  = 1'b0;
        second_winner_found = 1'b0;
        first_winner_idx    = 3'd0;
        second_winner_idx   = 3'd0;

        for (int i = 0; i < 8; i++) begin
            logic [2:0] idx;
            idx = rr_pointer + i[2:0];

            if (req_valid[idx]) begin
                if (!first_winner_found) begin
                    first_winner_idx   = idx;
                    first_winner_found = 1'b1;
                end else if (!second_winner_found) begin
                    second_winner_idx   = idx;
                    second_winner_found = 1'b1;
                end
            end
        end
    end

    logic first_to_fifo1;
    assign first_to_fifo1 = (fifo_in_count[1] < fifo_in_count[0]);

    logic                     requeue_to_0, requeue_to_1;
    logic                     new_can_write_fifo0, new_can_write_fifo1;
    assign new_can_write_fifo0 = !requeue_to_0;
    assign new_can_write_fifo1 = !requeue_to_1;

    logic first_target_has_space, second_target_has_space;
    assign first_target_has_space  = first_to_fifo1
        ? (!fifo_in_full[1] && new_can_write_fifo1)
        : (!fifo_in_full[0] && new_can_write_fifo0);
    assign second_target_has_space = first_to_fifo1
        ? (!fifo_in_full[0] && new_can_write_fifo0)
        : (!fifo_in_full[1] && new_can_write_fifo1);

    logic accept_first, accept_second;
    assign accept_first  = first_winner_found  && first_target_has_space;
    assign accept_second = second_winner_found && second_target_has_space &&
                           accept_first;

    always_comb begin
        for (int i = 0; i < 8; i++) req_ready[i] = 1'b0;
        if (accept_first)  req_ready[first_winner_idx]  = 1'b1;
        if (accept_second) req_ready[second_winner_idx] = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rr_pointer <= 3'd0;
        else if (accept_first && accept_second)
            rr_pointer <= second_winner_idx + 3'd1;
        else if (accept_first)
            rr_pointer <= first_winner_idx + 3'd1;
    end

    localparam int IN_FIFO_WIDTH = 32 + 1 + 86;

    logic [IN_FIFO_WIDTH-1:0] fifo_in_wr_data [2];
    logic [IN_FIFO_WIDTH-1:0] fifo_in_rd_data [2];
    logic                     fifo_in_wr_en   [2];
    logic                     fifo_in_rd_en   [2];

    logic [IN_FIFO_WIDTH-1:0] entry_first, entry_second;
    assign entry_first  = {req_va[first_winner_idx],
                           req_wr[first_winner_idx],
                           req_wdata[first_winner_idx]};
    assign entry_second = {req_va[second_winner_idx],
                           req_wr[second_winner_idx],
                           req_wdata[second_winner_idx]};

    logic [IN_FIFO_WIDTH-1:0] requeue_data_0, requeue_data_1;

    always_comb begin
        fifo_in_wr_en[0]   = 1'b0;
        fifo_in_wr_en[1]   = 1'b0;
        fifo_in_wr_data[0] = '0;
        fifo_in_wr_data[1] = '0;

        if (requeue_to_0) begin
            fifo_in_wr_en[0]   = 1'b1;
            fifo_in_wr_data[0] = requeue_data_0;
        end
        if (requeue_to_1) begin
            fifo_in_wr_en[1]   = 1'b1;
            fifo_in_wr_data[1] = requeue_data_1;
        end

        if (accept_first) begin
            if (first_to_fifo1 && new_can_write_fifo1) begin
                fifo_in_wr_en[1]   = 1'b1;
                fifo_in_wr_data[1] = entry_first;
            end else if (!first_to_fifo1 && new_can_write_fifo0) begin
                fifo_in_wr_en[0]   = 1'b1;
                fifo_in_wr_data[0] = entry_first;
            end
        end
        if (accept_second) begin
            if (first_to_fifo1 && new_can_write_fifo0) begin
                fifo_in_wr_en[0]   = 1'b1;
                fifo_in_wr_data[0] = entry_second;
            end else if (!first_to_fifo1 && new_can_write_fifo1) begin
                fifo_in_wr_en[1]   = 1'b1;
                fifo_in_wr_data[1] = entry_second;
            end
        end
    end

    fifo #(.WIDTH(IN_FIFO_WIDTH)) u_in_fifo_0 (
        .clk(clk), .rst_n(rst_n),
        .wr_en(fifo_in_wr_en[0]), .wr_data(fifo_in_wr_data[0]),
        .rd_en(fifo_in_rd_en[0]), .rd_data(fifo_in_rd_data[0]),
        .empty(fifo_in_empty[0]),
        .count(fifo_in_count[0])
    );

    fifo #(.WIDTH(IN_FIFO_WIDTH)) u_in_fifo_1 (
        .clk(clk), .rst_n(rst_n),
        .wr_en(fifo_in_wr_en[1]), .wr_data(fifo_in_wr_data[1]),
        .rd_en(fifo_in_rd_en[1]), .rd_data(fifo_in_rd_data[1]),
        .empty(fifo_in_empty[1]),
        .count(fifo_in_count[1])
    );

    logic [31:0] ptw0_in_va, ptw1_in_va;
    logic        ptw0_in_wr, ptw1_in_wr;
    logic [85:0] ptw0_in_wdata, ptw1_in_wdata;

    assign {ptw0_in_va, ptw0_in_wr, ptw0_in_wdata} = fifo_in_rd_data[0];
    assign {ptw1_in_va, ptw1_in_wr, ptw1_in_wdata} = fifo_in_rd_data[1];

    logic        ptw0_pa_valid, ptw1_pa_valid;
    logic [31:0] ptw0_pa,       ptw1_pa;
    logic [1:0]  ptw0_bank_id,  ptw1_bank_id;
    logic        ptw0_fault,    ptw1_fault;
    logic        ptw0_busy,     ptw1_busy;

    logic ptw0_va_valid_in, ptw1_va_valid_in;
    assign ptw0_va_valid_in = !fifo_in_empty[0] && !ptw0_busy;
    assign ptw1_va_valid_in = !fifo_in_empty[1] && !ptw1_busy;

    assign fifo_in_rd_en[0] = ptw0_va_valid_in;
    assign fifo_in_rd_en[1] = ptw1_va_valid_in;

    logic [31:0] ptw0_pipe_va, ptw1_pipe_va;
    logic        ptw0_pipe_wr, ptw1_pipe_wr;
    logic [85:0] ptw0_pipe_wdata, ptw1_pipe_wdata;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptw0_pipe_va    <= 32'd0;
            ptw0_pipe_wr    <= 1'b0;
            ptw0_pipe_wdata <= 86'd0;
            ptw1_pipe_va    <= 32'd0;
            ptw1_pipe_wr    <= 1'b0;
            ptw1_pipe_wdata <= 86'd0;
        end else begin
            if (ptw0_va_valid_in) begin
                ptw0_pipe_va    <= ptw0_in_va;
                ptw0_pipe_wr    <= ptw0_in_wr;
                ptw0_pipe_wdata <= ptw0_in_wdata;
            end
            if (ptw1_va_valid_in) begin
                ptw1_pipe_va    <= ptw1_in_va;
                ptw1_pipe_wr    <= ptw1_in_wr;
                ptw1_pipe_wdata <= ptw1_in_wdata;
            end
        end
    end

    logic [63:0]  page_node_free [240];
    logic [239:0] page_has_free;

    logic       ptw0_alloc, ptw1_alloc;
    logic [7:0] ptw0_alloc_page, ptw1_alloc_page;
    logic [5:0] ptw0_alloc_node, ptw1_alloc_node;

    logic [7:0] ptw0_page_select, ptw1_page_select;
    logic [63:0] ptw0_node_slice, ptw1_node_slice;

    assign ptw0_node_slice = page_node_free[ptw0_page_select];
    assign ptw1_node_slice = page_node_free[ptw1_page_select];

    logic same_alloc_collision;
    assign same_alloc_collision = ptw0_alloc && ptw1_alloc &&
                                  (ptw0_alloc_page == ptw1_alloc_page) &&
                                  (ptw0_alloc_node == ptw1_alloc_node);

    logic ptw1_alloc_eff;
    assign ptw1_alloc_eff = ptw1_alloc && !same_alloc_collision;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 240; i++) begin
                page_node_free[i] <= {64{1'b1}};
            end
            page_has_free <= {240{1'b1}};
        end else begin
            if (ptw0_alloc) begin
                page_node_free[ptw0_alloc_page][ptw0_alloc_node] <= 1'b0;
            end
            if (ptw1_alloc_eff) begin
                page_node_free[ptw1_alloc_page][ptw1_alloc_node] <= 1'b0;
            end

            for (int p = 0; p < 240; p++) begin
                logic [63:0] post_clear;
                post_clear = page_node_free[p];
                if (ptw0_alloc && (ptw0_alloc_page == p[7:0]))
                    post_clear[ptw0_alloc_node] = 1'b0;
                if (ptw1_alloc_eff && (ptw1_alloc_page == p[7:0]))
                    post_clear[ptw1_alloc_node] = 1'b0;
                page_has_free[p] <= |post_clear;
            end
        end
    end

    logic [13:0] ptw0_pt_raddr, ptw1_pt_raddr;
    logic [14:0] ptw0_pt_rdata, ptw1_pt_rdata;
    logic        ptw0_pt_we,    ptw1_pt_we;
    logic [13:0] ptw0_pt_waddr, ptw1_pt_waddr;
    logic [14:0] ptw0_pt_wdata, ptw1_pt_wdata;

    logic ptw1_pt_we_eff;
    assign ptw1_pt_we_eff = ptw1_pt_we && !same_alloc_collision;

    // page_table replicated so PTW0 and PTW1 can each read independently.
    // Per copy, two always blocks form Quartus's recognized TDP M10K
    // template (Verilog-style always @posedge clk so the array has multiple
    // drivers legally; SV always_ff requires single driver per LRM).
    //   * Port A: read + write from the owning PTW (R+W same port).
    //   * Port B: write-only from the other PTW.
    // The HPTW's invariant guarantees pt_raddr == pt_waddr when pt_we
    // (HPTW.sv: pt_we only fires in ALLOCATE; in non-IDLE pt_raddr =
    // latched_key = pt_waddr), so Port A's RDW collapses to a same-address
    // access.

    (* ramstyle = "M10K, no_rw_check" *)
    logic [14:0] page_table_copy_a [16384] = '{default:15'd0};
    (* ramstyle = "M10K, no_rw_check" *)
    logic [14:0] page_table_copy_b [16384] = '{default:15'd0};

    // Single muxed address per port (canonical Quartus TDP template:
    // ram[addr] used as both write target and read source on each port).
    // The HPTW invariant guarantees pt_raddr == pt_waddr when pt_we, so
    // selecting waddr on write cycles is semantically identical.
    wire [13:0] ptw0_pt_addr = ptw0_pt_we      ? ptw0_pt_waddr : ptw0_pt_raddr;
    wire [13:0] ptw1_pt_addr = ptw1_pt_we_eff  ? ptw1_pt_waddr : ptw1_pt_raddr;

    // page_table_copy_a: Port A = PTW0 (R+W), Port B = PTW1 (W only)
    always @(posedge clk) begin
        if (ptw0_pt_we) page_table_copy_a[ptw0_pt_addr] <= ptw0_pt_wdata;
        ptw0_pt_rdata <= page_table_copy_a[ptw0_pt_addr];
    end
    always @(posedge clk) begin
        if (ptw1_pt_we_eff) page_table_copy_a[ptw1_pt_waddr] <= ptw1_pt_wdata;
    end

    // page_table_copy_b: Port A = PTW1 (R+W), Port B = PTW0 (W only)
    always @(posedge clk) begin
        if (ptw1_pt_we_eff) page_table_copy_b[ptw1_pt_addr] <= ptw1_pt_wdata;
        ptw1_pt_rdata <= page_table_copy_b[ptw1_pt_addr];
    end
    always @(posedge clk) begin
        if (ptw0_pt_we) page_table_copy_b[ptw0_pt_waddr] <= ptw0_pt_wdata;
    end

    HPTW #(.LOW_FIRST(1'b1)) u_ptw0 (
        .clk                (clk),
        .rst_n              (rst_n),
        .va_valid           (ptw0_va_valid_in),
        .va                 (ptw0_in_va),
        .pa_valid           (ptw0_pa_valid),
        .pa                 (ptw0_pa),
        .bank_id            (ptw0_bank_id),
        .fault              (ptw0_fault),
        .busy               (ptw0_busy),
        .pt_raddr           (ptw0_pt_raddr),
        .pt_rdata           (ptw0_pt_rdata),
        .pt_we              (ptw0_pt_we),
        .pt_waddr           (ptw0_pt_waddr),
        .pt_wdata           (ptw0_pt_wdata),
        .page_has_free      (page_has_free),
        .node_free_slice    (ptw0_node_slice),
        .alloc_page_select  (ptw0_page_select),
        .alloc              (ptw0_alloc),
        .alloc_page_idx     (ptw0_alloc_page),
        .alloc_node_idx     (ptw0_alloc_node)
    );

    HPTW #(.LOW_FIRST(1'b0)) u_ptw1 (
        .clk                (clk),
        .rst_n              (rst_n),
        .va_valid           (ptw1_va_valid_in),
        .va                 (ptw1_in_va),
        .pa_valid           (ptw1_pa_valid),
        .pa                 (ptw1_pa),
        .bank_id            (ptw1_bank_id),
        .fault              (ptw1_fault),
        .busy               (ptw1_busy),
        .pt_raddr           (ptw1_pt_raddr),
        .pt_rdata           (ptw1_pt_rdata),
        .pt_we              (ptw1_pt_we),
        .pt_waddr           (ptw1_pt_waddr),
        .pt_wdata           (ptw1_pt_wdata),
        .page_has_free      (page_has_free),
        .node_free_slice    (ptw1_node_slice),
        .alloc_page_select  (ptw1_page_select),
        .alloc              (ptw1_alloc),
        .alloc_page_idx     (ptw1_alloc_page),
        .alloc_node_idx     (ptw1_alloc_node)
    );

    logic ptw1_pa_valid_eff, ptw1_fault_eff;
    assign ptw1_pa_valid_eff = ptw1_pa_valid && !same_alloc_collision;
    assign ptw1_fault_eff    = ptw1_fault    || same_alloc_collision;

    logic        arb_ptw0_valid, arb_ptw1_valid;
    logic [31:0] arb_ptw0_va,    arb_ptw1_va;
    logic [31:0] arb_ptw0_pa,    arb_ptw1_pa;
    logic [1:0]  arb_ptw0_bank,  arb_ptw1_bank;
    logic        arb_ptw0_wr,    arb_ptw1_wr;
    logic [85:0] arb_ptw0_wdata, arb_ptw1_wdata;
    logic        arb_ptw0_accept, arb_ptw0_reject;
    logic        arb_ptw1_accept, arb_ptw1_reject;

    assign arb_ptw0_valid = ptw0_pa_valid;
    assign arb_ptw0_va    = ptw0_pipe_va;
    assign arb_ptw0_pa    = ptw0_pa;
    assign arb_ptw0_bank  = ptw0_bank_id;
    assign arb_ptw0_wr    = ptw0_pipe_wr;
    assign arb_ptw0_wdata = ptw0_pipe_wdata;

    assign arb_ptw1_valid = ptw1_pa_valid_eff;
    assign arb_ptw1_va    = ptw1_pipe_va;
    assign arb_ptw1_pa    = ptw1_pa;
    assign arb_ptw1_bank  = ptw1_bank_id;
    assign arb_ptw1_wr    = ptw1_pipe_wr;
    assign arb_ptw1_wdata = ptw1_pipe_wdata;

    logic [85:0] arb_rdata_0, arb_rdata_1, arb_rdata_2, arb_rdata_3;
    logic [31:0] arb_rdata_va_0, arb_rdata_va_1, arb_rdata_va_2, arb_rdata_va_3;
    logic        arb_rdata_valid_0, arb_rdata_valid_1, arb_rdata_valid_2, arb_rdata_valid_3;

    assign requeue_to_0   = arb_ptw0_reject;
    assign requeue_to_1   = arb_ptw1_reject;
    assign requeue_data_0 = {ptw0_pipe_va, ptw0_pipe_wr, ptw0_pipe_wdata};
    assign requeue_data_1 = {ptw1_pipe_va, ptw1_pipe_wr, ptw1_pipe_wdata};

    arbiter u_arbiter (
        .clk               (clk),
        .rst_n             (rst_n),

        .ptw0_valid        (arb_ptw0_valid),
        .ptw0_va           (arb_ptw0_va),
        .ptw0_pa           (arb_ptw0_pa),
        .ptw0_bank_id      (arb_ptw0_bank),
        .ptw0_wr           (arb_ptw0_wr),
        .ptw0_wdata        (arb_ptw0_wdata),

        .ptw1_valid        (arb_ptw1_valid),
        .ptw1_va           (arb_ptw1_va),
        .ptw1_pa           (arb_ptw1_pa),
        .ptw1_bank_id      (arb_ptw1_bank),
        .ptw1_wr           (arb_ptw1_wr),
        .ptw1_wdata        (arb_ptw1_wdata),

        .ptw0_accept       (arb_ptw0_accept),
        .ptw0_reject       (arb_ptw0_reject),
        .ptw1_accept       (arb_ptw1_accept),
        .ptw1_reject       (arb_ptw1_reject),

        .rdata_0           (arb_rdata_0),
        .rdata_va_0        (arb_rdata_va_0),
        .rdata_valid_0     (arb_rdata_valid_0),
        .rdata_1           (arb_rdata_1),
        .rdata_va_1        (arb_rdata_va_1),
        .rdata_valid_1     (arb_rdata_valid_1),
        .rdata_2           (arb_rdata_2),
        .rdata_va_2        (arb_rdata_va_2),
        .rdata_valid_2     (arb_rdata_valid_2),
        .rdata_3           (arb_rdata_3),
        .rdata_va_3        (arb_rdata_va_3),
        .rdata_valid_3     (arb_rdata_valid_3),

        .mem_addr_0        (mem_addr_0),
        .mem_we_0          (mem_we_0),
        .mem_re_0          (mem_re_0),
        .mem_wdata_0       (mem_wdata_0),
        .mem_rdata_0       (mem_rdata_0),
        .mem_rdata_valid_0 (mem_rdata_valid_0),
	.mem_wdone_0	   (mem_wdone_0),
        .mem_busy_0        (mem_busy_0),

        .mem_addr_1        (mem_addr_1),
        .mem_we_1          (mem_we_1),
        .mem_re_1          (mem_re_1),
        .mem_wdata_1       (mem_wdata_1),
        .mem_rdata_1       (mem_rdata_1),
        .mem_rdata_valid_1 (mem_rdata_valid_1),
	.mem_wdone_1	   (mem_wdone_1),
        .mem_busy_1        (mem_busy_1),

        .mem_addr_2        (mem_addr_2),
        .mem_we_2          (mem_we_2),
        .mem_re_2          (mem_re_2),
        .mem_wdata_2       (mem_wdata_2),
        .mem_rdata_2       (mem_rdata_2),
        .mem_rdata_valid_2 (mem_rdata_valid_2),
	.mem_wdone_2       (mem_wdone_2),
        .mem_busy_2        (mem_busy_2),

        .mem_addr_3        (mem_addr_3),
        .mem_we_3          (mem_we_3),
        .mem_re_3          (mem_re_3),
        .mem_wdata_3       (mem_wdata_3),
        .mem_rdata_3       (mem_rdata_3),
        .mem_rdata_valid_3 (mem_rdata_valid_3),
	.mem_wdone_3	   (mem_wdone_3),
        .mem_busy_3        (mem_busy_3)
    );

    logic [85:0] resp_data    [8];
    logic        resp_valid   [8];

    always_comb begin
        for (int i = 0; i < 8; i++) begin
            resp_data[i]  = 86'd0;
            resp_valid[i] = 1'b0;
        end

        if (arb_rdata_valid_0) begin
            resp_data[arb_rdata_va_0[31:29]]  = arb_rdata_0;
            resp_valid[arb_rdata_va_0[31:29]] = 1'b1;
        end
        if (arb_rdata_valid_1) begin
            resp_data[arb_rdata_va_1[31:29]]  = arb_rdata_1;
            resp_valid[arb_rdata_va_1[31:29]] = 1'b1;
        end
        if (arb_rdata_valid_2) begin
            resp_data[arb_rdata_va_2[31:29]]  = arb_rdata_2;
            resp_valid[arb_rdata_va_2[31:29]] = 1'b1;
        end
        if (arb_rdata_valid_3) begin
            resp_data[arb_rdata_va_3[31:29]]  = arb_rdata_3;
            resp_valid[arb_rdata_va_3[31:29]] = 1'b1;
        end
    end

    assign resp_data_0  = resp_data[0];  assign resp_valid_0 = resp_valid[0];
    assign resp_data_1  = resp_data[1];  assign resp_valid_1 = resp_valid[1];
    assign resp_data_2  = resp_data[2];  assign resp_valid_2 = resp_valid[2];
    assign resp_data_3  = resp_data[3];  assign resp_valid_3 = resp_valid[3];
    assign resp_data_4  = resp_data[4];  assign resp_valid_4 = resp_valid[4];
    assign resp_data_5  = resp_data[5];  assign resp_valid_5 = resp_valid[5];
    assign resp_data_6  = resp_data[6];  assign resp_valid_6 = resp_valid[6];
    assign resp_data_7  = resp_data[7];  assign resp_valid_7 = resp_valid[7];

    logic resp_reject [8];

    always_comb begin
        for (int i = 0; i < 8; i++) resp_reject[i] = 1'b0;

        if (ptw0_fault) begin
            resp_reject[ptw0_pipe_va[31:29]] = 1'b1;
        end
        if (ptw1_fault_eff) begin
            resp_reject[ptw1_pipe_va[31:29]] = 1'b1;
        end
    end

    assign resp_reject_0 = resp_reject[0];
    assign resp_reject_1 = resp_reject[1];
    assign resp_reject_2 = resp_reject[2];
    assign resp_reject_3 = resp_reject[3];
    assign resp_reject_4 = resp_reject[4];
    assign resp_reject_5 = resp_reject[5];
    assign resp_reject_6 = resp_reject[6];
    assign resp_reject_7 = resp_reject[7];

endmodule

module fifo #(
    parameter int WIDTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,

    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,

    output logic             empty,
    output logic [3:0]       count
);

    logic [WIDTH-1:0] mem [8];
    logic [2:0]       wr_ptr, rd_ptr;
    logic [3:0]       count_reg;
    logic             full;

    assign empty   = (count_reg == 4'd0);
    assign full    = (count_reg == 4'd8);
    assign count   = count_reg;
    assign rd_data = mem[rd_ptr];

    logic do_write, do_read;
    assign do_write = wr_en && !full;
    assign do_read  = rd_en && !empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr    <= 3'd0;
            rd_ptr    <= 3'd0;
            count_reg <= 4'd0;
        end else begin
            if (do_write) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= wr_ptr + 3'd1;
            end
            if (do_read) begin
                rd_ptr <= rd_ptr + 3'd1;
            end
            unique case ({do_write, do_read})
                2'b10:   count_reg <= count_reg + 4'd1;
                2'b01:   count_reg <= count_reg - 4'd1;
                default: count_reg <= count_reg;
            endcase
        end
    end

endmodule
