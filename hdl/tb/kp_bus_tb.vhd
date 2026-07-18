-- kp_bus_tb.vhd - bus adapter test, VHDL-2008 twin of kp_bus_tb.sv:
-- drive kp_regs over AXI4-Lite and over Wishbone, each feeding kp_core ->
-- kp_capture, and check the emitted message against the C golden; plus
-- register read-back (STATUS + an ARG) over each bus.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.kp_msgs_pkg.all;

entity kp_bus_tb is
    generic (
        UOP_FILE    : string := "hdl/gen/uop_rom.mem";
        LIT_FILE    : string := "hdl/gen/lit_pool.mem";
        STR_FILE    : string := "hdl/gen/str_pool.mem";
        STRTAB_FILE : string := "hdl/gen/str_table.mem";
        MSTART_FILE : string := "hdl/gen/msg_start.mem";
        MARITY_FILE : string := "hdl/gen/msg_arity.mem";
        VEC_FILE    : string := "hdl/gen/vectors.txt";
        EXP_FILE    : string := "hdl/gen/expected.txt"
    );
end entity;

architecture tb of kp_bus_tb is
    constant ARGC_MAX : integer := 8;
    constant MSG_A : integer := 3;         -- MSG_REG "reg = %#06x", arity 1

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal aresetn : std_logic;

    -- AXI-Lite chain
    signal aw : std_logic_vector(5 downto 0) := (others=>'0');
    signal awv, awr : std_logic := '0';
    signal wd : std_logic_vector(31 downto 0) := (others=>'0');
    signal wv, wr : std_logic := '0';
    signal bresp : std_logic_vector(1 downto 0); signal bv : std_logic; signal bready : std_logic := '0';
    signal ar : std_logic_vector(5 downto 0) := (others=>'0');
    signal arv, arr : std_logic := '0';
    signal rdA : std_logic_vector(31 downto 0); signal rresp : std_logic_vector(1 downto 0);
    signal rv : std_logic; signal rready : std_logic := '0';
    signal a_wen : std_logic; signal a_addr : unsigned(3 downto 0);
    signal a_wdata, a_rdata : std_logic_vector(31 downto 0);
    signal a_mvalid, a_mready, a_err : std_logic; signal a_mid : unsigned(15 downto 0);
    signal a_args : std_logic_vector(32*ARGC_MAX-1 downto 0);
    signal a_cv, a_cr, a_cl : std_logic; signal a_cd : std_logic_vector(7 downto 0);
    signal a_mlen, a_cnt, a_msgs : unsigned(15 downto 0);
    signal a_rdaddr : unsigned(15 downto 0) := (others=>'0'); signal a_rddat : std_logic_vector(7 downto 0);

    -- Wishbone chain
    signal wadr : std_logic_vector(3 downto 0) := (others=>'0');
    signal wdi, wdo : std_logic_vector(31 downto 0) := (others=>'0');
    signal wwe, wcyc, wstb, wack : std_logic := '0';
    signal w_wen : std_logic; signal w_addr : unsigned(3 downto 0);
    signal w_wdata, w_rdata : std_logic_vector(31 downto 0);
    signal w_mvalid, w_mready, w_err : std_logic; signal w_mid : unsigned(15 downto 0);
    signal w_args : std_logic_vector(32*ARGC_MAX-1 downto 0);
    signal w_cv, w_cr, w_cl : std_logic; signal w_cd : std_logic_vector(7 downto 0);
    signal w_mlen, w_cnt, w_msgs : unsigned(15 downto 0);
    signal w_rdaddr : unsigned(15 downto 0) := (others=>'0'); signal w_rddat : std_logic_vector(7 downto 0);

    signal done : boolean := false;
