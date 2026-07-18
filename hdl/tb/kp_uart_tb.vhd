-- kp_uart_tb.vhd - system-level differential test, mirror of kp_uart_tb.sv:
-- kp_core -> kp_uart_tx, serial line sampled with an independent bit-time model,
-- rebuilt bytes compared against the C golden expected bytes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.kp_msgs_pkg.all;

entity kp_uart_tb is
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

architecture tb of kp_uart_tb is
    constant ARGC_MAX : integer := 8;
    constant CLK_HZ   : integer := 48_000_000;
    constant BAUD     : integer := 115_200;
    constant NUART    : integer := 12;
    constant BIT_T    : time    := 1 sec / BAUD;
    constant CLK_T    : time    := 1 sec / CLK_HZ;

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal msg_valid : std_logic := '0';
    signal msg_ready : std_logic;
    signal msg_id : unsigned(15 downto 0) := (others => '0');
    signal args_flat : std_logic_vector(32*ARGC_MAX-1 downto 0) := (others => '0');
    signal out_valid, out_last : std_logic;
    signal out_data : std_logic_vector(7 downto 0);
    signal msg_len : unsigned(15 downto 0);
    signal err : std_logic;
    signal uart_ready, txd : std_logic;
    signal core_ready, uart_valid : std_logic;
    signal done : boolean := false;

    type rx_arr is array(0 to 2047) of integer;
    signal rx  : rx_arr;
    signal nrx : integer := 0;
begin
    clk <= not clk after CLK_T / 2 when not done else '0';

    -- EOM marker beat carries no data: filter + consume unconditionally
    uart_valid <= out_valid and not out_last;
    core_ready <= '1' when out_last = '1' else uart_ready;

    core : entity work.kp_core
        generic map (
            UOP_FILE => UOP_FILE, LIT_FILE => LIT_FILE, STR_FILE => STR_FILE,
            STRTAB_FILE => STRTAB_FILE, MSTART_FILE => MSTART_FILE, MARITY_FILE => MARITY_FILE,
            ISA_VERSION => KP_ISA_VERSION,
            N_UOPS => KP_N_UOPS, LIT_BYTES => KP_LIT_BYTES, STR_BYTES => KP_STR_BYTES,
            N_STRINGS => KP_N_STRINGS, N_MSGS => KP_N_MSGS, ARGC_MAX => ARGC_MAX)
        port map (
            clk => clk, rst => rst, msg_valid => msg_valid, msg_ready => msg_ready,
            msg_id => msg_id, args_flat => args_flat,
            out_valid => out_valid, out_ready => core_ready, out_data => out_data,
            out_last => out_last, msg_len => msg_len, err => err);

    uart : entity work.kp_uart_tx
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
        port map (
            clk => clk, rst => rst,
            in_valid => uart_valid, in_ready => uart_ready,
            in_data => out_data, txd => txd);

    -- independent serial receiver (bit-time model, resync at each start edge)
    rxp : process
        variable byte_v : std_logic_vector(7 downto 0);
    begin
        wait until falling_edge(txd);
        wait for BIT_T * 3 / 2;                 -- centre of data bit 0
        for b in 0 to 7 loop
            byte_v(b) := txd;
            if b /= 7 then wait for BIT_T; end if;
        end loop;
        wait for BIT_T;                          -- centre of stop bit
        if txd /= '1' then
            report "FRAMING ERROR" severity warning;
        end if;
        rx(nrx) <= to_integer(unsigned(byte_v));
        nrx <= nrx + 1;
        wait for CLK_T;                          -- let nrx settle
    end process;

    stim : process
        file vf, ef : text;
        variable vl, el : line;
        variable mid, nargs, elen : integer;
        variable hx : std_logic_vector(31 downto 0);
        variable bx : std_logic_vector(7 downto 0);
        variable checks, fails : integer := 0;
        variable exp : rx_arr;
        variable nexp, base_rx : integer;
        variable bad : boolean;
        variable waited : time;
    begin
        file_open(vf, VEC_FILE, read_mode);
        file_open(ef, EXP_FILE, read_mode);

        rst <= '1';
        for i in 0 to 7 loop wait until rising_edge(clk); end loop;
        rst <= '0';
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;

        while not endfile(vf) and checks < NUART loop
            readline(vf, vl);
            if vl'length = 0 then next; end if;
            read(vl, mid);
            read(vl, nargs);
            args_flat <= (others => '0');
            for i in 0 to nargs-1 loop
                hread(vl, hx);
                args_flat(i*32+31 downto i*32) <= hx;
            end loop;
            readline(ef, el);
            read(el, elen);
            nexp := 0;
            for i in 0 to elen-1 loop
                hread(el, bx);
                exp(nexp) := to_integer(unsigned(bx));
                nexp := nexp + 1;
            end loop;

            base_rx := nrx;
            wait until rising_edge(clk);
            msg_id <= to_unsigned(mid, 16);
            msg_valid <= '1';
            wait until rising_edge(clk);
            while msg_ready /= '1' loop wait until rising_edge(clk); end loop;
            msg_valid <= '0';

            -- wait for the serial line to deliver all expected bytes
            waited := 0 ns;
            while (nrx - base_rx) < nexp and waited < BIT_T * 12 * (nexp + 20) loop
                wait for BIT_T;
                waited := waited + BIT_T;
            end loop;
            wait for BIT_T * 2;

            checks := checks + 1;
            bad := false;
            if (nrx - base_rx) /= nexp then bad := true;
            else
                for i in 0 to nexp-1 loop
                    if rx(base_rx + i) /= exp(i) then bad := true; end if;
                end loop;
            end if;
            if bad then
                fails := fails + 1;
                report "UART MISMATCH msg=" & integer'image(mid) &
                       " got=" & integer'image(nrx - base_rx) &
                       " exp=" & integer'image(nexp) severity warning;
            end if;
        end loop;

        file_close(vf); file_close(ef);
        report "RESULT: " & integer'image(checks) & " uart checks, " &
               integer'image(fails) & " failures";
        if fails = 0 then
            report "UART-DIFF: PASS";
        else
            report "UART-DIFF: FAIL";
        end if;
        done <= true;
        wait;
    end process;
end architecture;
