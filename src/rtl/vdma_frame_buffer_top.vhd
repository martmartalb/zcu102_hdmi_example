--------------------------------------------------------------------------------
-- Module:      vdma_frame_buffer_top
-- Description: Top-level wrapper for the VDMA-based frame buffer.
--              Instantiates:
--                1) vdma_frame_buffer — AXI Stream switch (passthrough /
--                   save-broadcast / read-playback)
--                2) vdma_ctrl — AXI4-Lite master that configures the Xilinx
--                   AXI VDMA IP entirely from PL logic (no PS software)
--
--              The block design connects:
--                - S_AXIS / M_AXIS to the HDMI RX / TX video pipeline
--                - VDMA_S2MM to AXI VDMA HDMI_S_AXIS_S2MM (capture to DDR4)
--                - VDMA_MM2S from AXI VDMA HDMI_M_AXIS_MM2S (playback from DDR4)
--                - M_AXI_LITE to AXI VDMA S_AXI_LITE (register config)
--                - init_calib_complete from the MIG DDR4 controller
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity vdma_frame_buffer_top is
    port (
        -- HDMI clock domain
        hdmi_clk             : in  std_logic;
        hdmi_resetn          : in  std_logic;

        -- AXI Stream Slave (from HDMI RX)
        HDMI_S_AXIS_tdata         : in  std_logic_vector(47 downto 0);
        HDMI_S_AXIS_tvalid        : in  std_logic;
        HDMI_S_AXIS_tlast         : in  std_logic;
        HDMI_S_AXIS_tuser         : in  std_logic;
        HDMI_S_AXIS_tready        : out std_logic;

        -- AXI Stream Master (to HDMI TX)
        HDMI_M_AXIS_tdata         : out std_logic_vector(47 downto 0);
        HDMI_M_AXIS_tvalid        : out std_logic;
        HDMI_M_AXIS_tlast         : out std_logic;
        HDMI_M_AXIS_tuser         : out std_logic;
        HDMI_M_AXIS_tready        : in  std_logic;

        -- AXI Stream Master → VDMA S2MM (capture: video → DDR4)
        VDMA_AXIS_S2MM_tdata      : out std_logic_vector(47 downto 0);
        VDMA_AXIS_S2MM_tvalid     : out std_logic;
        VDMA_AXIS_S2MM_tlast      : out std_logic;
        VDMA_AXIS_S2MM_tuser      : out std_logic_vector(0 downto 0);
        VDMA_AXIS_S2MM_tready     : in  std_logic;

        -- AXI Stream Slave ← VDMA MM2S (playback: DDR4 → video)
        VDMA_AXIS_MM2S_tdata      : in  std_logic_vector(47 downto 0);
        VDMA_AXIS_MM2S_tvalid     : in  std_logic;
        VDMA_AXIS_MM2S_tlast      : in  std_logic;
        VDMA_AXIS_MM2S_tuser      : in  std_logic_vector(0 downto 0);
        VDMA_AXIS_MM2S_tready     : out std_logic;

        -- AXI4-Lite Master → VDMA S_AXI_LITE (register configuration)
        M_AXI_LITE_awaddr    : out std_logic_vector(31 downto 0);
        M_AXI_LITE_awvalid   : out std_logic;
        M_AXI_LITE_awready   : in  std_logic;
        M_AXI_LITE_awprot    : out std_logic_vector(2 downto 0);
        M_AXI_LITE_wdata     : out std_logic_vector(31 downto 0);
        M_AXI_LITE_wstrb     : out std_logic_vector(3 downto 0);
        M_AXI_LITE_wvalid    : out std_logic;
        M_AXI_LITE_wready    : in  std_logic;
        M_AXI_LITE_bresp     : in  std_logic_vector(1 downto 0);
        M_AXI_LITE_bvalid    : in  std_logic;
        M_AXI_LITE_bready    : out std_logic;
        M_AXI_LITE_araddr    : out std_logic_vector(31 downto 0);
        M_AXI_LITE_arvalid   : out std_logic;
        M_AXI_LITE_arready   : in  std_logic;
        M_AXI_LITE_arprot    : out std_logic_vector(2 downto 0);
        M_AXI_LITE_rdata     : in  std_logic_vector(31 downto 0);
        M_AXI_LITE_rresp     : in  std_logic_vector(1 downto 0);
        M_AXI_LITE_rvalid    : in  std_logic;
        M_AXI_LITE_rready    : out std_logic;

        -- MIG status
        init_calib_complete  : in  std_logic;

        -- Switches
        sw_save              : in  std_logic;
        sw_read              : in  std_logic
    );
end entity vdma_frame_buffer_top;

