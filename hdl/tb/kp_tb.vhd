-- kp_tb.vhd - VHDL-2008 differential testbench for kp_core, mirror of kp_tb.sv.
--
-- Reads the same vectors.txt / expected.txt, drives each message through the VHDL
-- kp_core, collects the byte stream and asserts equality with the C golden bytes.
-- Dumps actual bytes to vhdl_out.txt so the equiv target can triple-diff C=SV=VHDL.
--
-- File paths and sizes come in as generics (set by the Makefile via ghdl -g...).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.kp_msgs_pkg.all;

entity kp_tb is
    generic (
        UOP_FILE    : string := "hdl/gen/uop_rom.mem";
        LIT_FILE    : string := "hdl/gen/lit_pool.mem";
        STR_FILE    : string := "hdl/gen/str_pool.mem";
        STRTAB_FILE : string := "hdl/gen/str_table.mem";
        MSTART_FILE : string := "hdl/gen/msg_start.mem";
        MARITY_FILE : string := "hdl/gen/msg_arity.mem";
        VEC_FILE    : string := "hdl/gen/vectors.txt";
        EXP_FILE    : string := "hdl/gen/expected.txt";
        OUT_FILE    : string := "hdl/gen/vhdl_out.txt"
    );
end entity;

architecture tb of kp_tb is
    constant ARGC_MAX : integer := 8;
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal msg_valid : std_logic := '0';
    signal msg_ready : std_logic;
    signal msg_id : unsigned(15 downto 0) := (others => '0');
    signal args_flat : std_logic_vector(32*ARGC_MAX-1 downto 0) := (others => '0');
    signal out_valid : std_logic;
    signal out_ready : std_logic := '1';
    signal out_data : std_logic_vector(7 downto 0);
    signal out_last : std_logic;
    signal msg_len : unsigned(15 downto 0);
    signal err : std_logic;
    signal done : boolean := false;
begin
    clk <= not clk after 5 ns when not done else '0';

    dut : entity work.kp_core
        generic map (
            UOP_FILE => UOP_FILE, LIT_FILE => LIT_FILE, STR_FILE => STR_FILE,
            STRTAB_FILE => STRTAB_FILE, MSTART_FILE => MSTART_FILE, MARITY_FILE => MARITY_FILE,
            N_UOPS => KP_N_UOPS, LIT_BYTES => KP_LIT_BYTES, STR_BYTES => KP_STR_BYTES,
            N_STRINGS => KP_N_STRINGS, N_MSGS => KP_N_MSGS, ARGC_MAX => ARGC_MAX)
        port map (
            clk => clk, rst => rst, msg_valid => msg_valid, msg_ready => msg_ready,
            msg_id => msg_id, args_flat => args_flat,
            out_valid => out_valid, out_ready => out_ready, out_data => out_data,
            out_last => out_last, msg_len => msg_len, err => err);

    process
        file vf, ef, ofl : text;
        variable vl, el, ol : line;
        variable mid, nargs, elen, av_i : integer;
        variable hx : std_logic_vector(31 downto 0);
        variable bx : std_logic_vector(7 downto 0);
        variable checks, fails : integer := 0;
        variable got : integer_vector(0 to 1023);
        variable exp : integer_vector(0 to 1023);
        variable ngot, nexp : integer;
        variable bad : boolean;
        variable guard : integer;
    begin
        file_open(vf, VEC_FILE, read_mode);
        file_open(ef, EXP_FILE, read_mode);
        file_open(ofl, OUT_FILE, write_mode);

        -- reset
        rst <= '1';
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;
        rst <= '0';
        wait until rising_edge(clk);

        while not endfile(vf) loop
            readline(vf, vl);
            if vl'length = 0 then next; end if;
            read(vl, mid);
            read(vl, nargs);
            args_flat <= (others => '0');
            for i in 0 to nargs-1 loop
                hread(vl, hx);
                args_flat(i*32+31 downto i*32) <= hx;
            end loop;

            -- expected line
            readline(ef, el);
            read(el, elen);
            nexp := 0;
            if elen >= 0 then
                for i in 0 to elen-1 loop
                    hread(el, bx);
                    exp(nexp) := to_integer(unsigned(bx));
                    nexp := nexp + 1;
                end loop;
            end if;

            -- drive message
            wait until rising_edge(clk);
            msg_id <= to_unsigned(mid, 16);
            msg_valid <= '1';
            wait until rising_edge(clk);
            while msg_ready /= '1' loop wait until rising_edge(clk); end loop;
            msg_valid <= '0';

            -- collect (out_ready held high; SV TB covers backpressure invariance)
            out_ready <= '1';
            ngot := 0; guard := 0;
            loop
                wait until rising_edge(clk);
                guard := guard + 1;
                if out_valid = '1' and out_ready = '1' then
                    if out_last = '1' then
                        exit;
                    else
                        got(ngot) := to_integer(unsigned(out_data));
                        ngot := ngot + 1;
                    end if;
                end if;
                if guard > 200000 then
                    report "TIMEOUT msg " & integer'image(mid) severity warning;
                    exit;
                end if;
            end loop;
            wait until rising_edge(clk);

            -- compare
            checks := checks + 1;
            bad := false;
            if ngot /= nexp then bad := true;
            else
                for i in 0 to nexp-1 loop
                    if got(i) /= exp(i) then bad := true; end if;
                end loop;
            end if;
            if bad then
                fails := fails + 1;
                report "MISMATCH msg=" & integer'image(mid) &
                       " ngot=" & integer'image(ngot) &
                       " nexp=" & integer'image(nexp) severity warning;
            end if;

            -- dump actual
            write(ol, ngot);
            for i in 0 to ngot-1 loop
                write(ol, string'(" "));
                hwrite(ol, std_logic_vector(to_unsigned(got(i), 8)));
            end loop;
            writeline(ofl, ol);
        end loop;

        file_close(vf); file_close(ef); file_close(ofl);
        report "RESULT: " & integer'image(checks) & " checks, " &
               integer'image(fails) & " failures";
        if fails = 0 then
            report "VHDL-DIFF: PASS";
        else
            report "VHDL-DIFF: FAIL";
        end if;
        done <= true;
        wait;
    end process;
end architecture;
