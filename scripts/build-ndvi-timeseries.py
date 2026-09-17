"""Extract monthly drone NDVI within 10 cm of every experimental core."""
from __future__ import annotations

import hashlib
import json
import re
from datetime import date
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
import rasterio
from rasterio.mask import mask
from shapely.geometry import mapping


ROOT = Path(__file__).resolve().parents[1]
POINTS = ROOT / "Data/SHP/Points.shp"
RASTER_ROOT = ROOT / "Data/MS_DRONE"
OUT = ROOT / "assets/seagrass-cover/generated"
BUFFER_M = 0.10
VERSION = "1"
PATTERN = re.compile(r"^(Stable|Unstable)_(\d{2})(\d{4})_NDVI\.tif$", re.I)
EXPECTED = {f"{station}{core}{site}" for station in range(1, 7)
            for core in "AN" for site in "SU"}


def discover_rasters() -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    keys: set[tuple[str, str]] = set()
    for path in RASTER_ROOT.glob("*/*.tif"):
        match = PATTERN.fullmatch(path.name)
        if not match:
            continue
        site, month, year = match.groups()
        site = site.capitalize()
        period = date(int(year), int(month), 1).isoformat()
        key = site, period
        if key in keys:
            raise ValueError(f"Duplicate processed monthly NDVI raster: {key}")
        keys.add(key)
        records.append({"meadow": site, "period": period, "path": path})
    records.sort(key=lambda record: (record["period"], record["meadow"]))
    expected = {(site, f"2026-{month:02d}-01")
                for site in ("Stable", "Unstable") for month in range(6, 10)}
    if keys != expected:
        raise ValueError(f"Monthly NDVI coverage mismatch; missing={sorted(expected - keys)}, "
                         f"extra={sorted(keys - expected)}")
    return records


def sample_points() -> gpd.GeoDataFrame:
    points = gpd.read_file(POINTS)
    points = points[points["Name"].str.fullmatch(r"[1-6][AN][SU]", na=False)].copy()
    for code in ("5AU", "5NU"):
        indices = points.index[points["Name"].eq(code)].tolist()
        if len(indices) != 2:
            raise ValueError(f"Expected two source points named {code}; found {len(indices)}.")
        northern = max(indices, key=lambda index: points.loc[index].geometry.y)
        points.loc[northern, "Name"] = "6" + code[1:]
    if set(points["Name"]) != EXPECTED or len(points) != 24:
        raise ValueError("The corrected point layer does not contain the expected 24 cores.")
    return points


def extract_raster(points: gpd.GeoDataFrame, raster_record: dict[str, object]) -> list[dict[str, object]]:
    site = str(raster_record["meadow"])
    path = Path(raster_record["path"])
    selected = points[points["Name"].str.endswith(site[0])].copy()
    metric = selected.to_crs(32630)
    buffers = gpd.GeoSeries(metric.geometry.buffer(BUFFER_M), crs=32630)
    rows: list[dict[str, object]] = []
    with rasterio.open(path) as source:
        polygons = buffers.to_crs(source.crs)
        for sample_id, polygon in zip(selected["Name"], polygons):
            subset, _ = mask(source, [mapping(polygon)], crop=True,
                             all_touched=False, filled=False)
            values = subset[0].compressed().astype(float)
            values = values[np.isfinite(values)]
            match = re.fullmatch(r"(\d+)([AN])([SU])", sample_id)
            if not match:
                raise ValueError(f"Unexpected sample identifier: {sample_id}")
            station, core_code, _ = match.groups()
            rows.append({
                "sample_id": sample_id,
                "station": int(station),
                "core_code": core_code,
                "treatment": "Treatment" if core_code == "A" else "Control",
                "meadow": site,
                "period": raster_record["period"],
                "ndvi_mean": float(values.mean()) if len(values) else np.nan,
                "ndvi_sd": float(values.std(ddof=1)) if len(values) > 1 else np.nan,
                "ndvi_n_pixels": int(len(values)),
                "ndvi_raster": path.relative_to(ROOT).as_posix(),
            })
    return rows


def fingerprint(rasters: list[dict[str, object]]) -> str:
    inputs = [Path(record["path"]) for record in rasters]
    inputs.extend(sorted(POINTS.parent.glob(f"{POINTS.stem}.*")))
    parts = [VERSION, str(BUFFER_M)]
    for path in inputs:
        stat = path.stat()
        parts.extend((path.relative_to(ROOT).as_posix(), str(stat.st_size), str(stat.st_mtime_ns)))
    return hashlib.sha256("|".join(parts).encode()).hexdigest()


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rasters = discover_rasters()
    output = OUT / "ndvi-timeseries.csv"
    manifest_path = OUT / "ndvi-timeseries-manifest.json"
    current = fingerprint(rasters)
    if output.exists() and manifest_path.exists():
        previous = json.loads(manifest_path.read_text(encoding="utf-8"))
        if previous.get("fingerprint") == current:
            print("NDVI time series: cached 96-observation extraction ready.")
            return

    points = sample_points()
    rows: list[dict[str, object]] = []
    for raster_record in rasters:
        rows.extend(extract_raster(points, raster_record))
    data = pd.DataFrame(rows).sort_values(["period", "meadow", "station", "core_code"])
    if len(data) != 96:
        raise ValueError(f"Expected 96 core-month records; found {len(data)}.")
    data.to_csv(output, index=False, float_format="%.8f")
    manifest = {
        "schema": 1,
        "fingerprint": current,
        "buffer_radius_m": BUFFER_M,
        "months": sorted(data["period"].unique().tolist()),
        "records": int(len(data)),
        "missing_ndvi": int(data["ndvi_mean"].isna().sum()),
        "treatment_codes": {"N": "Control", "A": "Treatment"},
        "station_name_correction": "northern duplicate 5AU/5NU pair assigned to station 6",
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"NDVI time series: {len(data)} core-month records; "
          f"{manifest['missing_ndvi']} missing NDVI values.", flush=True)


if __name__ == "__main__":
    main()
