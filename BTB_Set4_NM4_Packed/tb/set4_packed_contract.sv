`timescale 1ns/1ps
`ifdef NM4_PACKED
module set4_packed_contract(
    input clk, rst, done,
    input [15:0] n,
    input descriptor, operand, compute, nm_valid,
    input [31:0] ba, oa, ob,
    input [3:0] rows, cols,
    input ofirst, olast, cf, cl,
    input [1:0] dbank, obank, cbank, nm_bank,
    input [2:0] compute_bank,
    input [15:0] nm_k_base, nm_mask_a, nm_mask_b,
    input [2:0] nm_len,
    input [7:0] nm_mode_a, nm_mode_b
);
    reg [17:0] descriptors[0:3];
    reg [1:0] dw, dr;
    reg [15:0] mask_a[0:3], mask_b[0:3];
    reg [52:0] groups[0:7];
    integer written, observed;
    integer k_index, pos;
    reg [15:0] updated_a, updated_b;

    function automatic [1:0] mode(input [3:0] bits);
        integer count;
        begin
            count=$countones(bits);
            mode=(count>=3)?2'd3:count[1:0];
        end
    endfunction

    always @(posedge clk) begin
        if(rst) begin
            dw<=0;
            dr<=0;
            written<=0;
            observed<=0;
        end else begin
            if(descriptor) begin
                descriptors[dw]<={dbank,16'(ba/n)};
                dw<=dw+1'b1;
            end
            if(operand) begin
                k_index=int'(descriptors[dr][15:0]);
                if(obank!==descriptors[dr][17:16] || ofirst!==(k_index==0))
                    $fatal(1,"Loader reordered the original descriptor stream");
                dr<=dr+1'b1;
                pos=k_index%4;
                updated_a=(pos==0)?16'd0:mask_a[obank];
                updated_b=(pos==0)?16'd0:mask_b[obank];
                for(integer lane=0;lane<4;lane++) begin
                    updated_a[4*lane+pos]=rows[lane] && (oa[8*lane +: 8]!=0);
                    updated_b[4*lane+pos]=cols[lane] && (ob[8*lane +: 8]!=0);
                end
                mask_a[obank]<=updated_a;
                mask_b[obank]<=updated_b;
                if(pos==3 || olast) begin
                    if(written-observed>=8) $fatal(1,"Expected group FIFO overflow");
                    groups[written%8]<={obank,16'(k_index & ~3),3'(pos+1),updated_a,updated_b};
                    written<=written+1;
                end
            end
            if(nm_valid) begin
                if(observed==written || {nm_bank,nm_k_base,nm_len,nm_mask_a,nm_mask_b}
                    !== groups[observed%8]) $fatal(1,"N:4 group metadata mismatch");
                for(integer lane=0;lane<4;lane++)
                    if(nm_mode_a[2*lane +: 2]!==mode(nm_mask_a[4*lane +: 4]) ||
                       nm_mode_b[2*lane +: 2]!==mode(nm_mask_b[4*lane +: 4]))
                        $fatal(1,"Incorrect N:4 mode");
                observed<=observed+1;
            end
            if(compute && compute_bank!==((cf && cl)?3'd0:{1'b0,cbank}))
                $fatal(1,"Packed packet went to the wrong Compute ACC");
            if(done && written!=observed) $fatal(1,"Missing N:4 group observation");
        end
    end
endmodule

bind tb_gemm set4_packed_contract packed_contract(
    .clk(clk),.rst(rst),.done(done),.n(n),
    .descriptor(dut.dv && dut.dr),.operand(dut.ov && dut.ordy),.compute(dut.cv && dut.cr),
    .nm_valid(dut.nm_valid),.ba(dut.ba),.oa(dut.oa),.ob(dut.ob),.rows(dut.orm),.cols(dut.ocm),
    .ofirst(dut.ofirst),.olast(dut.olast),.cf(dut.cf),.cl(dut.cl),
    .dbank(dut.dbank),.obank(dut.obank),.cbank(dut.cbank),.nm_bank(dut.nm_bank),
    .compute_bank(3'(dut.compute.cur_idx)),.nm_k_base(dut.nm_k_base),
    .nm_mask_a(dut.nm_mask_a),.nm_mask_b(dut.nm_mask_b),.nm_len(dut.nm_len),
    .nm_mode_a(dut.nm_mode_a),.nm_mode_b(dut.nm_mode_b)
);
`endif
