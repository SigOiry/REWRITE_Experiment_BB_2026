import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build-ndvi-timeseries.py"
SPEC = importlib.util.spec_from_file_location("build_ndvi_timeseries", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NdviTimeSeriesTests(unittest.TestCase):
    def test_discovers_complete_processed_june_to_september_series(self):
        rasters = MODULE.discover_rasters()
        self.assertEqual(len(rasters), 8)
        self.assertEqual(sorted({record["period"] for record in rasters}), [
            "2026-06-01", "2026-07-01", "2026-08-01", "2026-09-01"
        ])
        self.assertEqual({record["meadow"] for record in rasters}, {"Stable", "Unstable"})


if __name__ == "__main__":
    unittest.main()
