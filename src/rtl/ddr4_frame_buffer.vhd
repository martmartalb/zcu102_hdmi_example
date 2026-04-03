--------------------------------------------------------------------------------
-- Module:      ddr4_frame_buffer
-- Description: DDR4 frame buffer with AXI Stream video interface.
--              Captures a full 1920x1080 frame from HDMI RX into DDR4 memory
--              and reads it back as an AXI Stream for HDMI TX.
--
-- Operation:
--   No switch:     Passthrough mode — S_AXIS is forwarded directly to M_AXIS.
--   sw_save = '1': Captures one frame (waits for SOF), writes to DDR starting
--                  at BASE_ADDR. Passthrough continues so the live image is
--                  still visible on HDMI TX. After completion, waits for
--                  sw_save = '0' before allowing another capture.
--   sw_read = '1': Reads the stored frame from DDR and outputs it as an AXI
--                  Stream on M_AXIS. Loops while sw_read remains high.
--                  S_AXIS input is discarded (tready = '1').
--
-- Clock Domain Crossing:
--   Two xpm_fifo_async FIFOs with asymmetric widths handle CDC between
--   the HDMI clock domain and the MIG ui_clk domain.
--
-- Data Packing (2:1):
--   Two 48-bit AXI words are packed into one 128-bit DDR word:
--     DDR[127:96] = 0 (padding)
--     DDR[95:48]  = AXI word 1
--     DDR[47:0]   = AXI word 0
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

library xpm;
use xpm.vcomponents.all;

entity ddr4_frame_buffer is
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
        app_rd_data_end      : in  std_logic
    );
end entity ddr4_frame_buffer;