architecture structural of vdma_frame_buffer_top is

    ---------------------------------------------------------------------------
    -- IP Integrator interface attributes — hdmi_clk drives S_AXIS, M_AXIS,
    -- VDMA_S2MM, VDMA_MM2S, and M_AXI_LITE
    ---------------------------------------------------------------------------
    ATTRIBUTE X_INTERFACE_INFO : STRING;
    ATTRIBUTE X_INTERFACE_INFO of hdmi_clk: SIGNAL is
        "xilinx.com:signal:clock:1.0 hdmi_clk CLK";

    ATTRIBUTE X_INTERFACE_PARAMETER : STRING;
    attribute X_INTERFACE_PARAMETER of hdmi_clk : signal is
        "ASSOCIATED_BUSIF S_AXIS:M_AXIS:VDMA_S2MM:VDMA_MM2S:M_AXI_LITE, ASSOCIATED_RESET hdmi_resetn, FREQ_HZ 299970032";

begin

    ---------------------------------------------------------------------------
    -- AXI Stream switch (passthrough / save-broadcast / read-playback)
    ---------------------------------------------------------------------------
    u_switch : entity work.vdma_frame_buffer
        port map (
            hdmi_clk         => hdmi_clk,
            hdmi_resetn      => hdmi_resetn,

            HDMI_S_AXIS_tdata     => HDMI_S_AXIS_tdata,
            HDMI_S_AXIS_tvalid    => HDMI_S_AXIS_tvalid,
            HDMI_S_AXIS_tlast     => HDMI_S_AXIS_tlast,
            HDMI_S_AXIS_tuser     => HDMI_S_AXIS_tuser,
            HDMI_S_AXIS_tready    => HDMI_S_AXIS_tready,

            HDMI_M_AXIS_tdata     => HDMI_M_AXIS_tdata,
            HDMI_M_AXIS_tvalid    => HDMI_M_AXIS_tvalid,
            HDMI_M_AXIS_tlast     => HDMI_M_AXIS_tlast,
            HDMI_M_AXIS_tuser     => HDMI_M_AXIS_tuser,
            HDMI_M_AXIS_tready    => HDMI_M_AXIS_tready,

            VDMA_AXIS_S2MM_tdata  => VDMA_AXIS_S2MM_tdata,
            VDMA_AXIS_S2MM_tvalid => VDMA_AXIS_S2MM_tvalid,
            VDMA_AXIS_S2MM_tlast  => VDMA_AXIS_S2MM_tlast,
            VDMA_AXIS_S2MM_tuser  => VDMA_AXIS_S2MM_tuser,
            VDMA_AXIS_S2MM_tready => VDMA_AXIS_S2MM_tready,

            VDMA_AXIS_MM2S_tdata  => VDMA_AXIS_MM2S_tdata,
            VDMA_AXIS_MM2S_tvalid => VDMA_AXIS_MM2S_tvalid,
            VDMA_AXIS_MM2S_tlast  => VDMA_AXIS_MM2S_tlast,
            VDMA_AXIS_MM2S_tuser  => VDMA_AXIS_MM2S_tuser,
            VDMA_AXIS_MM2S_tready => VDMA_AXIS_MM2S_tready,

            sw_save          => sw_save,
            sw_read          => sw_read
        );

    ---------------------------------------------------------------------------
    -- VDMA register controller (AXI4-Lite master)
    ---------------------------------------------------------------------------
    u_vdma_ctrl : entity work.vdma_ctrl
        generic map (
            FRAME_BASE_ADDR => x"00000000",
            HSIZE           => x"00001680",   -- 5760 bytes (1920 px × 3 B/px)
            VSIZE           => x"00000438",   -- 1080 lines
            STRIDE          => x"00001680"    -- 5760 bytes
        )
        port map (
            aclk                => hdmi_clk,
            aresetn             => hdmi_resetn,
            init_calib_complete => init_calib_complete,

            m_axi_lite_awaddr   => M_AXI_LITE_awaddr,
            m_axi_lite_awvalid  => M_AXI_LITE_awvalid,
            m_axi_lite_awready  => M_AXI_LITE_awready,
            m_axi_lite_awprot   => M_AXI_LITE_awprot,
            m_axi_lite_wdata    => M_AXI_LITE_wdata,
            m_axi_lite_wstrb    => M_AXI_LITE_wstrb,
            m_axi_lite_wvalid   => M_AXI_LITE_wvalid,
            m_axi_lite_wready   => M_AXI_LITE_wready,
            m_axi_lite_bresp    => M_AXI_LITE_bresp,
            m_axi_lite_bvalid   => M_AXI_LITE_bvalid,
            m_axi_lite_bready   => M_AXI_LITE_bready,
            m_axi_lite_araddr   => M_AXI_LITE_araddr,
            m_axi_lite_arvalid  => M_AXI_LITE_arvalid,
            m_axi_lite_arready  => M_AXI_LITE_arready,
            m_axi_lite_arprot   => M_AXI_LITE_arprot,
            m_axi_lite_rdata    => M_AXI_LITE_rdata,
            m_axi_lite_rresp    => M_AXI_LITE_rresp,
            m_axi_lite_rvalid   => M_AXI_LITE_rvalid,
            m_axi_lite_rready   => M_AXI_LITE_rready
        );

end architecture structural;
