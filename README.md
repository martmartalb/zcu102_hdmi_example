# ZCU102 HDMI DDR4 Frame Buffer

This project extends the Xilinx HDMI example design for the ZCU102 (Zynq UltraScale+) board with a DDR4-backed frame buffer. A live HDMI input stream can be captured to DDR4 memory and played back to the HDMI output, all controlled by two physical switches.

---

## Overview

```
HDMI RX ──► [AXI Stream] ──► ddr4_frame_buffer ──► [AXI Stream] ──► HDMI TX
                                     │
                              ┌──────┴──────┐
                              │  DDR4 MIG   │
                              │  (ZCU102)   │
                              └─────────────┘
```

The core module (`src/rtl/ddr4_frame_buffer.vhd`) sits between the HDMI RX and TX subsystems as an AXI4-Stream pass-through with optional frame capture and playback. The top-level wrapper (`ddr4_frame_buffer_top.vhd`) instantiates the DDR4 MIG IP alongside it.

**Target resolution:** 1920×1080, 2 pixels per clock cycle (48-bit AXI Stream words).

---

## Switch Modes

Two board switches (ZCU102 slide switches `sw_save` at AK13 and `sw_read` at AL13) select the operating mode:

| `sw_save` | `sw_read` | Mode | Behavior |
|:---------:|:---------:|------|----------|
| 0 | 0 | **Passthrough** | Live HDMI input is forwarded directly to HDMI output. Nothing is stored. |
| 1 | 0 | **Capture + Passthrough** | Live video continues to HDMI output AND one full frame (1080p) is captured to DDR4. When the full frame is saved the FSM stops writing but passthrough continues. |
| 0 | 1 | **DDR Playback** | The stored frame is read from DDR4 in a continuous loop and sent to the HDMI output. The live input is silently discarded. |
| 1 | 1 | Not intended; read takes priority. | |

The output multiplexer (line 828 of `ddr4_frame_buffer.vhd`) selects between the live S\_AXIS input and the DDR playback path based on `sw_read`.

---

## Architecture

### Clock Domains

| Domain | Source | Frequency |
|--------|--------|-----------|
| `hdmi_clk` | HDMI RX recovered clock | ~300 MHz |
| `mig_clk` | DDR4 MIG UI clock | ~300 MHz |

These two clocks are asynchronous to each other. All signals crossing between them go through 2-FF synchronisers or the async FIFOs described below.

---

### Two FIFOs (Clock Domain Crossing)

Both FIFOs use Xilinx `xpm_fifo_async` (BRAM-backed, first-word-fall-through).

#### Write FIFO — HDMI → MIG
Buffers captured pixel data from the HDMI clock domain before the MIG FSM drains it.

| Parameter | Value |
|-----------|-------|
| Width | 48 bits |
| Depth | 1024 entries |
| `PROG_FULL_THRESH` | 1020 — backpressures the HDMI capture when almost full |
| Write clock | `hdmi_clk` |
| Read clock | `mig_clk` |

#### Read FIFO — MIG → HDMI
Buffers DDR read data from the MIG before the HDMI output FSM consumes it.

| Parameter | Value |
|-----------|-------|
| Width | 48 bits |
| Depth | 512 entries |
| `PROG_FULL_THRESH` | 480 — pauses MIG read commands when almost full |
| Write clock | `mig_clk` |
| Read clock | `hdmi_clk` |

The read FIFO can be flushed by asserting `rd_fifo_flush` (active during the `M_RD_ABORT` state).

---

### Three State Machines

#### 1. HDMI Capture FSM (`cap_state_t`) — `hdmi_clk` domain

Controls writing incoming pixels into the write FIFO.

```
CAP_IDLE ──(sw_save rises)──► CAP_WAIT_SOF ──(SOF seen)──► CAP_CAPTURING
                                                                   │
                                                         (1,036,800 words written)
                                                                   │
                                                             CAP_DONE ──(sw_save low)──► CAP_IDLE
```

- Waits for the rising edge of `sw_save`, then waits for a start-of-frame (`S_AXIS_tuser`) to align to a frame boundary before writing.
- Counts exactly **1,036,800** AXI transfers (960 clocks × 1080 lines) then stops.
- Asserts backpressure (`cap_tready = 0`) when the write FIFO is almost full.

#### 2. MIG Main FSM (`mig_state_t`) — `mig_clk` domain

Drives the DDR4 MIG application interface for both writes and reads.

```
         ┌─────────── Write path ───────────┐
M_IDLE ──┤                                  ├──► M_WR_DONE ──► M_IDLE
         │  M_WR_LOAD → M_WR_SETUP → M_WR_SEND (loops)
         │
         └─────────── Read path ────────────┐
                                            ├──► M_RD_FRAME_DONE ──► (loop or M_IDLE)
           M_RD_CMD → M_RD_DRAIN ───────────┘
                │
                └──(sw_read drops mid-frame)──► M_RD_ABORT ──► M_IDLE
```

