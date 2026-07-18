// kp_trig.sv - multi-source hardware trigger front-end for kp_core.
//
// The hardware-native value proposition of k_printf_hdl (the plan's flagship
// system feature): N trigger sources, each a {trig, msg_id, args} tuple. On the
// cycle trig pulses, the arguments are captured into a per-source shadow
// register in ONE clock - an atomic snapshot no software printf can give you -
// and a round-robin arbiter then forwards complete messages to the core's
// msg port, message-granular (bytes of different sources never interleave;
// the structural k_printf_lock).
//
// Full-slot policy is the plan's DROP choice for hardware sources: a trigger
// that fires while its own slot is still pending is counted in dropped_cnt
// (per source) instead of stalling the DUT. CPU-style clients that prefer
// STALL should use the core's msg port (or kp_regs) directly.
`default_nettype none

module kp_trig #(
    parameter int N_SRC    = 2,
    parameter int ARGC_MAX = 8,
    parameter int CNT_W    = 8
)(
    input  wire                       clk,
    input  wire                       rst,
    // trigger sources
    input  wire [N_SRC-1:0]           trig,
    input  wire [N_SRC*16-1:0]        trig_msg_id,   // per-source message id
    input  wire [N_SRC*32*ARGC_MAX-1:0] trig_args,
    output reg  [N_SRC*CNT_W-1:0]     dropped_cnt,   // per-source, saturating
    // to kp_core's message port
    output reg                        msg_valid,
    input  wire                       msg_ready,
    output reg  [15:0]                msg_id,
    output reg  [32*ARGC_MAX-1:0]     args_flat
);
    localparam int PW = $clog2(N_SRC > 1 ? N_SRC : 2);

    reg [N_SRC-1:0]       pend;
    reg [15:0]            id_snap  [0:N_SRC-1];
    reg [32*ARGC_MAX-1:0] arg_snap [0:N_SRC-1];
    reg [PW-1:0]          rr;    // round-robin pointer
    reg                   busy;  // a message is being handed over
    reg [PW-1:0]          cur;   // source being handed over

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            pend <= {N_SRC{1'b0}}; msg_valid <= 1'b0; busy <= 1'b0;
            rr <= {PW{1'b0}};
            dropped_cnt <= {N_SRC*CNT_W{1'b0}};
        end else begin
            // ---- capture: one-cycle atomic snapshot per firing source ----
            for (i = 0; i < N_SRC; i = i + 1) begin
                if (trig[i]) begin
                    if (pend[i] || (busy && cur == i)) begin
                        // slot still in flight: DROP + count (saturating)
                        if (dropped_cnt[i*CNT_W +: CNT_W] != {CNT_W{1'b1}})
                            dropped_cnt[i*CNT_W +: CNT_W]
                                <= dropped_cnt[i*CNT_W +: CNT_W] + 1'b1;
                    end else begin
                        id_snap[i]  <= trig_msg_id[i*16 +: 16];
                        arg_snap[i] <= trig_args[i*32*ARGC_MAX +: 32*ARGC_MAX];
                        pend[i]     <= 1'b1;
                    end
                end
            end

            // ---- hand-over: round-robin grant, message-granular ----
            if (!busy) begin
                begin : pick
                    reg found; integer j, s;
                    found = 0;
                    for (j = 0; j < N_SRC; j = j + 1) begin
                        // wrap without '%': rr+j < 2*N_SRC, one subtract
                        s = (rr + j >= N_SRC) ? (rr + j - N_SRC) : (rr + j);
                        if (!found && pend[s]) begin
                            found = 1;
                            cur       <= s[PW-1:0];
                            msg_id    <= id_snap[s];
                            args_flat <= arg_snap[s];
                            msg_valid <= 1'b1;
                            busy      <= 1'b1;
                        end
                    end
                end
            end else if (msg_valid && msg_ready) begin
                // accepted by the core: free the slot, advance round-robin
                msg_valid <= 1'b0;
                busy      <= 1'b0;
                pend[cur] <= 1'b0;
                rr        <= (cur + 1'b1 >= N_SRC[PW:0]) ? {PW{1'b0}} : (cur + 1'b1);
            end
        end
    end
endmodule
`default_nettype wire