begin
    clk <= not clk after 5 ns when not done else '0';
    aresetn <= not rst;

    axil : entity work.kp_axil generic map (AW => 6)
        port map (aclk=>clk, aresetn=>aresetn,
            s_awaddr=>aw, s_awvalid=>awv, s_awready=>awr,
            s_wdata=>wd, s_wstrb=>"1111", s_wvalid=>wv, s_wready=>wr,
            s_bresp=>bresp, s_bvalid=>bv, s_bready=>bready,
            s_araddr=>ar, s_arvalid=>arv, s_arready=>arr,
            s_rdata=>rdA, s_rresp=>rresp, s_rvalid=>rv, s_rready=>rready,
            reg_wen=>a_wen, reg_addr=>a_addr, reg_wdata=>a_wdata, reg_rdata=>a_rdata);
    aregs : entity work.kp_regs generic map (ARGC_MAX => ARGC_MAX)
        port map (clk=>clk, rst=>rst, wen=>a_wen, addr=>a_addr, wdata=>a_wdata,
            rdata=>a_rdata, core_err=>a_err, msg_valid=>a_mvalid, msg_ready=>a_mready,
            msg_id=>a_mid, args_flat=>a_args);
    acore : entity work.kp_core
        generic map (UOP_FILE=>UOP_FILE, LIT_FILE=>LIT_FILE, STR_FILE=>STR_FILE,
            STRTAB_FILE=>STRTAB_FILE, MSTART_FILE=>MSTART_FILE, MARITY_FILE=>MARITY_FILE,
            ISA_VERSION=>KP_ISA_VERSION, N_UOPS=>KP_N_UOPS, LIT_BYTES=>KP_LIT_BYTES,
            STR_BYTES=>KP_STR_BYTES, N_STRINGS=>KP_N_STRINGS, N_MSGS=>KP_N_MSGS, ARGC_MAX=>ARGC_MAX)
        port map (clk=>clk, rst=>rst, msg_valid=>a_mvalid, msg_ready=>a_mready,
            msg_id=>a_mid, args_flat=>a_args, out_valid=>a_cv, out_ready=>a_cr,
            out_data=>a_cd, out_last=>a_cl, msg_len=>a_mlen, err=>a_err);
    acap : entity work.kp_capture generic map (DEPTH => 1024)
        port map (clk=>clk, rst=>rst, clear=>'0', in_valid=>a_cv, in_ready=>a_cr,
            in_data=>a_cd, in_last=>a_cl, count=>a_cnt, msgs=>a_msgs,
            rd_addr=>a_rdaddr, rd_data=>a_rddat);

    wb : entity work.kp_wb generic map (ADR_W => 4)
        port map (clk_i=>clk, rst_i=>rst, wb_adr_i=>wadr, wb_dat_i=>wdi, wb_dat_o=>wdo,
            wb_we_i=>wwe, wb_cyc_i=>wcyc, wb_stb_i=>wstb, wb_ack_o=>wack,
            reg_wen=>w_wen, reg_addr=>w_addr, reg_wdata=>w_wdata, reg_rdata=>w_rdata);
    wregs : entity work.kp_regs generic map (ARGC_MAX => ARGC_MAX)
        port map (clk=>clk, rst=>rst, wen=>w_wen, addr=>w_addr, wdata=>w_wdata,
            rdata=>w_rdata, core_err=>w_err, msg_valid=>w_mvalid, msg_ready=>w_mready,
            msg_id=>w_mid, args_flat=>w_args);
    wcore : entity work.kp_core
        generic map (UOP_FILE=>UOP_FILE, LIT_FILE=>LIT_FILE, STR_FILE=>STR_FILE,
            STRTAB_FILE=>STRTAB_FILE, MSTART_FILE=>MSTART_FILE, MARITY_FILE=>MARITY_FILE,
            ISA_VERSION=>KP_ISA_VERSION, N_UOPS=>KP_N_UOPS, LIT_BYTES=>KP_LIT_BYTES,
            STR_BYTES=>KP_STR_BYTES, N_STRINGS=>KP_N_STRINGS, N_MSGS=>KP_N_MSGS, ARGC_MAX=>ARGC_MAX)
        port map (clk=>clk, rst=>rst, msg_valid=>w_mvalid, msg_ready=>w_mready,
            msg_id=>w_mid, args_flat=>w_args, out_valid=>w_cv, out_ready=>w_cr,
            out_data=>w_cd, out_last=>w_cl, msg_len=>w_mlen, err=>w_err);
    wcap : entity work.kp_capture generic map (DEPTH => 1024)
        port map (clk=>clk, rst=>rst, clear=>'0', in_valid=>w_cv, in_ready=>w_cr,
            in_data=>w_cd, in_last=>w_cl, count=>w_cnt, msgs=>w_msgs,
            rd_addr=>w_rdaddr, rd_data=>w_rddat);

    stim : process
        file vf, ef : text;
        variable vl, el : line;
        variable mid, nargs, elen : integer;
        variable hx : std_logic_vector(31 downto 0);
        variable bx : std_logic_vector(7 downto 0);
        variable checks, fails : integer := 0;
        type barr is array(0 to 255) of integer;
        variable expA : barr;
        variable nexpA : integer := -1;
        variable argA : std_logic_vector(31 downto 0) := (others=>'0');
        variable guard : integer;
        variable d : std_logic_vector(31 downto 0);

        procedure chk(c : boolean; what : string) is
        begin
            checks := checks + 1;
            if not c then fails := fails + 1; report "FAIL " & what severity warning; end if;
        end procedure;

        procedure axil_write(a : std_logic_vector(5 downto 0); dat : std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clk);
            aw <= a; wd <= dat; awv <= '1'; wv <= '1'; bready <= '1';
            wait until rising_edge(clk);
            while not (awr = '1' and wr = '1') loop wait until rising_edge(clk); end loop;
            awv <= '0'; wv <= '0';
            while bv /= '1' loop wait until rising_edge(clk); end loop;
            wait until rising_edge(clk);
            bready <= '0';
        end procedure;
        procedure axil_read(a : std_logic_vector(5 downto 0); dat : out std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clk);
            ar <= a; arv <= '1'; rready <= '1';
            wait until rising_edge(clk);
            while arr /= '1' loop wait until rising_edge(clk); end loop;
            arv <= '0';
            while rv /= '1' loop wait until rising_edge(clk); end loop;
            dat := rdA;
            wait until rising_edge(clk);
            rready <= '0';
        end procedure;
        procedure wb_write(a : std_logic_vector(3 downto 0); dat : std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clk);
            wadr <= a; wdi <= dat; wwe <= '1'; wcyc <= '1'; wstb <= '1';
            wait until rising_edge(clk);
            while wack /= '1' loop wait until rising_edge(clk); end loop;
            wcyc <= '0'; wstb <= '0'; wwe <= '0';
        end procedure;
        procedure wb_read(a : std_logic_vector(3 downto 0); dat : out std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clk);
            wadr <= a; wwe <= '0'; wcyc <= '1'; wstb <= '1';
            wait until rising_edge(clk);
            while wack /= '1' loop wait until rising_edge(clk); end loop;
            dat := wdo;
            wcyc <= '0'; wstb <= '0';
        end procedure;
    begin
        file_open(vf, VEC_FILE, read_mode);
        file_open(ef, EXP_FILE, read_mode);
        while not endfile(vf) and nexpA < 0 loop
            readline(vf, vl); if vl'length = 0 then next; end if;
            read(vl, mid); read(vl, nargs);
            readline(ef, el); read(el, elen);
            if mid = MSG_A then
                for i in 0 to nargs-1 loop hread(vl, hx); argA := hx; end loop;
                for i in 0 to elen-1 loop hread(el, bx); expA(i) := to_integer(unsigned(bx)); end loop;
                nexpA := elen;
            end if;
        end loop;
        file_close(vf); file_close(ef);

        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        rst <= '0';
        wait until rising_edge(clk);

        -- AXI-Lite: write ARG0, fire SEND, check + readback
        axil_write("000000", argA);                 -- ARG0 (byte 0x00)
        axil_write("100000", std_logic_vector(to_unsigned(MSG_A, 32)));  -- SEND (reg 8 -> byte 0x20)
        guard := 0;
        while to_integer(a_msgs) < 1 and guard < 100000 loop wait until rising_edge(clk); guard := guard + 1; end loop;
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        chk(to_integer(a_msgs) = 1, "AXI: message emitted");
        chk(to_integer(a_cnt) = nexpA, "AXI: byte count == golden");
        for i in 0 to 255 loop
            if i < nexpA then
                a_rdaddr <= to_unsigned(i, 16);
                wait until rising_edge(clk); wait for 1 ns;
                chk(to_integer(unsigned(a_rddat)) = expA(i), "AXI: byte == golden");
            end if;
        end loop;
        axil_read("100100", d);                     -- STATUS reg 9 -> byte 0x24
        chk(d(0) = '0', "AXI: STATUS.pend clear");
        chk(d(1) = '0', "AXI: STATUS.err clear");
        axil_read("000000", d);                     -- ARG0 read-back
        chk(d = argA, "AXI: ARG0 read-back matches");

        -- Wishbone: same over WB
        wb_write("0000", argA);                      -- ARG0
        wb_write("1000", std_logic_vector(to_unsigned(MSG_A, 32)));  -- SEND (reg 8)
        guard := 0;
        while to_integer(w_msgs) < 1 and guard < 100000 loop wait until rising_edge(clk); guard := guard + 1; end loop;
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        chk(to_integer(w_msgs) = 1, "WB: message emitted");
        chk(to_integer(w_cnt) = nexpA, "WB: byte count == golden");
        for i in 0 to 255 loop
            if i < nexpA then
                w_rdaddr <= to_unsigned(i, 16);
                wait until rising_edge(clk); wait for 1 ns;
                chk(to_integer(unsigned(w_rddat)) = expA(i), "WB: byte == golden");
            end if;
        end loop;
        wb_read("1001", d);                          -- STATUS reg 9
        chk(d(0) = '0', "WB: STATUS.pend clear");
        wb_read("0000", d);                          -- ARG0 read-back
        chk(d = argA, "WB: ARG0 read-back matches");

        report "RESULT: " & integer'image(checks) & " bus checks, " &
               integer'image(fails) & " failures";
        if fails = 0 then report "BUS-DIFF: PASS"; else report "BUS-DIFF: FAIL"; end if;
        done <= true;
        wait;
    end process;
end architecture;
