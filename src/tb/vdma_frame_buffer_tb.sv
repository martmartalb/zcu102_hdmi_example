`timescale 1ns / 1ps

module vdma_frame_buffer_tb;

    // ---------------------------------------------------------------
    // Clock — single domain (no more MIG clock!)
    // ---------------------------------------------------------------
    logic hdmi_clk = 0;
    always #5 hdmi_clk = ~hdmi_clk;  // ~300 MHz (3.33 ns half-period)

    // ---------------------------------------------------------------
    // Reset
    // ---------------------------------------------------------------
    logic hdmi_resetn = 0;

    // ---------------------------------------------------------------
    // Switches
    // ---------------------------------------------------------------
    logic sw_save = 0;
    logic sw_read = 0;

    // ---------------------------------------------------------------
    // AXI Stream: bram_image_streamer → DUT (S_AXIS)
    // ---------------------------------------------------------------
    logic [47:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tlast;
    logic        s_axis_tuser;
    logic        s_axis_tready;

    // ---------------------------------------------------------------
    // AXI Stream: DUT → TX sink (M_AXIS)
    // ---------------------------------------------------------------
    logic [47:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tlast;
    logic        m_axis_tuser;
    logic        m_axis_tready;

    // ---------------------------------------------------------------
    // AXI Stream: DUT → VDMA model S2MM
    // ---------------------------------------------------------------
    logic [47:0] vdma_s2mm_tdata;
    logic        vdma_s2mm_tvalid;
    logic        vdma_s2mm_tlast;
    logic [0:0]  vdma_s2mm_tuser;
    logic        vdma_s2mm_tready;

    // ---------------------------------------------------------------
    // AXI Stream: VDMA model MM2S → DUT
    // ---------------------------------------------------------------
    logic [47:0] vdma_mm2s_tdata;
    logic        vdma_mm2s_tvalid;
    logic        vdma_mm2s_tlast;
    logic [0:0]  vdma_mm2s_tuser;
    logic        vdma_mm2s_tready;

    // ---------------------------------------------------------------
    // VDMA status
    // ---------------------------------------------------------------
    logic frame_stored;

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
    // VDMA behavioral model
    // ---------------------------------------------------------------
    vdma_model #(
        .MEM_DEPTH (1_036_800),
        .H_SIZE    (960),
        .V_SIZE    (1080)
    ) u_vdma (
        .clk          (hdmi_clk),
        .resetn       (hdmi_resetn),
        .s2mm_tdata   (vdma_s2mm_tdata),
        .s2mm_tvalid  (vdma_s2mm_tvalid),
        .s2mm_tlast   (vdma_s2mm_tlast),
        .s2mm_tuser   (vdma_s2mm_tuser),
        .s2mm_tready  (vdma_s2mm_tready),
        .mm2s_tdata   (vdma_mm2s_tdata),
        .mm2s_tvalid  (vdma_mm2s_tvalid),
        .mm2s_tlast   (vdma_mm2s_tlast),
        .mm2s_tuser   (vdma_mm2s_tuser),
        .mm2s_tready  (vdma_mm2s_tready),
        .frame_stored (frame_stored)
    );

    // ---------------------------------------------------------------
    // DUT: vdma_frame_buffer (stream switch)
    // ---------------------------------------------------------------
    vdma_frame_buffer u_dut (
        .hdmi_clk        (hdmi_clk),
        .hdmi_resetn     (hdmi_resetn),

        .S_AXIS_tdata    (s_axis_tdata),
        .S_AXIS_tvalid   (s_axis_tvalid),
        .S_AXIS_tlast    (s_axis_tlast),
        .S_AXIS_tuser    (s_axis_tuser),
        .S_AXIS_tready   (s_axis_tready),

        .M_AXIS_tdata    (m_axis_tdata),
        .M_AXIS_tvalid   (m_axis_tvalid),
        .M_AXIS_tlast    (m_axis_tlast),
        .M_AXIS_tuser    (m_axis_tuser),
        .M_AXIS_tready   (m_axis_tready),

        .VDMA_S2MM_tdata  (vdma_s2mm_tdata),
        .VDMA_S2MM_tvalid (vdma_s2mm_tvalid),
        .VDMA_S2MM_tlast  (vdma_s2mm_tlast),
        .VDMA_S2MM_tuser  (vdma_s2mm_tuser),
        .VDMA_S2MM_tready (vdma_s2mm_tready),

        .VDMA_MM2S_tdata  (vdma_mm2s_tdata),
        .VDMA_MM2S_tvalid (vdma_mm2s_tvalid),
        .VDMA_MM2S_tlast  (vdma_mm2s_tlast),
        .VDMA_MM2S_tuser  (vdma_mm2s_tuser),
        .VDMA_MM2S_tready (vdma_mm2s_tready),

        .sw_save          (sw_save),
        .sw_read          (sw_read)
    );

    // ---------------------------------------------------------------
    // VDMA S2MM write counter
    // ---------------------------------------------------------------
    int s2mm_xfer_count = 0;

    always @(posedge hdmi_clk) begin
        if (vdma_s2mm_tvalid && vdma_s2mm_tready) begin
            s2mm_xfer_count++;
            if (s2mm_xfer_count % 100000 == 0)
                $display("Time=%0t | VDMA S2MM writes: %0d", $time, s2mm_xfer_count);
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

    // ---------------------------------------------------------------
    // Golden reference for read-back verification
    // ---------------------------------------------------------------
    logic [47:0] golden_mem [0:1036799];
    initial begin
        for (int i = 0; i < 1036800; i++)
            golden_mem[i] = 48'h0;
        $readmemh("src/data/image.mem", golden_mem, 0, 1036799);
    end

    // ---------------------------------------------------------------
    // Data integrity checker during read playback
    // ---------------------------------------------------------------
    int  rd_check_idx      = 0;
    int  rd_mismatch_count = 0;
    bit  rd_checking       = 0;

    always @(posedge hdmi_clk) begin
        if (rd_checking && m_axis_tvalid && m_axis_tready) begin
            if (m_axis_tdata !== golden_mem[rd_check_idx]) begin
                if (rd_mismatch_count < 20) begin
                    $display("MISMATCH @ idx=%0d : got=0x%h  exp=0x%h",
                             rd_check_idx, m_axis_tdata, golden_mem[rd_check_idx]);
                end
                rd_mismatch_count++;
            end
            rd_check_idx++;
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
    // AXI Stream protocol checker during read playback
    // ---------------------------------------------------------------
    int rd_proto_xfer   = 0;
    bit rd_proto_active = 0;

    always @(posedge hdmi_clk) begin
        if (rd_proto_active && m_axis_tvalid && m_axis_tready) begin
            // Check tuser: should only be asserted on first transfer of frame
            if (rd_proto_xfer == 0 && !m_axis_tuser)
                $display("PROTO_ERR @ xfer=%0d : tuser expected HIGH (SOF)", rd_proto_xfer);
            if (rd_proto_xfer != 0 && m_axis_tuser)
                $display("PROTO_ERR @ xfer=%0d : tuser expected LOW (not SOF)", rd_proto_xfer);

            // Check tlast: should be asserted every 960 transfers (end of line)
            if ((rd_proto_xfer % 960) == 959 && !m_axis_tlast)
                $display("PROTO_ERR @ xfer=%0d : tlast expected HIGH (EOL)", rd_proto_xfer);
            if ((rd_proto_xfer % 960) != 959 && m_axis_tlast)
                $display("PROTO_ERR @ xfer=%0d : tlast expected LOW (not EOL)", rd_proto_xfer);

            rd_proto_xfer++;
            if (rd_proto_xfer == 1036800)
                rd_proto_xfer = 0;  // wrap for next frame
        end
    end

    // ---------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------
    initial begin
        $display("=== vdma_frame_buffer_tb START ===");

        // Hold reset
        hdmi_resetn = 0;
        sw_save     = 0;
        sw_read     = 0;

        // Assert reset for 100 ns
        #100;

        // Deassert reset
        hdmi_resetn = 1;
        $display("Time=%0t | Reset deasserted", $time);
        #50;

        // Start capture: sw_save ON
        sw_save = 1;
        $display("Time=%0t | sw_save = 1 (start capture)", $time);

        // Wait for VDMA model to store a complete frame
        wait(frame_stored);
        $display("Time=%0t | Frame stored in VDMA memory", $time);
        $display("Time=%0t | S2MM writes: %0d", $time, s2mm_xfer_count);
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

        // Reset M_AXIS counter and enable checkers
        @(posedge hdmi_clk);
        m_axis_xfer_count  = 0;
        m_axis_frame_count = 0;
        rd_check_idx       = 0;
        rd_mismatch_count  = 0;
        rd_checking        = 1;
        rd_proto_xfer      = 0;
        rd_proto_active    = 1;

        wait(m_axis_xfer_count >= 1036800);
        rd_checking = 0;
        $display("Time=%0t | Read playback: %0d M_AXIS transfers, %0d frames", $time, m_axis_xfer_count, m_axis_frame_count);
        $display("Time=%0t | Data mismatches: %0d / %0d", $time, rd_mismatch_count, rd_check_idx);

        if (rd_mismatch_count == 0)
            $display("PASS: Read-back data matches golden reference.");
        else
            $display("FAIL: %0d mismatches detected.", rd_mismatch_count);

        #20000;
        $display("=== vdma_frame_buffer_tb DONE ===");
        $finish;
    end

endmodule
