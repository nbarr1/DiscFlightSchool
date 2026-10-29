#!/usr/bin/env python3
"""Write the fixture that checks the app's port of Pillow's bilinear resize.

Roboflow's RF-DETR preprocessing resizes each frame with
`PIL.Image.resize(..., Image.BILINEAR)`. RfDetrInputTest resizes the same
random images with the Kotlin port and expects identical bytes.

    pip install pillow numpy
    python scripts/generate_pil_resize_fixture.py \
        disc_golf_android/core/src/test/resources/pil_resize_fixture.json
"""

from __future__ import annotations

import json
import sys

import numpy as np
from PIL import Image

CASES = [((61, 47), (20, 13)), ((61, 47), (97, 80)), ((40, 30), (40, 12)), ((33, 64), (90, 90)), ((160, 90), (48, 48))]


def main() -> int:
    rng = np.random.default_rng(7)
    cases = []
    for (width, height), (out_width, out_height) in CASES:
        pixels = rng.integers(0, 256, size=(height, width, 3), dtype=np.uint8)
        resized = np.asarray(Image.fromarray(pixels).resize((out_width, out_height), Image.BILINEAR))
        cases.append(
            {
                "width": width,
                "height": height,
                "outWidth": out_width,
                "outHeight": out_height,
                "pixels": pixels.reshape(-1).tolist(),
                "resized": resized.reshape(-1).tolist(),
            }
        )
    with open(sys.argv[1], "w") as handle:
        json.dump({"cases": cases}, handle)
    return 0


if __name__ == "__main__":
    sys.exit(main())
