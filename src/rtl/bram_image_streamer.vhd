--------------------------------------------------------------------------------
-- Module:      bram_image_streamer
-- Description: AXI Stream master that streams a 1920x1080 frame from Block RAM.
--              The image is stored in Block RAM, initialized from a .mem file.
--
-- AXI Stream Video Protocol:
--   - tuser is asserted on the first transfer of each frame (start-of-frame)
--   - tlast is asserted on the last transfer of each line (end-of-line)
--   - tdata carries 2 pixels per clock (48 bits = 2 x 24-bit RGB)
--   - tready backpressure is fully supported
--
-- BRAM Initialization:
--   Provide a .mem file with 1,036,800 lines (960 clks x 1080 lines), each
--   containing a 12-digit hex value (48 bits = 2 pixels).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity bram_image_streamer is
    generic (
        MEM_INIT_FILE : string := "image.mem"
    );
    port (
        aclk             : in  std_logic;
        aresetn          : in  std_logic;

        -- AXI Stream Master (Video Output)
        VIDEO_OUT_tdata  : out std_logic_vector(47 downto 0);
        VIDEO_OUT_tvalid : out std_logic;
        VIDEO_OUT_tlast  : out std_logic;
        VIDEO_OUT_tuser  : out std_logic;
        VIDEO_OUT_tready : in  std_logic
    );
end entity bram_image_streamer;

architecture rtl of bram_image_streamer is

    ---------------------------------------------------------------------------
    -- Frame constants
    ---------------------------------------------------------------------------
    constant C_PIXELS_PER_CLK : integer := 2;
    constant C_H_PIXELS       : integer := 1920;
    constant C_V_LINES        : integer := 1080;
    constant C_CLKS_PER_LINE  : integer := C_H_PIXELS / C_PIXELS_PER_CLK; -- 960
    constant C_TOTAL_ADDRS    : integer := C_CLKS_PER_LINE * C_V_LINES;   -- 1,036,800

    ---------------------------------------------------------------------------
    -- BRAM ROM type and initialization from .mem file
    ---------------------------------------------------------------------------
    type rom_type is array (0 to C_TOTAL_ADDRS - 1) of std_logic_vector(47 downto 0);

    impure function read_rom_file(filename : in string; data_length : in integer; rom_size : in integer) return rom_type is
        file mem_file     : text open read_mode is filename;
        variable line_buf : line;
        variable data     : std_logic_vector(data_length - 1 downto 0);
        variable rom      : rom_type;
    begin
        for i in 0 to (rom_size - 1) loop
            readline(mem_file, line_buf);
            hread(line_buf, data);
            rom(i) := data;
        end loop;
        return rom;
    end function;

    signal rom : rom_type := read_rom_file(MEM_INIT_FILE, 48, C_TOTAL_ADDRS);
    attribute ram_style : string;
    attribute ram_style of rom : signal is "block";

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------
    signal rom_data   : std_logic_vector(47 downto 0) := (others => '0');
    signal addr_reg   : integer range 0 to C_TOTAL_ADDRS - 1 := 0;
    signal x_cnt      : integer range 0 to C_CLKS_PER_LINE - 1 := 0;
    signal y_cnt      : integer range 0 to C_V_LINES - 1       := 0;
    signal primed     : std_logic := '0';
    signal data_valid : std_logic := '0';
    signal sof_flag   : std_logic := '1';
    signal handshake  : std_logic;
    signal bram_re    : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Handshake detection
    ---------------------------------------------------------------------------
    handshake <= data_valid and VIDEO_OUT_tready;

    ---------------------------------------------------------------------------
    -- BRAM read enable: read during priming or on handshake
    ---------------------------------------------------------------------------
    bram_re <= '1' when (primed = '0') or
                        (data_valid = '0') or
                        (handshake = '1')
               else '0';

    ---------------------------------------------------------------------------
    -- BRAM read process (1-cycle latency, registered output)
    ---------------------------------------------------------------------------
    p_bram_read : process(aclk)
    begin
        if rising_edge(aclk) then
            if bram_re = '1' then
                rom_data <= rom(addr_reg);
            end if;
        end if;
    end process p_bram_read;

    ---------------------------------------------------------------------------
    -- Main control process: counters, pipeline, start-of-frame
    ---------------------------------------------------------------------------
    p_control : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                addr_reg   <= 0;
                x_cnt      <= 0;
                y_cnt      <= 0;
                primed     <= '0';
                data_valid <= '0';
                sof_flag   <= '1';
            else
                -- Pipeline priming (2-stage startup after reset)
                if primed = '0' then
                    primed <= '1';
                elsif data_valid = '0' then
                    data_valid <= '1';
                end if;

                -- Advance counters only on successful handshake
                if handshake = '1' then

                    -- Frame position counters
                    if x_cnt = C_CLKS_PER_LINE - 1 then
                        x_cnt <= 0;
                        if y_cnt = C_V_LINES - 1 then
                            y_cnt    <= 0;
                            addr_reg <= 0;
                            sof_flag <= '1';
                        else
                            y_cnt    <= y_cnt + 1;
                            sof_flag <= '0';
                        end if;
                    else
                        x_cnt    <= x_cnt + 1;
                        sof_flag <= '0';
                    end if;

                    -- BRAM address: always advance (no windowing)
                    if addr_reg = C_TOTAL_ADDRS - 1 then
                        addr_reg <= 0;
                    else
                        addr_reg <= addr_reg + 1;
                    end if;

                end if;
            end if;
        end if;
    end process p_control;

    ---------------------------------------------------------------------------
    -- AXI Stream output assignments
    ---------------------------------------------------------------------------
    VIDEO_OUT_tdata  <= rom_data;
    VIDEO_OUT_tvalid <= data_valid;
    VIDEO_OUT_tlast  <= '1' when (x_cnt = C_CLKS_PER_LINE - 1) and (data_valid = '1') else '0';
    VIDEO_OUT_tuser  <= sof_flag and data_valid;

end architecture rtl;