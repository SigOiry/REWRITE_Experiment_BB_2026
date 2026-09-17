"""Extract September NDVI around sample points and fit a bounded cover model."""
from __future__ import annotations

import csv
import hashlib
import json
import math
import re
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
import rasterio
from rasterio.mask import mask
from scipy.optimize import curve_fit
from shapely.geometry import mapping


ROOT = Path(__file__).resolve().parents[1]
POINTS = ROOT / "Data/SHP/Points.shp"
COVER = ROOT / "assets/seagrass-cover/generated/seagrass-cover.csv"
OUT = ROOT / "assets/seagrass-cover/generated"
BUFFER_M = 0.10
VERSION = "1"
RASTERS = {
    "Stable": ROOT / "Data/MS_DRONE/REWRITE_Jim_08092026_Stable/Stable_092026_NDVI.tif",
    "Unstable": ROOT / "Data/MS_DRONE/REWRITE_Jim_08092026_Unstable/Unstable_092026_NDVI.tif",
}
EXPECTED = {f"{station}{core}{site}" for station in range(1, 7)
            for core in "AN" for site in "SU"}


def logistic(ndvi: np.ndarray | float, intercept: float, slope: float) -> np.ndarray:
    values = np.asarray(ndvi, dtype=float)
    return 100.0 / (1.0 + np.exp(-(intercept + slope * values)))


def sample_points() -> gpd.GeoDataFrame:
    points = gpd.read_file(POINTS)
    points = points[points["Name"].str.fullmatch(r"[1-6][AN][SU]", na=False)].copy()
    # The source layer contains two 5AU/5NU pairs and no 6AU/6NU pair. The
    # northern duplicate is the distinct sixth spatial group and is relabelled.
    for code in ("5AU", "5NU"):
        indices = points.index[points["Name"].eq(code)].tolist()
        if len(indices) != 2:
            raise ValueError(f"Expected two source points named {code}; found {len(indices)}.")
        northern = max(indices, key=lambda index: points.loc[index].geometry.y)
        points.loc[northern, "Name"] = "6" + code[1:]
    names = set(points["Name"])
    if names != EXPECTED or len(points) != 24:
        missing = sorted(EXPECTED - names)
        extra = sorted(names - EXPECTED)
        raise ValueError(f"Sample-point mismatch; missing={missing}, extra={extra}.")
    return points


def extract_site(points: gpd.GeoDataFrame, site: str, path: Path) -> list[dict[str, object]]:
    selected = points[points["Name"].str.endswith(site[0])].copy()
    metric = selected.to_crs(32630)
    buffers = gpd.GeoSeries(metric.geometry.buffer(BUFFER_M), crs=32630)
    records: list[dict[str, object]] = []
    with rasterio.open(path) as source:
        raster_buffers = buffers.to_crs(source.crs)
        for sample_id, point, polygon in zip(selected["Name"], selected.geometry, raster_buffers):
            subset, _ = mask(source, [mapping(polygon)], crop=True,
                             all_touched=False, filled=False)
            values = subset[0].compressed().astype(float)
            values = values[np.isfinite(values)]
            if not len(values):
                raise ValueError(f"No valid NDVI pixels within {BUFFER_M} m of {sample_id}.")
            records.append({
                "sample_id": sample_id,
                "longitude": point.x,
                "latitude": point.y,
                "ndvi_mean": float(values.mean()),
                "ndvi_sd": float(values.std(ddof=1)) if len(values) > 1 else 0.0,
                "ndvi_n_pixels": int(len(values)),
                "ndvi_raster": path.relative_to(ROOT).as_posix(),
            })
    return records


