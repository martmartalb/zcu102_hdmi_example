--------------------------------------------------------------------------------
-- Module:      vdma_frame_buffer
-- Description: AXI Stream switch for HDMI frame buffer using AXI VDMA.
--              Routes video streams between HDMI RX/TX and VDMA channels
--              based on switch inputs. The VDMA IP handles all memory access,
--              address generation, and frame synchronization.
--
-- Operation:
--   No switch:     Passthrough — S_AXIS forwarded directly to M_AXIS.
--   sw_save = '1': Broadcast — S_AXIS feeds both M_AXIS (passthrough) and
--                  VDMA S2MM (capture to DDR). Backpressure from either
--                  output stalls the input.
--   sw_read = '1': Playback — VDMA MM2S drives M_AXIS. S_AXIS input is
--                  accepted and discarded (tready = '1').
--
-- Priority: sw_read > sw_save > passthrough.
--
-- AXI Stream Video Protocol:
--   - tuser: start-of-frame (first transfer of each frame)
--   - tlast: end-of-line (last transfer of each line)
--   - tdata: 48 bits = 2 x 24-bit RGB pixels
--   - tready: backpressure fully supported
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vdma_frame_buffer is
    port (
        -- Clock / reset
        hdmi_clk        : in  std_logic;
        hdmi_resetn     : in  std_logic;

        -- AXI Stream Slave (from HDMI RX)
        HDMI_S_AXIS_tdata    : in  std_logic_vector(47 downto 0);
        HDMI_S_AXIS_tvalid   : in  std_logic;
        HDMI_S_AXIS_tlast    : in  std_logic;
        HDMI_S_AXIS_tuser    : in  std_logic_vector(0 downto 0);
        HDMI_S_AXIS_tready   : out std_logic;

        -- AXI Stream Master (to HDMI TX)
        HDMI_M_AXIS_tdata    : out std_logic_vector(47 downto 0);
        HDMI_M_AXIS_tvalid   : out std_logic;
        HDMI_M_AXIS_tlast    : out std_logic;
        HDMI_M_AXIS_tuser    : out std_logic_vector(0 downto 0);
        HDMI_M_AXIS_tready   : in  std_logic;

        -- AXI Stream Master to VDMA S2MM (capture: video → DDR)
        VDMA_AXIS_S2MM_tdata  : out std_logic_vector(47 downto 0);
        VDMA_AXIS_S2MM_tvalid : out std_logic;
        VDMA_AXIS_S2MM_tlast  : out std_logic;
        VDMA_AXIS_S2MM_tuser  : out std_logic_vector(0 downto 0);
        VDMA_AXIS_S2MM_tready : in  std_logic;

        -- AXI Stream Slave from VDMA MM2S (playback: DDR → video)
        VDMA_AXIS_MM2S_tdata  : in  std_logic_vector(47 downto 0);
        VDMA_AXIS_MM2S_tvalid : in  std_logic;
        VDMA_AXIS_MM2S_tlast  : in  std_logic;
        VDMA_AXIS_MM2S_tuser  : in  std_logic_vector(0 downto 0);
        VDMA_AXIS_MM2S_tready : out std_logic;

        -- Switches
        sw_save         : in  std_logic;
        sw_read         : in  std_logic
    );
end entity vdma_frame_buffer;

