-- kp_sys_tb.vhd - system test, VHDL-2008 twin of kp_sys_tb.sv:
-- kp_trig (2 sources) -> kp_core -> kp_tee -> {kp_capture A, kp_capture B}.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.kp_msgs_pkg.all;

entity kp_sys_tb is
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

architecture tb of kp_sys_tb is
    constant ARGC_MAX : integer := 8;
    constant SRC0_MSG : integer := 5;   -- MSG_TICK
    constant SRC1_MSG : integer := 3;   -- MSG_REG

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal trig : std_logic_vector(1 downto 0) := "00";
    signal trig_id : std_logic_vector(31 downto 0) := (others => '0');
    signal trig_args : std_logic_vector(2*32*ARGC_MAX-1 downto 0) := (others => '0');
    signal dropped : std_logic_vector(15 downto 0);
    signal t_valid, t_ready : std_logic;
    signal t_id : unsigned(15 downto 0);
    signal t_args : std_logic_vector(32*ARGC_MAX-1 downto 0);
    signal c_valid, c_ready, c_last : std_logic;
    signal c_data : std_logic_vector(7 downto 0);
    signal msg_len : unsigned(15 downto 0);
    signal err : std_logic;
    signal a_valid, a_ready, a_last, b_valid, b_ready, b_last : std_logic;
    signal a_data, b_data : std_logic_vector(7 downto 0);
    signal cnt_a, msgs_a, cnt_b, msgs_b : unsigned(15 downto 0);
    signal rd_addr : unsigned(15 downto 0) := (others => '0');
    signal rd_a, rd_b : std_logic_vector(7 downto 0);
    signal done : boolean := false;
