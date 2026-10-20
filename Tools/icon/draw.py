# Draws MacBeeb's icon layers (1024x1024 PNGs) for Resources/AppIcon.icon:
# the BASIC prompt in the SAA5050's ">" and a Mode 7 cursor, over a band of
# the BBC Micro's case with its red function keys. Also a flat preview.
#
#   python3 Tools/icon/draw.py OUTDIR

import sys
from PIL import Image, ImageDraw

S = 1024
out = sys.argv[1]

# The SAA5050's ">" (bit 0 leftmost), rows 0-9 of its 6x10 cell.
GT = [0x00, 0x04, 0x08, 0x10, 0x20, 0x10, 0x08, 0x04, 0x00, 0x00]
U = 56                      # one teletext pixel
# Two cells, ">" (in columns 2-5 of its) and the cursor, centred on what's
# drawn.
LEFT = (S - 10 * U) // 2 - 2 * U
TOP = 70
WHITE = (255, 255, 255, 255)

prompt = Image.new("RGBA", (S, S))
d = ImageDraw.Draw(prompt)
on = lambda r, c: 0 <= r < 10 and 0 <= c < 6 and GT[r] >> c & 1
for r in range(10):
    for c in range(6):
        if on(r, c):
            x, y = LEFT + c * U, TOP + r * U
            d.rectangle([x, y, x + U - 1, y + U - 1], fill=WHITE)
            # The SAA5050's character rounding: half-pixel steps fill the
            # corners between diagonal neighbours.
            for dr, dc in ((1, 1), (1, -1)):
                if on(r + dr, c + dc) and not on(r + dr, c) and not on(r, c + dc):
                    h = U // 2
                    if dc == 1:
                        d.rectangle([x + U, y + U - h, x + U + h - 1, y + U - 1], fill=WHITE)
                        d.rectangle([x + U - h, y + U, x + U - 1, y + U + h - 1], fill=WHITE)
                    else:
                        d.rectangle([x - h, y + U - h, x - 1, y + U - 1], fill=WHITE)
                        d.rectangle([x, y + U, x + h - 1, y + U + h - 1], fill=WHITE)
# The cursor: the next cell's bottom row.
cx, cy = LEFT + 6 * U, TOP + 9 * U
d.rectangle([cx, cy, cx + 6 * U - 1, cy + U - 1], fill=WHITE)
prompt.save(f"{out}/prompt.png")

# The case: cream, a row of red function keys, the black keys below.
CASE = (232, 221, 196, 255)
RED = (214, 64, 44, 255)
BLACK = (40, 38, 36, 255)
keys = Image.new("RGBA", (S, S))
d = ImageDraw.Draw(keys)
BAND = 690
d.rectangle([0, BAND, S, S], fill=CASE)
n, w, gap = 5, 150, 22
x0 = (S - (n * w + (n - 1) * gap)) // 2
for i in range(n):
    x = x0 + i * (w + gap)
    d.rounded_rectangle([x, BAND + 60, x + w, BAND + 170], radius=20, fill=RED)
# Staggered by half a key, as on the keyboard.
for i in range(n - 1):
    x = x0 + i * (w + gap) + (w + gap) // 2
    d.rounded_rectangle([x, BAND + 200, x + w, BAND + 310], radius=20, fill=BLACK)
keys.save(f"{out}/keys.png")

# A flat preview, masked to a rounded square.
preview = Image.new("RGBA", (S, S), (0, 0, 0, 0))
screen = Image.new("RGBA", (S, S), (18, 20, 26, 255))
screen.alpha_composite(prompt)
screen.alpha_composite(keys)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=230, fill=255)
preview.paste(screen, (0, 0), mask)
preview.save(f"{out}/preview.png")
