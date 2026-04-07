`timescale 1ns / 1ps

module ddr4_frame_buffer_tb;

    // ---------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------
    localparam APP_ADDR_WIDTH = 28;
    localparam APP_DATA_WIDTH = 128;
    localparam APP_MASK_WIDTH = 16;

    // ---------------------------------------------------------------
    // Clocks — asynchronous, both ~300 MHz
    // ---------------------------------------------------------------
    logic hdmi_clk = 0;
    logic mig_clk  = 0;

    always #5 hdmi_clk = ~hdmi_clk;  // ~300 MHz
    always #5.1 mig_clk  = ~mig_clk;   // ~300 MHz (slightly different)

    // ---------------------------------------------------------------
    // Resets
    // ---------------------------------------------------------------
    logic hdmi_resetn = 0;
    logic mig_rst     = 1;

    // ---------------------------------------------------------------
    // Switches
    // ---------------------------------------------------------------
    logic sw_save = 0;
    logic sw_read = 0;

    // ---------------------------------------------------------------
    // AXI Stream: bram_image_streamer → ddr4_frame_buffer (S_AXIS)
    // ---------------------------------------------------------------
    logic [47:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tlast;
    logic        s_axis_tuser;
    logic        s_axis_tready;

    // ---------------------------------------------------------------
    // AXI Stream: ddr4_frame_buffer → TX sink (M_AXIS)
    // ---------------------------------------------------------------
    logic [47:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tlast;
    logic        m_axis_tuser;
    logic        m_axis_tready;

    // ---------------------------------------------------------------
    // MIG app interface
    // ---------------------------------------------------------------
    logic [APP_ADDR_WIDTH-1:0] app_addr;
    logic [2:0]                app_cmd;
    logic                      app_en;
    logic [APP_DATA_WIDTH-1:0] app_wdf_data;
    logic                      app_wdf_end;
    logic [APP_MASK_WIDTH-1:0] app_wdf_mask;
    logic                      app_wdf_wren;
    logic                      app_rdy;
    logic                      app_wdf_rdy;
    logic [APP_DATA_WIDTH-1:0] app_rd_data;
    logic                      app_rd_data_valid;
    logic                      app_rd_data_end;
    logic                      init_calib_complete;

    // ---------------------------------------------------------------
    // DUT: bram_image_streamer (AXI Stream source)
    // ---------------------------------------------------------------
    bram_image_streamer #(
        .MEM_INIT_FILE ("src/data/image.mem")
    ) u_streamer (
        .aclk             (hdmi_clk),
        .aresetn          (hdmi_resetn),
        .VIDEO_OUT_tdata  (s_axis_tdata),
        .VIDEO_OUT_tvalid (s_axis_tvalid),
        .VIDEO_OUT_tlast  (s_axis_tlast),
        .VIDEO_OUT_tuser  (s_axis_tuser),
        .VIDEO_OUT_tready (s_axis_tready)
    );

    // ---------------------------------------------------------------
    // MIG model
    // ---------------------------------------------------------------
    mig_model #(
        .APP_ADDR_WIDTH (APP_ADDR_WIDTH),
        .APP_DATA_WIDTH (APP_DATA_WIDTH),
        .APP_MASK_WIDTH (APP_MASK_WIDTH),
        .MEM_INIT_FILE  ("src/data/image.mem"),
        .MEM_INIT_DEPTH (131072),
        .MEM_DEPTH      (1_036_800),
        .RD_LATENCY     (8)
    ) u_mig (
        .clk                (mig_clk),
        .rst                (mig_rst),
        .init_calib_complete(init_calib_complete),
        .app_addr           (app_addr),
        .app_cmd            (app_cmd),
        .app_en             (app_en),
        .app_rdy            (app_rdy),
        .app_wdf_data       (app_wdf_data),
        .app_wdf_end        (app_wdf_end),
        .app_wdf_mask       (app_wdf_mask),
        .app_wdf_wren       (app_wdf_wren),
        .app_wdf_rdy        (app_wdf_rdy),
        .app_rd_data        (app_rd_data),
        .app_rd_data_valid  (app_rd_data_valid),
        .app_rd_data_end    (app_rd_data_end)
    );

    // ---------------------------------------------------------------
    // DUT: ddr4_frame_buffer
    // ---------------------------------------------------------------
    ddr4_frame_buffer #(
        .APP_ADDR_WIDTH (APP_ADDR_WIDTH),
        .APP_DATA_WIDTH (APP_DATA_WIDTH),
        .APP_MASK_WIDTH (APP_MASK_WIDTH),
        .BASE_ADDR      (28'h0000000)
    ) u_dut (
        .hdmi_clk           (hdmi_clk),
        .hdmi_resetn        (hdmi_resetn),

        .S_AXIS_tdata       (s_axis_tdata),
        .S_AXIS_tvalid      (s_axis_tvalid),
        .S_AXIS_tlast       (s_axis_tlast),
        .S_AXIS_tuser       (s_axis_tuser),
        .S_AXIS_tready      (s_axis_tready),

        .M_AXIS_tdata       (m_axis_tdata),
        .M_AXIS_tvalid      (m_axis_tvalid),
        .M_AXIS_tlast       (m_axis_tlast),
        .M_AXIS_tuser       (m_axis_tuser),
        .M_AXIS_tready      (m_axis_tready),

        .sw_save            (sw_save),
        .sw_read            (sw_read),

        .mig_clk            (mig_clk),
        .mig_rst            (mig_rst),
        .init_calib_complete(init_calib_complete),

        .app_addr           (app_addr),
        .app_cmd            (app_cmd),
        .app_en             (app_en),
        .app_wdf_data       (app_wdf_data),
        .app_wdf_end        (app_wdf_end),
        .app_wdf_mask       (app_wdf_mask),
        .app_wdf_wren       (app_wdf_wren),
        .app_rdy            (app_rdy),
        .app_wdf_rdy        (app_wdf_rdy),
        .app_rd_data        (app_rd_data),
        .app_rd_data_valid  (app_rd_data_valid),
        .app_rd_data_end    (app_rd_data_end)
    );

    // ---------------------------------------------------------------
    // Write transaction counter (MIG domain)
    // ---------------------------------------------------------------
    int wr_count = 0;

    always @(posedge mig_clk) begin
        if (app_en && app_rdy && app_wdf_wren && app_wdf_rdy && app_cmd == 3'b000) begin
            wr_count++;
            if (wr_count % 100000 == 0)
                $display("Time=%0t | MIG writes: %0d | addr=0x%h", $time, wr_count, app_addr);
        end
    end

    // ---------------------------------------------------------------
    // M_AXIS monitors (HDMI domain)
    // ---------------------------------------------------------------
    int m_axis_xfer_count = 0;
    int m_axis_frame_count = 0;

    always @(posedge hdmi_clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            m_axis_xfer_count++;
            if (m_axis_tuser)
                m_axis_frame_count++;
        end
    end

    // M_AXIS tready pattern: 1 cycle on, 3 cycles off (simulates TX backpressure)
    initial begin
        m_axis_tready = 0;
        #500;
        forever begin
            @(posedge hdmi_clk);
            m_axis_tready = 1;

            repeat (3) begin
                @(posedge hdmi_clk);
                m_axis_tready = 0;
            end
        end
    end

    // ---------------------------------------------------------------
    // S_AXIS monitors (HDMI domain)
    // ---------------------------------------------------------------
    int s_axis_xfer_count = 0;
    int s_axis_frame_count = 0;

    always @(posedge hdmi_clk) begin
        if (s_axis_tvalid && s_axis_tready) begin
            s_axis_xfer_count++;
            if (s_axis_tuser)
                s_axis_frame_count++;
        end
    end

    // ---------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------
    initial begin
        $display("=== ddr4_frame_buffer_tb START ===");

        // Hold resets
        hdmi_resetn = 0;
        mig_rst     = 1;
        sw_save     = 0;
        sw_read     = 0;

        // Assert resets for 100 ns
        #100;

        // Deassert resets
        hdmi_resetn = 1;
        mig_rst     = 0;
        $display("Time=%0t | Resets deasserted", $time);

        // Wait for MIG calibration (handled by mig_model)
        wait(init_calib_complete);
        $display("Time=%0t | init_calib_complete asserted", $time);
        #50;

        // Start save: sw_save ON
        sw_save = 1;
        $display("Time=%0t | sw_save = 1 (start capture)", $time);
        #50;

        // Wait for capture to complete
        wait(wr_count == 1036800);
        $display("Time=%0t | All %0d MIG writes completed", $time, wr_count);
        $display("Time=%0t | S_AXIS: %0d transfers, %0d frames", $time, s_axis_xfer_count, s_axis_frame_count);
        $display("Time=%0t | M_AXIS: %0d transfers, %0d frames", $time, m_axis_xfer_count, m_axis_frame_count);

        // Release sw_save
        #200;
        sw_save = 0;
        $display("Time=%0t | sw_save = 0", $time);
        #1000;

        // Now test read playback
        $display("Time=%0t | sw_read = 1 (start read playback)", $time);
        sw_read = 1;

        // Reset M_AXIS counter to track the read frame
        @(posedge hdmi_clk);
        m_axis_xfer_count = 0;
        m_axis_frame_count = 0;

        wait(m_axis_xfer_count >= 1036800);
        $display("Time=%0t | Read playback: %0d M_AXIS transfers, %0d frames", $time, m_axis_xfer_count, m_axis_frame_count);

        #20000;
        $display("=== ddr4_frame_buffer_tb DONE ===");
        $finish;
    end

endmodule
