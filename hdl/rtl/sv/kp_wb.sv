// kp_wb.sv - Wishbone B4 (classic, single-cycle) slave adapter over kp_regs.
//
// The simplest bus front-end: a classic Wishbone slave that acks each access in
// one cycle. Word-addressed (adr is a word index; low 4 bits pick the register:
// ARG0..7 = 0..7, SEND = 8, STATUS = 9). Writes pulse kp_regs' wen (write-to-fire
// SEND lives in kp_regs); reads return reg_rdata (combinational) on the same beat.
`default_nettype none

module kp_wb #(
    parameter int ADR_W = 4
)(
    input  wire              clk_i,
    input  wire              rst_i,        // active-high, Wishbone convention
    input  wire [ADR_W-1:0]  wb_adr_i,     // word address
    input  wire [31:0]       wb_dat_i,
    output wire [31:0]       wb_dat_o,
    input  wire              wb_we_i,
    input  wire              wb_cyc_i,
    input  wire              wb_stb_i,
    output reg               wb_ack_o,
    // to kp_regs
    output wire              reg_wen,
    output wire [3:0]        reg_addr,
    output wire [31:0]       reg_wdata,
    input  wire [31:0]       reg_rdata
);
    wire access = wb_cyc_i & wb_stb_i & ~wb_ack_o;   // new beat, not yet acked

    // combinational register-port drive
    assign reg_addr  = wb_adr_i[3:0];
    assign reg_wdata = wb_dat_i;
    assign reg_wen   = access & wb_we_i;
    assign wb_dat_o  = reg_rdata;

    always @(posedge clk_i) begin
        if (rst_i)      wb_ack_o <= 1'b0;
        else            wb_ack_o <= access;           // single-cycle ack
    end
endmodule
`default_nettype wire
