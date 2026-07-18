-- kp_axil.vhd - AXI4-Lite slave adapter over kp_regs, VHDL-2008 twin of
-- rtl/sv/kp_axil.sv. Word-addressed (byte addr [5:2] = register index),
-- one transaction at a time, writes take priority.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity kp_axil is
    generic (
        AW : integer := 6
    );
    port (
        aclk      : in  std_logic;
        aresetn   : in  std_logic;
        s_awaddr  : in  std_logic_vector(AW-1 downto 0);
        s_awvalid : in  std_logic;
        s_awready : out std_logic;
        s_wdata   : in  std_logic_vector(31 downto 0);
        s_wstrb   : in  std_logic_vector(3 downto 0);
        s_wvalid  : in  std_logic;
        s_wready  : out std_logic;
        s_bresp   : out std_logic_vector(1 downto 0);
        s_bvalid  : out std_logic;
        s_bready  : in  std_logic;
        s_araddr  : in  std_logic_vector(AW-1 downto 0);
        s_arvalid : in  std_logic;
        s_arready : out std_logic;
        s_rdata   : out std_logic_vector(31 downto 0);
        s_rresp   : out std_logic_vector(1 downto 0);
        s_rvalid  : out std_logic;
        s_rready  : in  std_logic;
        reg_wen   : out std_logic;
        reg_addr  : out unsigned(3 downto 0);
        reg_wdata : out std_logic_vector(31 downto 0);
        reg_rdata : in  std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of kp_axil is
    type st_t is (IDLE, WRESP, RDATA);
    signal st : st_t := IDLE;
    signal bvalid_i, rvalid_i : std_logic := '0';
    signal wen_i   : std_logic := '0';
    signal addr_i  : unsigned(3 downto 0) := (others => '0');
    signal wdata_i : std_logic_vector(31 downto 0) := (others => '0');
    signal rdata_i : std_logic_vector(31 downto 0) := (others => '0');
    signal wr_go   : std_logic;
begin
    s_bresp <= "00";  s_rresp <= "00";
    -- combinational readys (state + input valids only -> no loop)
    wr_go     <= '1' when st = IDLE and s_awvalid = '1' and s_wvalid = '1' else '0';
    s_awready <= wr_go;
    s_wready  <= wr_go;
    s_arready <= '1' when st = IDLE and wr_go = '0' and s_arvalid = '1' else '0';

    s_bvalid  <= bvalid_i; s_rvalid <= rvalid_i; s_rdata <= rdata_i;
    reg_wen   <= wen_i; reg_addr <= addr_i; reg_wdata <= wdata_i;

    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                st <= IDLE;
                bvalid_i <= '0'; rvalid_i <= '0'; wen_i <= '0';
                addr_i <= (others => '0'); wdata_i <= (others => '0');
                rdata_i <= (others => '0');
            else
                wen_i <= '0';
                case st is
                when IDLE =>
                    if wr_go = '1' then                              -- write (priority)
                        addr_i  <= unsigned(s_awaddr(5 downto 2));
                        wdata_i <= s_wdata;
                        wen_i   <= '1';
                        bvalid_i <= '1';
                        st <= WRESP;
                    elsif s_arvalid = '1' then                       -- read
                        addr_i <= unsigned(s_araddr(5 downto 2));
                        st <= RDATA;
                    end if;
                when WRESP =>
                    if s_bready = '1' then bvalid_i <= '0'; st <= IDLE; end if;
                when RDATA =>
                    if rvalid_i = '0' then
                        rdata_i  <= reg_rdata;   -- reg_addr settled last cycle
                        rvalid_i <= '1';
                    elsif s_rready = '1' then
                        rvalid_i <= '0'; st <= IDLE;
                    end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
