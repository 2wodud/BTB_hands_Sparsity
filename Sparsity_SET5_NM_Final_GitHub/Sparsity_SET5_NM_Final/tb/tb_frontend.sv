`timescale 1ns/1ps
// Independent exhaustive check of all 16^4 column position combinations.
module tb_frontend;
    reg clk=0,rst=1,iv=0,ready=0;
    always #5 clk=~clk;
    wire ir,ov,first,last,ge;
    reg [31:0] ia=0,ib=0;
    reg [3:0] rows=15;
    reg inf=0,inl=0;
    wire [127:0] oa;
    wire [31:0] ob;
    wire [15:0] tag,wm,am,bm;
    wire [7:0] km,ma,mb;
    wire [3:0] orows,ocols;
    wire [15:0] base;
    wire [2:0] glen;
    wire [1:0] bank;
    integer gid=0,length=4,pattern=0,seen=0,rounds=0,tick=0,groups=0;
    integer q,r,c,rank,selected,nnz,want_b,want_a,want_tag,want_mask,max_count,count;
    integer mode_a,mode_b;
    reg active=0;
    sparsity_frontend dut(.clk(clk),.rst(rst),.in_valid(iv),.in_ready(ir),
        .in_a(ia),.in_b(ib),.in_rows(rows),.in_cols(4'hf),.in_first(inf),.in_last(inl),.in_bank(2'd0),
        .out_valid(ov),.out_ready(ready),.out_a(oa),.out_b(ob),.out_rows(orows),.out_cols(ocols),
        .out_first(first),.out_last(last),.work_mask(wm),.out_b_tag(tag),.out_k_mask(km),
        .out_k(base),.out_bank(bank),.out_group_end(ge),.out_group_len(glen),
        .out_group_mask_a(am),.out_group_mask_b(bm),.out_group_mode_a(ma),.out_group_mode_b(mb));
    rv_monitor #(.WIDTH(279)) stable(clk,rst,ov,ready,
        {oa,ob,tag,km,orows,ocols,first,last,wm,bank,base,glen,am,bm,ma,mb});

    function integer av(input integer row,input integer pos);
        av=(gid+row*7+pos*3)%9-4;
    endfunction
    function integer bv(input integer col,input integer pos);
        begin
            if(pos>=length || !(pattern & (1<<(4*col+pos)))) bv=0;
            else case((gid+col*3+pos)%18)
                0:bv=1; 1:bv=-1; 2:bv=2; 3:bv=4; 4:bv=8; 5:bv=16;
                6:bv=32; 7:bv=64; 8:bv=-2; 9:bv=-4; 10:bv=-8;
                11:bv=-16; 12:bv=-32; 13:bv=-64; 14:bv=-128;
                15:bv=127; 16:bv=7; 17:bv=-5;
            endcase
        end
    endfunction
    function integer tag_for(input integer value);
        case(value)
            0:tag_for=0;1:tag_for=2;-1:tag_for=3;
            2:tag_for=9;4:tag_for=10;8:tag_for=11;16:tag_for=12;
            32:tag_for=13;64:tag_for=14;default:tag_for=1;
        endcase
    endfunction
    function integer capacity(input integer n);
        capacity=n>=3 ? 4 : n;
    endfunction

    always @(negedge clk) begin
        tick=tick+1;
        ready=!rst && tick%7!=0 && tick%7!=1;
    end
    always @(posedge clk) if(!rst && ov && ready) begin
        if(!active || seen>=rounds || base!=0 || bank!=0 || glen!=length || orows!=rows || ocols!=15)
            $fatal(1,"Unexpected group metadata gid=%0d",gid);
        if(first!==(seen==0) || last!==(seen==rounds-1)) $fatal(1,"Boundary flag mismatch");
        for(q=0;q<4;q=q+1) for(r=0;r<4;r=r+1) begin
            want_a=(q<length && rows[r]) ? av(r,q) : 0;
            if($signed(oa[8*(4*q+r)+:8])!=want_a) $fatal(1,"A is not K-major gid=%0d",gid);
            if(am[4*r+q] !== (q<length && rows[r] && av(r,q)!=0)) $fatal(1,"A bitmap mismatch");
        end
        for(r=0;r<4;r=r+1) begin
            nnz=0;
            for(q=0;q<length;q=q+1) if(rows[r] && av(r,q)!=0) nnz=nnz+1;
            mode_a=nnz>=3?3:nnz;
            if(ma[2*r+:2]!=mode_a) $fatal(1,"A diagnostic mode mismatch");
        end
        for(c=0;c<4;c=c+1) begin
            nnz=0;
            for(q=0;q<4;q=q+1) begin
                if(bv(c,q)!=0) nnz=nnz+1;
                if(bm[4*c+q] !== (bv(c,q)!=0)) $fatal(1,"B bitmap mismatch");
            end
            mode_b=nnz>=3?3:nnz;
            if(mb[2*c+:2]!=mode_b) $fatal(1,"B mode mismatch");
            selected=-1;rank=0;
            if(nnz>=3) begin if(seen<length) selected=seen; end
            else for(q=0;q<length;q=q+1) if(bv(c,q)!=0) begin
                if(rank==seen) selected=q;
                rank=rank+1;
            end
            want_b=selected<0?0:bv(c,selected);
            want_tag=tag_for(want_b);
            if(km[2*c+:2]!=(selected<0?0:selected) || $signed(ob[8*c+:8])!=want_b || tag[4*c+:4]!=want_tag)
                $fatal(1,"B/K/tag mismatch gid=%0d round=%0d col=%0d",gid,seen,c);
            for(r=0;r<4;r=r+1) begin
                want_mask=selected>=0 && want_b!=0 && rows[r] && av(r,selected)!=0;
                if(wm[4*r+c]!==want_mask[0]) $fatal(1,"PE work mask mismatch");
            end
        end
        if(ge!==(seen==rounds-1)) $fatal(1,"Group-end mismatch");
        seen=seen+1;
    end

    task check_group(input integer p,input integer len,input integer row_count);
        integer pos,rr,cc,nz;
        begin
            @(negedge clk);pattern=p;length=len;rows=(1<<row_count)-1;seen=0;active=1;rounds=0;
            for(cc=0;cc<4;cc=cc+1) begin
                nz=0;
                for(pos=0;pos<len;pos=pos+1) if(bv(cc,pos)!=0) nz=nz+1;
                count=nz>=3?len:nz;
                if(count>rounds) rounds=count;
            end
            if(rounds==0) rounds=1;
            for(pos=0;pos<len;pos=pos+1) begin
                @(negedge clk);iv=1;inf=(pos==0);inl=(pos==len-1);
                for(rr=0;rr<4;rr=rr+1) ia[8*rr+:8]=av(rr,pos);
                for(cc=0;cc<4;cc=cc+1) ib[8*cc+:8]=bv(cc,pos);
                while(!ir) @(negedge clk);
                @(posedge clk);
            end
            @(negedge clk);iv=0;
            wait(seen==rounds);
            @(negedge clk);active=0;groups=groups+1;gid=gid+1;
        end
    endtask
    integer p,len,rc;
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(p=0;p<65536;p=p+1) check_group(p,4,4);
        for(len=1;len<4;len=len+1) for(rc=1;rc<=4;rc=rc+1)
            for(p=0;p<16;p=p+1) check_group(p*16'h1111,len,rc);
        $display("FRONTEND EXHAUSTIVE PASS groups=%0d",groups);$finish;
    end
    initial begin #100000000;$fatal(1,"Unit test timeout");end
endmodule
