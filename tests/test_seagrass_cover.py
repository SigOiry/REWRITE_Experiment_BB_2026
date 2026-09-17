import importlib.util
import unittest
from pathlib import Path

import numpy as np


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/estimate-seagrass-cover.py"
SPEC = importlib.util.spec_from_file_location("estimate_seagrass_cover", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SeagrassCoverTests(unittest.TestCase):
    def test_circle_fit_recovers_partially_clipped_boundary(self):
        height, width = 120, 140
        cx, cy, radius = 120.0, 100.0, 75.0
        y, x = np.ogrid[:height, :width]
        boundary = np.abs(np.hypot(x - cx, y - cy) - radius) <= 1.5
        fitted = MODULE.fit_circle(boundary)
        self.assertAlmostEqual(fitted[0], cx, delta=0.5)
        self.assertAlmostEqual(fitted[1], cy, delta=0.5)
        self.assertAlmostEqual(fitted[2], radius, delta=0.5)

    def test_green_rule_uses_green_channel_dominance(self):
        pixels = np.array([[[50, 90, 60], [95, 100, 96], [90, 70, 50], [40, 80, 95]]], dtype=np.uint8)
        result = MODULE.green_pixels(pixels)[0].tolist()
        self.assertEqual(result, [True, True, False, False])


if __name__ == "__main__":
    unittest.main()
