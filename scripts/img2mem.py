#!/usr/bin/env python3
"""
img2mem.py - Convert an image to a .mem hex file for BRAM initialization.

Generates a file compatible with the bram_image_streamer VHDL module.
Each line contains a 12-digit hex value representing 2 pixels (48 bits):
  Bits [47:24] = Pixel 0 (R[23:16], G[15:8], B[7:0])
  Bits [23:0]  = Pixel 1 (R[23:16], G[15:8], B[7:0])

Output: 1,036,800 lines (960 pixel-pairs/line x 1080 lines)

Usage:
    python3 img2mem.py <input_image> <output.mem>

Requirements:
    pip install Pillow
"""

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Error: Pillow is required. Install with: pip install Pillow",
          file=sys.stderr)
    sys.exit(1)

# Target resolution
H_PIXELS = 1920
V_LINES = 1080
PIXELS_PER_CLK = 2


def convert_image_to_mem(input_path: str, output_path: str) -> None:
    """Convert an image file to a .mem hex file for BRAM initialization."""

    # Load and prepare image
    img = Image.open(input_path)
    img = img.convert("RGB")

    if img.size != (H_PIXELS, V_LINES):
        print(f"Resizing image from {img.size[0]}x{img.size[1]} "
              f"to {H_PIXELS}x{V_LINES}")
        img = img.resize((H_PIXELS, V_LINES), Image.LANCZOS)

    pixels = img.load()
    clks_per_line = H_PIXELS // PIXELS_PER_CLK
    total_lines_written = 0

    with open(output_path, "w") as f:
        for y in range(V_LINES):
            for x_pair in range(clks_per_line):
                # Pixel 0 (stored in upper 24 bits)
                x0 = x_pair * PIXELS_PER_CLK
                r0, g0, b0 = pixels[x0, y]

                # Pixel 1 (stored in lower 24 bits)
                x1 = x0 + 1
                r1, g1, b1 = pixels[x1, y]

                # Pack into 48-bit value: [R0 G0 B0 R1 G1 B1]
                value = (r0 << 40) | (g0 << 32) | (b0 << 24) | \
                        (r1 << 16) | (g1 << 8) | b1

                f.write(f"{value:012X}\n")
                total_lines_written += 1

    print(f"Done: {total_lines_written} entries written to {output_path}")
    print(f"  Resolution: {H_PIXELS}x{V_LINES}")
    print(f"  Pixel pairs per line: {clks_per_line}")
    print(f"  Total memory: {total_lines_written * 6 / 1024 / 1024:.2f} MB")


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input_image> <output.mem>")
        print()
        print("Supported image formats: PNG, JPEG, BMP, TIFF, etc.")
        print("Image will be resized to 1920x1080 if needed.")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    if not Path(input_path).is_file():
        print(f"Error: Input file not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    convert_image_to_mem(input_path, output_path)


if __name__ == "__main__":
    main()
