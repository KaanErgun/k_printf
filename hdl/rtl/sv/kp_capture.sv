// kp_capture.sv - capture sink: the hardware analogue of k_snprintf.
//
// Stores the byte stream into a small RAM (up to DEPTH bytes; extra bytes are
// counted but not stored - the ISO-snprintf truncation idea) and counts
// completed messages via the out_last marker beat. A readout port lets a
// testbench or a register front-end inspect the captured text. count/msgs
// saturate at 0xFFFF so the truncation contract can't be broken by a wrap.
`default_nettype none

module kp_capture #(
    parameter int DEPTH = 1024
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,       // pulse: reset write pointer / counters
    // byte stream in (always ready)
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [7:0]  in_data,
    input  wire        in_last,     // end-of-message marker beat (not stored)
    // status + readout
    output reg  [15:0] count,       // bytes seen (saturating at 0xFFFF)
    output reg  [15:0] msgs,        // completed messages (saturating)
    input  wire [15:0] rd_addr,
    output wire [7:0]  rd_data
);
    localparam int AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    reg [7:0] mem [0:DEPTH-1];

    assign in_ready = 1'b1;
    // guarded readout: out-of-range reads return 0 (matches the VHDL twin;
    // an unguarded index would read X in sim / be implementation-defined in HW)
    assign rd_data  = (rd_addr < DEPTH) ? mem[rd_addr[AW-1:0]] : 8'd0;

    always @(posedge clk) begin
        if (rst || clear) begin
            count <= 16'd0; msgs <= 16'd0;
        end else if (in_valid) begin
            if (in_last) begin
                if (msgs != 16'hFFFF) msgs <= msgs + 16'd1;
            end else begin
                if (count < DEPTH) mem[count[AW-1:0]] <= in_data;
                if (count != 16'hFFFF) count <= count + 16'd1;   // saturate
            end
        end
    end
endmodule
`default_nettype wire
