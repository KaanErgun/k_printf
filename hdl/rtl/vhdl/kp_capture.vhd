-- kp_capture.vhd - capture sink (k_snprintf analogue), VHDL-2008 twin of
-- rtl/sv/kp_capture.sv: store the stream into a RAM (truncating at DEPTH,
-- still counting), count completed messages via the out_last marker.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity kp_capture is
    generic (
        DEPTH : integer := 1024
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        clear    : in  std_logic;
        in_valid : in  std_logic;
        in_ready : out std_logic;
        in_data  : in  std_logic_vector(7 downto 0);
        in_last  : in  std_logic;
        count    : out unsigned(15 downto 0);
        msgs     : out unsigned(15 downto 0);
        rd_addr  : in  unsigned(15 downto 0);
        rd_data  : out std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of kp_capture is
    type mem_t is array(0 to DEPTH-1) of std_logic_vector(7 downto 0);
    signal mem  : mem_t;
    signal cnt  : unsigned(15 downto 0) := (others => '0');
    signal msgc : unsigned(15 downto 0) := (others => '0');
begin
    in_ready <= '1';
    count    <= cnt;
    msgs     <= msgc;
    rd_data  <= mem(to_integer(rd_addr)) when to_integer(rd_addr) < DEPTH
                else (others => '0');

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or clear = '1' then
                cnt <= (others => '0'); msgc <= (others => '0');
            elsif in_valid = '1' then
                if in_last = '1' then
                    if msgc /= x"FFFF" then msgc <= msgc + 1; end if;
                else
                    if cnt < DEPTH then
                        mem(to_integer(cnt)) <= in_data;
                    end if;
                    if cnt /= x"FFFF" then cnt <= cnt + 1; end if;  -- saturate
                end if;
            end if;
        end if;
    end process;
end architecture;
