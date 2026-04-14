`timescale 1ns / 1ps

module bram_image_streamer_tb;

    // Clock & reset
    logic aclk;
    logic aresetn;

    // AXI Stream signals
    logic [47:0] tdata;
    logic        tvalid;
    logic        tlast;
    logic        tuser;
    logic        tready;

    // -------------------------------------------------
    // Clock generation (100 MHz → 10 ns period)
    // -------------------------------------------------
    always #5 aclk = ~aclk;

    // -------------------------------------------------
    // DUT instantiation (VHDL)
    // -------------------------------------------------
    bram_image_streamer #(
        .MEM_INIT_FILE  ( "src/data/image.mem" )
    ) uut (
        .aclk(aclk),
        .aresetn(aresetn),

        .VIDEO_OUT_tdata(tdata),
        .VIDEO_OUT_tvalid(tvalid),
        .VIDEO_OUT_tlast(tlast),
        .VIDEO_OUT_tuser(tuser),
        .VIDEO_OUT_tready(tready)
    );

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