// kp_axil.sv - AXI4-Lite slave adapter over kp_regs.
//
// A thin bus front-end so a softcore (PicoRV32/NEORV32/VexRiscv/...) can drive
// the register window over AXI-Lite. It translates the AXI4-Lite handshakes to
// kp_regs' simple {wen, addr, wdata, rdata} port; kp_regs still owns the
// write-to-fire SEND and the arg snapshot. Word-addressed: byte address bits
// [5:2] select the register (ARG0..7 = 0..7, SEND = 8, STATUS = 9).
//
// Deliberately simple: one transaction at a time, writes take priority. reg_rdata
// is combinational on reg_addr, so a read latches reg_addr one cycle, then samples
// - no combinational valid<->ready loops.
`default_nettype none

module kp_axil #(
    parameter int AW = 6
)(
    input  wire          aclk,
    input  wire          aresetn,          // active-low, AXI convention
    // write address channel
    input  wire [AW-1:0] s_awaddr,
    input  wire          s_awvalid,
    output wire          s_awready,
    // write data channel
    input  wire [31:0]   s_wdata,
    input  wire [3:0]    s_wstrb,          // accepted, treated as full-word
    input  wire          s_wvalid,
    output wire          s_wready,
    // write response channel
    output wire [1:0]    s_bresp,
    output reg           s_bvalid,
    input  wire          s_bready,
    // read address channel
    input  wire [AW-1:0] s_araddr,
    input  wire          s_arvalid,
    output wire          s_arready,
    // read data channel
    output reg  [31:0]   s_rdata,
    output wire [1:0]    s_rresp,
    output reg           s_rvalid,
    input  wire          s_rready,
    // to kp_regs
    output reg           reg_wen,
    output reg  [3:0]    reg_addr,
    output reg  [31:0]   reg_wdata,
    input  wire [31:0]   reg_rdata
);
    assign s_bresp = 2'b00;   // always OKAY
    assign s_rresp = 2'b00;

    localparam [1:0] IDLE = 2'd0, WRESP = 2'd1, RDATA = 2'd2;
    reg [1:0] st;

    // combinational readys (depend only on state + input valids -> no loop):
    // aw+w accepted together in IDLE; ar accepted in IDLE when no write is offered
    wire wr_go = (st == IDLE) && s_awvalid && s_wvalid;
    assign s_awready = wr_go;
    assign s_wready  = wr_go;
    assign s_arready = (st == IDLE) && !wr_go && s_arvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            st <= IDLE;
            s_bvalid <= 1'b0; s_rvalid <= 1'b0;
            reg_wen <= 1'b0; reg_addr <= 4'd0; reg_wdata <= 32'd0; s_rdata <= 32'd0;
        end else begin
            reg_wen <= 1'b0;                // one-cycle pulse
            case (st)
            IDLE: begin
                if (wr_go) begin                        // write (priority)
                    reg_addr  <= s_awaddr[5:2];
                    reg_wdata <= s_wdata;
                    reg_wen   <= 1'b1;
                    s_bvalid  <= 1'b1;
                    st        <= WRESP;
                end else if (s_arvalid) begin           // read
                    reg_addr  <= s_araddr[5:2];
                    st        <= RDATA;
                end
            end
            WRESP: if (s_bready) begin s_bvalid <= 1'b0; st <= IDLE; end
            RDATA: begin
                if (!s_rvalid) begin
                    s_rdata  <= reg_rdata;  // reg_addr settled last cycle
                    s_rvalid <= 1'b1;
                end else if (s_rready) begin
                    s_rvalid <= 1'b0; st <= IDLE;
                end
            end
            default: st <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