begin
    clk <= not clk after 5 ns when not done else '0';

    trigmod : entity work.kp_trig
        generic map (N_SRC => 2, ARGC_MAX => ARGC_MAX, CNT_W => 8)
        port map (
            clk => clk, rst => rst,
            trig => trig, trig_msg_id => trig_id, trig_args => trig_args,
            dropped_cnt => dropped,
            msg_valid => t_valid, msg_ready => t_ready,
            msg_id => t_id, args_flat => t_args);

    core : entity work.kp_core
        generic map (
            UOP_FILE => UOP_FILE, LIT_FILE => LIT_FILE, STR_FILE => STR_FILE,
            STRTAB_FILE => STRTAB_FILE, MSTART_FILE => MSTART_FILE, MARITY_FILE => MARITY_FILE,
            ISA_VERSION => KP_ISA_VERSION,
            N_UOPS => KP_N_UOPS, LIT_BYTES => KP_LIT_BYTES, STR_BYTES => KP_STR_BYTES,
            N_STRINGS => KP_N_STRINGS, N_MSGS => KP_N_MSGS, ARGC_MAX => ARGC_MAX)
        port map (
            clk => clk, rst => rst,
            msg_valid => t_valid, msg_ready => t_ready, msg_id => t_id, args_flat => t_args,
            out_valid => c_valid, out_ready => c_ready, out_data => c_data,
            out_last => c_last, msg_len => msg_len, err => err);

    tee : entity work.kp_tee
        port map (
            clk => clk, rst => rst,
            in_valid => c_valid, in_ready => c_ready, in_data => c_data, in_last => c_last,
            a_valid => a_valid, a_ready => a_ready, a_data => a_data, a_last => a_last,
            b_valid => b_valid, b_ready => b_ready, b_data => b_data, b_last => b_last);

    capA : entity work.kp_capture
        generic map (DEPTH => 1024)
        port map (clk => clk, rst => rst, clear => '0',
                  in_valid => a_valid, in_ready => a_ready, in_data => a_data,
                  in_last => a_last, count => cnt_a, msgs => msgs_a,
                  rd_addr => rd_addr, rd_data => rd_a);
    capB : entity work.kp_capture
        generic map (DEPTH => 1024)
        port map (clk => clk, rst => rst, clear => '0',
                  in_valid => b_valid, in_ready => b_ready, in_data => b_data,
                  in_last => b_last, count => cnt_b, msgs => msgs_b,
                  rd_addr => rd_addr, rd_data => rd_b);

    stim : process
        file vf, ef : text;
        variable vl, el : line;
        variable mid, nargs, elen : integer;
        variable hx : std_logic_vector(31 downto 0);
        variable bx : std_logic_vector(7 downto 0);
        variable checks, fails : integer := 0;
        type barr is array(0 to 255) of integer;
        variable exp0, exp1 : barr;
        variable nexp0 : integer := -1;
        variable nexp1 : integer := -1;
        variable a0, a1 : std_logic_vector(32*ARGC_MAX-1 downto 0);
        variable guard : integer;

        procedure chk(cond : boolean; what : string) is
        begin
            checks := checks + 1;
            if not cond then
                fails := fails + 1;
                report "FAIL " & what severity warning;
            end if;
        end procedure;
    begin
        a0 := (others => '0'); a1 := (others => '0');
        file_open(vf, VEC_FILE, read_mode);
        file_open(ef, EXP_FILE, read_mode);
        while not endfile(vf) and (nexp0 < 0 or nexp1 < 0) loop
            readline(vf, vl);
            if vl'length = 0 then next; end if;
            read(vl, mid);
            read(vl, nargs);
            readline(ef, el);
            read(el, elen);
            if mid = SRC0_MSG and nexp0 < 0 then
                for i in 0 to nargs-1 loop
                    hread(vl, hx); a0(i*32+31 downto i*32) := hx;
                end loop;
                for i in 0 to elen-1 loop
                    hread(el, bx); exp0(i) := to_integer(unsigned(bx));
                end loop;
                nexp0 := elen;
            elsif mid = SRC1_MSG and nexp1 < 0 then
                for i in 0 to nargs-1 loop
                    hread(vl, hx); a1(i*32+31 downto i*32) := hx;
                end loop;
                for i in 0 to elen-1 loop
                    hread(el, bx); exp1(i) := to_integer(unsigned(bx));
                end loop;
                nexp1 := elen;
            end if;
        end loop;
        file_close(vf); file_close(ef);

        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        rst <= '0';
        wait until rising_edge(clk);

        -- test 1: both sources fire in the SAME cycle
        trig_id(15 downto 0)  <= std_logic_vector(to_unsigned(SRC0_MSG, 16));
        trig_id(31 downto 16) <= std_logic_vector(to_unsigned(SRC1_MSG, 16));
        trig_args(32*ARGC_MAX-1 downto 0)              <= a0;
        trig_args(2*32*ARGC_MAX-1 downto 32*ARGC_MAX)  <= a1;
        wait until rising_edge(clk);
        trig <= "11";
        wait until rising_edge(clk);
        trig <= "00";
        -- POISON the trigger inputs after the pulse: the one-cycle atomic
        -- snapshot must make this garbage irrelevant. A non-snapshotting design
        -- (live read at grant) would emit it and fail the byte compare below.
        trig_id   <= x"DEADBEEF";
        trig_args <= (others => '1');

        guard := 0;
        while to_integer(msgs_a) < 2 and guard < 100000 loop
            wait until rising_edge(clk); guard := guard + 1;
        end loop;
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;

        chk(to_integer(msgs_a) = 2, "two messages completed on sink A");
        chk(to_integer(msgs_b) = 2, "two messages completed on sink B");
        chk(to_integer(cnt_a) = nexp0 + nexp1, "sink A byte count == golden total");
        chk(cnt_b = cnt_a, "tee: sink B count == sink A count");
        chk(unsigned(dropped) = 0, "no drops on clean double fire");
        for j in 0 to 255 loop
            if j < nexp0 + nexp1 then
                rd_addr <= to_unsigned(j, 16);
                wait until rising_edge(clk);
                wait for 1 ns;
                if j < nexp0 then
                    chk(to_integer(unsigned(rd_a)) = exp0(j), "sink A byte matches golden");
                else
                    chk(to_integer(unsigned(rd_a)) = exp1(j - nexp0), "sink A byte matches golden");
                end if;
                chk(rd_b = rd_a, "sink B byte == sink A");
            end if;
        end loop;

        -- test 2: DROP policy - re-fire src0 while its slot is in flight
        -- restore valid src0 trigger inputs (poisoned above)
        trig_id(15 downto 0) <= std_logic_vector(to_unsigned(SRC0_MSG, 16));
        trig_args(32*ARGC_MAX-1 downto 0) <= a0;
        wait until rising_edge(clk);
        trig <= "01";
        wait until rising_edge(clk);
        trig <= "01";
        wait until rising_edge(clk);
        trig <= "00";
        guard := 0;
        while to_integer(msgs_a) < 3 and guard < 100000 loop
            wait until rising_edge(clk); guard := guard + 1;
        end loop;
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        chk(to_integer(msgs_a) = 3, "third message (accepted snapshot) completed");
        chk(to_integer(unsigned(dropped(7 downto 0))) = 1, "src0 dropped_cnt == 1");
        chk(to_integer(unsigned(dropped(15 downto 8))) = 0, "src1 dropped_cnt == 0");
        chk(err = '0', "no core error through the system test");

        report "RESULT: " & integer'image(checks) & " sys checks, " &
               integer'image(fails) & " failures";
        if fails = 0 then
            report "SYS-DIFF: PASS";
        else
            report "SYS-DIFF: FAIL";
        end if;
        done <= true;
        wait;
    end process;
end architecture;
