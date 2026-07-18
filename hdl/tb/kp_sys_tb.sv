// kp_sys_tb.sv - system test: kp_trig (2 sources) -> kp_core -> kp_tee ->
// {kp_capture A, kp_capture B}.
//
// Verifies the plan's system-side promises against the C golden bytes:
//  - one-cycle atomic snapshot: both triggers fire in the SAME cycle, both
//    messages come out complete, in round-robin order, never interleaved
//  - DROP policy: re-triggering a source whose slot is in flight bumps its
//    dropped_cnt (saturating) and loses nothing else
//  - kp_tee: both sinks receive byte-identical streams
//  - kp_capture counts bytes and completed messages (k_snprintf analogue)
`default_nettype none
`timescale 1ns/1ps

module kp_sys_tb;
    localparam int ARGC_MAX = 8;
    localparam int SRC0_MSG = 5;   // MSG_TICK
    localparam int SRC1_MSG = 3;   // MSG_REG
`include "kp_msgs.svh"

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // trigger side
    reg  [1:0]  trig = 0;
    reg  [31:0] trig_id = 0;                  // 2 x 16
    reg  [2*32*ARGC_MAX-1:0] trig_args = 0;
    wire [15:0] dropped;
    // trig -> core
    wire        t_valid, t_ready;
    wire [15:0] t_id;
    wire [32*ARGC_MAX-1:0] t_args;
    // core -> tee
    wire        c_valid, c_ready, c_last;
    wire [7:0]  c_data;
    wire [15:0] msg_len;
    wire        err;
    // tee -> captures
    wire        a_valid, a_ready, a_last, b_valid, b_ready, b_last;
    wire [7:0]  a_data, b_data;
    wire [15:0] cnt_a, msgs_a, cnt_b, msgs_b;
    reg  [15:0] rd_addr = 0;
    wire [7:0]  rd_a, rd_b;

    kp_trig #(.N_SRC(2), .ARGC_MAX(ARGC_MAX), .CNT_W(8)) trigmod (
        .clk(clk), .rst(rst),
        .trig(trig), .trig_msg_id(trig_id), .trig_args(trig_args),
        .dropped_cnt(dropped),
        .msg_valid(t_valid), .msg_ready(t_ready), .msg_id(t_id), .args_flat(t_args)
    );

    kp_core #(
        .UOP_FILE(`UOP_FILE), .LIT_FILE(`LIT_FILE), .STR_FILE(`STR_FILE),
        .STRTAB_FILE(`STRTAB_FILE), .MSTART_FILE(`MSTART_FILE), .MARITY_FILE(`MARITY_FILE),
        .ISA_VERSION(KP_ISA_VERSION),
        .N_UOPS(KP_N_UOPS), .LIT_BYTES(KP_LIT_BYTES), .STR_BYTES(KP_STR_BYTES),
        .N_STRINGS(KP_N_STRINGS), .N_MSGS(KP_N_MSGS), .ARGC_MAX(ARGC_MAX)
    ) core (
        .clk(clk), .rst(rst),
        .msg_valid(t_valid), .msg_ready(t_ready), .msg_id(t_id), .args_flat(t_args),
        .out_valid(c_valid), .out_ready(c_ready), .out_data(c_data),
        .out_last(c_last), .msg_len(msg_len), .err(err)
    );

    kp_tee tee (
        .clk(clk), .rst(rst),
        .in_valid(c_valid), .in_ready(c_ready), .in_data(c_data), .in_last(c_last),
        .a_valid(a_valid), .a_ready(a_ready), .a_data(a_data), .a_last(a_last),
        .b_valid(b_valid), .b_ready(b_ready), .b_data(b_data), .b_last(b_last)
    );

    kp_capture #(.DEPTH(1024)) capA (
        .clk(clk), .rst(rst), .clear(1'b0),
        .in_valid(a_valid), .in_ready(a_ready), .in_data(a_data), .in_last(a_last),
        .count(cnt_a), .msgs(msgs_a), .rd_addr(rd_addr), .rd_data(rd_a)
    );
    kp_capture #(.DEPTH(1024)) capB (
        .clk(clk), .rst(rst), .clear(1'b0),
        .in_valid(b_valid), .in_ready(b_ready), .in_data(b_data), .in_last(b_last),
        .count(cnt_b), .msgs(msgs_b), .rd_addr(rd_addr), .rd_data(rd_b)
    );

    // expected bytes for the two messages (first vector row of each id)
    reg [7:0]  exp0 [0:255];  integer nexp0 = -1;
    reg [31:0] args0 [0:7];   integer nargs0;
    reg [7:0]  exp1 [0:255];  integer nexp1 = -1;
    reg [31:0] args1 [0:7];   integer nargs1;

    integer checks = 0, fails = 0;

    task automatic expect_ok(input bit cond, input string what);
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("FAIL %s", what);
            end
        end
    endtask

    integer vf, ef, code, mid, nargs, av, elen, i, j, guard;
    reg [8*64-1:0] dummy;

    initial begin
        // ---- load the two reference rows from vectors/expected ----
        vf = $fopen(`VEC_FILE, "r");
        ef = $fopen(`EXP_FILE, "r");
        if (vf == 0 || ef == 0) begin $display("FATAL: files"); $finish; end
        while (!$feof(vf) && (nexp0 < 0 || nexp1 < 0)) begin
            code = $fscanf(vf, "%d %d", mid, nargs);
            if (code != 2) begin code = $fgets(dummy, vf); end
            else begin
                for (i = 0; i < nargs; i = i + 1) begin
                    code = $fscanf(vf, "%h", av);
                    if (mid == SRC0_MSG && nexp0 < 0) args0[i] = av;
                    if (mid == SRC1_MSG && nexp1 < 0) args1[i] = av;
                end
                code = $fscanf(ef, "%d", elen);
                for (i = 0; i < elen; i = i + 1) begin
                    code = $fscanf(ef, "%h", av);
                    if (mid == SRC0_MSG && nexp0 < 0) exp0[i] = av[7:0];
                    if (mid == SRC1_MSG && nexp1 < 0) exp1[i] = av[7:0];
                end
                if (mid == SRC0_MSG && nexp0 < 0) begin nexp0 = elen; nargs0 = nargs; end
                else if (mid == SRC1_MSG && nexp1 < 0) begin nexp1 = elen; nargs1 = nargs; end
            end
        end
        $fclose(vf); $fclose(ef);

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // ---- test 1: both sources fire in the SAME cycle ----
        trig_id[15:0]  <= SRC0_MSG[15:0];
        trig_id[31:16] <= SRC1_MSG[15:0];
        for (i = 0; i < 8; i = i + 1) begin
            trig_args[i*32 +: 32]                 <= (i < nargs0) ? args0[i] : 32'd0;
            trig_args[(8+i)*32 +: 32]             <= (i < nargs1) ? args1[i] : 32'd0;
        end
        @(posedge clk);
        trig <= 2'b11;                 // simultaneous fire
        @(posedge clk);
        trig <= 2'b00;
        // POISON the trigger inputs right after the pulse: a correct core
        // took a one-cycle atomic snapshot on the trig edge, so garbage here
        // must NOT affect the output. A design that reads the inputs live at
        // grant time (no snapshot) would emit this garbage and fail below -
        // this is what makes the snapshot property actually discriminated.
        trig_id   <= 32'hDEAD_BEEF;
        for (i = 0; i < 16; i = i + 1) trig_args[i*32 +: 32] <= 32'hBADC0FFE;

        guard = 0;
        while (msgs_a < 2 && guard < 100000) begin @(posedge clk); guard = guard + 1; end
        repeat (4) @(posedge clk);

        expect_ok(msgs_a == 2, "two messages completed on sink A");
        expect_ok(msgs_b == 2, "two messages completed on sink B");
        expect_ok(cnt_a == nexp0 + nexp1, "sink A byte count == golden total");
        expect_ok(cnt_b == cnt_a, "tee: sink B count == sink A count");
        expect_ok(dropped == 16'd0, "no drops on clean double fire");
        // round-robin from rr=0: src0's message first, then src1's
        for (j = 0; j < nexp0 + nexp1; j = j + 1) begin
            rd_addr <= j[15:0];
            @(posedge clk); #1;
            expect_ok(rd_a === ((j < nexp0) ? exp0[j] : exp1[j - nexp0]),
                      $sformatf("sink A byte %0d matches golden", j));
            expect_ok(rd_b === rd_a, $sformatf("sink B byte %0d == sink A", j));
        end

        // ---- test 2: DROP policy - re-fire src0 while its slot is in flight ----
        // restore valid src0 trigger inputs (they were poisoned above)
        trig_id[15:0] <= SRC0_MSG[15:0];
        for (i = 0; i < 8; i = i + 1)
            trig_args[i*32 +: 32] <= (i < nargs0) ? args0[i] : 32'd0;
        @(posedge clk);
        trig <= 2'b01;                 // fire src0
        @(posedge clk);
        trig <= 2'b01;                 // fire again next cycle: slot pending/busy
        @(posedge clk);
        trig <= 2'b00;
        guard = 0;
        while (msgs_a < 3 && guard < 100000) begin @(posedge clk); guard = guard + 1; end
        repeat (4) @(posedge clk);
        expect_ok(msgs_a == 3, "third message (accepted snapshot) completed");
        expect_ok(dropped[7:0] == 8'd1, "src0 dropped_cnt == 1 after re-fire");
        expect_ok(dropped[15:8] == 8'd0, "src1 dropped_cnt still 0");
        expect_ok(!err, "no core error through the system test");

        $display("RESULT: %0d sys checks, %0d failures", checks, fails);
        if (fails != 0) $display("SYS-DIFF: FAIL");
        else            $display("SYS-DIFF: PASS");
        $finish;
    end
endmodule
`default_nettype wire
