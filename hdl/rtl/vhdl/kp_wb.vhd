-- kp_wb.vhd - Wishbone B4 classic single-cycle slave over kp_regs, VHDL-2008
-- twin of rtl/sv/kp_wb.sv. Word-addressed (low 4 bits pick the register).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity kp_wb is
    generic (
        ADR_W : integer := 4
    );
    port (
        clk_i     : in  std_logic;
        rst_i     : in  std_logic;
        wb_adr_i  : in  std_logic_vector(ADR_W-1 downto 0);
        wb_dat_i  : in  std_logic_vector(31 downto 0);
        wb_dat_o  : out std_logic_vector(31 downto 0);
        wb_we_i   : in  std_logic;
        wb_cyc_i  : in  std_logic;
        wb_stb_i  : in  std_logic;
        wb_ack_o  : out std_logic;
        reg_wen   : out std_logic;
        reg_addr  : out unsigned(3 downto 0);
        reg_wdata : out std_logic_vector(31 downto 0);
        reg_rdata : in  std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of kp_wb is
    signal ack_i   : std_logic := '0';
    signal access0 : std_logic;
begin
    access0   <= wb_cyc_i and wb_stb_i and (not ack_i);
    reg_addr  <= unsigned(wb_adr_i(3 downto 0));
    reg_wdata <= wb_dat_i;
    reg_wen   <= access0 and wb_we_i;
    wb_dat_o  <= reg_rdata;
    wb_ack_o  <= ack_i;

    process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then ack_i <= '0';
            else                ack_i <= access0;      -- single-cycle ack
            end if;
        end if;
    end process;
end architecture;
