`timescale 1ns/1ps
// PE_ROWS x PE_COLS output-stationary MAC array, NOT a systolic array.
// a[r] is broadcast across a row; b[c] is broadcast down a column.
// Dense baseline: multiplication+accumulation in the same clock stage.
module mac_array #(parameter PE_ROWS=4,PE_COLS=4,
    parameter FACTORED_MASK=0,SPECIAL_OPS=0)(
    input clk,rst,input op_valid,output op_ready,
    input [8*PE_ROWS-1:0] op_a,input [8*PE_COLS-1:0] op_b,
    input [PE_ROWS-1:0] op_rows,input [PE_COLS-1:0] op_cols,
    input op_first,op_last,
    input [PE_ROWS*PE_COLS-1:0] work_mask,
    // NM4 CHANGE: default keeps legacy standalone instantiations compatible.
    input [PE_ROWS-1:0] op_a_nz,input [PE_COLS-1:0] op_b_nz,
    input [4*PE_COLS-1:0] op_b_tag,
    output reg result_valid,input result_ready,
    output reg [32*PE_ROWS*PE_COLS-1:0] result_data,
    output reg [PE_ROWS*PE_COLS-1:0] result_mask,
    output [PE_ROWS*PE_COLS-1:0] event_mac,event_nonzero_mac,
    output [PE_ROWS*PE_COLS-1:0] event_mul,event_pass,event_neg,event_shift
);
    localparam P=PE_ROWS*PE_COLS;
    reg signed [31:0] acc[0:P-1];
    wire signed [15:0] product[0:P-1];
    wire signed [31:0] next_sum[0:P-1];
    wire [P-1:0] mask;
    wire [P-1:0] work_enable;
    assign op_ready=(!result_valid || result_ready) && !rst;
    genvar r,c;
    generate for(r=0;r<PE_ROWS;r=r+1) begin: row
        for(c=0;c<PE_COLS;c=c+1) begin: col
            localparam I=r*PE_COLS+c;
            assign mask[I]=op_rows[r] && op_cols[c];
            wire [3:0] b_tag=op_b_tag[4*c +: 4];
            wire b_live=SPECIAL_OPS?(b_tag!=4'h0):op_b_nz[c];
            wire is_pass=SPECIAL_OPS && b_tag==4'h2;
            wire is_neg=SPECIAL_OPS && b_tag==4'h3;
            wire is_shift=SPECIAL_OPS && b_tag>=4'h9 && b_tag<=4'he;
            wire is_fast=is_pass || is_neg || is_shift;
            assign work_enable[I]=FACTORED_MASK?(op_a_nz[r] && b_live):work_mask[I];
            if(SPECIAL_OPS) begin: special
                // INTEGRATED CHANGE: sign-extend BEFORE negate/shift. The
                // unselected multiplier receives zero operands (isolation).
                wire signed [15:0] a_ext={{8{op_a[8*r+7]}},op_a[8*r +: 8]};
                wire mul_enable=op_valid && mask[I] && work_enable[I] && !is_fast;
                wire [7:0] mul_a=mul_enable?op_a[8*r +: 8]:8'd0;
                wire [7:0] mul_b=mul_enable?op_b[8*c +: 8]:8'd0;
                wire signed [15:0] general_product=$signed(mul_a)*$signed(mul_b);
                assign product[I]=is_pass?a_ext:is_neg?(-a_ext):
                    is_shift?(a_ext <<< b_tag[2:0]):general_product;
            end else begin: original
                assign product[I]=$signed(op_a[r*8 +: 8])*$signed(op_b[c*8 +: 8]);
            end
            assign next_sum[I]=(op_first?32'sd0:acc[I])+
                (work_enable[I]?{{16{product[I][15]}},product[I]}:32'sd0);
            assign event_mac[I]=op_valid && op_ready && mask[I] && work_enable[I];
            assign event_mul[I]=event_mac[I] && !is_fast;
            assign event_pass[I]=event_mac[I] && is_pass;
            assign event_neg[I]=event_mac[I] && is_neg;
            assign event_shift[I]=event_mac[I] && is_shift;
            assign event_nonzero_mac[I]=event_mac[I] && (op_a[r*8 +: 8]!=0) && (op_b[c*8 +: 8]!=0);
        end
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            result_valid<=0;result_data<=0;result_mask<=0;
            for(i=0;i<P;i=i+1) acc[i]<=0;
        end else begin
            if(result_valid && result_ready) result_valid<=0;
            if(op_valid && op_ready) begin
                for(i=0;i<P;i=i+1) begin
                    // NM4 CHANGE: hold the accumulator on a skipped product.
                    // first still clears it; last still publishes every valid C.
                    if(!mask[i]) acc[i]<=32'sd0;
                    else if(op_first || work_enable[i]) acc[i]<=next_sum[i];
                    if(op_last) result_data[32*i +: 32]<=mask[i]?next_sum[i]:32'sd0;
                end
                if(op_last) begin result_valid<=1;result_mask<=mask;end
            end
        end
    end
endmodule
