`timescale 1ns/1ps
// BTB common dense INT8 GEMM baseline. Configuration latched at start.
// Profiling events are public so a replacement module can have variable latency.
// Integration top: Set 4 control/loader, bank-aware NM4, and Compute v2.
module gemm_top #(parameter PE_ROWS=4,PE_COLS=4,MAX_M=64,MAX_N=128,MAX_K=1024,
    // ---- Set 4 settings (one place) ----
    parameter NBANK=4,              // ACC banks = row tiles computed together (1 = no output blocking)
    parameter USE_A_REUSE=1, USE_B_REUSE=1,
    parameter USE_B_SHARE=1,        // banks 1.. reuse bank 0's B packet
    parameter NSLOTS=4,
    parameter ABUF_DEPTH=4096,      // A reuse buffer entries x 4 B (holds NBANK x K; 4096 = 16 KB = K 1024)
    parameter BBUF_DEPTH=1024,      // B reuse buffer entries x 4 B (holds G x K)
    parameter BKW=(NBANK>1)?$clog2(NBANK):1)(
    input clk,rst,start,
    input [15:0] cfg_m,cfg_n,cfg_k,
    output busy,done,error,

    output mem_req_valid,
    input mem_req_ready,
    output mem_req_is_b,
    output [31:0] mem_req_addr,

    input mem_rsp_valid,
    output mem_rsp_ready,
    input [7:0] mem_rsp_data,

    output out_valid,
    input out_ready,
    output [31:0] out_addr,out_data,

    output [PE_ROWS*PE_COLS-1:0] event_mac,event_nonzero_mac,
    output event_operand_wait,event_compute_stall,
    output nm_valid,output [15:0] nm_k_base,output [2:0] nm_len,
    output [4*PE_ROWS-1:0] nm_mask_a,output [4*PE_COLS-1:0] nm_mask_b,
    output [2*PE_ROWS-1:0] nm_mode_a,output [2*PE_COLS-1:0] nm_mode_b,
    output [BKW-1:0] nm_bank
);
    wire dv,dr,first,last,enable,rv,rr,wr,wd,ov,ordy,ofirst,olast,lb;
    wire [31:0] aa,ba,base;
    wire [15:0] astride,cstride;
    wire [PE_ROWS-1:0] rm,orm;
    wire [PE_COLS-1:0] cm,ocm;
    wire [8*PE_ROWS-1:0] oa;
    wire [8*PE_COLS-1:0] ob;
    wire [32*PE_ROWS*PE_COLS-1:0] data;
    wire [PE_ROWS*PE_COLS-1:0] mask;
    wire cv,cr,cf,cl;
    wire [8*PE_ROWS*PE_COLS-1:0] ca;
    wire [8*PE_COLS-1:0] cb;
    wire [PE_ROWS-1:0] crm;
    wire [PE_COLS-1:0] ccm;
    wire [PE_ROWS*PE_COLS-1:0] work_mask;
    wire [BKW-1:0] dbank, obank, cbank;
    wire dahit, dafill, dbhit, dbfill, dbshare;
    wire [31:0] daba, dbba;
    wire [4*PE_COLS-1:0] cb_tag;
    wire [15:0] ck;
    wire group_end;

    assign nm_valid=group_end;
    assign nm_k_base={ck[15:2],2'b00};
    assign nm_bank=cbank;
    assign rr=wr && enable;
    assign event_operand_wait=ordy && !ov && lb;
    assign event_compute_stall=ov && !ordy;

    gemm_control #(.PE_ROWS(PE_ROWS),.PE_COLS(PE_COLS),.MAX_M(MAX_M),.MAX_N(MAX_N),.MAX_K(MAX_K),
        .NBANK(NBANK),.USE_A_REUSE(USE_A_REUSE),.USE_B_REUSE(USE_B_REUSE),.USE_B_SHARE(USE_B_SHARE),
        .ABUF_DEPTH(ABUF_DEPTH),.BBUF_DEPTH(BBUF_DEPTH),.BKW(BKW)) control(
        .clk(clk),.rst(rst),.start(start),.cfg_m(cfg_m),.cfg_n(cfg_n),.cfg_k(cfg_k),
        .busy(busy),.done(done),.error(error),
        .req_valid(dv),.req_ready(dr),.req_a_addr(aa),.req_b_addr(ba),.req_a_stride(astride),
        .req_rows(rm),.req_cols(cm),.req_first(first),.req_last(last),
        .req_bank(dbank),.req_a_hit(dahit),.req_a_fill(dafill),.req_abuf_addr(daba),
        .req_b_hit(dbhit),.req_b_fill(dbfill),.req_b_share(dbshare),.req_bbuf_addr(dbba),
        .result_enable(enable),.result_base(base),.result_stride(cstride),
        .result_accepted(rv && rr),.write_done(wd));

    operand_loader #(.PE_ROWS(PE_ROWS),.PE_COLS(PE_COLS),.NBANK(NBANK),.NSLOTS(NSLOTS),
        .USE_A_REUSE(USE_A_REUSE),.USE_B_REUSE(USE_B_REUSE),
        .ABUF_DEPTH(ABUF_DEPTH),.BBUF_DEPTH(BBUF_DEPTH),.BKW(BKW)) loader(
        .clk(clk),.rst(rst),.req_valid(dv),.req_ready(dr),
        .req_a_addr(aa),.req_b_addr(ba),.req_a_stride(astride),
        .req_rows(rm),.req_cols(cm),.req_first(first),.req_last(last),
        .req_bank(dbank),.req_a_hit(dahit),.req_a_fill(dafill),.req_abuf_addr(daba),
        .req_b_hit(dbhit),.req_b_fill(dbfill),.req_b_share(dbshare),.req_bbuf_addr(dbba),
        .mem_req_valid(mem_req_valid),.mem_req_ready(mem_req_ready),
        .mem_req_is_b(mem_req_is_b),.mem_req_addr(mem_req_addr),
        .mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),.mem_rsp_data(mem_rsp_data),
        .op_valid(ov),.op_ready(ordy),.op_a(oa),.op_b(ob),.op_rows(orm),.op_cols(ocm),
        .op_first(ofirst),.op_last(olast),.op_bank(obank),.loader_busy(lb));

    // Each compacted round visits all active banks in Set 4 order.
    sparsity_frontend #(.PE_ROWS(PE_ROWS),.PE_COLS(PE_COLS),.NBANK(NBANK),.BKW(BKW)) sparsity(
        .clk(clk),.rst(rst),
        .in_valid(ov),.in_ready(ordy),.in_a(oa),.in_b(ob),.in_rows(orm),.in_cols(ocm),
        .in_first(ofirst),.in_last(olast),.in_bank(obank),.out_valid(cv),.out_ready(cr),.out_a(ca),.out_b(cb),
        .out_rows(crm),.out_cols(ccm),.out_first(cf),.out_last(cl),.work_mask(work_mask),
        .out_b_tag(cb_tag),
        .out_k(ck),.out_bank(cbank),.out_group_end(group_end),.out_group_len(nm_len),
        .out_group_mask_a(nm_mask_a),.out_group_mask_b(nm_mask_b),
        .out_group_mode_a(nm_mode_a),.out_group_mode_b(nm_mode_b));

    mac_array_compute #(.PE_ROWS(PE_ROWS),.PE_COLS(PE_COLS),
        .ACC_dup(NBANK>1),.PE_Folding(0),.FACTORED_MASK(0),.A_PER_COLUMN(1)) compute(
        .clk(clk),.rst(rst),.op_valid(cv),.op_ready(cr),.op_a(ca),.op_b(cb),
        .op_rows(crm),.op_cols(ccm),.op_first(cf),.op_last(cl),.work_mask(work_mask),
        .op_a_nz({PE_ROWS{1'b0}}),.op_b_nz({PE_COLS{1'b0}}),.op_b_tag(cb_tag),
        .result_valid(rv),.result_ready(rr),.result_data(data),.result_mask(mask),
        .event_mac(event_mac),.event_nonzero_mac(event_nonzero_mac));

    result_writer #(.PE_ROWS(PE_ROWS),.PE_COLS(PE_COLS)) writer(
        .clk(clk),.rst(rst),.result_valid(rv && enable),.result_ready(wr),
        .result_base(base),.result_stride(cstride),.result_data(data),.result_mask(mask),
        .out_valid(out_valid),.out_ready(out_ready),.out_addr(out_addr),.out_data(out_data),.done(wd));

endmodule
