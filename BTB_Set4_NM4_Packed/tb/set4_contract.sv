`timescale 1ns/1ps
// Independently track k from the Set 4 B address and check the NM4 record
// at the corresponding Compute transaction.
module set4_contract(
    input clk,rst,
    input [15:0] n,
    input dv,dr,ov,ordy,cv,cr,
    input [31:0] ba,oa,ob,
    input [3:0] orm,ocm,
    input ofirst,olast,
    input [1:0] dbank,obank,cbank,
    input [2:0] compute_bank,
    input [15:0] ck,nm_k_base,nm_mask_a,nm_mask_b,
    input nm_valid,
    input [2:0] nm_len,
    input [7:0] nm_mode_a,nm_mode_b,
    input [15:0] cb_tag
);
    reg [17:0] descriptors[0:3];
    reg [1:0] wr,rd;
    reg [15:0] mask_a[0:3],mask_b[0:3];
    reg [15:0] expected_k,expected_a,expected_b;
    reg [1:0] expected_bank;
    reg [2:0] expected_len;
    reg expected_valid,expected_end,expected_single_k;
    integer input_k,q,lane;

    function automatic [1:0] mode(input [3:0] bits);
        integer nnz;
        begin
            nnz=$countones(bits);
            mode=(nnz>=3)?2'd3:nnz[1:0];
        end
    endfunction

    function automatic [3:0] tag(input [7:0] b);
        integer shift;
        begin
            if(b==0) tag=0;
            else if(b==1) tag=2;
            else if(b==255) tag=3;
            else begin
                tag=1;
                for(shift=1;shift<=6;shift=shift+1)
                    if(int'(b)==(1<<shift)) tag=8+shift;
            end
        end
    endfunction
    reg [15:0] expected_tag;

    always @(posedge clk) begin
        if(rst) begin
            wr<=0;
            rd<=0;
            expected_valid<=0;
            for(integer bank=0;bank<4;bank++) begin
                mask_a[bank]<=0;
                mask_b[bank]<=0;
            end
        end else begin
            if(dv && dr) begin
                descriptors[wr]<={dbank,16'(ba/n)};
                wr<=wr+1'b1;
            end
            if(cv !== expected_valid) $fatal(1,"Sparsity changed packet count");
            if(nm_valid !== (cv && cr && expected_end))
                $fatal(1,"N:M record valid/handshake mismatch");
            if(cv) begin
                // For K=1, v2 reuses ACC 0: every packet starts and completes
                // its own tile in one transaction, so no partial sum survives.
                if(cbank!==expected_bank || ck!==expected_k ||
                   compute_bank!==(expected_single_k?3'd0:{1'b0,expected_bank}))
                    $fatal(1,"Bank/K mismatch: expected bank=%0d k=%0d, got %0d/%0d MAC bank=%0d",
                        expected_bank,expected_k,cbank,ck,compute_bank);
                if(cb_tag!==expected_tag || nm_k_base!==(expected_k & 16'hfffc) ||
                   nm_len!==expected_len || nm_mask_a!==expected_a || nm_mask_b!==expected_b)
                    $fatal(1,"Bank %0d k %0d: wrong tag or N:M bitmap",expected_bank,expected_k);
                for(integer j=0;j<4;j++)
                    if(nm_mode_a[2*j+:2]!==mode(expected_a[4*j+:4]) ||
                       nm_mode_b[2*j+:2]!==mode(expected_b[4*j+:4]))
                        $fatal(1,"Incorrect N:M mode");
            end
            if(cv && cr) expected_valid<=0;
            if(ov && ordy) begin
                if(obank!==descriptors[rd][17:16]) $fatal(1,"Loader bank reordered");
                input_k=int'(descriptors[rd][15:0]);
                q=input_k%4;
                if(ofirst!==(input_k==0)) $fatal(1,"Unexpected first flag");
                rd<=rd+1'b1;
                expected_bank<=obank;
                expected_k<=input_k;
                expected_end<=((q==3)||olast);
                expected_single_k<=ofirst && olast;
                expected_len<=q+1;
                expected_valid<=1;
                for(lane=0;lane<4;lane++) begin
                    expected_a[4*lane+:4]<=((q==0)?4'd0:mask_a[obank][4*lane+:4]) |
                                           (4'(orm[lane] && (oa[8*lane+:8]!=0))<<q);
                    expected_b[4*lane+:4]<=((q==0)?4'd0:mask_b[obank][4*lane+:4]) |
                                           (4'(ocm[lane] && (ob[8*lane+:8]!=0))<<q);
                    mask_a[obank][4*lane+:4]<=((q==0)?4'd0:mask_a[obank][4*lane+:4]) |
                                               (4'(orm[lane] && (oa[8*lane+:8]!=0))<<q);
                    mask_b[obank][4*lane+:4]<=((q==0)?4'd0:mask_b[obank][4*lane+:4]) |
                                               (4'(ocm[lane] && (ob[8*lane+:8]!=0))<<q);
                    expected_tag[4*lane+:4]<=ocm[lane]?tag(ob[8*lane+:8]):4'd0;
                end
            end
        end
    end
endmodule

`ifndef NM4_PACKED
bind tb_gemm set4_contract bank_contract(
    .clk(clk),.rst(rst),.n(n),
    .dv(dut.dv),.dr(dut.dr),.ov(dut.ov),.ordy(dut.ordy),.cv(dut.cv),.cr(dut.cr),
    .ba(dut.ba),.oa(dut.oa),.ob(dut.ob),.orm(dut.orm),.ocm(dut.ocm),
    .ofirst(dut.ofirst),.olast(dut.olast),.dbank(dut.dbank),.obank(dut.obank),
    .cbank(dut.cbank),.compute_bank(3'(dut.compute.cur_idx)),
    .ck(dut.ck),.nm_k_base(dut.nm_k_base),.nm_mask_a(dut.nm_mask_a),.nm_mask_b(dut.nm_mask_b),
    .nm_valid(dut.nm_valid),.nm_len(dut.nm_len),.nm_mode_a(dut.nm_mode_a),
    .nm_mode_b(dut.nm_mode_b),.cb_tag(dut.cb_tag)
);
`endif
