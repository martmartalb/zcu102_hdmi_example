`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// Module:      mig_model
// Description: Dummy MIG interface for testbench. Simulates the DDR4 MIG app
//              interface with a simple memory array. Supports write (store) and
//              read (return with pipeline latency) commands.
//
//              Memory is pre-loaded from image.mem (131,072 x 48-bit entries).
//              Each DDR address maps 1:1 to a 48-bit word: index = addr / 16.
//              Data is stored/returned in app_data[47:0], upper bits are padding.
// -----------------------------------------------------------------------------

module mig_model #(
    parameter APP_ADDR_WIDTH = 28,
    parameter APP_DATA_WIDTH = 128,
    parameter APP_MASK_WIDTH = 16,
    parameter MEM_DEPTH      = 1_036_800,  // full 1920x1080 frame
    parameter RD_LATENCY     = 8,          // read pipeline latency in cycles
    parameter MEM_INIT_FILE  = "src/data/image.mem",
    parameter MEM_INIT_DEPTH = 131072      // lines in .mem file
) (
    input  logic                        clk,
    input  logic                        rst,
    output logic                        init_calib_complete,

    // App command interface
    input  logic [APP_ADDR_WIDTH-1:0]   app_addr,
    input  logic [2:0]                  app_cmd,
    input  logic                        app_en,
    output logic                        app_rdy,

    // App write interface
    input  logic [APP_DATA_WIDTH-1:0]   app_wdf_data,
    input  logic                        app_wdf_end,
    input  logic [APP_MASK_WIDTH-1:0]   app_wdf_mask,
    input  logic                        app_wdf_wren,
    output logic                        app_wdf_rdy,

    // App read interface
    output logic [APP_DATA_WIDTH-1:0]   app_rd_data,
    output logic                        app_rd_data_valid,
    output logic                        app_rd_data_end
);

    // ---------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------
    localparam CMD_WRITE = 3'b000;
    localparam CMD_READ  = 3'b001;
    localparam ADDR_STEP = 16;

    // ---------------------------------------------------------------
    // Memory array (48-bit per entry)
    // ---------------------------------------------------------------
    logic [47:0] mem [0:MEM_DEPTH-1];

    // ---------------------------------------------------------------
    // Memory initialization from .mem file
    // ---------------------------------------------------------------
    initial begin
        // Zero-init all memory
        for (int i = 0; i < MEM_DEPTH; i++)
            mem[i] = 48'h0;
        // Load image data
        $readmemh(MEM_INIT_FILE, mem, 0, MEM_INIT_DEPTH - 1);
    end

    // ---------------------------------------------------------------
    // Always ready (simple model)
    // ---------------------------------------------------------------
    assign app_rdy     = 1'b1;
    assign app_wdf_rdy = 1'b1;

    // ---------------------------------------------------------------
    // Calibration complete after a few cycles
    // ---------------------------------------------------------------
    initial begin
        init_calib_complete = 1'b0;
        repeat (20) @(posedge clk);
        init_calib_complete = 1'b1;
    end

    // ---------------------------------------------------------------
    // Write handling
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (app_en && app_rdy && app_cmd == CMD_WRITE &&
            app_wdf_wren && app_wdf_rdy) begin
            automatic int idx = app_addr / ADDR_STEP;
            if (idx < MEM_DEPTH)
                mem[idx] = app_wdf_data[47:0];
        end
    end

    // ---------------------------------------------------------------
    // Read handling with pipeline latency
    // ---------------------------------------------------------------
    logic [APP_DATA_WIDTH-1:0] rd_pipe_data  [0:RD_LATENCY-1];
    logic                      rd_pipe_valid [0:RD_LATENCY-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < RD_LATENCY; i++) begin
                rd_pipe_data[i]  <= '0;
                rd_pipe_valid[i] <= 1'b0;
            end
        end else begin
            // Stage 0: capture read command
            if (app_en && app_rdy && app_cmd == CMD_READ) begin
                automatic int idx = app_addr / ADDR_STEP;
                if (idx < MEM_DEPTH)
                    rd_pipe_data[0] <= {{(APP_DATA_WIDTH-48){1'b0}}, mem[idx]};
                else
                    rd_pipe_data[0] <= '0;
                rd_pipe_valid[0] <= 1'b1;
            end else begin
                rd_pipe_data[0]  <= '0;
                rd_pipe_valid[0] <= 1'b0;
            end

            // Shift pipeline
            for (int i = 1; i < RD_LATENCY; i++) begin
                rd_pipe_data[i]  <= rd_pipe_data[i-1];
                rd_pipe_valid[i] <= rd_pipe_valid[i-1];
            end
        end
    end

    // Output from last pipeline stage
    assign app_rd_data       = rd_pipe_data[RD_LATENCY-1];
    assign app_rd_data_valid = rd_pipe_valid[RD_LATENCY-1];
    assign app_rd_data_end   = rd_pipe_valid[RD_LATENCY-1];

endmodule
