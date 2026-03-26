--------------------------------------------------------------------------------
-- Module:      bram_image_streamer
-- Description: AXI Stream master that streams a 1920x1080 frame with a
--              512x512 RGB image centered on a black background.
--              The image is stored in Block RAM, initialized from a .mem file.
--
-- AXI Stream Video Protocol:
--   - tuser is asserted on the first transfer of each frame (start-of-frame)
--   - tlast is asserted on the last transfer of each line (end-of-line)
--   - tdata carries 2 pixels per clock (48 bits = 2 x 24-bit RGB)
--   - tready backpressure is fully supported
--
-- BRAM Initialization:
--   Provide a .mem file with 131,072 lines (256 clks x 512 lines), each
--   containing a 12-digit hex value (48 bits = 2 pixels).
--
-- Image placement (centered in 1920x1080):
--   Horizontal: pixels 704..1215  (clocks 352..607)
--   Vertical:   lines  284..795
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

    ---------------------------------------------------------------------------
    -- Image window constants (512x512 centered)
    ---------------------------------------------------------------------------
    constant C_IMG_H_PIXELS      : integer := 512;
    constant C_IMG_V_LINES       : integer := 512;
    constant C_IMG_CLKS_PER_LINE : integer := C_IMG_H_PIXELS / C_PIXELS_PER_CLK; -- 256
    constant C_IMG_TOTAL_ADDRS   : integer := C_IMG_CLKS_PER_LINE * C_IMG_V_LINES; -- 131,072

    -- Horizontal image window in clock units
    constant C_H_START_CLK : integer := (C_H_PIXELS - C_IMG_H_PIXELS) / 2 / C_PIXELS_PER_CLK; -- 352
    constant C_H_END_CLK   : integer := C_H_START_CLK + C_IMG_CLKS_PER_LINE - 1;               -- 607

    -- Vertical image window in line units
    constant C_V_START : integer := (C_V_LINES - C_IMG_V_LINES) / 2; -- 284
    constant C_V_END   : integer := C_V_START + C_IMG_V_LINES - 1;   -- 795

    -- Black pixel pair
    constant C_BLACK : std_logic_vector(47 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- BRAM ROM type and initialization from .mem file
    ---------------------------------------------------------------------------
    type rom_type is array (0 to C_IMG_TOTAL_ADDRS - 1) of std_logic_vector(47 downto 0);

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

    signal rom : rom_type := read_rom_file(MEM_INIT_FILE, 48, C_IMG_TOTAL_ADDRS);
    attribute ram_style : string;
    attribute ram_style of rom : signal is "block";

    -- signal rom : rom_type;
    -- attribute ram_style        : string;
    -- attribute ram_style of rom : signal is "block";
    -- attribute ram_init_file        : string;
    -- attribute ram_init_file of rom : signal is MEM_INIT_FILE;

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------
    -- BRAM read output (1-cycle latency)
    signal rom_data   : std_logic_vector(47 downto 0) := (others => '0');

    -- BRAM address counter (only advances for image pixels)
    signal addr_reg   : integer range 0 to C_IMG_TOTAL_ADDRS - 1 := 0;

    -- Frame position counters
    signal x_cnt      : integer range 0 to C_CLKS_PER_LINE - 1 := 0;
    signal y_cnt      : integer range 0 to C_V_LINES - 1       := 0;

    -- Pipeline control
    signal primed     : std_logic := '0';
    signal data_valid : std_logic := '0';

    -- Start-of-frame flag
    signal sof_flag   : std_logic := '1';

    -- Handshake signal
    signal handshake  : std_logic;

    -- BRAM read enable
    signal bram_re    : std_logic;

    -- Image window flags
    signal in_image   : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Image window detection
    ---------------------------------------------------------------------------
    in_image <= '1' when (x_cnt >= C_H_START_CLK) and (x_cnt <= C_H_END_CLK) and
                         (y_cnt >= C_V_START)      and (y_cnt <= C_V_END)
                else '0';

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
                    -- Cycle 1: address 0 presented to BRAM, wait for data
                    primed <= '1';
                elsif data_valid = '0' then
                    -- Cycle 2: BRAM output now valid
                    data_valid <= '1';
                end if;

                -- Advance counters only on successful handshake
                if handshake = '1' then

                    -- Frame position counters
                    if x_cnt = C_CLKS_PER_LINE - 1 then
                        -- End of line
                        x_cnt <= 0;
                        if y_cnt = C_V_LINES - 1 then
                            -- End of frame
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

                    -- BRAM address: advance only within image window
                    if in_image = '1' then
                        if addr_reg = C_IMG_TOTAL_ADDRS - 1 then
                            addr_reg <= 0;
                        else
                            addr_reg <= addr_reg + 1;
                        end if;
                    end if;

                end if;
            end if;
        end if;
    end process p_control;

    ---------------------------------------------------------------------------
    -- AXI Stream output assignments
    ---------------------------------------------------------------------------

    -- Data: BRAM pixels inside image window, black outside
    VIDEO_OUT_tdata  <= rom_data when (in_image = '1') else C_BLACK;

    -- Valid: asserted once pipeline is primed
    VIDEO_OUT_tvalid <= data_valid;

    -- Last: end of line (last clock in the 1920-pixel line)
    VIDEO_OUT_tlast  <= '1' when (x_cnt = C_CLKS_PER_LINE - 1) and
                                 (data_valid = '1')
                        else '0';

    -- User: start of frame (first transfer of each frame only)
    VIDEO_OUT_tuser  <= sof_flag and data_valid;

end architecture rtl;