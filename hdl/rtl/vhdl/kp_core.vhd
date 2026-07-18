-- kp_core.vhd - k_printf_hdl formatting core, VHDL-2008 twin of rtl/sv/kp_core.sv.
--
-- Structural mirror: same entity/port names, same FSM states, same micro-op ISA
-- (docs/hdl/fmt_isa.md). Verified by the same golden model (the C library) and the
-- same stimulus/expected vectors as the SV core; the equiv target diffs C = SV = VHDL.
--
-- Features (ISA v2): LIT, EOM, %c, %s(table-id), %d %i %u %x %X %o %b %B %p,
-- flags - 0 # + space, width AND .precision 0..63 (literal or '*' from an
-- argument), l (32-bit). Decimal via serial double-dabble. ROM header verified
-- at run time; invalid msg_id / malformed uop -> drop + sticky err.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity kp_core is
    generic (
        UOP_FILE    : string  := "uop_rom.mem";
        LIT_FILE    : string  := "lit_pool.mem";
        STR_FILE    : string  := "str_pool.mem";
        STRTAB_FILE : string  := "str_table.mem";
        MSTART_FILE : string  := "msg_start.mem";
        MARITY_FILE : string  := "msg_arity.mem";
        ISA_VERSION : integer := 2;
        -- opt-in feature gates (K_PRINTF_ENABLE_* analogue, mirror of the SV)
        G_EN_DEC    : integer := 1;
        G_EN_STR    : integer := 1;
        N_UOPS      : integer := 90;
        LIT_BYTES   : integer := 149;
        STR_BYTES   : integer := 20;
        N_STRINGS   : integer := 5;
        N_MSGS      : integer := 15;
        ARGC_MAX    : integer := 8
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        msg_valid  : in  std_logic;
        msg_ready  : out std_logic;
        msg_id     : in  unsigned(15 downto 0);
        args_flat  : in  std_logic_vector(32*ARGC_MAX-1 downto 0);
        out_valid  : out std_logic;
        out_ready  : in  std_logic;
        out_data   : out std_logic_vector(7 downto 0);
        out_last   : out std_logic;
        msg_len    : out unsigned(15 downto 0);
        err        : out std_logic
    );
end entity;