architecture rtl of ddr4_frame_buffer is

    -- Attributes for HDMI AXI
    ATTRIBUTE X_INTERFACE_INFO : STRING;
    ATTRIBUTE X_INTERFACE_INFO of hdmi_clk: SIGNAL is "xilinx.com:signal:clock:1.0 hdmi_clk CLK";

    ATTRIBUTE X_INTERFACE_PARAMETER : STRING;
	attribute X_INTERFACE_PARAMETER of hdmi_clk : signal is "ASSOCIATED_BUSIF S_AXIS:M_AXIS, ASSOCIATED_RESET hdmi_resetn, FREQ_HZ 299970032";


    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant C_PIXELS_PER_CLK      : integer := 2;
    constant C_H_PIXELS            : integer := 1920;
    constant C_V_LINES             : integer := 1080;
    constant C_CLKS_PER_LINE       : integer := C_H_PIXELS / C_PIXELS_PER_CLK; -- 960
    constant C_AXI_XFERS_PER_FRAME : integer := C_CLKS_PER_LINE * C_V_LINES;   -- 1,036,800
    constant C_DDR_OPS_PER_FRAME   : integer := C_AXI_XFERS_PER_FRAME / 2;     -- 518,400
    constant C_ADDR_STEP           : unsigned(APP_ADDR_WIDTH-1 downto 0) := to_unsigned(16, APP_ADDR_WIDTH);

    constant CMD_WRITE : std_logic_vector(2 downto 0) := "000";
    constant CMD_READ  : std_logic_vector(2 downto 0) := "001";

    ---------------------------------------------------------------------------
    -- FSM state types
    ---------------------------------------------------------------------------
    type cap_state_t is (CAP_IDLE, CAP_WAIT_SOF, CAP_CAPTURING, CAP_DONE);
    type mig_state_t is (M_IDLE, M_WR_PRESENT, M_WR_ADVANCE, M_WR_DONE,
                         M_RD_CMD, M_RD_DRAIN, M_RD_FRAME_DONE);
    type ro_state_t  is (RO_IDLE, RO_DRAIN, RO_ACTIVE);

    ---------------------------------------------------------------------------
    -- Switch debounce (hdmi_clk domain, ~3.3 ms at 300 MHz)
    ---------------------------------------------------------------------------
    constant C_DEBOUNCE_MAX : unsigned(19 downto 0) := to_unsigned(999999, 20);
    signal sw_save_deb      : std_logic := '0';
    signal sw_read_deb      : std_logic := '0';
    signal sw_save_deb_cnt  : unsigned(19 downto 0) := (others => '0');
    signal sw_read_deb_cnt  : unsigned(19 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Switch synchronizers (2-FF) — to MIG domain
    ---------------------------------------------------------------------------
    signal sw_save_mig_meta : std_logic := '0';
    signal sw_save_mig_sync : std_logic := '0';
    signal sw_save_mig_prev : std_logic := '0';
    signal sw_read_mig_meta : std_logic := '0';
    signal sw_read_mig_sync : std_logic := '0';

    ---------------------------------------------------------------------------
    -- Switch synchronizer — sw_read to HDMI domain
    ---------------------------------------------------------------------------
    signal sw_read_hdmi_meta : std_logic := '0';
    signal sw_read_hdmi_sync : std_logic := '0';

    ---------------------------------------------------------------------------
    -- capture_en synchronizer — MIG to HDMI domain
    ---------------------------------------------------------------------------
    signal capture_en_mig       : std_logic := '0';
    signal capture_en_hdmi_meta : std_logic := '0';
    signal capture_en_hdmi_sync : std_logic := '0';
    signal capture_en_hdmi_prev : std_logic := '0';

    ---------------------------------------------------------------------------
    -- rd_fifo_empty synchronizer — HDMI to MIG domain
    ---------------------------------------------------------------------------
    signal rd_fifo_empty_mig_meta : std_logic := '1';
    signal rd_fifo_empty_mig_sync : std_logic := '1';

    ---------------------------------------------------------------------------
    -- ASYNC_REG attributes
    ---------------------------------------------------------------------------
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sw_save_mig_meta    : signal is "TRUE";
    attribute ASYNC_REG of sw_save_mig_sync    : signal is "TRUE";
    attribute ASYNC_REG of sw_read_mig_meta    : signal is "TRUE";
    attribute ASYNC_REG of sw_read_mig_sync    : signal is "TRUE";
    attribute ASYNC_REG of sw_read_hdmi_meta   : signal is "TRUE";
    attribute ASYNC_REG of sw_read_hdmi_sync   : signal is "TRUE";
    attribute ASYNC_REG of capture_en_hdmi_meta : signal is "TRUE";
    attribute ASYNC_REG of capture_en_hdmi_sync : signal is "TRUE";
    attribute ASYNC_REG of rd_fifo_empty_mig_meta : signal is "TRUE";
    attribute ASYNC_REG of rd_fifo_empty_mig_sync : signal is "TRUE";

    ---------------------------------------------------------------------------
    -- Write FIFO signals (HDMI → MIG), 48-bit write / 96-bit read
    ---------------------------------------------------------------------------
    signal wr_fifo_din         : std_logic_vector(47 downto 0);
    signal wr_fifo_wr_en       : std_logic;
    signal wr_fifo_full        : std_logic;
    signal wr_fifo_wr_rst_busy : std_logic;
    signal wr_fifo_dout        : std_logic_vector(95 downto 0);
    signal wr_fifo_rd_en       : std_logic;
    signal wr_fifo_empty       : std_logic;
    signal wr_fifo_rd_rst_busy : std_logic;

    ---------------------------------------------------------------------------
    -- Read FIFO signals (MIG → HDMI), 96-bit write / 48-bit read
    ---------------------------------------------------------------------------
    signal rd_fifo_din         : std_logic_vector(95 downto 0);
    signal rd_fifo_wr_en       : std_logic;
    signal rd_fifo_full        : std_logic;
    signal rd_fifo_prog_full   : std_logic;
    signal rd_fifo_wr_rst_busy : std_logic;
    signal rd_fifo_dout        : std_logic_vector(47 downto 0);
    signal rd_fifo_rd_en       : std_logic;
    signal rd_fifo_empty       : std_logic;
    signal rd_fifo_rd_rst_busy : std_logic;

    ---------------------------------------------------------------------------
    -- HDMI Capture FSM signals
    ---------------------------------------------------------------------------
    signal cap_state   : cap_state_t := CAP_IDLE;
    signal cap_count   : unsigned(20 downto 0) := (others => '0'); -- max 1,036,800
    signal cap_tready  : std_logic;
    signal cap_writing : std_logic;

    ---------------------------------------------------------------------------
    -- MIG Main FSM signals
    ---------------------------------------------------------------------------
    signal mig_state      : mig_state_t := M_IDLE;
    signal wr_addr        : unsigned(APP_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal wr_count       : unsigned(19 downto 0) := (others => '0'); -- max 518,400
    signal rd_addr        : unsigned(APP_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal rd_cmd_count   : unsigned(19 downto 0) := (others => '0');
    signal rd_data_count  : unsigned(19 downto 0) := (others => '0');

    -- Registered MIG outputs
    signal app_addr_r     : std_logic_vector(APP_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal app_cmd_r      : std_logic_vector(2 downto 0) := (others => '0');
    signal app_en_r       : std_logic := '0';
    signal app_wdf_data_r : std_logic_vector(APP_DATA_WIDTH-1 downto 0) := (others => '0');
    signal app_wdf_wren_r : std_logic := '0';
    signal app_wdf_end_r  : std_logic := '0';

    ---------------------------------------------------------------------------
    -- HDMI Read Output FSM signals
    ---------------------------------------------------------------------------
    signal ro_state   : ro_state_t := RO_IDLE;
    signal ro_x_cnt   : unsigned(9 downto 0)  := (others => '0'); -- 0..959
    signal ro_y_cnt   : unsigned(10 downto 0) := (others => '0'); -- 0..1079
    signal ro_sof     : std_logic := '1';
    signal ro_tvalid  : std_logic;
    signal ro_tlast   : std_logic;
    signal ro_drain_en : std_logic;

    ---------------------------------------------------------------------------
    -- Internal tready for passthrough muxing
    ---------------------------------------------------------------------------
    signal s_axis_tready_int : std_logic;

    ---------------------------------------------------------------------------
    -- Internal reset for write FIFO (active-high)
    ---------------------------------------------------------------------------
    signal wr_fifo_rst : std_logic;

begin

    wr_fifo_rst <= not hdmi_resetn;

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
                if sw_save = sw_save_deb then
                    sw_save_deb_cnt <= (others => '0');
                elsif sw_save_deb_cnt = C_DEBOUNCE_MAX then
                    sw_save_deb     <= sw_save;
                    sw_save_deb_cnt <= (others => '0');
                else
                    sw_save_deb_cnt <= sw_save_deb_cnt + 1;
                end if;
                -- sw_read debounce
                if sw_read = sw_read_deb then
                    sw_read_deb_cnt <= (others => '0');
                elsif sw_read_deb_cnt = C_DEBOUNCE_MAX then
                    sw_read_deb     <= sw_read;
                    sw_read_deb_cnt <= (others => '0');
                else
                    sw_read_deb_cnt <= sw_read_deb_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Switch synchronizers to MIG domain
    ---------------------------------------------------------------------------
    p_sync_sw_mig : process(mig_clk)
    begin
        if rising_edge(mig_clk) then
            if mig_rst = '1' then
                sw_save_mig_meta <= '0';
                sw_save_mig_sync <= '0';
                sw_save_mig_prev <= '0';
                sw_read_mig_meta <= '0';
                sw_read_mig_sync <= '0';
            else
                sw_save_mig_meta <= sw_save_deb;
                sw_save_mig_sync <= sw_save_mig_meta;
                sw_save_mig_prev <= sw_save_mig_sync;
                sw_read_mig_meta <= sw_read_deb;
                sw_read_mig_sync <= sw_read_mig_meta;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Switch synchronizer: sw_read to HDMI domain
    ---------------------------------------------------------------------------
    p_sync_sw_hdmi : process(hdmi_clk)
    begin
        if rising_edge(hdmi_clk) then
            if hdmi_resetn = '0' then
                sw_read_hdmi_meta <= '0';
                sw_read_hdmi_sync <= '0';
            else
                sw_read_hdmi_meta <= sw_read_deb;
                sw_read_hdmi_sync <= sw_read_hdmi_meta;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- rd_fifo_empty synchronizer: HDMI → MIG domain
    ---------------------------------------------------------------------------
    p_sync_rd_empty : process(mig_clk)
    begin
        if rising_edge(mig_clk) then
            if mig_rst = '1' then
                rd_fifo_empty_mig_meta <= '1';
                rd_fifo_empty_mig_sync <= '1';
            else
                rd_fifo_empty_mig_meta <= rd_fifo_empty;
                rd_fifo_empty_mig_sync <= rd_fifo_empty_mig_meta;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- capture_en synchronizer: MIG → HDMI domain
    ---------------------------------------------------------------------------
    p_sync_cap_en : process(hdmi_clk)
    begin
        if rising_edge(hdmi_clk) then
            if hdmi_resetn = '0' then
                capture_en_hdmi_meta <= '0';
                capture_en_hdmi_sync <= '0';
                capture_en_hdmi_prev <= '0';
            else
                capture_en_hdmi_meta <= capture_en_mig;
                capture_en_hdmi_sync <= capture_en_hdmi_meta;
                capture_en_hdmi_prev <= capture_en_hdmi_sync;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Write FIFO: xpm_fifo_async (48-bit write, 96-bit read, FWFT)
    ---------------------------------------------------------------------------
    u_wr_fifo : xpm_fifo_async
    generic map (
        FIFO_MEMORY_TYPE    => "block",
        FIFO_WRITE_DEPTH    => 1024,
        WRITE_DATA_WIDTH    => 48,
        READ_DATA_WIDTH     => 96,
        READ_MODE           => "fwft",
        FIFO_READ_LATENCY   => 0,
        CDC_SYNC_STAGES     => 2,
        FULL_RESET_VALUE    => 0,
        RELATED_CLOCKS      => 0,
        SIM_ASSERT_CHK      => 0,
        ECC_MODE            => "no_ecc",
        WAKEUP_TIME         => 0,
        PROG_FULL_THRESH    => 1020,
        PROG_EMPTY_THRESH   => 5,
        USE_ADV_FEATURES    => "0000",
        CASCADE_HEIGHT      => 0,
        RD_DATA_COUNT_WIDTH => 1,
        WR_DATA_COUNT_WIDTH => 1,
        DOUT_RESET_VALUE    => "0"
    )
    port map (
        rst           => wr_fifo_rst,
        wr_clk        => hdmi_clk,
        wr_en         => wr_fifo_wr_en,
        din           => wr_fifo_din,
        full          => wr_fifo_full,
        wr_rst_busy   => wr_fifo_wr_rst_busy,
        rd_clk        => mig_clk,
        rd_en         => wr_fifo_rd_en,
        dout          => wr_fifo_dout,
        empty         => wr_fifo_empty,
        rd_rst_busy   => wr_fifo_rd_rst_busy,
        -- Unused outputs
        overflow      => open,
        wr_ack        => open,
        almost_full   => open,
        prog_full     => open,
        wr_data_count => open,
        underflow     => open,
        data_valid    => open,
        almost_empty  => open,
        prog_empty    => open,
        rd_data_count => open,
        sbiterr       => open,
        dbiterr       => open,
        -- Unused inputs
        sleep         => '0',
        injectsbiterr => '0',
        injectdbiterr => '0'
    );

    ---------------------------------------------------------------------------
    -- Read FIFO: xpm_fifo_async (96-bit write, 48-bit read, FWFT)
    ---------------------------------------------------------------------------
    u_rd_fifo : xpm_fifo_async
    generic map (
        FIFO_MEMORY_TYPE    => "block",
        FIFO_WRITE_DEPTH    => 512,
        WRITE_DATA_WIDTH    => 96,
        READ_DATA_WIDTH     => 48,
        READ_MODE           => "fwft",
        FIFO_READ_LATENCY   => 0,
        CDC_SYNC_STAGES     => 2,
        FULL_RESET_VALUE    => 0,
        RELATED_CLOCKS      => 0,
        SIM_ASSERT_CHK      => 0,
        ECC_MODE            => "no_ecc",
        WAKEUP_TIME         => 0,
        PROG_FULL_THRESH    => 480,
        PROG_EMPTY_THRESH   => 5,
        USE_ADV_FEATURES    => "0707",
        CASCADE_HEIGHT      => 0,
        RD_DATA_COUNT_WIDTH => 1,
        WR_DATA_COUNT_WIDTH => 1,
        DOUT_RESET_VALUE    => "0"
    )
    port map (
        rst           => mig_rst,
        wr_clk        => mig_clk,
        wr_en         => rd_fifo_wr_en,
        din           => rd_fifo_din,
        full          => rd_fifo_full,
        prog_full     => rd_fifo_prog_full,
        wr_rst_busy   => rd_fifo_wr_rst_busy,
        rd_clk        => hdmi_clk,
        rd_en         => rd_fifo_rd_en,
        dout          => rd_fifo_dout,
        empty         => rd_fifo_empty,
        rd_rst_busy   => rd_fifo_rd_rst_busy,
        -- Unused outputs
        overflow      => open,
        wr_ack        => open,
        almost_full   => open,
        wr_data_count => open,
        underflow     => open,
        data_valid    => open,
        almost_empty  => open,
        prog_empty    => open,
        rd_data_count => open,
        sbiterr       => open,
        dbiterr       => open,
        -- Unused inputs
        sleep         => '0',
        injectsbiterr => '0',
        injectdbiterr => '0'
    );

    ---------------------------------------------------------------------------
    -- HDMI Capture FSM (hdmi_clk domain)
    ---------------------------------------------------------------------------

    -- S_AXIS_tready: depends on mode
    --   Passthrough (no switch): limited by M_AXIS_tready
    --   Capture (sw_save):       limited by both FIFO and M_AXIS_tready
    --   Read (sw_read):          always accept (discard S_AXIS)
    cap_writing <= '1' when cap_state = CAP_CAPTURING else '0';
    cap_tready  <= '0' when (cap_writing = '1' and
                             (wr_fifo_full = '1' or wr_fifo_wr_rst_busy = '1'))
                   else '1';

    s_axis_tready_int <= '1' when sw_read_hdmi_sync = '1'
                         else (cap_tready and M_AXIS_tready) when cap_writing = '1'
                         else M_AXIS_tready;
    S_AXIS_tready <= s_axis_tready_int;

    -- Write FIFO inputs
    wr_fifo_din   <= S_AXIS_tdata;
    wr_fifo_wr_en <= '1' when (cap_state = CAP_CAPTURING and
                               S_AXIS_tvalid = '1' and s_axis_tready_int = '1' and
                               wr_fifo_wr_rst_busy = '0')
                     else '1' when (cap_state = CAP_WAIT_SOF and
                                    S_AXIS_tvalid = '1' and S_AXIS_tuser = '1' and
                                    s_axis_tready_int = '1' and
                                    wr_fifo_wr_rst_busy = '0')
                     else '0';

    p_capture_fsm : process(hdmi_clk)
    begin
        if rising_edge(hdmi_clk) then
            if hdmi_resetn = '0' then
                cap_state <= CAP_IDLE;
                cap_count <= (others => '0');
            else
                case cap_state is

                    when CAP_IDLE =>
                        cap_count <= (others => '0');
                        -- Detect rising edge of capture_en
                        if capture_en_hdmi_sync = '1' and capture_en_hdmi_prev = '0' then
                            cap_state <= CAP_WAIT_SOF;
                        end if;

                    when CAP_WAIT_SOF =>
                        -- Wait for start-of-frame
                        if S_AXIS_tvalid = '1' and S_AXIS_tuser = '1' and s_axis_tready_int = '1' then
                            -- First pixel written to FIFO via concurrent logic
                            cap_count <= to_unsigned(1, cap_count'length);
                            cap_state <= CAP_CAPTURING;
                        end if;

                    when CAP_CAPTURING =>
                        -- Count accepted transfers
                        if S_AXIS_tvalid = '1' and s_axis_tready_int = '1' then
                            if cap_count = to_unsigned(C_AXI_XFERS_PER_FRAME - 1, cap_count'length) then
                                cap_state <= CAP_DONE;
                            else
                                cap_count <= cap_count + 1;
                            end if;
                        end if;

                    when CAP_DONE =>
                        -- Wait for capture_en to deassert
                        if capture_en_hdmi_sync = '0' then
                            cap_state <= CAP_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- MIG Main FSM (mig_clk domain)
    ---------------------------------------------------------------------------

    -- Drive MIG output ports from registered signals
    app_addr     <= app_addr_r;
    app_cmd      <= app_cmd_r;
    app_en       <= app_en_r;
    app_wdf_data <= app_wdf_data_r;
    app_wdf_wren <= app_wdf_wren_r;
    app_wdf_end  <= app_wdf_end_r;
    app_wdf_mask <= (others => '0');

    p_mig_fsm : process(mig_clk)
    begin
        if rising_edge(mig_clk) then
            if mig_rst = '1' then
                mig_state      <= M_IDLE;
                capture_en_mig <= '0';
                wr_addr        <= (others => '0');
                wr_count       <= (others => '0');
                rd_addr        <= (others => '0');
                rd_cmd_count   <= (others => '0');
                rd_data_count  <= (others => '0');
                app_addr_r     <= (others => '0');
                app_cmd_r      <= (others => '0');
                app_en_r       <= '0';
                app_wdf_data_r <= (others => '0');
                app_wdf_wren_r <= '0';
                app_wdf_end_r  <= '0';
                wr_fifo_rd_en  <= '0';
                rd_fifo_wr_en  <= '0';
                rd_fifo_din    <= (others => '0');
            else
                -- Defaults: deassert single-cycle pulses
                wr_fifo_rd_en <= '0';
                rd_fifo_wr_en <= '0';

                ---------------------------------------------------------------
                -- Read data handler (concurrent with FSM, active during reads)
                -- Runs in M_RD_CMD and M_RD_DRAIN states. Pushes returning
                -- DDR read data into the read FIFO.
                ---------------------------------------------------------------
                if (mig_state = M_RD_CMD or mig_state = M_RD_DRAIN) and
                   app_rd_data_valid = '1' and rd_fifo_wr_rst_busy = '0' and
                   rd_data_count < to_unsigned(C_DDR_OPS_PER_FRAME, rd_data_count'length) then
                    rd_fifo_wr_en <= '1';
                    rd_fifo_din   <= app_rd_data(95 downto 0);
                    rd_data_count <= rd_data_count + 1;
                end if;

                ---------------------------------------------------------------
                -- Main FSM
                ---------------------------------------------------------------
                case mig_state is

                    -------------------------------------------------------
                    when M_IDLE =>
                        app_en_r       <= '0';
                        app_wdf_wren_r <= '0';
                        app_wdf_end_r  <= '0';

                        if init_calib_complete = '1' then
                            -- Write priority: check sw_save rising edge first
                            if sw_save_mig_sync = '1' and sw_save_mig_prev = '0' then
                                capture_en_mig <= '1';
                                wr_addr        <= unsigned(BASE_ADDR);
                                wr_count       <= (others => '0');
                                mig_state      <= M_WR_PRESENT;
                            elsif sw_read_mig_sync = '1' then
                                rd_addr       <= unsigned(BASE_ADDR);
                                rd_cmd_count  <= (others => '0');
                                rd_data_count <= (others => '0');
                                mig_state     <= M_RD_CMD;
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- Write: present DDR write from FIFO dout, hold until
                    -- accepted. FWFT: dout valid when empty='0'.
                    -- After acceptance, need gap cycle (M_WR_ADVANCE)
                    -- for FIFO to present next word on dout.
                    -------------------------------------------------------
                    when M_WR_PRESENT =>
                        if app_en_r = '1' then
                            -- Command in flight: wait for acceptance
                            if app_rdy = '1' and app_wdf_rdy = '1' then
                                -- DDR accepted: advance FIFO and counters
                                wr_fifo_rd_en  <= '1';
                                wr_addr        <= wr_addr + C_ADDR_STEP;
                                app_en_r       <= '0';
                                app_wdf_wren_r <= '0';
                                app_wdf_end_r  <= '0';

                                if wr_count = to_unsigned(C_DDR_OPS_PER_FRAME - 1, wr_count'length) then
                                    capture_en_mig <= '0';
                                    mig_state      <= M_WR_DONE;
                                else
                                    wr_count  <= wr_count + 1;
                                    mig_state <= M_WR_ADVANCE;
                                end if;
                            end if;
                            -- If not accepted: hold (signals remain asserted)
                        else
                            -- No command in flight: present new one if FIFO has data
                            if wr_fifo_empty = '0' and wr_fifo_rd_rst_busy = '0' then
                                app_cmd_r      <= CMD_WRITE;
                                app_addr_r     <= std_logic_vector(wr_addr);
                                app_en_r       <= '1';
                                app_wdf_data_r <= x"00000000" & wr_fifo_dout;
                                app_wdf_wren_r <= '1';
                                app_wdf_end_r  <= '1';
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- Gap cycle: FIFO processes rd_en and updates dout.
                    -- After this cycle, new data is available on dout.
                    -------------------------------------------------------
                    when M_WR_ADVANCE =>
                        mig_state <= M_WR_PRESENT;

                    -------------------------------------------------------
                    when M_WR_DONE =>
                        app_en_r       <= '0';
                        app_wdf_wren_r <= '0';
                        app_wdf_end_r  <= '0';
                        -- Wait for sw_save to go low before returning to idle
                        if sw_save_mig_sync = '0' then
                            mig_state <= M_IDLE;
                        end if;

                    -------------------------------------------------------
                    -- Read: issue DDR read commands, pipelined.
                    -- Hold app_en until accepted, then update address for
                    -- next command. Throttled by prog_full on read FIFO.
                    -------------------------------------------------------
                    when M_RD_CMD =>
                        if app_en_r = '1' then
                            -- Command in flight: wait for acceptance
                            if app_rdy = '1' then
                                rd_cmd_count <= rd_cmd_count + 1;
                                rd_addr      <= rd_addr + C_ADDR_STEP;

                                if rd_cmd_count = to_unsigned(C_DDR_OPS_PER_FRAME - 1, rd_cmd_count'length) then
                                    -- All commands issued
                                    app_en_r  <= '0';
                                    mig_state <= M_RD_DRAIN;
                                elsif rd_fifo_prog_full = '1' then
                                    -- FIFO almost full: pause issuing
                                    app_en_r <= '0';
                                else
                                    -- Pipeline: update address for next command
                                    app_addr_r <= std_logic_vector(rd_addr + C_ADDR_STEP);
                                    -- app_en stays '1'
                                end if;
                            end if;
                            -- If not accepted: hold (app_en and addr stay)
                        else
                            -- No command in flight
                            if rd_cmd_count < to_unsigned(C_DDR_OPS_PER_FRAME, rd_cmd_count'length) and
                               rd_fifo_prog_full = '0' and rd_fifo_wr_rst_busy = '0' then
                                app_cmd_r  <= CMD_READ;
                                app_addr_r <= std_logic_vector(rd_addr);
                                app_en_r   <= '1';
                            elsif rd_cmd_count = to_unsigned(C_DDR_OPS_PER_FRAME, rd_cmd_count'length) then
                                mig_state <= M_RD_DRAIN;
                            end if;
                        end if;

                    -------------------------------------------------------
                    when M_RD_DRAIN =>
                        app_en_r <= '0';
                        -- Wait for all read data to arrive
                        if rd_data_count = to_unsigned(C_DDR_OPS_PER_FRAME, rd_data_count'length) then
                            mig_state <= M_RD_FRAME_DONE;
                        end if;

                    -------------------------------------------------------
                    when M_RD_FRAME_DONE =>
                        if sw_read_mig_sync = '0' then
                            mig_state <= M_IDLE;
                        elsif rd_fifo_empty_mig_sync = '1' then
                            -- HDMI side consumed all data; safe to loop
                            rd_addr       <= unsigned(BASE_ADDR);
                            rd_cmd_count  <= (others => '0');
                            rd_data_count <= (others => '0');
                            mig_state     <= M_RD_CMD;
                        end if;
                        -- else: wait for FIFO to drain

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- HDMI Read Output FSM (hdmi_clk domain)
    ---------------------------------------------------------------------------

    -- AXI Stream master outputs
    ro_tvalid <= '1' when (ro_state = RO_ACTIVE and
                           rd_fifo_empty = '0' and
                           rd_fifo_rd_rst_busy = '0')
                 else '0';

    ro_tlast  <= '1' when (ro_x_cnt = to_unsigned(C_CLKS_PER_LINE - 1, ro_x_cnt'length))
                 else '0';

    -- M_AXIS mux: read playback (sw_read) vs passthrough (default)
    M_AXIS_tdata  <= rd_fifo_dout              when sw_read_hdmi_sync = '1' else S_AXIS_tdata;
    M_AXIS_tvalid <= ro_tvalid                 when sw_read_hdmi_sync = '1' else S_AXIS_tvalid;
    M_AXIS_tlast  <= ro_tlast and ro_tvalid    when sw_read_hdmi_sync = '1' else S_AXIS_tlast;
    M_AXIS_tuser  <= ro_sof   and ro_tvalid    when sw_read_hdmi_sync = '1' else S_AXIS_tuser;

    -- Drain enable: flush stale FIFO data before playback
    ro_drain_en <= '1' when (ro_state = RO_DRAIN and rd_fifo_empty = '0' and rd_fifo_rd_rst_busy = '0')
                   else '0';

    -- Read FIFO pop: normal handshake OR drain flush
    rd_fifo_rd_en <= (ro_tvalid and M_AXIS_tready) or ro_drain_en;

    p_read_output_fsm : process(hdmi_clk)
    begin
        if rising_edge(hdmi_clk) then
            if hdmi_resetn = '0' then
                ro_state <= RO_IDLE;
                ro_x_cnt <= (others => '0');
                ro_y_cnt <= (others => '0');
                ro_sof   <= '1';
            else
                case ro_state is

                    when RO_IDLE =>
                        ro_x_cnt <= (others => '0');
                        ro_y_cnt <= (others => '0');
                        ro_sof   <= '1';
                        if sw_read_hdmi_sync = '1' then
                            ro_state <= RO_DRAIN;
                        end if;

                    when RO_DRAIN =>
                        -- Discard stale FIFO data before starting playback
                        if sw_read_hdmi_sync = '0' then
                            ro_state <= RO_IDLE;
                        elsif rd_fifo_empty = '1' and rd_fifo_rd_rst_busy = '0' then
                            ro_state <= RO_ACTIVE;
                        end if;

                    when RO_ACTIVE =>
                        -- Abort if switch goes low
                        if sw_read_hdmi_sync = '0' then
                            ro_state <= RO_IDLE;
                        -- Advance on handshake
                        elsif ro_tvalid = '1' and M_AXIS_tready = '1' then
                            -- Clear SOF after first transfer
                            ro_sof <= '0';

                            if ro_x_cnt = to_unsigned(C_CLKS_PER_LINE - 1, ro_x_cnt'length) then
                                -- End of line
                                ro_x_cnt <= (others => '0');
                                if ro_y_cnt = to_unsigned(C_V_LINES - 1, ro_y_cnt'length) then
                                    -- End of frame: reset for next frame
                                    ro_y_cnt <= (others => '0');
                                    ro_sof   <= '1';
                                    -- Stay in RO_ACTIVE to loop
                                else
                                    ro_y_cnt <= ro_y_cnt + 1;
                                end if;
                            else
                                ro_x_cnt <= ro_x_cnt + 1;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