**Write path** (`M_WR_LOAD → M_WR_SETUP → M_WR_SEND`): Reads one 48-bit word from the write FIFO, packs it into a 128-bit MIG word (lower 48 bits only), and issues a write command. Address increments by 8 bytes per transfer. Loops until 1,036,800 words are written.

**Read path** (`M_RD_CMD → M_RD_DRAIN`): Issues pipelined read commands to MIG, pausing when the read FIFO reaches its `PROG_FULL` threshold. After all commands are sent it drains remaining in-flight data. Loops the full frame as long as `sw_read` remains high.

**Abort** (`M_RD_ABORT`): If `sw_read` drops while a read is in progress, the FSM flushes the read FIFO for 16 cycles and returns to idle.

State debug encoding is wired to an Integrated Logic Analyzer (ILA) probe for in-hardware visibility.

#### 3. HDMI Read Output FSM (`ro_state_t`) — `hdmi_clk` domain

Generates the AXI Stream output from read FIFO data, reconstructing the correct pixel/line/frame timing.

```
RO_IDLE ──(sw_read high)──► RO_WAIT_READY ──(x = 959)──► RO_EOL_HOLD (20 cycles)
                                  ▲                              │
                                  └──────────(blanking done)─────┘
                                  (1-cycle gap: RO_ADVANCE)
```

- `RO_WAIT_READY`: Waits for the downstream to be ready and the read FIFO to have data, then pulses `ro_tvalid` + `rd_fifo_rd_en` for one cycle. Tracks X (0–959) and Y (0–1079) counters and sets `ro_tlast`/`ro_tuser` accordingly.
- `RO_ADVANCE`: One-cycle pipeline gap for the FIFO to present the next word.
- `RO_EOL_HOLD`: Holds `ro_tlast` high for 20 cycles at end of line to cover horizontal blanking.

---

## Memory Utilisation (Known Limitation)

The DDR4 MIG on the ZCU102 provides a **128-bit** application data bus. This design uses only **48 bits** per transfer — the lower 48 bits hold two 24-bit RGB pixels; the upper 80 bits are always zero on writes and discarded on reads.

```
app_wdf_data[127:0]:
┌──────────────────────────────────┬─────────────────┐
│       Unused (zeros) [127:48]    │  2 pixels [47:0] │
└──────────────────────────────────┴─────────────────┘
         80 bits wasted                 48 bits used
```

**Efficiency: 48 / 128 = 37.5%**

Each DDR4 write/read transaction transfers 128 bits but carries only 48 bits of useful data. A frame of 1,036,800 transfers therefore uses **16.7× more DDR bandwidth and address space than necessary**. A straightforward improvement would be to pack multiple pixels across the full 128-bit word before issuing a MIG command, reducing the required number of transactions by ~2.67× (128 ÷ 48 ≈ 2.67 pixels-pairs per transfer).

---

## Directory Structure

```
zcu102_hdmi_example/
├── src/
│   ├── rtl/
│   │   ├── ddr4_frame_buffer.vhd       # Core: FIFOs + 3 FSMs
│   │   ├── ddr4_frame_buffer_top.vhd   # Top wrapper + MIG instantiation
│   │   └── bram_image_streamer.vhd     # Test pattern generator (BRAM)
│   ├── tb/
│   │   ├── ddr4_frame_buffer_tb.sv     # Full testbench
│   │   ├── bram_image_streamer_tb.sv   # Streamer unit test
│   │   └── mig_model.sv                # Behavioural DDR4 MIG model
│   ├── constraints/
│   │   └── hdmi_example_zcu102.xdc     # Pin assignments & timing
│   ├── ip/
│   │   ├── ddr4/ddr4_0.xci             # DDR4 MIG IP (MT40A256M16, 1.2 GHz)
│   │   └── ila_mig/ila_mig.xci         # ILA for MIG FSM debug
│   └── data/
│       └── image.mem                   # 1,036,800 × 48-bit test image
└── scripts/                            # Vivado TCL build scripts
```

---

## Build

Use the provided Vivado TCL scripts:

```tcl
# From Vivado Tcl console:
source scripts/create_project.tcl
source scripts/create_root_design.tcl
```

Post-route physical optimisation scripts (`phys_opt_design.tcl`, `postroute_phys_opt_design.tcl`) are provided for timing closure.

---

## Key Design Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `C_H_PIXELS` | 1920 | Horizontal pixels |
| `C_V_LINES` | 1080 | Vertical lines |
| `C_PIXELS_PER_CLK` | 2 | Pixels per AXI clock |
| `C_CLKS_PER_LINE` | 960 | AXI transfers per line |
| `C_AXI_XFERS_PER_FRAME` | 1,036,800 | Total AXI transfers per frame |
| `C_DDR_OPS_PER_FRAME` | 1,036,800 | DDR read/write ops per frame (1:1) |
| `C_ADDR_STEP` | 8 | Address increment per op (bytes) |
| `C_TLAST_HOLD_CYCLES` | 20 | Blanking hold cycles at EOL |
