// kp_regs.sv - bus-agnostic register-window front-end for kp_core.
//
// The plan's CPU-facing surface: a softcore writes ARG0..7 then writes the
// message id to SEND - the SEND write IS the trigger (write-to-fire: no
// separate START bit, so there is no race window between "set id" and "go").
// Map (32-bit word registers, addr = word index):
//   0..7  ARG0..ARG7            (R/W)
//   8     SEND: write msg_id    (W)   - fires the message
//   9     STATUS                (R)   - [0] pend (SEND queued, not yet
//                                       accepted), [1] core err,
//                                       [15:8] overflow count (SEND written
//                                       while the previous one was pending:
//                                       the write is DROPPED and counted -
//                                       poll STATUS.pend first, that's the
//                                       CPU-side STALL contract)
// AXI-Lite / Wishbone bridges are thin shims over this port (future work).
`default_nettype none

module kp_regs #(
    parameter int ARGC_MAX = 8
)(
    input  wire        clk,
    input  wire        rst,
    // register access port
    input  wire        wen,
    input  wire [3:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    // core error status in
    input  wire        core_err,
    // to kp_core's message port
    output reg         msg_valid,
    input  wire        msg_ready,
    output reg  [15:0] msg_id,
    output wire [32*ARGC_MAX-1:0] args_flat
);
    reg [31:0] argr    [0:ARGC_MAX-1];   // live register file (CPU writes)
    reg [31:0] argsnap [0:ARGC_MAX-1];   // snapshot taken when SEND fires
    reg [7:0]  ovf;

    genvar g;
    generate
        for (g = 0; g < ARGC_MAX; g = g + 1) begin : flat
            // the core sees the SNAPSHOT, so ARG writes while a SEND is
            // pending cannot corrupt the already-fired message (matches
            // kp_trig's per-source snapshot semantics)
            assign args_flat[g*32 +: 32] = argsnap[g];
        end
    endgenerate

    always @(*) begin
        if (addr < ARGC_MAX)      rdata = argr[addr[2:0]];
        else if (addr == 4'd9)    rdata = {16'd0, ovf, 6'd0, core_err, msg_valid};
        else                      rdata = 32'd0;
    end

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            msg_valid <= 1'b0; ovf <= 8'd0;
            for (i = 0; i < ARGC_MAX; i = i + 1) begin
                argr[i] <= 32'd0; argsnap[i] <= 32'd0;
            end
        end else begin
            if (msg_valid && msg_ready)
                msg_valid <= 1'b0;                  // accepted by the core
            if (wen) begin
                if (addr < ARGC_MAX) begin
                    argr[addr[2:0]] <= wdata;
                end else if (addr == 4'd8) begin
                    // SEND may fire only if no SEND is still pending. A pending
                    // SEND being accepted THIS cycle frees the slot, so allow it.
                    if (msg_valid && !msg_ready) begin
                        // previous SEND still pending: drop + count (CPU must
                        // poll STATUS.pend - the register-window STALL contract)
                        if (ovf != 8'hFF) ovf <= ovf + 8'd1;
                    end else begin
                        msg_id    <= wdata[15:0];
                        msg_valid <= 1'b1;          // write-to-fire
                        for (i = 0; i < ARGC_MAX; i = i + 1)
                            argsnap[i] <= argr[i];  // snapshot args at fire time
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
