`timescale 1ns / 1ps

module bram_image_streamer_tb;

    // -------------------------------------------------
    // HDMI related signal
    // -------------------------------------------------

    // Clock & reset
    logic hdmi_clk_tb;
    logic hdmi_resetn_tb;

    // Slave AXI Stream signals
    logic [47:0] S_AXIS_tdata_tb;
    logic        S_AXIS_tvalid_tb;
    logic        S_AXIS_tlast_tb;
    logic        S_AXIS_tuser_tb;
    logic        S_AXIS_tready_tb;

    // Master AXI Stream signals
    logic [47:0] M_AXIS_tdata_tb;
    logic        M_AXIS_tvalid_tb;
    logic        M_AXIS_tlast_tb;
    logic        M_AXIS_tuser_tb;
    logic        M_AXIS_tready_tb;

    // -------------------------------------------------
    // Input switches
    // -------------------------------------------------
    logic        sw_save_tb;
    logic        sw_read_tb;

    // -------------------------------------------------
    // MIG related signal
    // -------------------------------------------------
    logic        mig_clk_tb;
    logic        mig_rst_tb;

    // -------------------------------------------------
    // Video In Generator
    // -------------------------------------------------
    bram_image_streamer #(
        .MEM_INIT_FILE  ( "src/data/image.mem" )
    ) uut (
        .aclk(aclk),
        .aresetn(aresetn),

        .VIDEO_OUT_tdata(S_AXIS_tdata_tb),
        .VIDEO_OUT_tvalid(S_AXIS_tvalid_tb),
        .VIDEO_OUT_tlast(S_AXIS_tlast_tb),
        .VIDEO_OUT_tuser(S_AXIS_tuser_tb),
        .VIDEO_OUT_tready(S_AXIS_tready_tb)
    );

    // -------------------------------------------------
    // DUT (ddr4_frame_buffer)
    // -------------------------------------------------
    ddr4_frame_buffer # (
        .APP_ADDR_WIDTH(28),
        .APP_DATA_WIDTH(128),
        .APP_MASK_WIDTH(16),
        .BASE_ADDR(28'h0000000)
    );
    uut (
        .hdmi_clk(hdmi_clk_tb),
        .hdmi_resetn(hdmi_resetn_tb)

        .S_AXIS_tdata(S_AXIS_tdata_tb),
        .S_AXIS_tvalid(S_AXIS_tvalid_tb),
        .S_AXIS_tlast(S_AXIS_tlast_tb),
        .S_AXIS_tuser(S_AXIS_tuser_tb),
        .S_AXIS_tready(S_AXIS_tready),

        .M_AXIS_tdata(M_AXIS_tdata_tb),
        .M_AXIS_tvalid(M_AXIS_tvalid_tb),
        .M_AXIS_tlast(M_AXIS_tlast_tb),
        .M_AXIS_tuser(M_AXIS_tuser_tb),
        .M_AXIS_tready(M_AXIS_tready_tb),

        .sw_save(sw_save_tb),
        .sw_read(sw_read_tb),

        .mig_clk(mig_clk_tb),
        .mig_rst(mig_rst_tb),
        .init_calib_complete(),
        .app_addr(),
        .app_cmd(),
        .app_en(),
        .app_wdf_data(),
        .app_wdf_end(),
        .app_wdf_mask(),
        .app_wdf_wren(),
        .app_rdy(),
        .app_wdf_rdy(),
        .app_rd_data(),
        .app_rd_data_valid(),
        .app_rd_data_end()
    );

    // -------------------------------------------------
    // HDMI Clock generation (100 MHz → 10 ns period)
    // -------------------------------------------------
    initial begin
        hdmi_clk = 0;
        forever #5 hdmi_clk = ~hdmi_clk;
    end

    // -------------------------------------------------
    // MIG Clock generation, Phase-shifted clock (1 ns delay)
    // -------------------------------------------------
    initial begin
        mig_clk_tb = 0;
        #1; // phase offset
        forever #5 mig_clk_tb = ~mig_clk_tb;
    end

    // -------------------------------------------------
    // Stimulus
    // -------------------------------------------------
    initial begin
        aclk     = 0;
        aresetn  = 0;
        tready   = 0;

        // Apply reset
        #20;
        aresetn = 1;

        // Wait a bit, then allow transfers
        #20;
        tready = 1;

        // Run for a while
        #20000000;

        $finish;
    end

    // -------------------------------------------------
    // Monitor AXI Stream activity
    // -------------------------------------------------
    always @(posedge aclk) begin
        if (tvalid && tready) begin
            $display("Time=%0t | DATA=0x%h | TLAST=%0b | TUSER=%0b",
                     $time, tdata, tlast, tuser);
        end
    end

endmodule