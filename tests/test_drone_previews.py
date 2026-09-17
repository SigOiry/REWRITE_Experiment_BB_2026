"""Check geographic extent and masking with small synthetic scientific rasters."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image
import rasterio
from rasterio.enums import ColorInterp
from rasterio.transform import from_bounds
from rasterio.warp import transform_bounds

spec = importlib.util.spec_from_file_location("builder", Path(__file__).resolve().parents[1] / "scripts/build-drone-viewer.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class PreviewTests(unittest.TestCase):
    def test_ndvi_mask_scale_and_full_extent(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / "ndvi.tif", Path(tmp) / "ndvi.webp"
            data = np.tile(np.array([-1, 0, 0.4, 0.8, 1.1, np.nan, -999], dtype="float32"), (7, 1))
            bounds = (-242000, 5935000, -241930, 5935070)
            with rasterio.open(source, "w", driver="GTiff", width=7, height=7, count=1,
                               dtype="float32", crs="EPSG:3857", nodata=-999,
                               transform=from_bounds(*bounds, 7, 7)) as dst:
                dst.write(data, 1)
            record = builder.preview(source, "NDVI", output)
            west, south, east, north = transform_bounds("EPSG:3857", "EPSG:4326", *bounds)
            np.testing.assert_allclose(record["bounds"], [[south, west], [north, east]])
            rgba = np.array(Image.open(output).convert("RGBA"))
            np.testing.assert_array_equal(rgba[2, :, 3], [255, 255, 255, 255, 255, 0, 0])
            np.testing.assert_array_equal(
                rgba[2, :5, :3],
                [[32, 17, 88], [32, 17, 88], [87, 139, 33], [255, 206, 244], [255, 206, 244]],
            )

    def test_rgb_zero_channels_do_not_override_alpha(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / "rgb.tif", Path(tmp) / "rgb.webp"
            rgba = np.zeros((4, 16, 16), dtype="uint8")
            rgba[1] = 150
            rgba[3, :, :8] = 255
            with rasterio.open(source, "w", driver="GTiff", width=16, height=16, count=4,
                               dtype="uint8", crs="EPSG:4326", nodata=0,
                               transform=from_bounds(-2.18, 46.96, -2.179, 46.961, 16, 16)) as dst:
                dst.write(rgba)
                dst.colorinterp = (ColorInterp.red, ColorInterp.green, ColorInterp.blue, ColorInterp.alpha)
            record = builder.preview(source, "RGB", output)
            rendered = np.array(Image.open(output).convert("RGBA"))
            self.assertEqual(rendered[5, 2, 3], 255)
            self.assertEqual(rendered[5, -2, 3], 0)
            np.testing.assert_allclose(record["bounds"], [[46.96, -2.18], [46.961, -2.179]], atol=1e-8)


if __name__ == "__main__":
    unittest.main()
