// kp_core.sv - k_printf_hdl formatting core (ISA v2, docs/hdl/fmt_isa.md).
//
// RTL image of the C library's stateless core (k_vprintf_cb): consumes micro-ops
// from a ROM built by tools/k_fmtgen.py and emits the formatted ASCII byte stream
// with valid/ready handshake. Golden model = the real C library (see hdl/gold).
//
// Features: LIT, EOM, %c, %s(table-id), %d %i %u %x %X %o %b %B %p, flags
// - 0 # + space, field width AND .precision 0..63 (literal or '*' from an
// argument, C semantics incl. negative '*'), the l (32-bit) modifier. Decimal
// via serial double-dabble (no divider). ROM header (magic+version) verified at
// run time; invalid msg_id / malformed uop -> drop + sticky err, never hangs.
//
// Style note: this reference assembles each field into a small buffer and
// streams it - correctness first; the plan's buffer-free emit refactor (needed
// before kp_core itself synthesizes practically) is the next step.
`default_nettype none

module kp_core #(
    parameter        UOP_FILE    = "uop_rom.mem",
    parameter        LIT_FILE    = "lit_pool.mem",
    parameter        STR_FILE    = "str_pool.mem",
    parameter        STRTAB_FILE = "str_table.mem",
    parameter        MSTART_FILE = "msg_start.mem",
    parameter        MARITY_FILE = "msg_arity.mem",
    parameter int    ISA_VERSION = 2,
    // opt-in feature gates (the K_PRINTF_ENABLE_* analogue): with a gate at 0
    // the matching FSM branch becomes unreachable and synthesis prunes the
    // datapath (double-dabble / string machinery). k_fmtgen --disable keeps
    // the ROM consistent; a disabled uop reaching the core is treated as
    // malformed (err), defense in depth.
    parameter int    G_EN_DEC = 1,
    parameter int    G_EN_STR = 1,
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
        S_POW2=4'd5, S_LAYOUT=4'd6, S_EMIT=4'd7, S_STRLD=4'd8, S_EOM=4'd9,
        S_RESOLVE=4'd10, S_DROP=4'd11;

    // ROM word 0 must carry this header, or every message is refused (err).
    localparam [31:0] ROM_HDR = 32'h4B50_0000 | ISA_VERSION[7:0];
    reg [3:0]  st;
    reg [15:0] pc;                 // uop index
    reg [31:0] arg_snap [0:ARGC_MAX-1];

    // current uop decode (shared field positions per docs/hdl/fmt_isa.md)
    reg [31:0] uw;
    wire [2:0] op       = uw[31:29];
    wire [1:0] base     = uw[1:0];
    wire       upper    = uw[2];
    wire       is_sig   = uw[3];
    wire       size32   = uw[4];
    wire [4:0] flags    = uw[9:5];
    wire [5:0] width    = uw[15:10];
    wire [2:0] aslot    = uw[18:16];
    wire [5:0] precf    = uw[24:19];
    wire       prec_en  = uw[25];
    wire       w_from_a = uw[26];
    wire       p_from_a = uw[27];

    // literal streaming
    reg [15:0] lit_ptr, lit_rem;

    // resolved per-conversion state (literal or '*'-sourced)
    reg [31:0] mag;                // magnitude
    reg [1:0]  cbase;
    reg        cupper;
    reg [4:0]  cflags;
    reg [5:0]  cwidth;
    reg        cpen;               // effective precision present
    reg [5:0]  cprec;              // effective precision value
    reg [2:0]  vslot;              // derived value slot (past *-args)
    reg [7:0]  dig [0:31];         // ascii digits, LSB-first
    reg [5:0]  ndig;
    reg [39:0] bcd;
    reg [31:0] ddbin;
    reg [5:0]  ddi;
    reg [31:0] pw_tmp;

    // emit plan: the field is streamed phase-by-phase from counters (buffer-
    // free - the C fmt_int layout without materializing the field), which is
    // what lets kp_core synthesize (a byte buffer here explodes into muxes)
    reg [7:0]  sign_ch;            // 0 = none
    reg [1:0]  body_sel;           // 0=DIG 1=CHR 2=STR
    reg [7:0]  chr_byte;
    reg [15:0] str_addr;
    reg [7:0]  body_len;
    reg [7:0]  n_pre, n_zero, n_body, n_post;  // pending emit counts per phase
    reg        do_sign;
    reg [1:0]  n_pfx;
    reg [7:0]  p0_r, p1_r;
    reg [15:0] str_ptr;

    function [7:0] digit_ascii(input [3:0] v, input up);
        digit_ascii = (v < 4'd10) ? (8'h30 + v)
                    : (up ? (8'h41 + (v - 4'd10)) : (8'h61 + (v - 4'd10)));
    endfunction

    function [5:0] sat63(input [31:0] v);
        sat63 = (v > 32'd63) ? 6'd63 : v[5:0];
    endfunction

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
                    // !== : an X/unloaded ROM must fail CLOSED (refuse), like
                    // the VHDL twin's all-zeros fallback; yosys treats it as !=
                    if (uop_rom[0] !== ROM_HDR) begin
                        err <= 1'b1; st <= S_DROP;   // wrong ROM image: refuse all
                    end else if (msg_id >= N_MSGS) begin
                        err <= 1'b1; st <= S_DROP;   // drop, never hang
                    end else begin
                        pc <= msg_start[msg_id][15:0];
                        st <= S_FETCH;
                    end
                end
            end
            // ------------------------------------------------------------
            S_DROP: begin
                // one-cycle bounce after refusing a message, so exactly one
                // msg_ready pulse pairs with each presented message (staying
                // in S_IDLE would re-accept every cycle and let a duplicate
                // ready pulse swallow a later good message)
                st <= S_IDLE;
            end
            // ------------------------------------------------------------
            S_FETCH: begin
                uw <= uop_rom[pc];
                pc <= pc + 16'd1;
                case (uop_rom[pc][31:29])
                OP_LIT: begin
                    lit_ptr <= uop_rom[pc][15:0];
                    lit_rem <= uop_rom[pc][27:16];
                    st <= S_LIT;
                end
                OP_EOM: st <= S_EOM;
                OP_FMT, OP_CHR, OP_STR: st <= S_RESOLVE;
                default: begin      // reserved opcode -> malformed
                    err <= 1'b1; st <= S_EOM;
                end
                endcase
            end
            // ------------------------------------------------------------
            S_RESOLVE: begin
                // shared for FMT/CHR/STR: resolve '*'-sourced width/precision
                // from the leading argument slots ([w][p][value] order) and
                // latch the effective flags/width/precision + value slot.
                begin : rsv
                    reg [2:0] s; reg [31:0] wa, pa; reg [4:0] f;
                    s = aslot; f = flags;
                    if (w_from_a) begin
                        wa = arg_snap[s]; s = s + 3'd1;
                        if (wa[31]) begin       /* negative '*' width = LEFT */
                            f = f | (5'd1 << F_LEFT);
                            cwidth <= sat63(32'd0 - wa);
                        end else cwidth <= sat63(wa);
                    end else cwidth <= width;
                    if (p_from_a) begin
                        pa = arg_snap[s]; s = s + 3'd1;
                        cpen  <= ~pa[31];       /* negative '.*' = no precision */
                        cprec <= pa[31] ? 6'd0 : sat63(pa);
                    end else begin
                        cpen <= prec_en; cprec <= precf;
                    end
                    cflags <= f;
                    vslot  <= s;
                    sign_ch <= 8'd0;
                    case (op)
                    OP_FMT: st <= S_NUMSET;
                    OP_CHR: begin
                        chr_byte <= arg_snap[s][7:0];
                        body_sel <= 2'd1; body_len <= 8'd1;
                        st <= S_LAYOUT;
                    end
                    default: begin  /* OP_STR */
                        if (G_EN_STR == 0) begin
                            err <= 1'b1; st <= S_EOM;   // gated off: malformed
                        end else begin
                            pw_tmp   <= arg_snap[s];   /* string-table id */
                            body_sel <= 2'd2;
                            st <= S_STRLD;
                        end
                    end
                    endcase
                end
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
                    // id = low 16 bits mod table size (ISA rule; matches the
                    // golden dispatch and the VHDL integer range)
                    sid = pw_tmp[15:0] % N_STRINGS;
                    te  = str_table[sid];
                    str_addr <= te[15:0];
                    body_len <= te[23:16];   // string length
                    body_sel <= 2'd2;
                end
                st <= S_LAYOUT;
            end
            // ------------------------------------------------------------
            S_NUMSET: begin
                cbase <= base; cupper <= upper;
                begin : numset
                    reg [31:0] a, v; reg n;
                    a = arg_snap[vslot];
                    v = size32 ? a : {16'd0, a[15:0]};
                    n = 1'b0;
                    if (is_sig) begin
                        if (size32 ? a[31] : a[15]) begin
                            n = 1'b1;
                            v = size32 ? (32'd0 - a)
                                       : {16'd0, (16'd0 - a[15:0])};
                        end
                    end
                    mag <= v;
                    // sign char (cflags resolved in S_RESOLVE). The golden C
                    // library applies '+'/' ' to unsigned conversions too (its
                    // documented deviation from ISO C) - mirror it exactly.
                    if (is_sig && n)                      sign_ch <= 8'h2d; // '-'
                    else if (cflags[F_PLUS])              sign_ch <= 8'h2b; // '+'
                    else if (cflags[F_SPACE])             sign_ch <= 8'h20; // ' '
                    else                                  sign_ch <= 8'd0;
                    // prep converters
                    bcd <= 40'd0; ddbin <= v; ddi <= 6'd0;
                    pw_tmp <= v; ndig <= 6'd0;
                    body_sel <= 2'd0;
                end
                if (base == B_DEC) begin
                    if (G_EN_DEC == 0) begin
                        err <= 1'b1; st <= S_EOM;       // gated off: malformed
                    end else st <= S_DD;
                end else st <= S_POW2;
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
                // fmt_int layout: [pre_sp][sign][prefix][zeros] digits [post_sp]
                // with the C precision rules (see src/k_printf.c fmt_int).
                begin : lay
                    reg is_zero; reg [1:0] pl; reg [7:0] p0, p1;
                    reg [7:0] nde, lz, blen, bl, pad; reg zero_ok, slen;
                    reg [7:0] presp, zp, postsp;
                    slen = (sign_ch != 0) ? 8'd1 : 8'd0;
                    is_zero = (body_sel == 2'd0) && (mag == 0);
                    // precision 0 with value 0 => no digits at all (C rule)
                    nde = (body_sel == 2'd0 && cpen && cprec == 0 && mag == 0)
                          ? 8'd0 : {2'd0, ndig};
                    // precision = minimum digit count (zero-filled)
                    lz = (body_sel == 2'd0 && cpen && {2'd0,cprec} > nde)
                         ? ({2'd0,cprec} - nde) : 8'd0;
                    // alternate form: hex/bin get a prefix (nonzero only);
                    // octal forces a leading zero unless one already leads
                    // (C11 %#.0o-of-0 prints "0")
                    pl = 2'd0; p0 = 8'd0; p1 = 8'd0;
                    if (body_sel == 2'd0 && cflags[F_HASH]) begin
                        if (cbase == B_HEX && !is_zero) begin
                            pl=2'd2; p0=8'h30; p1=(cupper?8'h58:8'h78);
                        end else if (cbase == B_BIN && !is_zero) begin
                            pl=2'd2; p0=8'h30; p1=(cupper?8'h42:8'h62);
                        end else if (cbase == B_OCT) begin
                            if (lz == 0 && !(nde > 0 && mag == 0)) lz = 8'd1;
                        end
                    end
                    // body length per kind; %s truncated by precision
                    if (body_sel == 2'd0)      blen = lz + nde;
                    else if (body_sel == 2'd1) blen = 8'd1;
                    else begin
                        blen = body_len;
                        if (cpen && {2'd0,cprec} < blen) blen = {2'd0,cprec};
                    end
                    bl  = slen + {6'd0,pl} + blen;
                    pad = (cwidth > bl) ? (cwidth - bl) : 8'd0;
                    // '0' flag: numeric only, not with '-', ignored with precision
                    zero_ok = (body_sel==2'd0) && cflags[F_ZERO] && !cflags[F_LEFT] && !cpen;
                    presp = 8'd0; zp = 8'd0; postsp = 8'd0;
                    if (cflags[F_LEFT])   postsp = pad;
                    else if (zero_ok)     zp     = pad;
                    else                  presp  = pad;
                    // load the phase counters (no field buffer):
                    // [pre spaces][sign][prefix][zeros: zpad+lead] body [post]
                    n_pre  <= presp;
                    do_sign<= (slen != 0);
                    n_pfx  <= pl; p0_r <= p0; p1_r <= p1;
                    n_zero <= zp + lz;
                    n_body <= (body_sel == 2'd0) ? nde : blen;
                    n_post <= postsp;
                    str_ptr<= str_addr;
                end
                out_valid <= 1'b0;
                st <= S_EMIT;
            end
            // ------------------------------------------------------------
            S_EMIT: begin
                // stream the field phase-by-phase with the clean valid/ready
                // discipline; digits come out MSB-first via dig[n_body-1]
                if (!out_valid || out_ready) begin
                    out_last <= 1'b0;
                    if (n_pre != 0) begin
                        out_data <= 8'h20; out_valid <= 1'b1;
                        n_pre <= n_pre - 8'd1; msg_len <= msg_len + 16'd1;
                    end else if (do_sign) begin
                        out_data <= sign_ch; out_valid <= 1'b1;
                        do_sign <= 1'b0; msg_len <= msg_len + 16'd1;
                    end else if (n_pfx != 0) begin
                        out_data <= (n_pfx == 2'd2) ? p0_r : p1_r; out_valid <= 1'b1;
                        n_pfx <= n_pfx - 2'd1; msg_len <= msg_len + 16'd1;
                    end else if (n_zero != 0) begin
                        out_data <= 8'h30; out_valid <= 1'b1;
                        n_zero <= n_zero - 8'd1; msg_len <= msg_len + 16'd1;
                    end else if (n_body != 0) begin
                        case (body_sel)
                        2'd0:    out_data <= dig[n_body - 8'd1];
                        2'd1:    out_data <= chr_byte;
                        default: begin
                            out_data <= str_pool[str_ptr];
                            str_ptr  <= str_ptr + 16'd1;
                        end
                        endcase
                        out_valid <= 1'b1;
                        n_body <= n_body - 8'd1; msg_len <= msg_len + 16'd1;
                    end else if (n_post != 0) begin
                        out_data <= 8'h20; out_valid <= 1'b1;
                        n_post <= n_post - 8'd1; msg_len <= msg_len + 16'd1;
                    end else begin
                        out_valid <= 1'b0; st <= S_FETCH;
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
