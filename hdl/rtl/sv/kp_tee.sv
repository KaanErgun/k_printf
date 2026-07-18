// kp_tee.sv - broadcast one byte stream to two sinks (the k_fprintf idea:
// the same message to UART and to a capture RAM at once).
//
// A registered "fork": each byte is offered to both sinks and held until BOTH
// have accepted it, so neither sink misses a byte and the two streams stay
// byte-identical - even when the sinks accept on different cycles. Unlike a
// purely combinational tee (a_valid<-b_ready, b_valid<-a_ready), a_valid/b_valid
// here depend only on in_valid and internal state, so there is NO combinational
// valid<->ready loop: it is safe with ready-when-valid (AXI-Stream-legal) sinks.
`default_nettype none

module kp_tee (
    input  wire       clk,
    input  wire       rst,

    input  wire       in_valid,
    output wire       in_ready,
    input  wire [7:0] in_data,
    input  wire       in_last,

    output wire       a_valid,
    input  wire       a_ready,
    output wire [7:0] a_data,
    output wire       a_last,

    output wire       b_valid,
    input  wire       b_ready,
    output wire [7:0] b_data,
    output wire       b_last
);
    reg sent_a, sent_b;             // this byte already accepted by A / B

    // present to a sink until it has accepted the current byte
    assign a_valid = in_valid & ~sent_a;
    assign b_valid = in_valid & ~sent_b;
    assign a_data  = in_data;  assign a_last = in_last;
    assign b_data  = in_data;  assign b_last = in_last;
    // the input beat completes only once BOTH sinks have the byte
    assign in_ready = in_valid & (sent_a | a_ready) & (sent_b | b_ready);

    always @(posedge clk) begin
        if (rst) begin
            sent_a <= 1'b0; sent_b <= 1'b0;
        end else if (in_valid) begin
            if (in_ready) begin
                sent_a <= 1'b0; sent_b <= 1'b0;   // beat done: reset for next
            end else begin
                if (a_valid & a_ready) sent_a <= 1'b1;
                if (b_valid & b_ready) sent_b <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
