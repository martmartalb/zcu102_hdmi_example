library ieee ;
use ieee.std_logic_1164.all ;
use ieee.numeric_std.all ;

entity ddr4_frame_buffer_top is
  generic (
        APP_ADDR_WIDTH : integer := 28;
        APP_DATA_WIDTH : integer := 128;
        APP_MASK_WIDTH : integer := 16;
        BASE_ADDR      : std_logic_vector(27 downto 0) := x"0000000"
    );
    port (
        -- HDMI clock domain
        hdmi_clk        : in  std_logic;
        hdmi_resetn     : in  std_logic;

        -- AXI Stream Slave (from HDMI RX)
        S_AXIS_tdata    : in  std_logic_vector(47 downto 0);
        S_AXIS_tvalid   : in  std_logic;
        S_AXIS_tlast    : in  std_logic;
        S_AXIS_tuser    : in  std_logic;
        S_AXIS_tready   : out std_logic;

        -- AXI Stream Master (to HDMI TX)
        M_AXIS_tdata    : out std_logic_vector(47 downto 0);
        M_AXIS_tvalid   : out std_logic;
        M_AXIS_tlast    : out std_logic;
        M_AXIS_tuser    : out std_logic;
        M_AXIS_tready   : in  std_logic;

        -- Switches
        sw_save         : in  std_logic;
        sw_read         : in  std_logic;

        -- DDR4 PHI
        c0_sys_clk_p     : IN STD_LOGIC;
        c0_sys_clk_n     : IN STD_LOGIC;
        sys_rst          : IN STD_LOGIC ;
        c0_ddr4_adr      : OUT STD_LOGIC_VECTOR(16 DOWNTO 0);
        c0_ddr4_ba       : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        c0_ddr4_cke      : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_cs_n     : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_dm_dbi_n : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        c0_ddr4_dq       : INOUT STD_LOGIC_VECTOR(15 DOWNTO 0);
        c0_ddr4_dqs_c    : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        c0_ddr4_dqs_t    : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        c0_ddr4_odt      : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_bg       : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_reset_n  : OUT STD_LOGIC;
        c0_ddr4_act_n    : OUT STD_LOGIC;
        c0_ddr4_ck_c     : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_ck_t     : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        --Debug outputs (ILA probes)
        ila_ro_x_cnt     : out std_logic_vector(15 downto 0);
        ila_ro_y_cnt     : out std_logic_vector(15 downto 0)
  ) ;
end ddr4_frame_buffer_top ;