def fit_model(data: pd.DataFrame) -> tuple[dict[str, float | int | str], pd.DataFrame]:
    x = data["ndvi_mean"].to_numpy(dtype=float)
    y = data["seagrass_cover_pct"].to_numpy(dtype=float)
    coefficients, covariance = curve_fit(logistic, x, y, p0=(-3.0, 5.0), maxfev=20_000)
    intercept, slope = (float(value) for value in coefficients)
    fitted = logistic(x, intercept, slope)
    residuals = y - fitted
    rss = float(np.sum(residuals**2))
    tss = float(np.sum((y - y.mean())**2))
    r_squared = 1.0 - rss / tss
    rmse = math.sqrt(float(np.mean(residuals**2)))

    grid = np.linspace(float(x.min()), float(x.max()), 200)
    predicted = logistic(grid, intercept, slope)
    proportion = predicted / 100.0
    gradient = np.column_stack((100 * proportion * (1 - proportion),
                                100 * proportion * (1 - proportion) * grid))
    variance = np.einsum("ij,jk,ik->i", gradient, covariance, gradient)
    standard_error = np.sqrt(np.maximum(variance, 0))
    curve = pd.DataFrame({
        "ndvi": grid,
        "spc_fitted": predicted,
        "spc_lower_95": np.clip(predicted - 1.96 * standard_error, 0, 100),
        "spc_upper_95": np.clip(predicted + 1.96 * standard_error, 0, 100),
    })
    model = {
        "model": "two-parameter logistic",
        "intercept": intercept,
        "slope": slope,
        "r_squared": r_squared,
        "rmse_percentage_points": rmse,
        "n": int(len(data)),
        "ndvi_min": float(x.min()),
        "ndvi_max": float(x.max()),
        "buffer_radius_m": BUFFER_M,
        "equation": "SPC = 100 / (1 + exp(-(intercept + slope * NDVI)))",
    }
    return model, curve


def fingerprint() -> str:
    inputs = [COVER, *RASTERS.values()]
    inputs.extend(sorted(POINTS.parent.glob(f"{POINTS.stem}.*")))
    parts = [VERSION, str(BUFFER_M)]
    for path in inputs:
        stat = path.stat()
        parts.extend((path.relative_to(ROOT).as_posix(), str(stat.st_size), str(stat.st_mtime_ns)))
    return hashlib.sha256("|".join(parts).encode()).hexdigest()


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    manifest_path = OUT / "ndvi-calibration-manifest.json"
    outputs = [OUT / "ndvi-calibration.csv", OUT / "ndvi-model.csv", OUT / "ndvi-curve.csv"]
    current = fingerprint()
    if manifest_path.exists() and all(path.exists() for path in outputs):
        previous = json.loads(manifest_path.read_text(encoding="utf-8"))
        if previous.get("fingerprint") == current:
            print("NDVI calibration: cached 24-sample extraction ready.")
            return

    points = sample_points()
    extracted: list[dict[str, object]] = []
    for site, path in RASTERS.items():
        extracted.extend(extract_site(points, site, path))
    cover = pd.read_csv(COVER)
    data = cover.merge(pd.DataFrame(extracted), on="sample_id", validate="one_to_one")
    if len(data) != 24:
        raise ValueError(f"Expected 24 matched cover–NDVI observations; found {len(data)}.")
    data = data.sort_values(["station", "core_code", "meadow"]).reset_index(drop=True)
    model, curve = fit_model(data)
    data["spc_fitted"] = logistic(data["ndvi_mean"], model["intercept"], model["slope"])
    data.to_csv(outputs[0], index=False, float_format="%.8f")
    pd.DataFrame([model]).to_csv(outputs[1], index=False, float_format="%.8f")
    curve.to_csv(outputs[2], index=False, float_format="%.8f")
    manifest = {
        "schema": 1,
        "fingerprint": current,
        "station_name_correction": {
            "source_issue": "two 5AU/5NU pairs and no 6AU/6NU pair",
            "rule": "relabel northern duplicate pair as station 6",
        },
        "extraction": "mean of valid raster pixels whose centres fall within each 0.10 m buffer",
        "model": model,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        "NDVI calibration: 24 samples; "
        f"SPC = 100 / (1 + exp(-({model['intercept']:.4f} + {model['slope']:.4f} * NDVI))); "
        f"R2 = {model['r_squared']:.3f}.",
        flush=True,
    )


if __name__ == "__main__":
    main()
