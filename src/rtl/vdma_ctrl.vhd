--------------------------------------------------------------------------------
-- Module:      vdma_ctrl
-- Description: AXI4-Lite master controller that configures the AXI VDMA IP
--              entirely from PL logic — no PS software required.
--
--              After the MIG reports init_calib_complete, this module programs
--              the VDMA S2MM and MM2S channel registers through a sequence of
--              AXI4-Lite write transactions, then starts both channels in
--              circular mode.
--
-- Register map (PG020 AXI VDMA v6.3):
--   0x00  MM2S_VDMACR           0x30  S2MM_VDMACR
--   0x50  MM2S_VSIZE            0xA0  S2MM_VSIZE
--   0x54  MM2S_HSIZE            0xA4  S2MM_HSIZE
--   0x58  MM2S_FRMDLY_STRIDE    0xA8  S2MM_FRMDLY_STRIDE
--   0x5C  MM2S_START_ADDRESS1   0xAC  S2MM_START_ADDRESS1
--
-- Writing VSIZE is the "trigger" that starts each channel.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vdma_ctrl is
    generic (
        FRAME_BASE_ADDR : std_logic_vector(31 downto 0) := x"00000000";
        HSIZE           : std_logic_vector(31 downto 0) := x"00001680"; -- 5760 bytes
        VSIZE           : std_logic_vector(31 downto 0) := x"00000438"; -- 1080 lines
        STRIDE          : std_logic_vector(31 downto 0) := x"00001680"  -- 5760 bytes
    );
    port (
        aclk                : in  std_logic;
        aresetn             : in  std_logic;
        init_calib_complete : in  std_logic;

        -- AXI4-Lite Master Interface
        m_axi_lite_awaddr   : out std_logic_vector(31 downto 0);
        m_axi_lite_awvalid  : out std_logic;
        m_axi_lite_awready  : in  std_logic;
        m_axi_lite_awprot   : out std_logic_vector(2 downto 0);
        m_axi_lite_wdata    : out std_logic_vector(31 downto 0);
        m_axi_lite_wstrb    : out std_logic_vector(3 downto 0);
        m_axi_lite_wvalid   : out std_logic;
        m_axi_lite_wready   : in  std_logic;
        m_axi_lite_bresp    : in  std_logic_vector(1 downto 0);
        m_axi_lite_bvalid   : in  std_logic;
        m_axi_lite_bready   : out std_logic;
        m_axi_lite_araddr   : out std_logic_vector(31 downto 0);
        m_axi_lite_arvalid  : out std_logic;
        m_axi_lite_arready  : in  std_logic;
        m_axi_lite_arprot   : out std_logic_vector(2 downto 0);
        m_axi_lite_rdata    : in  std_logic_vector(31 downto 0);
        m_axi_lite_rresp    : in  std_logic_vector(1 downto 0);
        m_axi_lite_rvalid   : in  std_logic;
        m_axi_lite_rready   : out std_logic
    );
end entity vdma_ctrl;

