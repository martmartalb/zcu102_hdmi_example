module axi_pixel_not #(
    parameter DATA_WIDTH = 48
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    input wire [DATA_WIDTH-1:0]   VIDEO_IN_tdata,
    input wire                    VIDEO_IN_tvalid,
    input wire                    VIDEO_IN_tlast,
    input wire                    VIDEO_IN_tuser,
    output  wire                  VIDEO_IN_tready,

    // VIDEO_OUT (actually INPUT to your module → AXI slave)
    output  wire [DATA_WIDTH-1:0] VIDEO_OUT_tdata,
    output  wire                  VIDEO_OUT_tvalid,
    output  wire                  VIDEO_OUT_tlast,
    output  wire                  VIDEO_OUT_tuser,
    input wire                    VIDEO_OUT_tready
);

    // Handshake (reverse flow)
    assign VIDEO_IN_tready   = VIDEO_OUT_tready;
    assign VIDEO_OUT_tvalid  = VIDEO_IN_tvalid;

    // Control signals
    assign VIDEO_OUT_tlast  = VIDEO_IN_tlast;
    assign VIDEO_OUT_tuser  = VIDEO_IN_tuser;

    // Data processing
    assign VIDEO_OUT_tdata  = ~VIDEO_IN_tdata;

endmodule : axi_pixel_not