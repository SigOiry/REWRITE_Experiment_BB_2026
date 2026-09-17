"""Build cached, full-extent web previews; never modify the scientific GeoTIFFs."""
from pathlib import Path
import calendar
import hashlib
import json
import math
import re

import numpy as np
from PIL import Image
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import Affine, from_bounds
from rasterio.warp import reproject, transform_bounds

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/drone/generated"
MAX_EDGE = 2048
VERSION = "2"
PATTERN = re.compile(r"^(Stable|Unstable)_(\d{2})(\d{4})_(RGB|NDVI)\.tif$", re.I)
STOPS = [(0.0, "#201158"), (0.1, "#003E5F"), (0.2, "#005E5E"),
         (0.3, "#00784C"), (0.4, "#578B21"), (0.5, "#A89800"),
         (0.6, "#E89E6B"), (0.7, "#FFADC1"), (0.8, "#FFCEF4")]


def ndvi_rgba(values):
    valid = np.isfinite(values)
    colors = np.array([[int(color[i:i+2], 16) for i in (1, 3, 5)]
                       for _, color in STOPS])
    rgba = np.zeros((*values.shape, 4), dtype="uint8")
    # Clamp valid observations to the common display interval. Scientific values
    # remain unchanged in the source rasters and quantitative analyses.
    safe = np.clip(np.where(valid, values, 0), STOPS[0][0], STOPS[-1][0])
    for channel in range(3):
        rgba[:, :, channel] = np.rint(np.interp(safe, [s[0] for s in STOPS], colors[:, channel]))
    rgba[:, :, 3] = valid * 255
    return rgba


def preview(source, kind, target):
    with rasterio.open(source) as src:
        if src.crs is None:
            raise ValueError(f"Missing CRS: {source}")
        if kind == "RGB" and (src.count < 3 or src.dtypes[0] != "uint8"):
            raise ValueError(f"RGB preview requires byte RGB bands: {source}")
        # Read a bounded-size grid before reprojection; source footprint is retained.
        factor = max(1, max(src.width, src.height) / MAX_EDGE)
        w, h = max(1, math.ceil(src.width / factor)), max(1, math.ceil(src.height / factor))
        transform = src.transform * Affine.scale(src.width / w, src.height / h)
        mercator = transform_bounds(src.crs, "EPSG:3857", *src.bounds, densify_pts=41)
        left, bottom, right, top = mercator
        resolution = max(right-left, top-bottom) / min(MAX_EDGE, max(src.width, src.height))
        dw, dh = math.ceil((right-left)/resolution), math.ceil((top-bottom)/resolution)
        dst_transform = from_bounds(*mercator, dw, dh)
        kwargs = dict(src_transform=transform, src_crs=src.crs,
                      dst_transform=dst_transform, dst_crs="EPSG:3857", num_threads=2)
        if kind == "RGB":
            # Use the explicit alpha band rather than masking valid zero RGB channels.
            indexes = [1, 2, 3, 4] if src.count >= 4 else [1, 2, 3]
            small = src.read(indexes, out_shape=(len(indexes), h, w), resampling=Resampling.bilinear)
            if len(indexes) == 3:
                alpha = src.dataset_mask(out_shape=(h, w), resampling=Resampling.nearest)
                small = np.concatenate([small, alpha[None]], axis=0)
            output = np.zeros((4, dh, dw), dtype="uint8")
            reproject(small, output, src_alpha=4, dst_alpha=4,
                      resampling=Resampling.bilinear, **kwargs)
            rgba = output.transpose(1, 2, 0)
        else:
            small = src.read(1, out_shape=(h, w), resampling=Resampling.nearest).astype("float32")
            if src.nodata is not None:
                small[small == src.nodata] = np.nan
            small[~np.isfinite(small)] = np.nan
            output = np.full((dh, dw), np.nan, dtype="float32")
            reproject(small, output, src_nodata=np.nan, dst_nodata=np.nan,
                      resampling=Resampling.nearest, **kwargs)
            rgba = ndvi_rgba(output)
        if not np.any(rgba[:, :, 3]):
            raise ValueError(f"Preview contains no valid pixels: {source}")
        Image.fromarray(rgba).save(target, "WEBP", lossless=kind == "NDVI", quality=86, method=4)
        west, south, east, north = transform_bounds("EPSG:3857", "EPSG:4326", *mercator)
        return dict(bounds=[[south, west], [north, east]], source_crs=str(src.crs),
                    source_shape=[src.width, src.height], preview_shape=[dw, dh],
                    source_nodata="NaN" if src.nodata is not None and math.isnan(src.nodata) else src.nodata)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest_path = OUT / "manifest.json"
    previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    cached = {r["source"]: r for r in previous.get("maps", [])}
    records, keys = [], set()
    sources = sorted((ROOT / "Data/MS_DRONE").glob("*/*.tif"))
    for source in sources:
        match = PATTERN.fullmatch(source.name)
        if not match:
            continue
        site, month, year, kind = match.groups()
        site, kind = site.lower(), kind.upper()
        month_number = int(month)
        if not 1 <= month_number <= 12:
            raise ValueError(f"Invalid month: {source}")
        period = f"{year}-{month}"
        key = (site, period, kind)
        if key in keys:
            raise ValueError(f"Ambiguous duplicate product: {key}")
        keys.add(key)
        relative = source.relative_to(ROOT).as_posix()
        stat = source.stat()
        fingerprint = hashlib.sha256(f"{VERSION}:{MAX_EDGE}:{relative}:{stat.st_size}:{stat.st_mtime_ns}".encode()).hexdigest()[:12]
        image_name = f"{site}-{period}-{kind.lower()}-{fingerprint}.webp"
        target = OUT / image_name
        old = cached.get(relative)
        if old and old.get("fingerprint") == fingerprint and target.exists():
            records.append(old)
            continue
        print(f"Drone preview: {site} {period} {kind}", flush=True)
        metadata = preview(source, kind, target)
        records.append(dict(site=site, period=period, kind=kind,
                            label=f"{calendar.month_name[month_number]} {year}",
                            image=target.relative_to(ROOT).as_posix(), source=relative,
                            fingerprint=fingerprint, **metadata))
    if not records:
        raise ValueError("No monthly drone products found under Data/MS_DRONE.")
    records.sort(key=lambda r: (r["period"], r["site"], r["kind"]))
    manifest = dict(schema=2, max_preview_edge=MAX_EDGE, ndvi_scale="batlow",
                    ndvi_clamp=[STOPS[0][0], STOPS[-1][0]], ndvi_stops=STOPS,
                    maps=records)
    serialized = json.dumps(manifest, indent=2, allow_nan=False) + "\n"
    if not manifest_path.exists() or manifest_path.read_text() != serialized:
        manifest_path.write_text(serialized, encoding="utf-8")
    retained = {Path(record["image"]).name for record in records}
    for generated in OUT.glob("*.webp"):
        if generated.name not in retained:
            generated.unlink()
    print(f"Drone viewer: {len(records)} full-extent previews ready.", flush=True)


if __name__ == "__main__":
    main()