architecture rtl of vdma_ctrl is

    ---------------------------------------------------------------------------
    -- Configuration ROM
    ---------------------------------------------------------------------------
    constant NUM_WRITES : integer := 10;

    type cfg_entry_t is record
        addr : std_logic_vector(31 downto 0);
        data : std_logic_vector(31 downto 0);
    end record;

    type cfg_rom_t is array (0 to NUM_WRITES - 1) of cfg_entry_t;

    -- VDMACR: bit 0 = RS (Run/Stop), bit 1 = Circular_Park (1 = circular)
    constant DMACR_RUN_CIRC : std_logic_vector(31 downto 0) := x"00000003";

    constant CFG_ROM : cfg_rom_t := (
        -- S2MM channel (capture to DDR4) — configure before VSIZE trigger
        0 => (addr => x"000000AC", data => FRAME_BASE_ADDR),   -- S2MM start addr
        1 => (addr => x"000000A8", data => STRIDE),            -- S2MM stride
        2 => (addr => x"000000A4", data => HSIZE),             -- S2MM hsize
        3 => (addr => x"00000030", data => DMACR_RUN_CIRC),    -- S2MM DMACR
        4 => (addr => x"000000A0", data => VSIZE),             -- S2MM vsize (START)
        -- MM2S channel (playback from DDR4)
        5 => (addr => x"0000005C", data => FRAME_BASE_ADDR),   -- MM2S start addr
        6 => (addr => x"00000058", data => STRIDE),            -- MM2S stride
        7 => (addr => x"00000054", data => HSIZE),             -- MM2S hsize
        8 => (addr => x"00000000", data => DMACR_RUN_CIRC),    -- MM2S DMACR
        9 => (addr => x"00000050", data => VSIZE)              -- MM2S vsize (START)
    );

    ---------------------------------------------------------------------------
    -- init_calib_complete synchronizer (MIG clock → AXI-Lite clock)
    ---------------------------------------------------------------------------
    signal calib_meta : std_logic := '0';
    signal calib_sync : std_logic := '0';

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of calib_meta : signal is "TRUE";
    attribute ASYNC_REG of calib_sync : signal is "TRUE";

    ---------------------------------------------------------------------------
    -- FSM
    ---------------------------------------------------------------------------
    type state_t is (S_WAIT_CALIB, S_WRITE, S_WAIT_BRESP, S_DONE);
    signal state   : state_t := S_WAIT_CALIB;
    signal wr_idx  : integer range 0 to NUM_WRITES - 1 := 0;
    signal aw_done : std_logic := '0';
    signal w_done  : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Read channel: unused — tie off
    ---------------------------------------------------------------------------
    m_axi_lite_araddr  <= (others => '0');
    m_axi_lite_arvalid <= '0';
    m_axi_lite_arprot  <= "000";
    m_axi_lite_rready  <= '0';

    -- Write protection: unprivileged, secure, data access
    m_axi_lite_awprot  <= "000";

    -- Write strobe: always write all 4 bytes
    m_axi_lite_wstrb   <= "1111";

    ---------------------------------------------------------------------------
    -- Synchronize init_calib_complete
    ---------------------------------------------------------------------------
    p_sync_calib : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                calib_meta <= '0';
                calib_sync <= '0';
            else
                calib_meta <= init_calib_complete;
                calib_sync <= calib_meta;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- AXI4-Lite write FSM
    ---------------------------------------------------------------------------
    p_fsm : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state              <= S_WAIT_CALIB;
                wr_idx             <= 0;
                aw_done            <= '0';
                w_done             <= '0';
                m_axi_lite_awaddr  <= (others => '0');
                m_axi_lite_awvalid <= '0';
                m_axi_lite_wdata   <= (others => '0');
                m_axi_lite_wvalid  <= '0';
                m_axi_lite_bready  <= '0';
            else
                case state is

                    -------------------------------------------------------
                    -- Wait for MIG calibration
                    -------------------------------------------------------
                    when S_WAIT_CALIB =>
                        if calib_sync = '1' then
                            m_axi_lite_awaddr  <= CFG_ROM(0).addr;
                            m_axi_lite_awvalid <= '1';
                            m_axi_lite_wdata   <= CFG_ROM(0).data;
                            m_axi_lite_wvalid  <= '1';
                            aw_done <= '0';
                            w_done  <= '0';
                            state   <= S_WRITE;
                        end if;

                    -------------------------------------------------------
                    -- Issue address + data simultaneously
                    -------------------------------------------------------
                    when S_WRITE =>
                        -- Address channel accepted?
                        if m_axi_lite_awvalid = '1' and m_axi_lite_awready = '1' then
                            m_axi_lite_awvalid <= '0';
                            aw_done <= '1';
                        end if;

                        -- Data channel accepted?
                        if m_axi_lite_wvalid = '1' and m_axi_lite_wready = '1' then
                            m_axi_lite_wvalid <= '0';
                            w_done <= '1';
                        end if;

                        -- Both accepted → wait for write response
                        if (aw_done = '1' or (m_axi_lite_awvalid = '1' and m_axi_lite_awready = '1')) and
                           (w_done  = '1' or (m_axi_lite_wvalid  = '1' and m_axi_lite_wready  = '1')) then
                            m_axi_lite_awvalid <= '0';
                            m_axi_lite_wvalid  <= '0';
                            m_axi_lite_bready  <= '1';
                            state <= S_WAIT_BRESP;
                        end if;

                    -------------------------------------------------------
                    -- Consume write response, advance to next register
                    -------------------------------------------------------
                    when S_WAIT_BRESP =>
                        if m_axi_lite_bvalid = '1' then
                            m_axi_lite_bready <= '0';

                            if wr_idx < NUM_WRITES - 1 then
                                wr_idx <= wr_idx + 1;
                                m_axi_lite_awaddr  <= CFG_ROM(wr_idx + 1).addr;
                                m_axi_lite_awvalid <= '1';
                                m_axi_lite_wdata   <= CFG_ROM(wr_idx + 1).data;
                                m_axi_lite_wvalid  <= '1';
                                aw_done <= '0';
                                w_done  <= '0';
                                state   <= S_WRITE;
                            else
                                state <= S_DONE;
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- Configuration complete — idle forever
                    -------------------------------------------------------
                    when S_DONE =>
                        null;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
