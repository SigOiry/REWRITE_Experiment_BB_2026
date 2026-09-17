import importlib.util
import unittest
from pathlib import Path

import numpy as np
import pandas as pd


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build-ndvi-calibration.py"
SPEC = importlib.util.spec_from_file_location("build_ndvi_calibration", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NdviCalibrationTests(unittest.TestCase):
    def test_logistic_cover_is_bounded_and_increases_for_positive_slope(self):
        ndvi = np.linspace(-1, 1, 50)
        cover = MODULE.logistic(ndvi, -3, 5)
        self.assertTrue(np.all((cover > 0) & (cover < 100)))
        self.assertTrue(np.all(np.diff(cover) > 0))

    def test_model_returns_curve_over_observed_domain(self):
        data = pd.DataFrame({
            "ndvi_mean": np.linspace(0.1, 0.8, 12),
            "seagrass_cover_pct": MODULE.logistic(np.linspace(0.1, 0.8, 12), -3, 5),
        })
        model, curve = MODULE.fit_model(data)
        self.assertEqual(model["n"], 12)
        self.assertAlmostEqual(curve["ndvi"].iloc[0], 0.1)
        self.assertAlmostEqual(curve["ndvi"].iloc[-1], 0.8)
        self.assertTrue(np.all(curve["spc_lower_95"] <= curve["spc_upper_95"]))


if __name__ == "__main__":
    unittest.main()
