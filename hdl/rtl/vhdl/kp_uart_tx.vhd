-- kp_uart_tx.vhd - 8N1 UART transmitter, VHDL-2008 twin of rtl/sv/kp_uart_tx.sv.
--
-- Fractional (N.F) baud generator: acc += BAUD, bit tick when acc >= CLK_HZ.
-- Feed from kp_core with in_valid = out_valid and not out_last (the EOM marker
-- beat carries no data byte) and out_ready = '1' when out_last else in_ready.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity kp_uart_tx is
    generic (
        CLK_HZ : integer := 48_000_000;
        BAUD   : integer := 115_200
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        in_valid : in  std_logic;
        in_ready : out std_logic;
        in_data  : in  std_logic_vector(7 downto 0);
        txd      : out std_logic
    );
end entity;

architecture rtl of kp_uart_tx is
    signal acc     : integer range 0 to 2*CLK_HZ := 0;
    signal shifter : std_logic_vector(8 downto 0);
    signal nbits   : integer range 0 to 9 := 0;
    signal busy    : std_logic := '0';
begin
    in_ready <= not busy;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                busy <= '0'; txd <= '1'; acc <= 0;
            elsif busy = '0' then
                txd <= '1';
                if in_valid = '1' then
                    shifter <= '1' & in_data;   -- stop bit + data (LSB first)
                    txd     <= '0';             -- start bit from this cycle
                    nbits   <= 9;
                    acc     <= 0;
                    busy    <= '1';
                end if;
            else
                if acc + BAUD >= CLK_HZ then
                    acc <= acc + BAUD - CLK_HZ;
                    if nbits = 0 then
                        busy <= '0';            -- stop bit complete
                        txd  <= '1';
                    else
                        txd     <= shifter(0);
                        shifter <= '1' & shifter(8 downto 1);
                        nbits   <= nbits - 1;
                    end if;
                else
                    acc <= acc + BAUD;
                end if;
            end if;
        end if;
    end process;
end architecture;