architecture rtl of vdma_frame_buffer is

    ---------------------------------------------------------------------------
    -- IP Integrator interface attributes
    ---------------------------------------------------------------------------
    ATTRIBUTE X_INTERFACE_INFO : STRING;
    ATTRIBUTE X_INTERFACE_INFO of hdmi_clk: SIGNAL is
        "xilinx.com:signal:clock:1.0 hdmi_clk CLK";

    ATTRIBUTE X_INTERFACE_PARAMETER : STRING;
    attribute X_INTERFACE_PARAMETER of hdmi_clk : signal is
        "ASSOCIATED_BUSIF S_AXIS:M_AXIS:VDMA_S2MM:VDMA_MM2S, ASSOCIATED_RESET hdmi_resetn, FREQ_HZ 299970032";

    ---------------------------------------------------------------------------
    -- Switch synchronizers (2-FF) to HDMI clock domain
    ---------------------------------------------------------------------------
    signal sw_save_meta : std_logic := '0';
    signal sw_save_sync : std_logic := '0';
    signal sw_read_meta : std_logic := '0';
    signal sw_read_sync : std_logic := '0';

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sw_save_meta : signal is "TRUE";
    attribute ASYNC_REG of sw_save_sync : signal is "TRUE";
    attribute ASYNC_REG of sw_read_meta : signal is "TRUE";
    attribute ASYNC_REG of sw_read_sync : signal is "TRUE";

    ---------------------------------------------------------------------------
    -- Switch debouncer
    ---------------------------------------------------------------------------
    constant C_DEBOUNCE_MAX   : unsigned(19 downto 0) := to_unsigned(999999, 20);
    signal   sw_save_deb      : std_logic;
    signal   sw_read_deb      : std_logic;
    signal   sw_save_deb_cnt  : unsigned(19 downto 0) := (others => '0');
    signal   sw_read_deb_cnt  : unsigned(19 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Mode signals (derived from synchronized switches)
    ---------------------------------------------------------------------------
    signal reading : std_logic;
    signal saving  : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Synchronize asynchronous switch inputs to HDMI clock domain
    ---------------------------------------------------------------------------
    p_sync_switches : process(hdmi_clk)
    begin
        if rising_edge(hdmi_clk) then
            if hdmi_resetn = '0' then
                sw_save_meta <= '0';
                sw_save_sync <= '0';
                sw_read_meta <= '0';
                sw_read_sync <= '0';
            else
                sw_save_meta <= sw_save;
                sw_save_sync <= sw_save_meta;
                sw_read_meta <= sw_read;
                sw_read_sync <= sw_read_meta;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Switch debounce (hdmi_clk domain)
    ---------------------------------------------------------------------------
    p_debounce : process(hdmi_clk)
    begin
        if rising_edge(hdmi_clk) then
            if hdmi_resetn = '0' then
                sw_save_deb     <= '0';
                sw_read_deb     <= '0';
                sw_save_deb_cnt <= (others => '0');
                sw_read_deb_cnt <= (others => '0');
            else
                -- sw_save debounce
                if sw_save_sync = sw_save_deb then
                    sw_save_deb_cnt <= (others => '0');
                elsif sw_save_deb_cnt = C_DEBOUNCE_MAX then
                    sw_save_deb     <= sw_save_sync;
                    sw_save_deb_cnt <= (others => '0');
                else
                    sw_save_deb_cnt <= sw_save_deb_cnt + 1;
                end if;
                -- sw_read debounce
                if sw_read_sync = sw_read_deb then
                    sw_read_deb_cnt <= (others => '0');
                elsif sw_read_deb_cnt = C_DEBOUNCE_MAX then
                    sw_read_deb     <= sw_read_sync;
                    sw_read_deb_cnt <= (others => '0');
                else
                    sw_read_deb_cnt <= sw_read_deb_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- sw_save  --> sw_save_meta --> sw_save_sync --> debouncer --> sw_save_deb
    -- sw_read  --> sw_read_meta --> sw_read_sync --> debouncer --> sw_read_deb
    -- sw_read takes priority over sw_save
    ----------------------------------------------------------------------------
    reading <= sw_read_deb;
    saving  <= sw_save_deb and not sw_read_deb;

    ---------------------------------------------------------------------------
    -- S_AXIS backpressure
    --   Read mode:  always accept (discard RX input)
    --   Save mode:  both TX and VDMA S2MM must be ready (broadcast)
    --   Passthrough: follow TX ready
    ---------------------------------------------------------------------------
    HDMI_S_AXIS_tready <= 
        '1'                                          when reading = '1' else
        HDMI_M_AXIS_tready and VDMA_AXIS_S2MM_tready when saving  = '1' else
        HDMI_M_AXIS_tready;

    ---------------------------------------------------------------------------
    -- M_AXIS output mux (to HDMI TX)
    --   Read mode:  driven by VDMA MM2S (playback)
    --   Save mode and Passthrough:  driven by S_AXIS
    ---------------------------------------------------------------------------
    HDMI_M_AXIS_tdata  <= VDMA_AXIS_MM2S_tdata  when reading = '1' else 
                          HDMI_S_AXIS_tdata;
    HDMI_M_AXIS_tvalid <= VDMA_AXIS_MM2S_tvalid when reading = '1' else
                          HDMI_S_AXIS_tvalid;
    HDMI_M_AXIS_tlast  <= VDMA_AXIS_MM2S_tlast  when reading = '1' else
                          HDMI_S_AXIS_tlast;
    HDMI_M_AXIS_tuser  <= VDMA_AXIS_MM2S_tuser  when reading = '1' else 
                          HDMI_S_AXIS_tuser;

    ---------------------------------------------------------------------------
    -- VDMA S2MM
    --   Always driven by HDMI_S_AXIS
    ---------------------------------------------------------------------------
    VDMA_AXIS_S2MM_tdata    <= HDMI_S_AXIS_tdata;
    VDMA_AXIS_S2MM_tvalid   <= HDMI_S_AXIS_tvalid;
    VDMA_AXIS_S2MM_tlast    <= HDMI_S_AXIS_tlast;
    VDMA_AXIS_S2MM_tuser    <= HDMI_S_AXIS_tuser;

    ---------------------------------------------------------------------------
    -- VDMA MM2S (playback from DDR)
    --   Read mode:  backpressure follows TX ready
    --   Otherwise:  always accept and discard (keep VDMA flowing)
    ---------------------------------------------------------------------------
    VDMA_AXIS_MM2S_tready <= HDMI_M_AXIS_tready when reading = '1' else '1';

end architecture rtl;
