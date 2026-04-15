`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// Module:      vdma_model
// Description: Behavioral AXI VDMA model for testbench.
//
//              S2MM channel: AXI Stream slave that captures video frames into
//              a memory array. Uses tuser[0] (SOF) to synchronize frame start.
//
//              MM2S channel: AXI Stream master that reads stored frames from
//              the memory array and outputs them with proper tuser/tlast
//              video timing. Loops continuously once a frame is available.
//
//              This replaces the mig_model that simulated the raw DDR4 MIG
//              app interface. The VDMA model is dramatically simpler because
//              all address generation and data packing is handled internally.
// -----------------------------------------------------------------------------

module vdma_model #(
    parameter MEM_DEPTH = 1_036_800,  // 960 clks/line x 1080 lines
    parameter H_SIZE    = 960,        // clocks per line (1920 pixels / 2 ppc)
    parameter V_SIZE    = 1080        // lines per frame
) (
    input  logic        clk,
    input  logic        resetn,

    // S2MM: AXI Stream slave (capture — video into memory)
    input  logic [47:0] s2mm_tdata,
    input  logic        s2mm_tvalid,
    input  logic        s2mm_tlast,
    input  logic [0:0]  s2mm_tuser,
    output logic        s2mm_tready,

    // MM2S: AXI Stream master (playback — memory to video)
    output logic [47:0] mm2s_tdata,
    output logic        mm2s_tvalid,
    output logic        mm2s_tlast,
    output logic [0:0]  mm2s_tuser,
    input  logic        mm2s_tready,

    // Status
    output logic        frame_stored
);

    // -----------------------------------------------------------------
    // Memory array (48-bit per pixel-pair, same as AXI Stream width)
    // -----------------------------------------------------------------
    logic [47:0] mem [0:MEM_DEPTH-1];

    initial begin
        for (int i = 0; i < MEM_DEPTH; i++)
            mem[i] = 48'h0;
    end

    // -----------------------------------------------------------------
    // S2MM: always ready when not in reset
    // -----------------------------------------------------------------
    assign s2mm_tready = resetn;

    // -----------------------------------------------------------------
    // S2MM write logic — SOF-synchronized frame capture
    // -----------------------------------------------------------------
    int s2mm_wr_idx;
    bit s2mm_active;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            s2mm_wr_idx  <= 0;
            s2mm_active  <= 0;
            frame_stored <= 0;
        end else if (s2mm_tvalid && s2mm_tready) begin
            if (s2mm_tuser[0]) begin
                // Start-of-frame: begin capture at index 0
                mem[0]      <= s2mm_tdata;
                s2mm_wr_idx <= 1;
                s2mm_active <= 1;
            end else if (s2mm_active) begin
                mem[s2mm_wr_idx] <= s2mm_tdata;
                if (s2mm_wr_idx == MEM_DEPTH - 1) begin
                    // Frame complete
                    frame_stored <= 1;
                    s2mm_active  <= 0;
                    s2mm_wr_idx  <= 0;
                end else begin
                    s2mm_wr_idx <= s2mm_wr_idx + 1;
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // MM2S read logic — outputs stored frame with video timing
    // -----------------------------------------------------------------
    int mm2s_rd_idx;
    int mm2s_x;
    int mm2s_y;
    bit mm2s_active;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            mm2s_rd_idx <= 0;
            mm2s_x      <= 0;
            mm2s_y      <= 0;
            mm2s_active <= 0;
        end else begin
            if (!mm2s_active) begin
                // Start outputting once a frame has been captured
                if (frame_stored) begin
                    mm2s_active <= 1;
                    mm2s_rd_idx <= 0;
                    mm2s_x      <= 0;
                    mm2s_y      <= 0;
                end
            end else if (mm2s_tvalid && mm2s_tready) begin
                // Handshake: advance to next pixel-pair
                if (mm2s_rd_idx == MEM_DEPTH - 1) begin
                    // End of frame: loop back to start
                    mm2s_rd_idx <= 0;
                    mm2s_x      <= 0;
                    mm2s_y      <= 0;
                end else begin
                    mm2s_rd_idx <= mm2s_rd_idx + 1;
                    if (mm2s_x == H_SIZE - 1) begin
                        mm2s_x <= 0;
                        mm2s_y <= mm2s_y + 1;
                    end else begin
                        mm2s_x <= mm2s_x + 1;
                    end
                end
            end
        end
    end

    // MM2S outputs (active = data valid, combinational memory read)
    assign mm2s_tdata    = mem[mm2s_rd_idx];
    assign mm2s_tvalid   = mm2s_active;
    assign mm2s_tlast    = mm2s_active && (mm2s_x == H_SIZE - 1);
    assign mm2s_tuser[0] = mm2s_active && (mm2s_x == 0) && (mm2s_y == 0);

endmodule
