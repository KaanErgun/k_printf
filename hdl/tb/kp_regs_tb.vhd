-- kp_regs_tb.vhd - register-window test, VHDL-2008 twin of kp_regs_tb.sv:
-- kp_regs -> kp_core -> kp_capture, bytes vs the C golden; write-to-fire,
-- STATUS.pend contract and SEND-while-pending overflow.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.kp_msgs_pkg.all;

entity kp_regs_tb is
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

architecture tb of kp_regs_tb is
    constant ARGC_MAX : integer := 8;
    constant MSG_A : integer := 3;    -- MSG_REG
    constant MSG_B : integer := 12;   -- MSG_NAME (long)

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal wen : std_logic := '0';
    signal addr : unsigned(3 downto 0) := (others => '0');
    signal wdata : std_logic_vector(31 downto 0) := (others => '0');
    signal rdata : std_logic_vector(31 downto 0);
    signal r_valid, r_ready : std_logic;
    signal r_id : unsigned(15 downto 0);
    signal r_args : std_logic_vector(32*ARGC_MAX-1 downto 0);
    signal c_valid, c_ready, c_last, err : std_logic;
    signal c_data : std_logic_vector(7 downto 0);
    signal msg_len, cnt, msgs : unsigned(15 downto 0);
    signal rd_addr : unsigned(15 downto 0) := (others => '0');
    signal rd_data : std_logic_vector(7 downto 0);
    signal done : boolean := false;