architecture arch of ddr4_frame_buffer_top is

    -- Attributes for HDMI AXI
    ATTRIBUTE X_INTERFACE_INFO : STRING;
    ATTRIBUTE X_INTERFACE_INFO of hdmi_clk: SIGNAL is "xilinx.com:signal:clock:1.0 hdmi_clk CLK";

    ATTRIBUTE X_INTERFACE_PARAMETER : STRING;
	attribute X_INTERFACE_PARAMETER of hdmi_clk : signal is "ASSOCIATED_BUSIF S_AXIS:M_AXIS, ASSOCIATED_RESET hdmi_resetn, FREQ_HZ 299970032";


    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal s_init_calib_complente : std_logic;
    signal s_mig_clk              : std_logic;
    signal s_mig_rst              : std_logic;

    -- UI app interface
    signal s_app_addr               : std_logic_vector(APP_ADDR_WIDTH-1 downto 0);
    signal s_app_cmd                : std_logic_vector(2 downto 0);
    signal s_app_en                 : std_logic;
    signal s_app_wdf_data           : std_logic_vector(APP_DATA_WIDTH-1 downto 0);
    signal s_app_wdf_end            : std_logic;
    signal s_app_wdf_mask           : std_logic_vector(APP_MASK_WIDTH-1 downto 0);
    signal s_app_wdf_wren           : std_logic;
    signal s_app_rdy                : std_logic;
    signal s_app_wdf_rdy            : std_logic;
    signal s_app_rd_data            : std_logic_vector(APP_DATA_WIDTH-1 downto 0);
    signal s_app_rd_data_valid      : std_logic;
    signal s_app_rd_data_end        : std_logic;

    ---------------------------------------------------------------------------
    -- Components
    ---------------------------------------------------------------------------
    COMPONENT ddr4_0
    PORT (
        c0_init_calib_complete      : OUT STD_LOGIC;
        c0_sys_clk_p                : IN STD_LOGIC;
        c0_sys_clk_n                : IN STD_LOGIC;
        sys_rst                     : IN STD_LOGIC ;
        c0_ddr4_adr                 : OUT STD_LOGIC_VECTOR(16 DOWNTO 0);
        c0_ddr4_ba                  : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        c0_ddr4_cke                 : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_cs_n                : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_dm_dbi_n            : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        c0_ddr4_dq                  : INOUT STD_LOGIC_VECTOR(15 DOWNTO 0);
        c0_ddr4_dqs_c               : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        c0_ddr4_dqs_t               : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        c0_ddr4_odt                 : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_bg                  : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_reset_n             : OUT STD_LOGIC;
        c0_ddr4_act_n               : OUT STD_LOGIC;
        c0_ddr4_ck_c                : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_ck_t                : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        c0_ddr4_ui_clk              : OUT STD_LOGIC;
        c0_ddr4_ui_clk_sync_rst     : OUT STD_LOGIC;
        c0_ddr4_app_en              : IN STD_LOGIC;
        c0_ddr4_app_hi_pri          : IN STD_LOGIC;
        c0_ddr4_app_wdf_end         : IN STD_LOGIC;
        c0_ddr4_app_wdf_wren        : IN STD_LOGIC;
        c0_ddr4_app_rd_data_end     : OUT STD_LOGIC;
        c0_ddr4_app_rd_data_valid   : OUT STD_LOGIC;
        c0_ddr4_app_rdy             : OUT STD_LOGIC;
        c0_ddr4_app_wdf_rdy         : OUT STD_LOGIC;
        c0_ddr4_app_addr            : IN STD_LOGIC_VECTOR(27 DOWNTO 0);
        c0_ddr4_app_cmd             : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
        c0_ddr4_app_wdf_data        : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
        c0_ddr4_app_wdf_mask        : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
        c0_ddr4_app_rd_data         : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
        addn_ui_clkout1             : OUT STD_LOGIC;
        dbg_bus                     : OUT STD_LOGIC_VECTOR(511 DOWNTO 0);
        dbg_clk                     : OUT STD_LOGIC
    );
    END COMPONENT;

    COMPONENT ddr4_frame_buffer
    GENERIC (
        APP_ADDR_WIDTH : integer := 28;
        APP_DATA_WIDTH : integer := 128;
        APP_MASK_WIDTH : integer := 16;
        BASE_ADDR      : std_logic_vector(27 downto 0) := x"0000000"
    );
    PORT (
        -- HDMI clock domain
        hdmi_clk        : in  std_logic;
        hdmi_resetn     : in  std_logic;

        -- AXI Stream Slave (from HDMI RX)
        S_AXIS_tdata    : in  std_logic_vector(47 downto 0);
        S_AXIS_tvalid   : in  std_logic;
        S_AXIS_tlast    : in  std_logic;
        S_AXIS_tuser    : in  std_logic;
        S_AXIS_tready   : out std_logic;

        -- AXI Stream Master (to HDMI TX)
        M_AXIS_tdata    : out std_logic_vector(47 downto 0);
        M_AXIS_tvalid   : out std_logic;
        M_AXIS_tlast    : out std_logic;
        M_AXIS_tuser    : out std_logic;
        M_AXIS_tready   : in  std_logic;

        -- Switches
        sw_save         : in  std_logic;
        sw_read         : in  std_logic;

        -- MIG clock domain
        mig_clk              : in  std_logic;
        mig_rst              : in  std_logic;
        init_calib_complete  : in  std_logic;

        -- MIG app interface
        app_addr             : out std_logic_vector(APP_ADDR_WIDTH-1 downto 0);
        app_cmd              : out std_logic_vector(2 downto 0);
        app_en               : out std_logic;
        app_wdf_data         : out std_logic_vector(APP_DATA_WIDTH-1 downto 0);
        app_wdf_end          : out std_logic;
        app_wdf_mask         : out std_logic_vector(APP_MASK_WIDTH-1 downto 0);
        app_wdf_wren         : out std_logic;
        app_rdy              : in  std_logic;
        app_wdf_rdy          : in  std_logic;
        app_rd_data          : in  std_logic_vector(APP_DATA_WIDTH-1 downto 0);
        app_rd_data_valid    : in  std_logic;
        app_rd_data_end      : in  std_logic;
        --Debug outputs (ILA probes)
        ila_ro_x_cnt         : out std_logic_vector(15 downto 0);
        ila_ro_y_cnt         : out std_logic_vector(15 downto 0)
    );
    END COMPONENT;

