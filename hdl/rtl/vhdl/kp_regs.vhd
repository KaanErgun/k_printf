-- kp_regs.vhd - register-window front-end, VHDL-2008 twin of rtl/sv/kp_regs.sv.
-- ARG0..7 at word 0..7, write-to-fire SEND at word 8, STATUS at word 9
-- ([0] pend, [1] core err, [15:8] overflow count for SEND-while-pending).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity kp_regs is
    generic (
        ARGC_MAX : integer := 8
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        wen       : in  std_logic;
        addr      : in  unsigned(3 downto 0);
        wdata     : in  std_logic_vector(31 downto 0);
        rdata     : out std_logic_vector(31 downto 0);
        core_err  : in  std_logic;
        msg_valid : out std_logic;
        msg_ready : in  std_logic;
        msg_id    : out unsigned(15 downto 0);
        args_flat : out std_logic_vector(32*ARGC_MAX-1 downto 0)
    );
end entity;

architecture rtl of kp_regs is
    type arg_t is array(0 to ARGC_MAX-1) of std_logic_vector(31 downto 0);
    signal argr    : arg_t := (others => (others => '0'));  -- live (CPU writes)
    signal argsnap : arg_t := (others => (others => '0'));  -- snapshot at fire
    signal ovf     : unsigned(7 downto 0) := (others => '0');
    signal mvalid  : std_logic := '0';
begin
    msg_valid <= mvalid;

    -- the core sees the SNAPSHOT (ARG writes while a SEND is pending cannot
    -- corrupt the already-fired message; matches kp_trig)
    flat : for g in 0 to ARGC_MAX-1 generate
        args_flat(g*32+31 downto g*32) <= argsnap(g);
    end generate;

    rdata <= argr(to_integer(addr)) when to_integer(addr) < ARGC_MAX else
             x"0000" & std_logic_vector(ovf) & "000000" & core_err & mvalid
                 when to_integer(addr) = 9 else
             (others => '0');

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                mvalid <= '0'; ovf <= (others => '0');
                argr <= (others => (others => '0'));
                argsnap <= (others => (others => '0'));
            else
                if mvalid = '1' and msg_ready = '1' then
                    mvalid <= '0';                 -- accepted by the core
                end if;
                if wen = '1' then
                    if to_integer(addr) < ARGC_MAX then
                        argr(to_integer(addr)) <= wdata;
                    elsif to_integer(addr) = 8 then
                        if mvalid = '1' and msg_ready = '0' then
                            if ovf /= x"FF" then ovf <= ovf + 1; end if;
                        else
                            msg_id <= unsigned(wdata(15 downto 0));
                            mvalid <= '1';         -- write-to-fire
                            argsnap <= argr;       -- snapshot args at fire time
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
