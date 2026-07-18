// kp_regs_tb.sv - register-window front-end test: kp_regs -> kp_core ->
// kp_capture, bytes compared against the C golden.
//
// Covers: write-to-fire SEND (args then id, no race window), STATUS.pend
// poll-then-fire contract, SEND-while-pending overflow counting, and that
// the queued (pending) message still comes out intact.
`default_nettype none
`timescale 1ns/1ps

module kp_regs_tb;
    localparam int ARGC_MAX = 8;
    localparam int MSG_A = 3;   // MSG_REG  - reg = %#06x
    localparam int MSG_B = 12;  // MSG_NAME - three %s fields (long output)
`include "kp_msgs.svh"

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         wen = 0;
    reg  [3:0]  addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire        r_valid, r_ready;
    wire [15:0] r_id;
    wire [32*ARGC_MAX-1:0] r_args;
    wire        c_valid, c_ready, c_last, err;
    wire [7:0]  c_data;
    wire [15:0] msg_len, cnt, msgs;
    reg  [15:0] rd_addr = 0;
    wire [7:0]  rd_data;

    kp_regs #(.ARGC_MAX(ARGC_MAX)) regs (
        .clk(clk), .rst(rst),
        .wen(wen), .addr(addr), .wdata(wdata), .rdata(rdata),
        .core_err(err),
        .msg_valid(r_valid), .msg_ready(r_ready), .msg_id(r_id), .args_flat(r_args)
    );

    kp_core #(
        .UOP_FILE(`UOP_FILE), .LIT_FILE(`LIT_FILE), .STR_FILE(`STR_FILE),
        .STRTAB_FILE(`STRTAB_FILE), .MSTART_FILE(`MSTART_FILE), .MARITY_FILE(`MARITY_FILE),
        .ISA_VERSION(KP_ISA_VERSION),
        .N_UOPS(KP_N_UOPS), .LIT_BYTES(KP_LIT_BYTES), .STR_BYTES(KP_STR_BYTES),
        .N_STRINGS(KP_N_STRINGS), .N_MSGS(KP_N_MSGS), .ARGC_MAX(ARGC_MAX)
    ) core (
        .clk(clk), .rst(rst),
        .msg_valid(r_valid), .msg_ready(r_ready), .msg_id(r_id), .args_flat(r_args),
        .out_valid(c_valid), .out_ready(c_ready), .out_data(c_data),
        .out_last(c_last), .msg_len(msg_len), .err(err)
    );

    kp_capture #(.DEPTH(1024)) cap (
        .clk(clk), .rst(rst), .clear(1'b0),
        .in_valid(c_valid), .in_ready(c_ready), .in_data(c_data), .in_last(c_last),
        .count(cnt), .msgs(msgs), .rd_addr(rd_addr), .rd_data(rd_data)
    );
    reg [7:0]  expA [0:255]; integer nexpA = -1; reg [31:0] argsA [0:7]; integer nargsA;
    integer checks = 0, fails = 0;

    task automatic wr(input [3:0] a, input [31:0] d);
        begin
            @(posedge clk);
            wen <= 1'b1; addr <= a; wdata <= d;
            @(posedge clk);
            wen <= 1'b0;
        end
    endtask

    task automatic expect_ok(input bit cond, input string what);
        begin
            checks = checks + 1;
            if (!cond) begin fails = fails + 1; $display("FAIL %s", what); end
        end
    endtask

    integer vf, ef, code, mid, nargs, av, elen, i, guard;
    reg [8*64-1:0] dummy;

    initial begin
        vf = $fopen(`VEC_FILE, "r");
        ef = $fopen(`EXP_FILE, "r");
        if (vf == 0 || ef == 0) begin $display("FATAL files"); $finish; end
        while (!$feof(vf) && nexpA < 0) begin
            code = $fscanf(vf, "%d %d", mid, nargs);
            if (code != 2) begin code = $fgets(dummy, vf); end
            else begin
                for (i = 0; i < nargs; i = i + 1) begin
                    code = $fscanf(vf, "%h", av);
                    if (mid == MSG_A) argsA[i] = av;
                end
                code = $fscanf(ef, "%d", elen);
                for (i = 0; i < elen; i = i + 1) begin
                    code = $fscanf(ef, "%h", av);
                    if (mid == MSG_A) expA[i] = av[7:0];
                end
                if (mid == MSG_A) begin nexpA = elen; nargsA = nargs; end
            end
        end
        $fclose(vf); $fclose(ef);

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // ---- test 1: poll-then-fire, golden byte compare ----
        for (i = 0; i < nargsA; i = i + 1) wr(i[3:0], argsA[i]);
        wr(4'd8, MSG_A[31:0]);                 // write-to-fire
        guard = 0;
        while (msgs < 1 && guard < 100000) begin @(posedge clk); guard = guard + 1; end
        repeat (4) @(posedge clk);
        expect_ok(msgs == 1, "message completed via register window");
        expect_ok(cnt == nexpA, "byte count == golden");
        for (i = 0; i < nexpA; i = i + 1) begin
            rd_addr <= i[15:0];
            @(posedge clk); #1;
            expect_ok(rd_data === expA[i], $sformatf("byte %0d matches golden", i));
        end
        addr <= 4'd9; @(posedge clk); #1;
        expect_ok(rdata[0] == 1'b0, "STATUS.pend clear after acceptance");

        // ---- test 2: SEND while pending -> overflow counted, queue intact ----
        // fire the long message, then immediately queue another and overflow a third
        for (i = 0; i < 3; i = i + 1) wr(i[3:0], 32'd1);   // str ids = "cpu"
        wr(4'd8, MSG_B[31:0]);                 // fires; core starts emitting
        wr(4'd8, MSG_A[31:0]);                 // queues (pend) while core busy
        wr(4'd8, MSG_A[31:0]);                 // pend still set -> DROP + count
        guard = 0;
        while (msgs < 3 && guard < 100000) begin @(posedge clk); guard = guard + 1; end
        repeat (4) @(posedge clk);
        expect_ok(msgs == 3, "queued message still delivered after busy period");
        addr <= 4'd9; @(posedge clk); #1;
        expect_ok(rdata[15:8] == 8'd1, "overflow count == 1 for dropped SEND");
        expect_ok(rdata[1] == 1'b0, "no core error");

        // ---- test 3: arg snapshot - a queued SEND is immune to later ARG
        // writes. Fire a LONG message, queue MSG_A with GOOD args, then poison
        // the ARG registers while MSG_A is pending. The delivered MSG_A must
        // still carry the GOOD args (snapshot at fire time), not the poison. ----
        begin : snap_test
            integer m0, base, k;
            m0 = msgs;
            wr(4'd0, 32'd1); wr(4'd1, 32'd2); wr(4'd2, 32'd3);   // MSG_B str ids
            wr(4'd8, MSG_B[31:0]);                 // long message fires, core busy
            wr(4'd0, argsA[0]);                    // MSG_A GOOD arg
            wr(4'd8, MSG_A[31:0]);                 // MSG_A queued -> snapshot GOOD
            wr(4'd0, 32'hDEAD_BEEF);               // poison ARG0 while pending
            guard = 0;
            while (msgs < m0 + 2 && guard < 100000) begin @(posedge clk); guard = guard + 1; end
            repeat (4) @(posedge clk);
            expect_ok(msgs == m0 + 2, "long + queued message both delivered");
            // MSG_A is the last message: its bytes are the tail of the capture
            base = cnt - nexpA;
            for (k = 0; k < nexpA; k = k + 1) begin
                rd_addr <= base[15:0] + k[15:0];
                @(posedge clk); #1;
                expect_ok(rd_data === expA[k],
                          $sformatf("snapshot: queued MSG_A byte %0d == GOOD golden", k));
            end
        end

        $display("RESULT: %0d regs checks, %0d failures", checks, fails);
        if (fails != 0) $display("REGS-DIFF: FAIL");
        else            $display("REGS-DIFF: PASS");
        $finish;
    end
endmodule
`default_nettype wire
