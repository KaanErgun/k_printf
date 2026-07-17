// kp_core.sv - k_printf_hdl formatting core (reference slice, ISA v1).
//
// RTL image of the C library's stateless core (k_vprintf_cb): consumes micro-ops
// from a ROM built by tools/k_fmtgen.py and emits the formatted ASCII byte stream
// with valid/ready handshake. Golden model = the real C library (see hdl/gold).
//
// Feature slice: LIT, EOM, %c, %s(table-id), %d %i %u %x %X %o %b %B %p, flags
// - 0 # + space, field width 0..63, and the l (32-bit) modifier. Decimal via
// serial double-dabble (no divider), matching the plan. Precision / '*' deferred.
//
// Style note: this reference keeps a small digit buffer (<=32 bytes) and emits
// sign/prefix/pad via counters - correctness first; the plan's buffer-free area
// optimisation is Phase-2 work. Written in a synthesizable, Icarus-friendly subset.
`default_nettype none

module kp_core #(
    parameter        UOP_FILE    = "uop_rom.mem",
    parameter        LIT_FILE    = "lit_pool.mem",
    parameter        STR_FILE    = "str_pool.mem",
    parameter        STRTAB_FILE = "str_table.mem",
    parameter        MSTART_FILE = "msg_start.mem",
    parameter        MARITY_FILE = "msg_arity.mem",
    parameter int    N_UOPS   = 90,
    parameter int    LIT_BYTES= 149,
    parameter int    STR_BYTES= 20,
    parameter int    N_STRINGS= 5,
    parameter int    N_MSGS   = 15,
    parameter int    ARGC_MAX = 8
)(
    input  wire         clk,
    input  wire         rst,
    // message input
    input  wire         msg_valid,
    output reg          msg_ready,
    input  wire [15:0]  msg_id,
    input  wire [32*ARGC_MAX-1:0] args_flat,   // slot k = args_flat[k*32 +:32]
    // byte output stream
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [7:0]   out_data,
    output reg          out_last,
    output reg  [15:0]  msg_len,
    output reg          err          // sticky: bad msg_id / malformed uop seen
);
    // ---- flags / bases (mirror docs/hdl/fmt_isa.md) ----
    localparam [2:0] OP_LIT=3'd0, OP_FMT=3'd1, OP_STR=3'd2, OP_CHR=3'd3, OP_EOM=3'd7;
    localparam [1:0] B_DEC=2'd0, B_HEX=2'd1, B_OCT=2'd2, B_BIN=2'd3;
    localparam F_ZERO=0, F_LEFT=1, F_PLUS=2, F_SPACE=3, F_HASH=4;

    // ---- memories (init from generated .mem images) ----
    reg [31:0] uop_rom  [0:N_UOPS-1];
    reg [7:0]  lit_pool [0:LIT_BYTES-1];
    reg [7:0]  str_pool [0:STR_BYTES-1];
    reg [31:0] str_table[0:N_STRINGS-1];
    reg [31:0] msg_start[0:N_MSGS-1];
    reg [31:0] msg_arity[0:N_MSGS-1];
    initial begin
        $readmemh(UOP_FILE,    uop_rom);
        $readmemh(LIT_FILE,    lit_pool);
        $readmemh(STR_FILE,    str_pool);
        $readmemh(STRTAB_FILE, str_table);
        $readmemh(MSTART_FILE, msg_start);
        $readmemh(MARITY_FILE, msg_arity);
    end

    // ---- FSM ----
    localparam [3:0]
        S_IDLE=4'd0, S_FETCH=4'd1, S_LIT=4'd2, S_NUMSET=4'd3, S_DD=4'd4,
        S_POW2=4'd5, S_LAYOUT=4'd6, S_EMIT=4'd7, S_STRLD=4'd8, S_EOM=4'd9;
    reg [3:0]  st;
    reg [15:0] pc;                 // uop index
    reg [31:0] arg_snap [0:ARGC_MAX-1];

    // current uop decode
    reg [31:0] uw;
    wire [2:0] op    = uw[31:29];
    wire [15:0] lit_addr = uw[15:0];
    wire [11:0] lit_len  = uw[27:16];
    wire [1:0] base  = uw[1:0];
    wire       upper = uw[2];
    wire       is_sig= uw[3];
    wire       size32= uw[4];
    wire [4:0] flags = uw[9:5];
    wire [5:0] width = uw[15:10];
    wire [2:0] aslot = uw[18:16];

    // literal streaming
    reg [15:0] lit_ptr, lit_rem;

    // numeric working state
    reg [31:0] mag;                // magnitude
    reg        neg;
    reg [1:0]  cbase;
    reg        cupper;
    reg [4:0]  cflags;
    reg [5:0]  cwidth;
    reg [7:0]  dig [0:31];         // ascii digits, LSB-first
    reg [5:0]  ndig;
    reg [39:0] bcd;
    reg [31:0] ddbin;
    reg [5:0]  ddi;
    reg [31:0] pw_tmp;

    // emit plan
    reg [7:0]  sign_ch;            // 0 = none
    reg [1:0]  plen;
    reg [7:0]  pfx0, pfx1;
    reg [6:0]  pre_sp, zpad, post_sp;
    reg [1:0]  body_sel;           // 0=DIG 1=CHR 2=STR
    reg [7:0]  chr_byte;
    reg [15:0] str_addr;
    reg [7:0]  body_len;
    // assembled output field (reference keeps a small buffer; <=80 bytes)
    reg [7:0]  fld [0:95];
    reg [7:0]  flen, fidx;

    function [7:0] digit_ascii(input [3:0] v, input up);
        digit_ascii = (v < 4'd10) ? (8'h30 + v)
                    : (up ? (8'h41 + (v - 4'd10)) : (8'h61 + (v - 4'd10)));
    endfunction

    // helper: pick arg slot
    reg [31:0] cur_arg;
    always @(*) cur_arg = arg_snap[aslot];

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; msg_ready <= 1'b0; out_valid <= 1'b0;
            out_last <= 1'b0; msg_len <= 16'd0; err <= 1'b0;
        end else begin
            msg_ready <= 1'b0;
            case (st)
            // ------------------------------------------------------------
            S_IDLE: begin
                out_valid <= 1'b0; out_last <= 1'b0;
                if (msg_valid) begin
                    msg_ready <= 1'b1;               // accept this cycle
                    for (k = 0; k < ARGC_MAX; k = k+1)
                        arg_snap[k] <= args_flat[k*32 +: 32];   // atomic snapshot
                    msg_len <= 16'd0;
                    if (msg_id >= N_MSGS) begin
                        err <= 1'b1; st <= S_IDLE;   // drop, never hang
                    end else begin
                        pc <= msg_start[msg_id][15:0];
                        st <= S_FETCH;
                    end
                end
            end
            // ------------------------------------------------------------
            S_FETCH: begin
                uw <= uop_rom[pc];
                pc <= pc + 16'd1;
                // decode next cycle via combinational wires on uw; branch here
                // using the freshly-latched value requires a 1-cycle settle:
                st <= S_LAYOUT;    // provisional; corrected below by op
                // We decode by reading uop_rom[pc] directly (same value as uw):
                case (uop_rom[pc][31:29])
                OP_LIT: begin
                    lit_ptr <= uop_rom[pc][15:0];
                    lit_rem <= uop_rom[pc][27:16];
                    st <= S_LIT;
                end
                OP_EOM: st <= S_EOM;
                OP_FMT: st <= S_NUMSET;
                OP_CHR: begin
                    chr_byte <= arg_snap[uop_rom[pc][18:16]][7:0];
                    cflags   <= uop_rom[pc][9:5];
                    cwidth   <= uop_rom[pc][15:10];
                    body_sel <= 2'd1;
                    sign_ch  <= 8'd0; plen <= 2'd0;
                    body_len <= 7'd1;
                    st <= S_LAYOUT;
                end
                OP_STR: begin
                    cflags   <= uop_rom[pc][9:5];
                    cwidth   <= uop_rom[pc][15:10];
                    body_sel <= 2'd2;
                    sign_ch  <= 8'd0; plen <= 2'd0;
                    // str_id from arg slot, looked up next state
                    str_addr <= {16{1'b0}};   // set in S_STRLD
                    // stash chosen id via chr_byte reuse? use dedicated:
                    pw_tmp   <= arg_snap[uop_rom[pc][18:16]]; // holds str id
                    st <= S_STRLD;
                end
                default: begin      // reserved opcode -> malformed
                    err <= 1'b1; st <= S_EOM;
                end
                endcase
            end
            // ------------------------------------------------------------
            S_LIT: begin
                // clean valid/ready producer: only load a new byte when the
                // output slot is free (not valid, or being accepted this cycle)
                if (!out_valid || out_ready) begin
                    if (lit_rem == 0) begin
                        out_valid <= 1'b0; st <= S_FETCH;
                    end else begin
                        out_data  <= lit_pool[lit_ptr];
                        out_valid <= 1'b1;
                        out_last  <= 1'b0;
                        lit_ptr   <= lit_ptr + 16'd1;
                        lit_rem   <= lit_rem - 16'd1;
                        msg_len   <= msg_len + 16'd1;
                    end
                end
            end
            // ------------------------------------------------------------
            S_STRLD: begin
                // pw_tmp holds the string id; clamp to table then load {addr,len}
                begin : strload
                    reg [31:0] te, sid;
                    sid = pw_tmp % N_STRINGS;
                    te  = str_table[sid];
                    str_addr <= te[15:0];
                    body_len <= te[23:16];   // string length
                    body_sel <= 2'd2;
                end
                st <= S_LAYOUT;
            end
            // ------------------------------------------------------------
            S_NUMSET: begin
                cbase  <= base; cupper <= upper; cflags <= flags; cwidth <= width;
                begin : numset
                    reg [31:0] v; reg n;
                    v = size32 ? cur_arg : {16'd0, cur_arg[15:0]};
                    n = 1'b0;
                    if (is_sig) begin
                        if (size32 ? cur_arg[31] : cur_arg[15]) begin
                            n = 1'b1;
                            v = size32 ? (32'd0 - cur_arg)
                                       : {16'd0, (16'd0 - cur_arg[15:0])};
                        end
                    end
                    mag <= v; neg <= n;
                    // sign char
                    if (is_sig && n)                      sign_ch <= 8'h2d; // '-'
                    else if (is_sig && flags[F_PLUS])     sign_ch <= 8'h2b; // '+'
                    else if (is_sig && flags[F_SPACE])    sign_ch <= 8'h20; // ' '
                    else                                  sign_ch <= 8'd0;
                    // prep converters
                    bcd <= 40'd0; ddbin <= v; ddi <= 6'd0;
                    pw_tmp <= v; ndig <= 6'd0;
                    body_sel <= 2'd0;
                end
                st <= (base == B_DEC) ? S_DD : S_POW2;
            end
            // ------------------------------------------------------------
            S_DD: begin   // serial double-dabble: 32 iterations
                if (ddi == 6'd32) begin
                    // extract significant BCD digits into dig[] LSB-first
                    begin : ddext
                        integer j; reg [5:0] cnt;
                        for (j = 0; j <= 9; j = j+1)
                            dig[j] = digit_ascii(bcd[j*4 +: 4], 1'b0);
                        cnt = 1;   // at least one digit ("0")
                        for (j = 0; j <= 9; j = j+1)
                            if (bcd[j*4 +: 4] != 0) cnt = j+1;
                        ndig <= cnt;
                    end
                    st <= S_LAYOUT;
                end else begin
                    // add-3 correction then shift
                    begin : ddstep
                        reg [39:0] c; integer j;
                        c = bcd;
                        for (j = 0; j <= 9; j = j+1)
                            if (c[j*4 +: 4] >= 5) c[j*4 +: 4] = c[j*4 +: 4] + 4'd3;
                        bcd   <= {c[38:0], ddbin[31]};
                        ddbin <= {ddbin[30:0], 1'b0};
                    end
                    ddi <= ddi + 6'd1;
                end
            end
            // ------------------------------------------------------------
            S_POW2: begin  // extract base-2^k digits LSB-first
                begin : pw
                    reg [4:0] sh; reg [3:0] msk; reg [3:0] d;
                    case (cbase)
                        B_HEX: begin sh = 5'd4; msk = 4'hf; end
                        B_OCT: begin sh = 5'd3; msk = 4'h7; end
                        default: begin sh = 5'd1; msk = 4'h1; end // BIN
                    endcase
                    d = pw_tmp[3:0] & msk;
                    dig[ndig] <= digit_ascii(d, cupper);
                    pw_tmp <= pw_tmp >> sh;
                    if ((pw_tmp >> sh) == 0) begin
                        ndig <= ndig + 6'd1;
                        st <= S_LAYOUT;
                    end else begin
                        ndig <= ndig + 6'd1;
                    end
                end
            end
            // ------------------------------------------------------------
            S_LAYOUT: begin
                // assemble the whole field into fld[0..flen-1], matching the C
                // fmt_int layout: [pre_sp][sign][prefix][zero_pad] body [post_sp]
                begin : lay
                    reg is_zero; reg [1:0] pl; reg [7:0] p0, p1;
                    reg [7:0] blen, bl, pad; reg zero_ok, slen;
                    reg [7:0] presp, zp, postsp;
                    integer j; reg [7:0] idx;
                    slen = (sign_ch != 0) ? 8'd1 : 8'd0;
                    is_zero = (body_sel == 2'd0) && (mag == 0);
                    pl = 2'd0; p0 = 8'd0; p1 = 8'd0;
                    if (body_sel == 2'd0 && cflags[F_HASH] && !is_zero) begin
                        if (cbase == B_HEX) begin pl=2'd2; p0=8'h30; p1=(cupper?8'h58:8'h78); end
                        else if (cbase == B_BIN) begin pl=2'd2; p0=8'h30; p1=(cupper?8'h42:8'h62); end
                        else if (cbase == B_OCT) begin pl=2'd1; p0=8'h30; end
                    end
                    blen = (body_sel==2'd0) ? {2'd0,ndig} : ((body_sel==2'd1) ? 8'd1 : body_len);
                    bl  = slen + {6'd0,pl} + blen;
                    pad = (cwidth > bl) ? (cwidth - bl) : 8'd0;
                    zero_ok = (body_sel==2'd0) && cflags[F_ZERO] && !cflags[F_LEFT];
                    presp = 8'd0; zp = 8'd0; postsp = 8'd0;
                    if (cflags[F_LEFT])   postsp = pad;
                    else if (zero_ok)     zp     = pad;
                    else                  presp  = pad;
                    // fill buffer
                    idx = 0;
                    for (j = 0; j < presp; j = j+1) begin fld[idx] = 8'h20; idx = idx+1; end
                    if (slen)                     begin fld[idx] = sign_ch; idx = idx+1; end
                    if (pl >= 1)                  begin fld[idx] = p0; idx = idx+1; end
                    if (pl == 2)                  begin fld[idx] = p1; idx = idx+1; end
                    for (j = 0; j < zp; j = j+1)   begin fld[idx] = 8'h30; idx = idx+1; end
                    if (body_sel == 2'd0)
                        for (j = 0; j < blen; j = j+1) begin fld[idx] = dig[ndig-1-j[5:0]]; idx = idx+1; end
                    else if (body_sel == 2'd1)    begin fld[idx] = chr_byte; idx = idx+1; end
                    else
                        for (j = 0; j < blen; j = j+1) begin fld[idx] = str_pool[str_addr + j[15:0]]; idx = idx+1; end
                    for (j = 0; j < postsp; j = j+1) begin fld[idx] = 8'h20; idx = idx+1; end
                    flen = idx;
                end
                fidx <= 8'd0; out_valid <= 1'b0;
                st <= S_EMIT;
            end
            // ------------------------------------------------------------
            S_EMIT: begin
                // stream fld[0..flen-1] with the clean valid/ready discipline
                if (!out_valid || out_ready) begin
                    if (fidx >= flen) begin
                        out_valid <= 1'b0; st <= S_FETCH;
                    end else begin
                        out_data  <= fld[fidx];
                        out_valid <= 1'b1;
                        out_last  <= 1'b0;
                        fidx      <= fidx + 8'd1;
                        msg_len   <= msg_len + 16'd1;
                    end
                end
            end
            // ------------------------------------------------------------
            S_EOM: begin
                // present the end-of-message marker for exactly one accepted
                // handshake (out_last=1, no data byte counted)
                if (!out_valid) begin
                    out_valid <= 1'b1; out_last <= 1'b1; out_data <= 8'd0;
                end else if (out_ready) begin
                    out_valid <= 1'b0; out_last <= 1'b0; st <= S_IDLE;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
