// kp_uart_tx.sv - 8N1 UART transmitter with a fractional (N.F) baud generator.
//
// The RTL echo of the MSP430 examples' USCI UART: the baud rate is derived with
// a fractional accumulator (acc += BAUD; tick when acc >= CLK_HZ) - the same
// idea as the UCBRS modulation - so no derived clock and no divider are needed;
// average bit rate is exactly BAUD with <= 1 clk of jitter per bit edge.
//
// Feed it from kp_core with:  in_valid = out_valid && !out_last
// (the EOM marker beat carries no data byte) and give the core
// out_ready = out_last ? 1'b1 : uart_in_ready.
`default_nettype none

module kp_uart_tx #(
    parameter int CLK_HZ = 48_000_000,
    parameter int BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       in_valid,
    output wire       in_ready,
    input  wire [7:0] in_data,
    output reg        txd
);
    reg [31:0] acc;
    reg [8:0]  shifter;      // {stop, data[7:0]}
    reg [3:0]  nbits;        // bits left after the one currently on txd
    reg        busy;

    assign in_ready = !busy;

    wire tick = (acc + BAUD) >= CLK_HZ;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; txd <= 1'b1; acc <= 32'd0;
        end else if (!busy) begin
            txd <= 1'b1;
            if (in_valid) begin
                shifter <= {1'b1, in_data};   // stop bit + data (LSB first)
                txd     <= 1'b0;              // start bit from this cycle
                nbits   <= 4'd9;              // 8 data + stop still to send
                acc     <= 32'd0;             // full-width start bit
                busy    <= 1'b1;
            end
        end else begin
            if (tick) begin
                acc <= acc + BAUD - CLK_HZ;
                if (nbits == 0) begin
                    busy <= 1'b0;             // stop bit complete
                    txd  <= 1'b1;
                end else begin
                    txd     <= shifter[0];
                    shifter <= {1'b1, shifter[8:1]};
                    nbits   <= nbits - 4'd1;
                end
            end else begin
                acc <= acc + BAUD;
            end
        end
    end
endmodule
`default_nettype wire
