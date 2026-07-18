-- kp_trig.vhd - multi-source hardware trigger front-end, VHDL-2008 twin of
-- rtl/sv/kp_trig.sv. One-cycle atomic argument snapshot per source, round-robin
-- message-granular arbiter into kp_core's msg port, per-source saturating
-- dropped_cnt (the plan's DROP policy for hardware sources).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity kp_trig is
    generic (
        N_SRC    : integer := 2;
        ARGC_MAX : integer := 8;
        CNT_W    : integer := 8
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        trig        : in  std_logic_vector(N_SRC-1 downto 0);
        trig_msg_id : in  std_logic_vector(N_SRC*16-1 downto 0);
        trig_args   : in  std_logic_vector(N_SRC*32*ARGC_MAX-1 downto 0);
        dropped_cnt : out std_logic_vector(N_SRC*CNT_W-1 downto 0);
        msg_valid   : out std_logic;
        msg_ready   : in  std_logic;
        msg_id      : out unsigned(15 downto 0);
        args_flat   : out std_logic_vector(32*ARGC_MAX-1 downto 0)
    );
end entity;

architecture rtl of kp_trig is
    type id_arr  is array(0 to N_SRC-1) of std_logic_vector(15 downto 0);
    type arg_arr is array(0 to N_SRC-1) of std_logic_vector(32*ARGC_MAX-1 downto 0);
    signal pend    : std_logic_vector(N_SRC-1 downto 0) := (others => '0');
    signal id_snap : id_arr;
    signal argsnap : arg_arr;
    signal rr, cur : integer range 0 to N_SRC-1 := 0;
    signal busy    : std_logic := '0';
    signal mvalid  : std_logic := '0';
    signal drops   : std_logic_vector(N_SRC*CNT_W-1 downto 0) := (others => '0');
begin
    msg_valid   <= mvalid;
    dropped_cnt <= drops;

    process(clk)
        variable s     : integer;
        variable found : boolean;
        variable dc    : unsigned(CNT_W-1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pend <= (others => '0'); mvalid <= '0'; busy <= '0'; rr <= 0;
                drops <= (others => '0');
            else
                -- capture: one-cycle atomic snapshot per firing source
                for i in 0 to N_SRC-1 loop
                    if trig(i) = '1' then
                        if pend(i) = '1' or (busy = '1' and cur = i) then
                            dc := unsigned(drops(i*CNT_W+CNT_W-1 downto i*CNT_W));
                            if dc /= (2**CNT_W - 1) then
                                drops(i*CNT_W+CNT_W-1 downto i*CNT_W)
                                    <= std_logic_vector(dc + 1);
                            end if;
                        else
                            id_snap(i) <= trig_msg_id(i*16+15 downto i*16);
                            argsnap(i) <= trig_args((i+1)*32*ARGC_MAX-1 downto i*32*ARGC_MAX);
                            pend(i)    <= '1';
                        end if;
                    end if;
                end loop;

                -- hand-over: round-robin grant, message-granular
                if busy = '0' then
                    found := false;
                    for j in 0 to N_SRC-1 loop
                        if rr + j >= N_SRC then s := rr + j - N_SRC;
                        else s := rr + j; end if;
                        if (not found) and pend(s) = '1' then
                            found := true;
                            cur       <= s;
                            msg_id    <= unsigned(id_snap(s));
                            args_flat <= argsnap(s);
                            mvalid    <= '1';
                            busy      <= '1';
                        end if;
                    end loop;
                elsif mvalid = '1' and msg_ready = '1' then
                    mvalid    <= '0';
                    busy      <= '0';
                    pend(cur) <= '0';
                    if cur + 1 >= N_SRC then rr <= 0; else rr <= cur + 1; end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