architecture rtl of kp_core is
    type u32_array is array(natural range <>) of unsigned(31 downto 0);
    type u8_array  is array(natural range <>) of unsigned(7 downto 0);

    impure function load32(fname : string; n : integer) return u32_array is
        file f     : text;
        variable l : line;
        variable v : std_logic_vector(31 downto 0);
        variable a : u32_array(0 to n-1) := (others => (others => '0'));
        variable i : integer := 0;
        variable status : file_open_status;
    begin
        file_open(status, f, fname, read_mode);
        if status /= open_ok then return a; end if;
        while not endfile(f) and i < n loop
            readline(f, l);
            if l'length > 0 then hread(l, v); a(i) := unsigned(v); i := i + 1; end if;
        end loop;
        file_close(f);
        return a;
    end function;

    impure function load8(fname : string; n : integer) return u8_array is
        file f     : text;
        variable l : line;
        variable v : std_logic_vector(7 downto 0);
        variable a : u8_array(0 to n-1) := (others => (others => '0'));
        variable i : integer := 0;
        variable status : file_open_status;
    begin
        file_open(status, f, fname, read_mode);
        if status /= open_ok then return a; end if;
        while not endfile(f) and i < n loop
            readline(f, l);
            if l'length > 0 then hread(l, v); a(i) := unsigned(v); i := i + 1; end if;
        end loop;
        file_close(f);
        return a;
    end function;

    signal uop_rom   : u32_array(0 to N_UOPS-1)   := load32(UOP_FILE, N_UOPS);
    signal lit_pool  : u8_array(0 to LIT_BYTES-1)  := load8(LIT_FILE, LIT_BYTES);
    signal str_pool  : u8_array(0 to STR_BYTES-1)  := load8(STR_FILE, STR_BYTES);
    signal str_table : u32_array(0 to N_STRINGS-1) := load32(STRTAB_FILE, N_STRINGS);
    signal msg_start : u32_array(0 to N_MSGS-1)    := load32(MSTART_FILE, N_MSGS);
    signal msg_arity : u32_array(0 to N_MSGS-1)    := load32(MARITY_FILE, N_MSGS);

    -- op / flag / base codes (mirror the ISA)
    constant OP_LIT : unsigned(2 downto 0) := "000";
    constant OP_FMT : unsigned(2 downto 0) := "001";
    constant OP_STR : unsigned(2 downto 0) := "010";
    constant OP_CHR : unsigned(2 downto 0) := "011";
    constant OP_EOM : unsigned(2 downto 0) := "111";
    constant B_DEC : unsigned(1 downto 0) := "00";
    constant B_HEX : unsigned(1 downto 0) := "01";
    constant B_OCT : unsigned(1 downto 0) := "10";
    constant B_BIN : unsigned(1 downto 0) := "11";

    type state_t is (S_IDLE, S_FETCH, S_LIT, S_NUMSET, S_DD, S_POW2, S_LAYOUT,
                     S_EMIT, S_STRLD, S_EOM, S_RESOLVE, S_DROP);
    signal st : state_t := S_IDLE;

    -- ROM word 0 must carry this header, or every message is refused (err).
    constant ROM_HDR : unsigned(31 downto 0) :=
        x"4B50_0000" or to_unsigned(ISA_VERSION, 32);

    type snap_t is array(0 to ARGC_MAX-1) of unsigned(31 downto 0);
    type dig_t  is array(0 to 31) of unsigned(7 downto 0);

    function digit_ascii(v : unsigned(3 downto 0); up : std_logic) return unsigned is
        variable n : integer := to_integer(v);
    begin
        if n < 10 then return to_unsigned(16#30# + n, 8);
        elsif up = '1' then return to_unsigned(16#41# + n - 10, 8);
        else return to_unsigned(16#61# + n - 10, 8); end if;
    end function;

    function sat63(v : unsigned(31 downto 0)) return integer is
    begin
        if v > 63 then return 63; else return to_integer(v(5 downto 0)); end if;
    end function;

    -- registers
    signal pc       : integer range 0 to 65535 := 0;
    signal arg_snap : snap_t;
    signal uw       : unsigned(31 downto 0) := (others => '0');
    signal lit_ptr  : integer range 0 to 65535 := 0;
    signal lit_rem  : integer range 0 to 65535 := 0;
    signal mag      : unsigned(31 downto 0);
    signal cbase    : unsigned(1 downto 0);
    signal cupper   : std_logic;
    signal cflags   : unsigned(4 downto 0);
    signal cwidth   : integer range 0 to 63;
    signal cpen     : std_logic;                 -- effective precision present
    signal cprec    : integer range 0 to 63;     -- effective precision value
    signal vslot    : integer range 0 to 7;      -- derived value slot
    signal dig      : dig_t;
    signal ndig     : integer range 0 to 32;
    signal bcd      : unsigned(39 downto 0);
    signal ddi      : integer range 0 to 32;
    signal pw_tmp   : unsigned(31 downto 0);
    signal sign_ch  : unsigned(7 downto 0);
    signal body_sel : integer range 0 to 2;
    signal chr_byte : unsigned(7 downto 0);
    signal str_addr : integer range 0 to 65535;
    signal body_len : integer range 0 to 255;
    -- buffer-free emit: pending counts per phase (mirror of the SV core)
    signal n_pre, n_zero, n_body, n_post : integer range 0 to 255;
    signal do_sign  : std_logic;
    signal n_pfx    : integer range 0 to 2;
    signal p0_r, p1_r : unsigned(7 downto 0);
    signal str_ptr  : integer range 0 to 65535;
    signal ovalid   : std_logic := '0';
    signal olast    : std_logic := '0';
    signal odata    : unsigned(7 downto 0) := (others => '0');
    signal mlen     : unsigned(15 downto 0) := (others => '0');
    signal errr     : std_logic := '0';

    -- flag bit indices
    constant F_ZERO  : integer := 0;
    constant F_LEFT  : integer := 1;
    constant F_PLUS  : integer := 2;
    constant F_SPACE : integer := 3;
    constant F_HASH  : integer := 4;
begin
    out_valid <= ovalid;
    out_last  <= olast;
    out_data  <= std_logic_vector(odata);
    msg_len   <= mlen;
    err       <= errr;

    process(clk)
        variable w        : unsigned(31 downto 0);
        variable aslot    : integer;
        variable cur_arg  : unsigned(31 downto 0);
        variable v        : unsigned(31 downto 0);
        variable n        : std_logic;
        variable c        : unsigned(39 downto 0);
        variable j        : integer;
        variable cnt      : integer;
        variable fl       : unsigned(4 downto 0);
        variable slotv    : integer;
        variable wa, pa   : unsigned(31 downto 0);
        variable nde, lz  : integer;
        variable sh, mskn : integer;
        variable dval     : unsigned(3 downto 0);
        variable is_zero  : boolean;
        variable pl       : integer;
        variable p0, p1   : unsigned(7 downto 0);
        variable slen     : integer;
        variable blen     : integer;
        variable bl       : integer;
        variable pad      : integer;
        variable zero_ok  : boolean;
        variable presp, zp, postsp : integer;
        variable sid      : integer;
        variable te       : unsigned(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                st <= S_IDLE; msg_ready <= '0'; ovalid <= '0'; olast <= '0';
                mlen <= (others => '0'); errr <= '0';
            else
                msg_ready <= '0';
                case st is
                -- ----------------------------------------------------------
                when S_IDLE =>
                    ovalid <= '0'; olast <= '0';
                    if msg_valid = '1' then
                        msg_ready <= '1';
                        for k in 0 to ARGC_MAX-1 loop
                            arg_snap(k) <= unsigned(args_flat(k*32+31 downto k*32));
                        end loop;
                        mlen <= (others => '0');
                        if uop_rom(0) /= ROM_HDR then
                            errr <= '1'; st <= S_DROP;  -- wrong ROM image: refuse all
                        elsif to_integer(msg_id) >= N_MSGS then
                            errr <= '1'; st <= S_DROP;  -- drop, never hang
                        else
                            pc <= to_integer(msg_start(to_integer(msg_id))(15 downto 0));
                            st <= S_FETCH;
                        end if;
                    end if;
                -- ----------------------------------------------------------
                when S_DROP =>
                    -- one-cycle bounce after refusing a message: exactly one
                    -- msg_ready pulse pairs with each presented message
                    st <= S_IDLE;
                -- ----------------------------------------------------------
                when S_FETCH =>
                    w  := uop_rom(pc);
                    uw <= w;
                    pc <= pc + 1;
                    case w(31 downto 29) is
                    when OP_LIT =>
                        lit_ptr <= to_integer(w(15 downto 0));
                        lit_rem <= to_integer(w(27 downto 16));
                        st <= S_LIT;
                    when OP_EOM =>
                        st <= S_EOM;
                    when OP_FMT | OP_CHR | OP_STR =>
                        st <= S_RESOLVE;
                    when others =>
                        errr <= '1'; st <= S_EOM;
                    end case;
                -- ----------------------------------------------------------
                when S_RESOLVE =>
                    -- shared for FMT/CHR/STR: resolve '*'-sourced width and
                    -- precision from the leading arg slots ([w][p][value]) and
                    -- latch effective flags/width/precision + value slot. All
                    -- arg_snap reads mask the slot to the valid range (a
                    -- malformed ROM could drive slotv past ARGC_MAX; the SV
                    -- twin's 3-bit index wraps the same way instead of
                    -- crashing the sim on an out-of-bounds read).
                    slotv := to_integer(uw(18 downto 16));
                    fl    := uw(9 downto 5);
                    if uw(26) = '1' then                 -- w_from_arg
                        wa := arg_snap(slotv mod ARGC_MAX); slotv := slotv + 1;
                        if wa(31) = '1' then             -- negative '*' = LEFT
                            fl(F_LEFT) := '1';
                            cwidth <= sat63(0 - wa);
                        else
                            cwidth <= sat63(wa);
                        end if;
                    else
                        cwidth <= to_integer(uw(15 downto 10));
                    end if;
                    if uw(27) = '1' then                 -- p_from_arg
                        pa := arg_snap(slotv mod ARGC_MAX); slotv := slotv + 1;
                        if pa(31) = '1' then             -- negative '.*' = none
                            cpen <= '0'; cprec <= 0;
                        else
                            cpen <= '1'; cprec <= sat63(pa);
                        end if;
                    else
                        cpen  <= uw(25);
                        cprec <= to_integer(uw(24 downto 19));
                    end if;
                    cflags  <= fl;
                    vslot   <= slotv mod ARGC_MAX;
                    sign_ch <= (others => '0');
                    case uw(31 downto 29) is
                    when OP_FMT =>
                        st <= S_NUMSET;
                    when OP_CHR =>
                        chr_byte <= arg_snap(slotv mod ARGC_MAX)(7 downto 0);
                        body_sel <= 1; body_len <= 1;
                        st <= S_LAYOUT;
                    when others =>                        -- OP_STR
                        if G_EN_STR = 0 then
                            errr <= '1'; st <= S_EOM;     -- gated off: malformed
                        else
                            pw_tmp   <= arg_snap(slotv mod ARGC_MAX);  -- str id
                            body_sel <= 2;
                            st <= S_STRLD;
                        end if;
                    end case;
                -- ----------------------------------------------------------
                when S_LIT =>
                    if ovalid = '0' or out_ready = '1' then
                        if lit_rem = 0 then
                            ovalid <= '0'; st <= S_FETCH;
                        else
                            odata  <= lit_pool(lit_ptr);
                            ovalid <= '1'; olast <= '0';
                            lit_ptr <= lit_ptr + 1;
                            lit_rem <= lit_rem - 1;
                            mlen <= mlen + 1;
                        end if;
                    end if;
                -- ----------------------------------------------------------
                when S_STRLD =>
                    -- low 16 bits are enough for the id and avoid the VHDL
                    -- integer-overflow trap of to_integer on a full 2^32 value
                    sid := to_integer(pw_tmp(15 downto 0)) mod N_STRINGS;
                    te  := str_table(sid);
                    str_addr <= to_integer(te(15 downto 0));
                    body_len <= to_integer(te(23 downto 16));  -- string length
                    body_sel <= 2;
                    st <= S_LAYOUT;
                -- ----------------------------------------------------------
                when S_NUMSET =>
                    cur_arg := arg_snap(vslot);
                    cbase <= uw(1 downto 0); cupper <= uw(2);
                    if uw(4) = '1' then v := cur_arg;
                    else v := x"0000" & cur_arg(15 downto 0); end if;
                    n := '0';
                    if uw(3) = '1' then  -- signed
                        if (uw(4) = '1' and cur_arg(31) = '1') or
                           (uw(4) = '0' and cur_arg(15) = '1') then
                            n := '1';
                            if uw(4) = '1' then v := (0 - cur_arg);
                            else v := x"0000" & (0 - cur_arg(15 downto 0)); end if;
                        end if;
                    end if;
                    mag <= v;
                    -- sign char (cflags resolved in S_RESOLVE). The golden C
                    -- library applies '+'/' ' to unsigned conversions too (its
                    -- documented deviation from ISO C) - mirror it exactly.
                    if uw(3) = '1' and n = '1' then sign_ch <= x"2d";
                    elsif cflags(F_PLUS) = '1' then sign_ch <= x"2b";
                    elsif cflags(F_SPACE) = '1' then sign_ch <= x"20";
                    else sign_ch <= (others => '0'); end if;
                    bcd <= (others => '0'); ddi <= 0;
                    pw_tmp <= v; ndig <= 0; body_sel <= 0;
                    if uw(1 downto 0) = B_DEC then
                        if G_EN_DEC = 0 then
                            errr <= '1'; st <= S_EOM;     -- gated off: malformed
                        else
                            st <= S_DD;
                        end if;
                    else
                        st <= S_POW2;
                    end if;
                -- ----------------------------------------------------------
                when S_DD =>
                    if ddi = 32 then
                        for jj in 0 to 9 loop
                            dig(jj) <= digit_ascii(bcd(jj*4+3 downto jj*4), '0');
                        end loop;
                        cnt := 1;
                        for jj in 0 to 9 loop
                            if bcd(jj*4+3 downto jj*4) /= "0000" then cnt := jj+1; end if;
                        end loop;
                        ndig <= cnt;
                        st <= S_LAYOUT;
                    else
                        c := bcd;
                        for jj in 0 to 9 loop
                            if c(jj*4+3 downto jj*4) >= 5 then
                                c(jj*4+3 downto jj*4) := c(jj*4+3 downto jj*4) + 3;
                            end if;
                        end loop;
                        bcd    <= c(38 downto 0) & pw_tmp(31);
                        pw_tmp <= pw_tmp(30 downto 0) & '0';
                        ddi <= ddi + 1;
                    end if;
                -- ----------------------------------------------------------
                when S_POW2 =>
                    case cbase is
                        when B_HEX  => sh := 4; mskn := 16#f#;
                        when B_OCT  => sh := 3; mskn := 16#7#;
                        when others => sh := 1; mskn := 16#1#;
                    end case;
                    dval := pw_tmp(3 downto 0) and to_unsigned(mskn, 4);
                    dig(ndig) <= digit_ascii(dval, cupper);
                    pw_tmp <= shift_right(pw_tmp, sh);
                    if shift_right(pw_tmp, sh) = 0 then
                        ndig <= ndig + 1; st <= S_LAYOUT;
                    else
                        ndig <= ndig + 1;
                    end if;
                -- ----------------------------------------------------------
                when S_LAYOUT =>
                    -- C fmt_int layout with the precision rules (mirror of the
                    -- SV core's S_LAYOUT; see src/k_printf.c).
                    if sign_ch /= x"00" then slen := 1; else slen := 0; end if;
                    is_zero := (body_sel = 0) and (mag = 0);
                    -- precision 0 with value 0 => no digits at all (C rule)
                    if body_sel = 0 and cpen = '1' and cprec = 0 and mag = 0 then
                        nde := 0;
                    else
                        nde := ndig;
                    end if;
                    -- precision = minimum digit count (zero-filled)
                    if body_sel = 0 and cpen = '1' and cprec > nde then
                        lz := cprec - nde;
                    else
                        lz := 0;
                    end if;
                    -- alternate form: hex/bin prefix (nonzero only); octal
                    -- forces a leading zero unless one already leads
                    pl := 0; p0 := (others => '0'); p1 := (others => '0');
                    if body_sel = 0 and cflags(F_HASH) = '1' then
                        if cbase = B_HEX and not is_zero then
                            pl := 2; p0 := x"30";
                            if cupper = '1' then p1 := x"58"; else p1 := x"78"; end if;
                        elsif cbase = B_BIN and not is_zero then
                            pl := 2; p0 := x"30";
                            if cupper = '1' then p1 := x"42"; else p1 := x"62"; end if;
                        elsif cbase = B_OCT then
                            if lz = 0 and not (nde > 0 and mag = 0) then lz := 1; end if;
                        end if;
                    end if;
                    -- body length per kind; %s truncated by precision
                    if body_sel = 0 then blen := lz + nde;
                    elsif body_sel = 1 then blen := 1;
                    else
                        blen := body_len;
                        if cpen = '1' and cprec < blen then blen := cprec; end if;
                    end if;
                    bl  := slen + pl + blen;
                    if cwidth > bl then pad := cwidth - bl; else pad := 0; end if;
                    -- '0' flag: numeric only, not with '-', ignored with precision
                    zero_ok := (body_sel = 0) and (cflags(F_ZERO) = '1') and
                               (cflags(F_LEFT) = '0') and (cpen = '0');
                    presp := 0; zp := 0; postsp := 0;
                    if cflags(F_LEFT) = '1' then postsp := pad;
                    elsif zero_ok then zp := pad;
                    else presp := pad; end if;
                    -- load the phase counters (buffer-free; mirror of the SV)
                    n_pre  <= presp;
                    if slen = 1 then do_sign <= '1'; else do_sign <= '0'; end if;
                    n_pfx  <= pl; p0_r <= p0; p1_r <= p1;
                    n_zero <= zp + lz;
                    if body_sel = 0 then n_body <= nde; else n_body <= blen; end if;
                    n_post <= postsp;
                    str_ptr <= str_addr;
                    ovalid <= '0';
                    st <= S_EMIT;
                -- ----------------------------------------------------------
                when S_EMIT =>
                    -- stream the field phase-by-phase; digits MSB-first via
                    -- dig(n_body-1)
                    if ovalid = '0' or out_ready = '1' then
                        olast <= '0';
                        if n_pre /= 0 then
                            odata <= x"20"; ovalid <= '1';
                            n_pre <= n_pre - 1; mlen <= mlen + 1;
                        elsif do_sign = '1' then
                            odata <= sign_ch; ovalid <= '1';
                            do_sign <= '0'; mlen <= mlen + 1;
                        elsif n_pfx /= 0 then
                            if n_pfx = 2 then odata <= p0_r; else odata <= p1_r; end if;
                            ovalid <= '1';
                            n_pfx <= n_pfx - 1; mlen <= mlen + 1;
                        elsif n_zero /= 0 then
                            odata <= x"30"; ovalid <= '1';
                            n_zero <= n_zero - 1; mlen <= mlen + 1;
                        elsif n_body /= 0 then
                            case body_sel is
                                when 0 => odata <= dig(n_body - 1);
                                when 1 => odata <= chr_byte;
                                when others =>
                                    odata <= str_pool(str_ptr);
                                    str_ptr <= str_ptr + 1;
                            end case;
                            ovalid <= '1';
                            n_body <= n_body - 1; mlen <= mlen + 1;
                        elsif n_post /= 0 then
                            odata <= x"20"; ovalid <= '1';
                            n_post <= n_post - 1; mlen <= mlen + 1;
                        else
                            ovalid <= '0'; st <= S_FETCH;
                        end if;
                    end if;
                -- ----------------------------------------------------------
                when S_EOM =>
                    if ovalid = '0' then
                        ovalid <= '1'; olast <= '1'; odata <= (others => '0');
                    elsif out_ready = '1' then
                        ovalid <= '0'; olast <= '0'; st <= S_IDLE;
                    end if;
                -- ----------------------------------------------------------
                when others => st <= S_IDLE;
                end case;
            end if;
        end if;
    end process;
end architecture;
