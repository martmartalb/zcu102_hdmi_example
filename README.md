# ZCU102 HDMI + VDMA Frame Buffer Example

A Xilinx HDMI example design for the ZCU102 board extended with an AXI VDMA-based frame buffer. Two physical switches control three operating modes: HDMI passthrough (default), frame capture to DDR4, and frame playback from DDR4.

---

## Table of Contents

1. [Overview](#overview)
2. [Hardware Requirements](#hardware-requirements)
3. [Architecture](#architecture)
4. [Operating Modes](#operating-modes)
5. [RTL Design](#rtl-design)
6. [Block Diagram Connectivity](#block-diagram-connectivity)
7. [Clock Domains](#clock-domains)
8. [Register Map](#register-map)
9. [Build Flow](#build-flow)
10. [Running on Hardware](#running-on-hardware)
11. [Simulation](#simulation)
12. [Debug](#debug)
13. [Repository Structure](#repository-structure)

---

## Overview

This project starts from the Xilinx HDMI Example Design (for the ZCU102 board) and adds a **Video DMA (VDMA) frame buffer** entirely in PL (Programmable Logic), with no ARM firmware required for the VDMA configuration.

Key additions over the base Xilinx example:

- **Custom RTL** (`vdma_frame_buffer_top`) acting as an AXI Stream switch between HDMI RX, HDMI TX, and an AXI VDMA
- **PL-only VDMA controller** (`vdma_ctrl`) that programs the Xilinx AXI VDMA v6.3 via AXI4-Lite on power-up, without any software involvement
- **DDR4 frame store** — a single 1920×1080 RGB frame (≈6 MB) stored in the on-board DDR4
- **Two-switch interface** on the ZCU102 DIP switches for mode selection

---

## Hardware Requirements

| Item | Details |
|---|---|
| Board | Xilinx ZCU102 Evaluation Kit |
| HDMI Input | HDMI RX connector (J1) |
| HDMI Output | HDMI TX connector (J2) |
| Switch SW_SAVE | ZCU102 DIP switch — pin AK13 (LVCMOS33) |
| Switch SW_READ | ZCU102 DIP switch — pin AL13 (LVCMOS33) |
| DDR4 | On-board SDRAM (16-bit width, MIG controller) |

---

## Architecture

```
            ┌────────────────────────────────────────────────────┐
            │                  ZCU102 PL Fabric                  │
            │                                                    │
  HDMI RX  ──────────┐                                           │
  (PHY J1)  │        │                                           │
            │        │         ┌─────────────────────────────┐   │
            │        │         │  vdma_frame_buffer_top      │   │
            │        │         │                             │   │
            │        └────────►│ HDMI_S_AXIS    HDMI_M_AXIS  │──► HDMI TX (PHY J2)
            │                  │                             │   │
  sw_save ────────────────────►│ vdma_frame_buffer           │   │
  sw_read ────────────────────►│  (AXI Stream switch)        │   │
            │                  │                             │   │
            │                  │ VDMA_S2MM ─────────────────►│──► axi_vdma_0  ──► DDR4
            │                  │ VDMA_MM2S ◄─────────────────│◄── axi_vdma_0 ◄── DDR4
            │                  │                             │   │
            │                  │ M_AXI_LITE ─────────────────│──► axi_vdma_0 (reg. config)
            │                  │  vdma_ctrl                  │   │
            │                  └──────────────↑──────────────┘   │
            │                                 │                  │
            │  init_calib_complete ───────────┘                  │
            │  (from DDR4 MIG)                                   │
            └────────────────────────────────────────────────────┘
```

---

## Operating Modes

The design has three modes, selected by two physical switches. `sw_read` takes priority over `sw_save`.

### Mode 1: Passthrough (default — both switches OFF)

```
HDMI RX ──────────────────────────────────────────► HDMI TX
                          VDMA: idle
```

- Video from HDMI RX is passed directly to HDMI TX with full AXI Stream backpressure
- The VDMA is running (configured at startup) but no data is sent to or read from DDR4
- Lowest latency — no buffering

### Mode 2: Save / Broadcast (`sw_save` ON, `sw_read` OFF)

```
HDMI RX ─────────────────────────────────────────► VDMA S2MM ──► DDR4
```

- HDMI input is broadcast to the VDMA capture path (S2MM → DDR4)
- The VDMA continuously overwrites a single frame in DDR4 in circular mode
- AXI Stream backpressure from the VDMA S2MM propagates back to HDMI RX input, so no pixel is dropped

### Mode 3: Read / Playback (`sw_read` ON, regardless of `sw_save`)

```
DDR4 ──► VDMA MM2S ──────────────────────────────► HDMI TX
                          HDMI RX: discarded
```

- The last frame written to DDR4 is played back continuously to the HDMI TX output
- HDMI RX input is accepted but silently discarded (`tready = 1`)
- Playback loops via VDMA circular mode — the stored frame repeats indefinitely
- If DDR4 has never been written (no prior Save), output content is undefined

---

## RTL Design

All custom RTL lives under `src/rtl/`.

### `vdma_frame_buffer_top.vhd`

Top-level wrapper. Instantiates:

1. `vdma_frame_buffer` — AXI Stream switching logic
2. `vdma_ctrl` — AXI4-Lite master that programs the VDMA IP

It connects the two sub-modules and exposes the full port list to the block diagram.

### `vdma_frame_buffer.vhd` — AXI Stream Switch

Implements the three-mode multiplexer described above.

**Switch input handling:**
- 2-FF synchronizer on both `sw_save` and `sw_read` pins (CDC from asynchronous PL I/O to `hdmi_clk` domain)
- 20-bit debounce counter (≈3.3 ms at 300 MHz) — switch must be stable for this long before a mode change is registered
- Priority: `sw_read` dominates; `sw_save` only activates when `sw_read` is de-asserted

**Stream muxing (simplified):**

```vhdl
-- Passthrough
if saving = '0' and reading = '0' then
    HDMI_M_AXIS <= HDMI_S_AXIS;       -- Direct pass
    VDMA_AXIS_S2MM_tvalid <= '0';     -- VDMA idle

-- Save (broadcast)
elsif saving = '1' then
    HDMI_M_AXIS <= HDMI_S_AXIS;       -- Still pass to TX
    VDMA_AXIS_S2MM <= HDMI_S_AXIS;    -- Also send to VDMA
    HDMI_S_AXIS_tready <= VDMA_AXIS_S2MM_tready;  -- Backpressure from VDMA

-- Read (playback)
elsif reading = '1' then
    HDMI_M_AXIS <= VDMA_AXIS_MM2S;    -- TX driven from DDR4
    HDMI_S_AXIS_tready <= '1';        -- Discard RX input
end if;
```

### `vdma_ctrl.vhd` — VDMA Configuration Controller

An AXI4-Lite master FSM that programs the Xilinx AXI VDMA IP once at startup. No ARM processor or software driver is required.

**Startup sequence:**
1. Waits for `init_calib_complete` from the DDR4 MIG controller
2. Walks through a 10-entry configuration ROM, issuing AXI4-Lite write transactions
3. After the last write, transitions to `DONE` state and remains idle

**Configuration ROM** (both S2MM and MM2S channels, 1920×1080 frame):

| Step | Register        | Offset | Value      | Description                        |
|------|-----------------|--------|------------|------------------------------------|
| 0 | S2MM DMACR         | 0x30   | 0x00010083 | Run, Circular mode                 |
| 1 | S2MM START_ADDR1   | 0xAC   | 0x00000000 | DDR4 frame base address            |
| 2 | S2MM FRMDLY_STRIDE | 0xA8   | 0x00001680 | Stride = 5760 bytes (1920×3)       |
| 3 | S2MM HSIZE         | 0xA4   | 0x00001680 | Horizontal size = 5760 bytes       |
| 4 | S2MM VSIZE         | 0xA0   | 0x00000438 | Vertical size = 1080 — **trigger** |
| 5 | MM2S DMACR         | 0x00   | 0x00010083 | Run, Circular mode                 |
| 6 | MM2S START_ADDR1   | 0x5C   | 0x00000000 | DDR4 frame base address            |
| 7 | MM2S FRMDLY_STRIDE | 0x58   | 0x00001680 | Stride = 5760 bytes                |
| 8 | MM2S HSIZE         | 0x54   | 0x00001680 | Horizontal size = 5760 bytes       |
| 9 | MM2S VSIZE         | 0x50   | 0x00000438 | Vertical size = 1080 — **trigger** |

Writing VSIZE last is mandatory per the AXI VDMA specification (PG020) — it is the register that arms and launches the DMA channel.

---

## Block Diagram Connectivity

The Vivado block diagram is fully scripted in `scripts/create_root_design.tcl`. Major connections:

```
Zynq UltraScale+ (PS)
  └─ S_AXI_HP0 → PS HP port (available for future use)

Video PHY Controller
  ├─ HDMI_RX_CLK_P/N (N27)  → RX reference clock
  ├─ TX_REFCLK_P/N  (R27)   → TX reference clock
  ├─ ch0/ch1/ch2 TX/RX      → HDMI TX/RX PHY lanes
  └─ vid_phy_axi_lite        ← Zynq AXI master (initialization)

v_hdmi_rx_ss (HDMI RX Subsystem)
  └─ M_AXIS_VIDEO → rx_video_axis_reg_slice → vdma_frame_buffer_top.HDMI_S_AXIS

v_hdmi_tx_ss (HDMI TX Subsystem)
  └─ S_AXIS_VIDEO ← tx_video_axis_reg_slice ← vdma_frame_buffer_top.HDMI_M_AXIS

vdma_frame_buffer_top_0 (custom RTL)
  ├─ HDMI_S_AXIS  ← rx path
  ├─ HDMI_M_AXIS  → tx path
  ├─ VDMA_AXIS_S2MM → axi_vdma_0.S_AXIS_S2MM
  ├─ VDMA_AXIS_MM2S ← axi_vdma_0.M_AXIS_MM2S
  ├─ M_AXI_LITE   → axi_vdma_0.S_AXI_LITE
  ├─ sw_save       ← ZCU102 DIP switch (AK13)
  ├─ sw_read       ← ZCU102 DIP switch (AL13)
  └─ init_calib_complete ← ddr4_0.c0_init_calib_complete

axi_vdma_0 (Xilinx AXI VDMA v6.3)
  ├─ M_AXI_S2MM → vdma_mem_ic.S00_AXI
  └─ M_AXI_MM2S → vdma_mem_ic.S01_AXI

vdma_mem_ic (SmartConnect, 2S → 1M)
  └─ M00_AXI → ddr4_0.C0_DDR4_S_AXI

ddr4_0 (DDR4 MIG)
  ├─ C0_DDR4 → physical DDR4 SDRAM pins
  └─ c0_ddr4_ui_clk → VDMA M_AXI clocks, vdma_frame_buffer_top axi_lite_clk
```

---

## Clock Domains

| Domain | Source | Frequency | Used By |
|--------|--------|-----------|---------|
| `hdmi_clk` | HDMI RX PHY recovered clock | ~300 MHz (297.xx) | HDMI RX/TX AXI streams, switch logic, VDMA S/M AXIS |
| `axi_lite_clk` | DDR4 MIG UI clock ÷3 | ~100 MHz | `vdma_ctrl` AXI4-Lite master |
| `ddr4_ui_clk` | DDR4 MIG UI clock | ~300 MHz | VDMA M_AXI_S2MM, M_AXI_MM2S (DDR4 access) |

Clock domain crossings:
- `sw_save` / `sw_read` physical pins → `hdmi_clk`: 2-FF synchronizer inside `vdma_frame_buffer`
- `init_calib_complete` (`ddr4_ui_clk`) → `axi_lite_clk`: 2-FF synchronizer inside `vdma_ctrl`

---

## Register Map

The AXI VDMA register offsets follow Xilinx PG020 (AXI Video DMA v6.3 Product Guide).

The frame buffer uses DDR4 base address `0x0000_0000` (C0_DDR4_S_AXI address space) and stores one frame: `1920 × 1080 × 3 bytes = 6,220,800 bytes (~5.9 MB)`.

---

## Build Flow

### Prerequisites

- Vivado 2022.2 (or compatible version)
- Vitis 2022.2
- Xilinx board files for ZCU102 installed
- Licensed HDMI IP cores (v_hdmi_rx_ss, v_hdmi_tx_ss, vid_phy_controller)

### Steps

```bash
# 1. Create Vivado project and block diagram
make vivado_project

# 2. Synthesize, implement, and export hardware platform (.xsa)
make hw_platform

# 3. Create Vitis platform from XSA
make vitis_platform

# 4. Create Vitis application project
make vitis_app
```

Individual make targets:

| Target | Action |
|--------|--------|
| `vivado_project` | Runs `create_project.tcl` + `create_root_design.tcl` |
| `hw_platform` | Runs synthesis, implementation, `gen_hw_platform.tcl` → exports `.xsa` |
| `vitis_platform` | Creates Vitis hardware platform from `.xsa` |
| `vitis_app` | Creates and builds Vitis application (default target) |
| `clean` | Removes all build artifacts |
| `trace` | Re-runs without `-notrace` for step-by-step TCL logging |

### Output Artifacts

```
build/
├── zcu102_hdmi_example.xpr          # Vivado project
├── zcu102_hdmi_example.runs/        # Synthesis & implementation runs
├── zcu102_hdmi_example.xsa          # Hardware platform for Vitis
└── vitis_workspace/                 # Vitis platform + application
```

---

## Running on Hardware

1. **Program the FPGA** via JTAG from Vivado Hardware Manager or Vitis
2. **Connect HDMI** source to the RX connector (J1) and a display to the TX connector (J2)
3. **Power on** — DDR4 calibration takes a few seconds. `vdma_ctrl` will configure the VDMA automatically once calibration is complete

### Switch Operation

| SW_SAVE (AK13) | SW_READ (AL13) | Mode | Description |
|:-:|:-:|---|---|
| 0 | 0 | Passthrough | HDMI input displayed directly on output |
| 1 | 0 | Save | Input captured to DDR4                       |
| 0 | 1 | Read | Stored frame played back in a loop on output |
| 1 | 1 | Read | `sw_read` dominates — same as Read mode |

> **Note:** Switch debounce time is ≈3.3 ms. Mode changes take effect shortly after the switch stabilizes.

### Expected Behavior

- **Default (passthrough):** Turn on the board with both switches OFF — the HDMI source appears live on the connected display
- **Capturing a frame:** Flip `sw_save` ON — video continues uninterrupted while the frame is being written to DDR4
- **Freezing the frame:** While `sw_save` is ON (so a frame has been written), flip `sw_read` ON — the display immediately shows the last captured frame, frozen and looping
- **Returning to live:** Turn both switches OFF to go back to passthrough

---

## Simulation

A self-checking testbench is provided under `src/tb/`.

```
src/tb/
├── vdma_frame_buffer_tb.sv   # Top-level testbench
└── vdma_model.sv             # Behavioral model of Xilinx AXI VDMA
```

### Test Flow

1. Loads a 960×1080 golden reference image from `src/data/image.mem`
2. Applies reset
3. Asserts `sw_save=1`, streams the golden image into the VDMA model (simulating HDMI RX input)
4. Waits for full-frame capture to complete
5. De-asserts `sw_save`, then asserts `sw_read=1`
6. Reads back the frame from the VDMA model and compares it against the golden reference pixel-by-pixel
7. Checks AXI Stream protocol: `tuser` (start-of-frame) and `tlast` (end-of-line) timing

### Run Simulation

```bash
# ModelSim (as configured in run.do)
vsim -do run.do
```

The `vdma_model` behavioral model replicates the Xilinx VDMA S2MM/MM2S behavior (memory write on S2MM, memory read with correct video timing on MM2S) without needing the real Xilinx IP in simulation.

---

## Debug

An **Integrated Logic Analyzer (ILA)** is instantiated in the block diagram with four probe slots capturing all critical AXI Stream interfaces:

| ILA Slot | Signal | Description |
|----------|--------|-------------|
| SLOT_0 | `HDMI_S_AXIS` | Input video from HDMI RX (before switch) |
| SLOT_1 | `HDMI_M_AXIS` | Output video to HDMI TX (after switch) |
| SLOT_2 | `VDMA_AXIS_S2MM` | Capture path to VDMA (→ DDR4) |
| SLOT_3 | `VDMA_AXIS_MM2S` | Playback path from VDMA (← DDR4) |

Connect to the ILA from Vivado Hardware Manager after programming the FPGA to inspect frame timing, tvalid/tready handshakes, tuser (SOF), and tlast (EOL) in real time.

A second ILA (`ila_vdma`) is also instantiated specifically for the VDMA AXI4-Lite configuration bus, allowing verification of the register-write startup sequence from `vdma_ctrl`.

---

## Repository Structure

```
zcu102_hdmi_example/
├── Makefile                            # Top-level build automation
├── run.do                              # ModelSim simulation script
├── scripts/
│   ├── create_project.tcl              # Vivado project creation
│   ├── create_root_design.tcl          # Block diagram (IPs + connections)
│   ├── gen_hw_platform.tcl             # Synthesis + implementation + XSA export
│   ├── create_vitis_project.py         # Vitis platform & application setup
│   ├── phys_opt_design.tcl             # Post-synthesis physical optimization
│   ├── postroute_phys_opt_design.tcl   # Post-route physical optimization
│   └── route_design.tcl                # Routing script
├── src/
│   ├── constraints/
│   │   └── hdmi_example_zcu102.xdc     # ZCU102 pin assignments & timing
│   ├── data/
│   │   └── image.mem                   # Golden test image (960×1080, simulation)
│   ├── ip/
│   │   ├── ddr4/ddr4_0.xci             # DDR4 MIG controller configuration
│   │   └── ila_vdma/ila_vdma.xci       # ILA for VDMA debug
│   ├── rtl/
│   │   ├── vdma_frame_buffer_top.vhd   # Top-level wrapper
│   │   ├── vdma_frame_buffer.vhd       # AXI Stream switch (3 modes)
│   │   └── vdma_ctrl.vhd               # AXI4-Lite VDMA config master
│   ├── tb/
│   │   ├── vdma_frame_buffer_tb.sv     # Self-checking testbench
│   │   └── vdma_model.sv               # Behavioral VDMA model for simulation
│   └── hdmi_demo_app/src/              # Vitis C application (HDMI menu, HDCP, audio)
└── simlib/xpm/                         # Xilinx Primitive Models for simulation
```

---

## Known Limitations

- **Single frame buffer:** Only one frame is stored in DDR4. Save mode continuously overwrites the same frame.
- **No frame synchronization:** The VDMA runs continuously in circular mode; there is no explicit frame sync between HDMI timing and VDMA frame boundaries. A torn frame may be captured if `sw_save` is toggled mid-frame.
- **Fixed resolution:** The VDMA is configured for 1920×1080 at startup. Connecting a source at a different resolution will result in incorrect frame capture.
- **DDR4 dependency:** Playback mode produces undefined output if the DDR4 has not been written at least once after power-on.
