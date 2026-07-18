// kp_uart_tb.sv - system-level differential test: kp_core -> kp_uart_tx.
//
// Drives the first NUART vector lines through the core, routes the byte stream
// into the UART (filtering the EOM marker beat), samples the serial line with an
// INDEPENDENT real-time bit model (resynchronized at every start edge), rebuilds
// the bytes and compares them against the C golden expected bytes. This verifies
// the whole chain a board would use, including the actual baud timing.
`default_nettype none
`timescale 1ns/1ps

module kp_uart_tb;
    localparam int ARGC_MAX = 8;
    localparam int CLK_HZ   = 48_000_000;
    localparam int BAUD     = 115_200;
    localparam int NUART    = 12;             // vector lines to run (UART is slow)
    localparam real BIT_NS  = 1.0e9 / BAUD;
`include "kp_msgs.svh"

    reg clk = 0, rst = 1;
    always #10.416 clk = ~clk;                // ~48 MHz

    reg         msg_valid = 0;
    wire        msg_ready;
    reg  [15:0] msg_id = 0;
    reg  [32*ARGC_MAX-1:0] args_flat = 0;
    wire        out_valid, out_last;
    wire [7:0]  out_data;
    wire [15:0] msg_len;
    wire        err;
    wire        uart_ready, txd;

    // EOM marker beat carries no data: filter it out of the UART stream and
    // consume it unconditionally on the core side.
    wire core_ready = out_last ? 1'b1 : uart_ready;

    kp_core #(
        .UOP_FILE(`UOP_FILE), .LIT_FILE(`LIT_FILE), .STR_FILE(`STR_FILE),
        .STRTAB_FILE(`STRTAB_FILE), .MSTART_FILE(`MSTART_FILE), .MARITY_FILE(`MARITY_FILE),
        .ISA_VERSION(KP_ISA_VERSION),
        .N_UOPS(KP_N_UOPS), .LIT_BYTES(KP_LIT_BYTES), .STR_BYTES(KP_STR_BYTES),
        .N_STRINGS(KP_N_STRINGS), .N_MSGS(KP_N_MSGS), .ARGC_MAX(ARGC_MAX)
    ) core (
        .clk(clk), .rst(rst), .msg_valid(msg_valid), .msg_ready(msg_ready),
        .msg_id(msg_id), .args_flat(args_flat),
        .out_valid(out_valid), .out_ready(core_ready), .out_data(out_data),
        .out_last(out_last), .msg_len(msg_len), .err(err)
    );

    kp_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) uart (
        .clk(clk), .rst(rst),
        .in_valid(out_valid && !out_last), .in_ready(uart_ready),
        .in_data(out_data), .txd(txd)
    );

    // ---- independent serial receiver (real-time bit model) ----
    reg [7:0] rx [0:2047];
    integer   nrx = 0;
    initial begin : rxproc
        integer b; reg [7:0] byte_v;
        forever begin
            @(negedge txd);                    // start edge
            #(BIT_NS * 1.5);                   // centre of data bit 0
            byte_v = 8'd0;
            for (b = 0; b < 8; b = b + 1) begin
                byte_v[b] = txd;
                #(BIT_NS);
            end
            // now at centre of the stop bit
            if (txd !== 1'b1)
                $display("FRAMING ERROR at byte %0d", nrx);
            rx[nrx] = byte_v;
            nrx = nrx + 1;
        end
    end

    integer vf, ef;
    integer checks = 0, fails = 0;
    integer i, mid, nargs, av, elen, code, base_rx;
    reg [7:0] exp [0:1023];
    integer nexp;
    reg [8*64-1:0] dummy;

    initial begin
        vf = $fopen(`VEC_FILE, "r");
        ef = $fopen(`EXP_FILE, "r");
        if (vf == 0 || ef == 0) begin $display("FATAL: cannot open files"); $finish; end
        repeat (8) @(posedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);

        while (!$feof(vf) && checks < NUART) begin
            code = $fscanf(vf, "%d %d", mid, nargs);
            if (code != 2) begin
                code = $fgets(dummy, vf);
            end else begin
                args_flat = {32*ARGC_MAX{1'b0}};
                for (i = 0; i < nargs; i = i + 1) begin
                    code = $fscanf(vf, "%h", av);
                    args_flat[i*32 +: 32] = av[31:0];
                end
                code = $fscanf(ef, "%d", elen);
                nexp = 0;
                for (i = 0; i < elen; i = i + 1) begin
                    code = $fscanf(ef, "%h", av);
                    exp[nexp] = av[7:0]; nexp = nexp + 1;
                end

                base_rx = nrx;
                @(posedge clk);
                msg_id <= mid[15:0]; msg_valid <= 1'b1;
                @(posedge clk);
                while (!msg_ready) @(posedge clk);
                msg_valid <= 1'b0;

                // wait until the serial line has delivered all expected bytes
                begin : waitrx
                    time t0;
                    t0 = $time;
                    while ((nrx - base_rx) < nexp &&
                           ($time - t0) < (nexp + 20) * BIT_NS * 12) #(BIT_NS);
                end
                #(BIT_NS * 2);

                checks = checks + 1;
                begin : cmp
                    integer bad; bad = 0;
                    if ((nrx - base_rx) != nexp) bad = 1;
                    else for (i = 0; i < nexp; i = i + 1)
                        if (rx[base_rx + i] !== exp[i]) bad = 1;
                    if (bad) begin
                        fails = fails + 1;
                        $write("UART MISMATCH msg=%0d got[%0d]=", mid, nrx - base_rx);
                        for (i = base_rx; i < nrx; i = i + 1) $write("%02x ", rx[i]);
                        $write("\n                exp[%0d]=", nexp);
                        for (i = 0; i < nexp; i = i + 1) $write("%02x ", exp[i]);
                        $write("\n");
                    end
                end
            end
        end

        $fclose(vf); $fclose(ef);
        $display("RESULT: %0d uart checks, %0d failures", checks, fails);
        if (fails != 0) $display("UART-DIFF: FAIL");
        else            $display("UART-DIFF: PASS");
        $finish;
    end
endmodule
`default_nettype wire
