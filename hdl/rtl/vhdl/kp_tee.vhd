-- kp_tee.vhd - broadcast one byte stream to two sinks, VHDL-2008 twin of
-- rtl/sv/kp_tee.sv. Registered fork: hold each byte until BOTH sinks accept;
-- a_valid/b_valid depend only on in_valid + state, so no combinational
-- valid<->ready loop (safe with ready-when-valid sinks).
library ieee;
use ieee.std_logic_1164.all;

entity kp_tee is
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;

        in_valid : in  std_logic;
        in_ready : out std_logic;
        in_data  : in  std_logic_vector(7 downto 0);
        in_last  : in  std_logic;

        a_valid  : out std_logic;
        a_ready  : in  std_logic;
        a_data   : out std_logic_vector(7 downto 0);
        a_last   : out std_logic;

        b_valid  : out std_logic;
        b_ready  : in  std_logic;
        b_data   : out std_logic_vector(7 downto 0);
        b_last   : out std_logic
    );
end entity;

architecture rtl of kp_tee is
    signal sent_a, sent_b : std_logic := '0';
    signal av, bv, inr    : std_logic;
begin
    av  <= in_valid and not sent_a;
    bv  <= in_valid and not sent_b;
    inr <= in_valid and (sent_a or a_ready) and (sent_b or b_ready);

    a_valid  <= av;   b_valid  <= bv;
    in_ready <= inr;
    a_data   <= in_data;  a_last <= in_last;
    b_data   <= in_data;  b_last <= in_last;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sent_a <= '0'; sent_b <= '0';
            elsif in_valid = '1' then
                if inr = '1' then
                    sent_a <= '0'; sent_b <= '0';
                else
                    if av = '1' and a_ready = '1' then sent_a <= '1'; end if;
                    if bv = '1' and b_ready = '1' then sent_b <= '1'; end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