begin
    clk <= not clk after 5 ns when not done else '0';

    regs : entity work.kp_regs
        generic map (ARGC_MAX => ARGC_MAX)
        port map (
            clk => clk, rst => rst,
            wen => wen, addr => addr, wdata => wdata, rdata => rdata,
            core_err => err,
            msg_valid => r_valid, msg_ready => r_ready,
            msg_id => r_id, args_flat => r_args);

    core : entity work.kp_core
        generic map (
            UOP_FILE => UOP_FILE, LIT_FILE => LIT_FILE, STR_FILE => STR_FILE,
            STRTAB_FILE => STRTAB_FILE, MSTART_FILE => MSTART_FILE, MARITY_FILE => MARITY_FILE,
            ISA_VERSION => KP_ISA_VERSION,
            N_UOPS => KP_N_UOPS, LIT_BYTES => KP_LIT_BYTES, STR_BYTES => KP_STR_BYTES,
            N_STRINGS => KP_N_STRINGS, N_MSGS => KP_N_MSGS, ARGC_MAX => ARGC_MAX)
        port map (
            clk => clk, rst => rst,
            msg_valid => r_valid, msg_ready => r_ready, msg_id => r_id, args_flat => r_args,
            out_valid => c_valid, out_ready => c_ready, out_data => c_data,
            out_last => c_last, msg_len => msg_len, err => err);

    cap : entity work.kp_capture
        generic map (DEPTH => 1024)
        port map (clk => clk, rst => rst, clear => '0',
                  in_valid => c_valid, in_ready => c_ready, in_data => c_data,
                  in_last => c_last, count => cnt, msgs => msgs,
                  rd_addr => rd_addr, rd_data => rd_data);

    stim : process
        file vf, ef : text;
        variable vl, el : line;
        variable mid, nargs, elen : integer;
        variable hx : std_logic_vector(31 downto 0);
        variable bx : std_logic_vector(7 downto 0);
        variable checks, fails : integer := 0;
        type barr is array(0 to 255) of integer;
        type warr is array(0 to 15) of std_logic_vector(31 downto 0);
        variable expA : barr;
        variable nexpA : integer := -1;
        variable nargsA : integer := 0;
        variable argsA : warr := (others => (others => '0'));  -- full 32-bit
        variable guard : integer;
        variable m0, base : integer;

        procedure chk(cond : boolean; what : string) is
        begin
            checks := checks + 1;
            if not cond then
                fails := fails + 1;
                report "FAIL " & what severity warning;
            end if;
        end procedure;

        procedure wr(a : integer; d : std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clk);
            wen <= '1'; addr <= to_unsigned(a, 4); wdata <= d;
            wait until rising_edge(clk);
            wen <= '0';
        end procedure;
    begin
        file_open(vf, VEC_FILE, read_mode);
        file_open(ef, EXP_FILE, read_mode);
        while not endfile(vf) and nexpA < 0 loop
            readline(vf, vl);
            if vl'length = 0 then next; end if;
            read(vl, mid);
            read(vl, nargs);
            readline(ef, el);
            read(el, elen);
            if mid = MSG_A then
                for i in 0 to nargs-1 loop
                    hread(vl, hx); argsA(i) := hx;   -- full 32-bit, no truncation
                end loop;
                for i in 0 to elen-1 loop
                    hread(el, bx); expA(i) := to_integer(unsigned(bx));
                end loop;
                nexpA := elen; nargsA := nargs;
            end if;
        end loop;
        file_close(vf); file_close(ef);

        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        rst <= '0';
        wait until rising_edge(clk);

        -- test 1: poll-then-fire, golden byte compare
        for i in 0 to nargsA-1 loop
            wr(i, argsA(i));
        end loop;
        wr(8, std_logic_vector(to_unsigned(MSG_A, 32)));   -- write-to-fire
        guard := 0;
        while to_integer(msgs) < 1 and guard < 100000 loop
            wait until rising_edge(clk); guard := guard + 1;
        end loop;
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        chk(to_integer(msgs) = 1, "message completed via register window");
        chk(to_integer(cnt) = nexpA, "byte count == golden");
        for i in 0 to 255 loop
            if i < nexpA then
                rd_addr <= to_unsigned(i, 16);
                wait until rising_edge(clk);
                wait for 1 ns;
                chk(to_integer(unsigned(rd_data)) = expA(i), "byte matches golden");
            end if;
        end loop;
        addr <= to_unsigned(9, 4);
        wait until rising_edge(clk); wait for 1 ns;
        chk(rdata(0) = '0', "STATUS.pend clear after acceptance");

        -- test 2: SEND while pending -> overflow counted, queue intact
        for i in 0 to 2 loop
            wr(i, std_logic_vector(to_unsigned(1, 32)));   -- str ids = "cpu"
        end loop;
        wr(8, std_logic_vector(to_unsigned(MSG_B, 32)));   -- fires; core emits
        wr(8, std_logic_vector(to_unsigned(MSG_A, 32)));   -- queues (pend)
        wr(8, std_logic_vector(to_unsigned(MSG_A, 32)));   -- pend set -> DROP
        guard := 0;
        while to_integer(msgs) < 3 and guard < 100000 loop
            wait until rising_edge(clk); guard := guard + 1;
        end loop;
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        chk(to_integer(msgs) = 3, "queued message still delivered");
        addr <= to_unsigned(9, 4);
        wait until rising_edge(clk); wait for 1 ns;
        chk(to_integer(unsigned(rdata(15 downto 8))) = 1, "overflow count == 1");
        chk(rdata(1) = '0', "no core error");

        -- test 3: arg snapshot - a queued SEND is immune to later ARG writes
        m0 := to_integer(msgs);
        wr(0, std_logic_vector(to_unsigned(1, 32)));
        wr(1, std_logic_vector(to_unsigned(2, 32)));
        wr(2, std_logic_vector(to_unsigned(3, 32)));
        wr(8, std_logic_vector(to_unsigned(MSG_B, 32)));   -- long, core busy
        wr(0, argsA(0));                                   -- MSG_A GOOD arg
        wr(8, std_logic_vector(to_unsigned(MSG_A, 32)));   -- queued -> snapshot
        wr(0, x"DEADBEEF");                                -- poison while pending
        guard := 0;
        while to_integer(msgs) < m0 + 2 and guard < 100000 loop
            wait until rising_edge(clk); guard := guard + 1;
        end loop;
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        chk(to_integer(msgs) = m0 + 2, "long + queued message both delivered");
        base := to_integer(cnt) - nexpA;                   -- MSG_A is the tail
        for k in 0 to 255 loop
            if k < nexpA then
                rd_addr <= to_unsigned(base + k, 16);
                wait until rising_edge(clk); wait for 1 ns;
                chk(to_integer(unsigned(rd_data)) = expA(k),
                    "snapshot: queued MSG_A byte == GOOD golden");
            end if;
        end loop;

        report "RESULT: " & integer'image(checks) & " regs checks, " &
               integer'image(fails) & " failures";
        if fails = 0 then
            report "REGS-DIFF: PASS";
        else
            report "REGS-DIFF: FAIL";
        end if;
        done <= true;
        wait;
    end process;
end architecture;