begin

    u_frame_buffer : ddr4_frame_buffer
        generic map (
            APP_ADDR_WIDTH => APP_ADDR_WIDTH,
            APP_DATA_WIDTH => APP_DATA_WIDTH,
            APP_MASK_WIDTH => APP_MASK_WIDTH,
            BASE_ADDR      => BASE_ADDR
        )
        port map (
            -- HDMI (direct)
            hdmi_clk      => hdmi_clk,
            hdmi_resetn   => hdmi_resetn,

            -- AXI Stream Slave (direct)
            S_AXIS_tdata  => S_AXIS_tdata,
            S_AXIS_tvalid => S_AXIS_tvalid,
            S_AXIS_tlast  => S_AXIS_tlast,
            S_AXIS_tuser  => S_AXIS_tuser,
            S_AXIS_tready => S_AXIS_tready,

            -- AXI Stream Master (direct)
            M_AXIS_tdata  => M_AXIS_tdata,
            M_AXIS_tvalid => M_AXIS_tvalid,
            M_AXIS_tlast  => M_AXIS_tlast,
            M_AXIS_tuser  => M_AXIS_tuser,
            M_AXIS_tready => M_AXIS_tready,

            -- Switches (direct)
            sw_save       => sw_save,
            sw_read       => sw_read,

            -- MIG side (intentionally left open / placeholder)
            mig_clk             => s_mig_clk,
            mig_rst             => s_mig_rst,
            init_calib_complete => s_init_calib_complente,

            app_addr            => s_app_addr,
            app_cmd             => s_app_cmd,
            app_en              => s_app_en,
            app_wdf_data        => s_app_wdf_data,
            app_wdf_end         => s_app_wdf_end,
            app_wdf_mask        => s_app_wdf_mask,
            app_wdf_wren        => s_app_wdf_wren,
            app_rdy             => s_app_rdy,
            app_wdf_rdy         => s_app_wdf_rdy,
            app_rd_data         => s_app_rd_data,
            app_rd_data_valid   => s_app_rd_data_valid,
            app_rd_data_end     => s_app_rd_data_end,
            ila_ro_x_cnt        => ila_ro_x_cnt,
            ila_ro_y_cnt        => ila_ro_y_cnt
        );

    u_ddr4 : ddr4_0
    PORT MAP (
        c0_init_calib_complete      => s_init_calib_complente,
        c0_sys_clk_p                => c0_sys_clk_p,
        c0_sys_clk_n                => c0_sys_clk_n,
        sys_rst                     => sys_rst,
        c0_ddr4_adr                 => c0_ddr4_adr,
        c0_ddr4_ba                  => c0_ddr4_ba,
        c0_ddr4_cke                 => c0_ddr4_cke,
        c0_ddr4_cs_n                => c0_ddr4_cs_n,
        c0_ddr4_dm_dbi_n            => c0_ddr4_dm_dbi_n,
        c0_ddr4_dq                  => c0_ddr4_dq,
        c0_ddr4_dqs_c               => c0_ddr4_dqs_c,
        c0_ddr4_dqs_t               => c0_ddr4_dqs_t,
        c0_ddr4_odt                 => c0_ddr4_odt,
        c0_ddr4_bg                  => c0_ddr4_bg,
        c0_ddr4_reset_n             => c0_ddr4_reset_n,
        c0_ddr4_act_n               => c0_ddr4_act_n,
        c0_ddr4_ck_c                => c0_ddr4_ck_c,
        c0_ddr4_ck_t                => c0_ddr4_ck_t,
        c0_ddr4_ui_clk              => s_mig_clk,
        c0_ddr4_ui_clk_sync_rst     => s_mig_rst,
        c0_ddr4_app_addr            => s_app_addr,
        c0_ddr4_app_cmd             => s_app_cmd,
        c0_ddr4_app_en              => s_app_en,
        c0_ddr4_app_wdf_data        => s_app_wdf_data,
        c0_ddr4_app_wdf_end         => s_app_wdf_end,
        c0_ddr4_app_wdf_mask        => s_app_wdf_mask,
        c0_ddr4_app_wdf_wren        => s_app_wdf_wren,
        c0_ddr4_app_rdy             => s_app_rdy,
        c0_ddr4_app_wdf_rdy         => s_app_wdf_rdy,
        c0_ddr4_app_rd_data         => s_app_rd_data,
        c0_ddr4_app_rd_data_valid   => s_app_rd_data_valid,
        c0_ddr4_app_rd_data_end     => s_app_rd_data_end,
        c0_ddr4_app_hi_pri          => '0',
        addn_ui_clkout1             => open,
        dbg_bus                     => open,
        dbg_clk                     => open
        );
end architecture ;