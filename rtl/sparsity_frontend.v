`timescale 1ns/1ps
// NM4 CHANGE: stream exact-zero masks; collect K-axis M=4 metadata in parallel.
// Values and packet order are retained. No pruning or value serialization.
module sparsity_frontend #(parameter PE_ROWS=4,PE_COLS=4,
    parameter MASK_PIPELINE=1, SKIP_EMPTY=0)(
    input clk,rst,
    input in_valid,output in_ready,
    input [8*PE_ROWS-1:0] in_a,input [8*PE_COLS-1:0] in_b,
    input [PE_ROWS-1:0] in_rows,input [PE_COLS-1:0] in_cols,
    input in_first,in_last,
    output out_valid,input out_ready,
    output [8*PE_ROWS-1:0] out_a,output [8*PE_COLS-1:0] out_b,
    output [PE_ROWS-1:0] out_rows,output [PE_COLS-1:0] out_cols,
    output out_first,out_last,output [PE_ROWS*PE_COLS-1:0] work_mask,
    output [PE_ROWS-1:0] out_a_nz,output [PE_COLS-1:0] out_b_nz,
    output [4*PE_COLS-1:0] out_b_tag, // integrated 4-bit ZERO/MUL/PASS/NEG/SHIFT
    output [15:0] out_k,
    // Descriptor accompanies the final packet of each group. It uses the SAME
    // ready/valid handshake. bit 4*lane+q means original K position q (LSB first).
    output out_group_end,output [2:0] out_group_len,
    output [4*PE_ROWS-1:0] out_group_mask_a,
    output [4*PE_COLS-1:0] out_group_mask_b,
    output [2*PE_ROWS-1:0] out_group_mode_a,
    output [2*PE_COLS-1:0] out_group_mode_b
);
    localparam NM_M=4;
    wire [PE_ROWS-1:0] a_nz;
    wire [PE_COLS-1:0] b_nz;
    wire [4*PE_COLS-1:0] b_tag;
    reg [1:0] group_pos;
    reg [15:0] next_k;
    reg [4*PE_ROWS-1:0] group_mask_a,group_mask_a_next;
    reg [4*PE_COLS-1:0] group_mask_b,group_mask_b_next;
    wire [1:0] current_pos=in_first?2'd0:group_pos;
    wire [15:0] current_k=in_first?16'd0:next_k;
    wire group_end=(current_pos==NM_M-1) || in_last;
    wire [2:0] group_len={1'b0,current_pos}+3'd1;
    wire [2*PE_ROWS-1:0] group_mode_a;
    wire [2*PE_COLS-1:0] group_mode_b;
    // Default: preserve every K packet. Optional skip preserves first/last AND
    // group-end descriptors. The original K index is always carried explicitly.
    wire keep_packet=!SKIP_EMPTY || ((|a_nz) && (|b_nz)) ||
                     in_first || in_last || group_end;
    wire accept_input=in_valid && in_ready;

    // 00=0:4, 01=1:4, 10=2:4, 11=dense capacity (3 or 4 NNZ).
    // Mode is NOT an ALU opcode and does not replace the position bitmap.
    function [1:0] choose_mode;
        input [3:0] positions;
        reg [2:0] nnz;
        begin
            nnz={2'd0,positions[0]}+{2'd0,positions[1]}+
                {2'd0,positions[2]}+{2'd0,positions[3]};
            if(nnz==0) choose_mode=2'b00;
            else if(nnz==1) choose_mode=2'b01;
            else if(nnz==2) choose_mode=2'b10;
            else choose_mode=2'b11;
        end
    endfunction
    // INTEGRATED CHANGE: ten states need at least four bits. Shift tags
    // have bit3=1 and carry n directly in [2:0]. No separate exponent bus.
    // 0=ZERO, 1=MUL, 2=PASS(+1), 3=NEG(-1), 9..E=SHL1..SHL6.
    function [3:0] classify_b;
        input [7:0] value;
        begin
            case(value)
                8'h00: classify_b=4'h0;
                8'h01: classify_b=4'h2;
                8'hff: classify_b=4'h3;
                8'h02: classify_b=4'h9;
                8'h04: classify_b=4'ha;
                8'h08: classify_b=4'hb;
                8'h10: classify_b=4'hc;
                8'h20: classify_b=4'hd;
                8'h40: classify_b=4'he;
                default: classify_b=4'h1;
            endcase
        end
    endfunction
    genvar r,c;
    generate for(r=0;r<PE_ROWS;r=r+1) begin: rows
        assign a_nz[r]=in_rows[r] && (|in_a[8*r +: 8]);
        assign group_mode_a[2*r +: 2]=choose_mode(group_mask_a_next[4*r +: 4]);
        for(c=0;c<PE_COLS;c=c+1) begin: cols
            // Compatibility/verification view. MAC uses the factored mask.
            assign work_mask[r*PE_COLS+c]=out_a_nz[r] && out_b_nz[c];
        end
    end
    for(c=0;c<PE_COLS;c=c+1) begin: columns
        assign b_tag[4*c +: 4]=in_cols[c]?classify_b(in_b[8*c +: 8]):4'h0;
        assign b_nz[c]=(b_tag[4*c +: 4]!=4'h0);
        assign out_b_nz[c]=(out_b_tag[4*c +: 4]!=4'h0);
        assign group_mode_b[2*c +: 2]=choose_mode(group_mask_b_next[4*c +: 4]);
    end endgenerate
    integer i;
    always @* begin
        group_mask_a_next=(current_pos==0)?0:group_mask_a;
        group_mask_b_next=(current_pos==0)?0:group_mask_b;
        for(i=0;i<PE_ROWS;i=i+1) group_mask_a_next[4*i+current_pos]=a_nz[i];
        for(i=0;i<PE_COLS;i=i+1) group_mask_b_next[4*i+current_pos]=b_nz[i];
    end
    always @(posedge clk) begin
        if(rst) begin group_pos<=0;next_k<=0;group_mask_a<=0;group_mask_b<=0;end
        else if(accept_input) begin
            group_mask_a<=group_mask_a_next;group_mask_b<=group_mask_b_next;
            group_pos<=group_end?2'd0:current_pos+2'd1;
            next_k<=in_last?16'd0:current_k+16'd1;
        end
    end
    // One elastic register; no wait-for-four / PACK / EMIT phase.
    // Bypass is provided for cycle/STA comparison with the same functionality.
    localparam PACKET_W=8*(PE_ROWS+PE_COLS)+2*(PE_ROWS+PE_COLS)+2+16+1+3+
                        6*(PE_ROWS+PE_COLS)+3*PE_COLS;
    wire [PACKET_W-1:0] packet_in={in_a,in_b,in_rows,in_cols,in_first,in_last,
        a_nz,b_tag,current_k,group_end,group_len,
        group_mask_a_next,group_mask_b_next,group_mode_a,group_mode_b};
    wire [PACKET_W-1:0] packet_out;
    generate if(MASK_PIPELINE) begin: pipeline
        reg valid_hold;
        reg [PACKET_W-1:0] packet_hold;
        wire slot_ready=!valid_hold || out_ready;
        assign in_ready=!rst && (!keep_packet || slot_ready);
        assign out_valid=!rst && valid_hold;
        assign packet_out=packet_hold;
        always @(posedge clk) begin
            if(rst) begin valid_hold<=0;packet_hold<=0;end
            else if(slot_ready) begin
                valid_hold<=accept_input && keep_packet;
                if(accept_input && keep_packet) packet_hold<=packet_in;
            end
        end
    end else begin: bypass
        assign in_ready=!rst && (!keep_packet || out_ready);
        assign out_valid=!rst && in_valid && keep_packet;
        assign packet_out=packet_in;
    end endgenerate
    assign {out_a,out_b,out_rows,out_cols,out_first,out_last,out_a_nz,out_b_tag,
        out_k,out_group_end,out_group_len,
        out_group_mask_a,out_group_mask_b,out_group_mode_a,out_group_mode_b}=packet_out;
endmodule
