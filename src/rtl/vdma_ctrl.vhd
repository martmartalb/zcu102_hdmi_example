--------------------------------------------------------------------------------
-- Module:      vdma_ctrl
-- Description: AXI4-Lite master controller that configures the AXI VDMA IP
--              entirely from PL logic — no PS software required.
--
--              After reset is released (which is gated by MIG init_calib_complete),
--              this module programs the VDMA S2MM and MM2S channel registers
--              through a sequence of AXI4-Lite write transactions, then starts
--              both channels in circular mode.
--
-- Register map (PG020 AXI VDMA v6.3):
--   0x00  MM2S_VDMACR           0x30  S2MM_VDMACR
--   0x50  MM2S_VSIZE            0xA0  S2MM_VSIZE
--   0x54  MM2S_HSIZE            0xA4  S2MM_HSIZE
--   0x58  MM2S_FRMDLY_STRIDE    0xA8  S2MM_FRMDLY_STRIDE
--   0x5C  MM2S_START_ADDRESS1   0xAC  S2MM_START_ADDRESS1
--
-- Programming order per PG020: VDMACR (RS=1) first, then START_ADDRESS,
-- STRIDE, HSIZE, and finally VSIZE — writing VSIZE starts the channel.
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

        -- Status outputs
        cfg_done            : out std_logic;
        cfg_error           : out std_logic;

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
    constant DMACR_RUN_CIRC : std_logic_vector(31 downto 0) := x"00010083";

    constant CFG_ROM : cfg_rom_t := (
        -- S2MM channel (capture to DDR4): DMACR first (RS=1), VSIZE last (trigger)
        0 => (addr => x"00000030", data => DMACR_RUN_CIRC),    -- S2MM DMACR (RS=1)
        1 => (addr => x"000000AC", data => FRAME_BASE_ADDR),   -- S2MM start addr
        2 => (addr => x"000000A8", data => STRIDE),            -- S2MM stride
        3 => (addr => x"000000A4", data => HSIZE),             -- S2MM hsize
        4 => (addr => x"000000A0", data => VSIZE),             -- S2MM vsize (trigger)
        -- MM2S channel (playback from DDR4): DMACR first (RS=1), VSIZE last (trigger)
        5 => (addr => x"00000000", data => DMACR_RUN_CIRC),    -- MM2S DMACR (RS=1)
        6 => (addr => x"0000005C", data => FRAME_BASE_ADDR),   -- MM2S start addr
        7 => (addr => x"00000058", data => STRIDE),            -- MM2S stride
        8 => (addr => x"00000054", data => HSIZE),             -- MM2S hsize
        9 => (addr => x"00000050", data => VSIZE)              -- MM2S vsize (trigger)
    );

    ---------------------------------------------------------------------------
    -- FSM States
    ---------------------------------------------------------------------------
    type state_t is (S_START, S_WRITE_ADDR, S_WAIT_BRESP, S_DONE);
    signal state : state_t := S_START;

    ---------------------------------------------------------------------------
    -- AXI4-Lite internal signals
    ---------------------------------------------------------------------------
    signal axi_awvalid : std_logic := '0';
    signal axi_awaddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal axi_wvalid  : std_logic := '0';
    signal axi_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal axi_bready  : std_logic := '0';

    ---------------------------------------------------------------------------
    -- Transaction tracking
    ---------------------------------------------------------------------------
    signal wr_idx        : integer range 0 to NUM_WRITES := 0;
    signal aw_accepted   : std_logic := '0';
    signal w_accepted    : std_logic := '0';
    signal write_resp_error : std_logic := '0';
    signal error_reg     : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- Read channel: unused — tie off
    ---------------------------------------------------------------------------
    m_axi_lite_araddr  <= (others => '0');
    m_axi_lite_arvalid <= '0';
    m_axi_lite_arprot  <= "000";
    m_axi_lite_rready  <= '0';

    ---------------------------------------------------------------------------
    -- Connect internal signals to outputs
    ---------------------------------------------------------------------------
    m_axi_lite_awaddr  <= axi_awaddr;
    m_axi_lite_awvalid <= axi_awvalid;
    m_axi_lite_awprot  <= "000";
    m_axi_lite_wdata   <= axi_wdata;
    m_axi_lite_wvalid  <= axi_wvalid;
    m_axi_lite_wstrb   <= "1111";
    m_axi_lite_bready  <= axi_bready;

    -- Status outputs
    cfg_done  <= '1' when state = S_DONE else '0';
    cfg_error <= error_reg;

    ---------------------------------------------------------------------------
    -- Flag write response errors (BRESP[1] indicates SLVERR or DECERR)
    ---------------------------------------------------------------------------
    write_resp_error <= axi_bready and m_axi_lite_bvalid and m_axi_lite_bresp(1);

    ---------------------------------------------------------------------------
    -- Error register: capture any write response errors
    ---------------------------------------------------------------------------
    p_error_reg : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                error_reg <= '0';
            elsif write_resp_error = '1' then
                error_reg <= '1';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Main AXI4-Lite Write FSM
    ---------------------------------------------------------------------------
    p_fsm : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state        <= S_START;
                wr_idx       <= 0;
                aw_accepted  <= '0';
                w_accepted   <= '0';
                axi_awvalid  <= '0';
                axi_awaddr   <= (others => '0');
                axi_wvalid   <= '0';
                axi_wdata    <= (others => '0');
                axi_bready   <= '0';
            else
                case state is

                    -------------------------------------------------------
                    -- S_START: Begin first transaction immediately
                    -------------------------------------------------------
                    when S_START =>
                        axi_awaddr  <= CFG_ROM(wr_idx).addr;
                        axi_awvalid <= '1';
                        axi_wdata   <= CFG_ROM(wr_idx).data;
                        axi_wvalid  <= '1';
                        aw_accepted <= '0';
                        w_accepted  <= '0';
                        wr_idx      <= wr_idx + 1;
                        state       <= S_WRITE_ADDR;

                    -------------------------------------------------------
                    -- S_WRITE_ADDR: Handle address/data channel handshakes
                    -------------------------------------------------------
                    when S_WRITE_ADDR =>
                        -- Write address channel handshake
                        if axi_awvalid = '1' and m_axi_lite_awready = '1' then
                            axi_awvalid <= '0';
                            aw_accepted <= '1';
                        end if;

                        -- Write data channel handshake
                        if axi_wvalid = '1' and m_axi_lite_wready = '1' then
                            axi_wvalid <= '0';
                            w_accepted <= '1';
                        end if;

                        -- Both channels completed handshake
                        if ((aw_accepted = '1') or (axi_awvalid = '1' and m_axi_lite_awready = '1')) and
                           ((w_accepted  = '1') or (axi_wvalid  = '1' and m_axi_lite_wready  = '1')) then
                            axi_awvalid <= '0';
                            axi_wvalid  <= '0';
                            axi_bready  <= '1';
                            state       <= S_WAIT_BRESP;
                        end if;

                    -------------------------------------------------------
                    -- S_WAIT_BRESP: Wait for write response, advance index
                    -------------------------------------------------------
                    when S_WAIT_BRESP =>
                        if m_axi_lite_bvalid = '1' and axi_bready = '1' then
                            axi_bready <= '0';

                            if wr_idx < NUM_WRITES then
                                axi_awaddr  <= CFG_ROM(wr_idx).addr;
                                axi_awvalid <= '1';
                                axi_wdata   <= CFG_ROM(wr_idx).data;
                                axi_wvalid  <= '1';
                                aw_accepted <= '0';
                                w_accepted  <= '0';
                                wr_idx      <= wr_idx + 1;
                                state       <= S_WRITE_ADDR;
                            else
                                state  <= S_DONE;
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- S_DONE: Configuration complete
                    -------------------------------------------------------
                    when S_DONE =>
                        null;

                    when others =>
                        state <= S_START;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;