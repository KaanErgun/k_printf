// kp_bus_tb.sv - bus adapter test: drive kp_regs over AXI4-Lite and over
// Wishbone, each feeding kp_core -> kp_capture, and check the emitted message
// byte-for-byte against the C golden. Also exercises register read-back
// (STATUS + an ARG) over each bus.
`default_nettype none
`timescale 1ns/1ps

module kp_bus_tb;
    localparam int ARGC_MAX = 8;
    localparam int MSG_A = 3;           // MSG_REG "reg = %#06x", arity 1
`include "kp_msgs.svh"

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    wire aresetn = ~rst;

    // ---------------- AXI-Lite chain ----------------
    reg  [5:0]  aw = 0;  reg awv = 0;  wire awr;
    reg  [31:0] wd = 0;  reg wv = 0;   wire wr;
    wire [1:0]  bresp; wire bv; reg bready = 0;
    reg  [5:0]  ar = 0;  reg arv = 0;  wire arr;
    wire [31:0] rd;  wire [1:0] rresp; wire rv; reg rready = 0;
    wire        a_wen; wire [3:0] a_addr; wire [31:0] a_wdata, a_rdata;
    wire        a_mvalid, a_mready; wire [15:0] a_mid;
    wire [32*ARGC_MAX-1:0] a_args;
    wire        a_cv, a_cr, a_cl, a_err; wire [7:0] a_cd;
    wire [15:0] a_mlen, a_cnt, a_msgs; reg [15:0] a_rdaddr = 0; wire [7:0] a_rddat;

    kp_axil #(.AW(6)) axil (
        .aclk(clk), .aresetn(aresetn),
        .s_awaddr(aw), .s_awvalid(awv), .s_awready(awr),
        .s_wdata(wd), .s_wstrb(4'hF), .s_wvalid(wv), .s_wready(wr),
        .s_bresp(bresp), .s_bvalid(bv), .s_bready(bready),
        .s_araddr(ar), .s_arvalid(arv), .s_arready(arr),
        .s_rdata(rd), .s_rresp(rresp), .s_rvalid(rv), .s_rready(rready),
        .reg_wen(a_wen), .reg_addr(a_addr), .reg_wdata(a_wdata), .reg_rdata(a_rdata)
    );
    kp_regs #(.ARGC_MAX(ARGC_MAX)) aregs (
        .clk(clk), .rst(rst), .wen(a_wen), .addr(a_addr), .wdata(a_wdata),
        .rdata(a_rdata), .core_err(a_err),
        .msg_valid(a_mvalid), .msg_ready(a_mready), .msg_id(a_mid), .args_flat(a_args)
    );
    kp_core #(
        .UOP_FILE(`UOP_FILE), .LIT_FILE(`LIT_FILE), .STR_FILE(`STR_FILE),
        .STRTAB_FILE(`STRTAB_FILE), .MSTART_FILE(`MSTART_FILE), .MARITY_FILE(`MARITY_FILE),
        .ISA_VERSION(KP_ISA_VERSION),
        .N_UOPS(KP_N_UOPS), .LIT_BYTES(KP_LIT_BYTES), .STR_BYTES(KP_STR_BYTES),
        .N_STRINGS(KP_N_STRINGS), .N_MSGS(KP_N_MSGS), .ARGC_MAX(ARGC_MAX)
    ) acore (
        .clk(clk), .rst(rst), .msg_valid(a_mvalid), .msg_ready(a_mready),
        .msg_id(a_mid), .args_flat(a_args),
        .out_valid(a_cv), .out_ready(a_cr), .out_data(a_cd), .out_last(a_cl),
        .msg_len(a_mlen), .err(a_err)
    );
    kp_capture #(.DEPTH(1024)) acap (
        .clk(clk), .rst(rst), .clear(1'b0),
        .in_valid(a_cv), .in_ready(a_cr), .in_data(a_cd), .in_last(a_cl),
        .count(a_cnt), .msgs(a_msgs), .rd_addr(a_rdaddr), .rd_data(a_rddat)
    );

    // ---------------- Wishbone chain ----------------
    reg  [3:0]  wadr = 0; reg [31:0] wdi = 0; wire [31:0] wdo;
    reg         wwe = 0, wcyc = 0, wstb = 0; wire wack;
    wire        w_wen; wire [3:0] w_addr; wire [31:0] w_wdata, w_rdata;
    wire        w_mvalid, w_mready, w_err; wire [15:0] w_mid;
    wire [32*ARGC_MAX-1:0] w_args;
    wire        w_cv, w_cr, w_cl; wire [7:0] w_cd;
    wire [15:0] w_mlen, w_cnt, w_msgs; reg [15:0] w_rdaddr = 0; wire [7:0] w_rddat;

    kp_wb #(.ADR_W(4)) wb (
        .clk_i(clk), .rst_i(rst), .wb_adr_i(wadr), .wb_dat_i(wdi), .wb_dat_o(wdo),
        .wb_we_i(wwe), .wb_cyc_i(wcyc), .wb_stb_i(wstb), .wb_ack_o(wack),
        .reg_wen(w_wen), .reg_addr(w_addr), .reg_wdata(w_wdata), .reg_rdata(w_rdata)
    );
    kp_regs #(.ARGC_MAX(ARGC_MAX)) wregs (
        .clk(clk), .rst(rst), .wen(w_wen), .addr(w_addr), .wdata(w_wdata),
        .rdata(w_rdata), .core_err(w_err),
        .msg_valid(w_mvalid), .msg_ready(w_mready), .msg_id(w_mid), .args_flat(w_args)
    );
    kp_core #(
        .UOP_FILE(`UOP_FILE), .LIT_FILE(`LIT_FILE), .STR_FILE(`STR_FILE),
        .STRTAB_FILE(`STRTAB_FILE), .MSTART_FILE(`MSTART_FILE), .MARITY_FILE(`MARITY_FILE),
        .ISA_VERSION(KP_ISA_VERSION),
        .N_UOPS(KP_N_UOPS), .LIT_BYTES(KP_LIT_BYTES), .STR_BYTES(KP_STR_BYTES),
        .N_STRINGS(KP_N_STRINGS), .N_MSGS(KP_N_MSGS), .ARGC_MAX(ARGC_MAX)
    ) wcore (
        .clk(clk), .rst(rst), .msg_valid(w_mvalid), .msg_ready(w_mready),
        .msg_id(w_mid), .args_flat(w_args),
        .out_valid(w_cv), .out_ready(w_cr), .out_data(w_cd), .out_last(w_cl),
        .msg_len(w_mlen), .err(w_err)
    );
    kp_capture #(.DEPTH(1024)) wcap (
        .clk(clk), .rst(rst), .clear(1'b0),
        .in_valid(w_cv), .in_ready(w_cr), .in_data(w_cd), .in_last(w_cl),
        .count(w_cnt), .msgs(w_msgs), .rd_addr(w_rdaddr), .rd_data(w_rddat)
    );

    // ---------------- golden vectors ----------------
    reg [7:0]  expA [0:255]; integer nexpA = -1; reg [31:0] argA;
    integer checks = 0, fails = 0;

    task automatic ok(input bit c, input string what);
        begin checks++; if (!c) begin fails++; $display("FAIL %s", what); end end
    endtask

    // AXI-Lite master ops
    task automatic axil_write(input [5:0] a, input [31:0] d);
        begin
            @(posedge clk);
            aw <= a; wd <= d; awv <= 1'b1; wv <= 1'b1; bready <= 1'b1;
            @(posedge clk);
            while (!(awr && wr)) @(posedge clk);
            awv <= 1'b0; wv <= 1'b0;
            while (!bv) @(posedge clk);
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask
    task automatic axil_read(input [5:0] a, output [31:0] d);
        begin
            @(posedge clk);
            ar <= a; arv <= 1'b1; rready <= 1'b1;
            @(posedge clk);
            while (!arr) @(posedge clk);
            arv <= 1'b0;
            while (!rv) @(posedge clk);
            d = rd;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask
    // Wishbone master ops
    task automatic wb_write(input [3:0] a, input [31:0] d);
        begin
            @(posedge clk);
            wadr <= a; wdi <= d; wwe <= 1'b1; wcyc <= 1'b1; wstb <= 1'b1;
            @(posedge clk);
            while (!wack) @(posedge clk);
            wcyc <= 1'b0; wstb <= 1'b0; wwe <= 1'b0;
        end
    endtask
    task automatic wb_read(input [3:0] a, output [31:0] d);
        begin
            @(posedge clk);
            wadr <= a; wwe <= 1'b0; wcyc <= 1'b1; wstb <= 1'b1;
            @(posedge clk);
            while (!wack) @(posedge clk);
            d = wdo;
            wcyc <= 1'b0; wstb <= 1'b0;
        end
    endtask

    integer vf, ef, code, mid, nargs, av, elen, i, guard;
    reg [8*64-1:0] dummy;
    reg [31:0] rv32;

    initial begin
        vf = $fopen(`VEC_FILE, "r"); ef = $fopen(`EXP_FILE, "r");
        if (vf == 0 || ef == 0) begin $display("FATAL files"); $finish; end
        while (!$feof(vf) && nexpA < 0) begin
            code = $fscanf(vf, "%d %d", mid, nargs);
            if (code != 2) code = $fgets(dummy, vf);
            else begin
                for (i = 0; i < nargs; i = i + 1) begin
                    code = $fscanf(vf, "%h", av);
                    if (mid == MSG_A) argA = av;
                end
                code = $fscanf(ef, "%d", elen);
                for (i = 0; i < elen; i = i + 1) begin
                    code = $fscanf(ef, "%h", av);
                    if (mid == MSG_A) expA[i] = av[7:0];
                end
                if (mid == MSG_A) nexpA = elen;
            end
        end
        $fclose(vf); $fclose(ef);

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // ===== AXI-Lite: write ARG0, fire SEND, check message + readback =====
        axil_write(6'h00, argA);              // ARG0 (byte addr 0)
        axil_write(6'h20, MSG_A);             // SEND (reg 8 -> byte addr 0x20)
        guard = 0;
        while (a_msgs < 1 && guard < 100000) begin @(posedge clk); guard = guard + 1; end
        repeat (4) @(posedge clk);
        ok(a_msgs == 1, "AXI: message emitted");
        ok(a_cnt == nexpA, "AXI: byte count == golden");
        for (i = 0; i < nexpA; i = i + 1) begin
            a_rdaddr <= i[15:0]; @(posedge clk); #1;
            ok(a_rddat === expA[i], $sformatf("AXI: byte %0d == golden", i));
        end
        axil_read(6'h24, rv32);               // STATUS (reg 9 -> byte 0x24)
        ok(rv32[0] == 1'b0, "AXI: STATUS.pend clear after accept");
        ok(rv32[1] == 1'b0, "AXI: STATUS.err clear");
        axil_read(6'h00, rv32);               // ARG0 read-back
        ok(rv32 == argA, "AXI: ARG0 read-back matches");

        // ===== Wishbone: same over WB =====
        wb_write(4'h0, argA);                 // ARG0
        wb_write(4'h8, MSG_A);                // SEND
        guard = 0;
        while (w_msgs < 1 && guard < 100000) begin @(posedge clk); guard = guard + 1; end
        repeat (4) @(posedge clk);
        ok(w_msgs == 1, "WB: message emitted");
        ok(w_cnt == nexpA, "WB: byte count == golden");
        for (i = 0; i < nexpA; i = i + 1) begin
            w_rdaddr <= i[15:0]; @(posedge clk); #1;
            ok(w_rddat === expA[i], $sformatf("WB: byte %0d == golden", i));
        end
        wb_read(4'h9, rv32);                  // STATUS
        ok(rv32[0] == 1'b0, "WB: STATUS.pend clear after accept");
        wb_read(4'h0, rv32);                  // ARG0 read-back
        ok(rv32 == argA, "WB: ARG0 read-back matches");

        $display("RESULT: %0d bus checks, %0d failures", checks, fails);
        if (fails != 0) $display("BUS-DIFF: FAIL");
        else            $display("BUS-DIFF: PASS");
        $finish;
    end
endmodule
`default_nettype wire
