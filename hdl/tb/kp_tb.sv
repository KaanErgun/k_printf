// kp_tb.sv - differential testbench for kp_core against the C golden model.
//
// Reads vectors.txt (stimuli) and expected.txt (C library output bytes), drives
// each message through kp_core, collects the emitted stream and asserts it equals
// the golden bytes. Exercises backpressure (out_ready gaps) per plan section 6.5.
// Also dumps the actual bytes to sv_out.txt so the equiv target can triple-diff
// C = SV = VHDL.
//
// Files are passed as +plusargs so the Makefile controls paths.
`default_nettype none
`timescale 1ns/1ps

module kp_tb;
    localparam int ARGC_MAX = 8;
`include "kp_msgs.svh"

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         msg_valid = 0;
    wire        msg_ready;
    reg  [15:0] msg_id = 0;
    reg  [32*ARGC_MAX-1:0] args_flat = 0;
    wire        out_valid;
    reg         out_ready = 1;
    wire [7:0]  out_data;
    wire        out_last;
    wire [15:0] msg_len;
    wire        err;

    kp_core #(
        .UOP_FILE(`UOP_FILE), .LIT_FILE(`LIT_FILE), .STR_FILE(`STR_FILE),
        .STRTAB_FILE(`STRTAB_FILE), .MSTART_FILE(`MSTART_FILE), .MARITY_FILE(`MARITY_FILE),
        .N_UOPS(KP_N_UOPS), .LIT_BYTES(KP_LIT_BYTES), .STR_BYTES(KP_STR_BYTES),
        .N_STRINGS(KP_N_STRINGS), .N_MSGS(KP_N_MSGS), .ARGC_MAX(ARGC_MAX)
    ) dut (
        .clk(clk), .rst(rst), .msg_valid(msg_valid), .msg_ready(msg_ready),
        .msg_id(msg_id), .args_flat(args_flat),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_last(out_last), .msg_len(msg_len), .err(err)
    );

    integer vf, ef, of;
    integer checks = 0, fails = 0;
    integer bp_lfsr = 32'h1234_5678;

    // collected bytes for the current message
    reg [7:0] got [0:1023];
    integer   ngot;

    // golden expected bytes for the current message
    reg [7:0] exp [0:1023];
    integer   nexp;

    integer i, mid, nargs, av, elen, code;
    reg [8*64-1:0] dummy;

    task automatic drive_message(input integer id, input integer na);
        integer j;
        begin
            @(posedge clk);
            msg_id    <= id[15:0];
            msg_valid <= 1'b1;
            // wait for accept
            @(posedge clk);
            while (!msg_ready) @(posedge clk);
            msg_valid <= 1'b0;
        end
    endtask

    // continuously collect output bytes; backpressure via out_ready
    reg collecting = 0;
    reg bp_pattern = 0;
    always @(posedge clk) begin
        // pseudo-random backpressure: sometimes drop ready
        bp_lfsr <= {bp_lfsr[30:0], bp_lfsr[31]^bp_lfsr[21]^bp_lfsr[1]^bp_lfsr[0]};
        if (bp_pattern == 0) out_ready <= 1'b1;
        else                 out_ready <= bp_lfsr[3];   // gappy
        if (collecting && out_valid && out_ready) begin
            if (out_last) begin
                collecting <= 1'b0;
            end else begin
                got[ngot] <= out_data;
                ngot <= ngot + 1;
            end
        end
    end

    initial begin
        vf = $fopen(`VEC_FILE, "r");
        ef = $fopen(`EXP_FILE, "r");
        of = $fopen(`OUT_FILE, "w");
        if (vf == 0 || ef == 0) begin $display("FATAL: cannot open vectors/expected"); $finish; end
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        while (!$feof(vf)) begin
            code = $fscanf(vf, "%d %d", mid, nargs);
            if (code != 2) begin
                // consume rest of line if malformed / blank
                code = $fgets(dummy, vf);
            end else begin
                args_flat = {32*ARGC_MAX{1'b0}};
                for (i = 0; i < nargs; i = i + 1) begin
                    code = $fscanf(vf, "%h", av);   // args are 8-nibble hex
                    args_flat[i*32 +: 32] = av[31:0];
                end
                // read expected line: elen then elen bytes
                code = $fscanf(ef, "%d", elen);
                nexp = 0;
                if (elen >= 0) begin
                    for (i = 0; i < elen; i = i + 1) begin
                        code = $fscanf(ef, "%h", av);
                        exp[nexp] = av[7:0]; nexp = nexp + 1;
                    end
                end

                // alternate backpressure pattern per message
                bp_pattern = mid[0];

                // drive and collect
                ngot = 0; collecting = 1;
                drive_message(mid, nargs);
                // wait until collection finishes (out_last seen) or timeout
                begin : waitdone
                    integer guard;
                    guard = 0;
                    while (collecting && guard < 200000) begin
                        @(posedge clk); guard = guard + 1;
                    end
                    if (guard >= 200000) $display("TIMEOUT msg %0d", mid);
                end
                @(posedge clk);

                // compare
                checks = checks + 1;
                begin : cmp
                    integer bad; bad = 0;
                    if (ngot != nexp) bad = 1;
                    else for (i = 0; i < nexp; i = i + 1)
                        if (got[i] !== exp[i]) bad = 1;
                    if (bad) begin
                        fails = fails + 1;
                        $write("MISMATCH msg=%0d got[%0d]=", mid, ngot);
                        for (i = 0; i < ngot; i = i + 1) $write("%02x ", got[i]);
                        $write("\n              exp[%0d]=", nexp);
                        for (i = 0; i < nexp; i = i + 1) $write("%02x ", exp[i]);
                        $write("\n");
                    end
                end
                // dump actual to out file for triple-diff
                $fwrite(of, "%0d", ngot);
                for (i = 0; i < ngot; i = i + 1) $fwrite(of, " %02x", got[i]);
                $fwrite(of, "\n");
            end
        end

        $fclose(vf); $fclose(ef); $fclose(of);
        $display("RESULT: %0d checks, %0d failures", checks, fails);
        if (fails != 0) $display("SV-DIFF: FAIL");
        else            $display("SV-DIFF: PASS");
        $finish;
    end
endmodule
`default_nettype wire
