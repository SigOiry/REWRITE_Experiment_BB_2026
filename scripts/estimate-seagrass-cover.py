"""Estimate seagrass cover inside the red sample boundaries in field photographs."""
from __future__ import annotations

import csv
import hashlib
import json
import math
import re
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
PHOTO_DIR = ROOT / "Data/Sept_2026/Quadrat_September2026"
RAW_DIR = PHOTO_DIR / "RAW"
OUT = ROOT / "assets/seagrass-cover/generated"
VERSION = "2"
SAMPLE_PATTERN = re.compile(r"^(\d+)([AN])([SU])$")
BOUNDARY_INSET_PX = 4.0
MAX_QC_EDGE = 1100


def sample_key(path: Path) -> tuple[int, str, str]:
    match = SAMPLE_PATTERN.fullmatch(path.stem)
    if not match:
        raise ValueError(f"Unexpected sample filename: {path.name}")
    return int(match.group(1)), match.group(2), match.group(3)


def red_boundary(rgb: np.ndarray) -> np.ndarray:
    """Return the strongly red annotation pixels."""
    r, g, b = (rgb[..., i].astype(np.float32) for i in range(3))
    return (r > 180) & (g < 140) & (r > 1.7 * g) & (r > 1.7 * b)


def fit_circle(boundary: np.ndarray) -> tuple[float, float, float, float]:
    """Fit x²+y²=2*cx*x+2*cy*y+c to a possibly clipped circular ring."""
    y, x = np.nonzero(boundary)
    if len(x) < 200:
        raise ValueError(f"Too few red boundary pixels ({len(x):,}).")
    stride = max(1, len(x) // 15_000)
    x_fit = x[::stride].astype(np.float64)
    y_fit = y[::stride].astype(np.float64)
    design = np.column_stack((2 * x_fit, 2 * y_fit, np.ones_like(x_fit)))
    response = x_fit * x_fit + y_fit * y_fit
    cx, cy, constant = np.linalg.lstsq(design, response, rcond=None)[0]
    radius = math.sqrt(constant + cx * cx + cy * cy)
    residual = np.abs(np.hypot(x - cx, y - cy) - radius)
    median_residual = float(np.median(residual))
    if median_residual > 6:
        raise ValueError(f"Red boundary is not circular (median residual {median_residual:.1f} px).")
    return float(cx), float(cy), float(radius), median_residual


def green_pixels(rgb: np.ndarray) -> np.ndarray:
    """Classify pixels for which green is the dominant RGB channel."""
    r, g, b = (rgb[..., i] for i in range(3))
    return (g > r) & (g > b)


def analysis_mask(shape: tuple[int, int], cx: float, cy: float, radius: float) -> np.ndarray:
    y, x = np.ogrid[: shape[0], : shape[1]]
    inner_radius = radius - BOUNDARY_INSET_PX
    return (x - cx) ** 2 + (y - cy) ** 2 <= inner_radius**2


def qc_image(raw: np.ndarray, roi: np.ndarray, vegetation: np.ndarray,
             circle: tuple[float, float, float], target: Path) -> None:
    """Save a cropped mask overlay; magenta denotes classified seagrass."""
    cx, cy, radius = circle
    display = raw.copy()
    display[~roi] = np.rint(display[~roi] * 0.25 + 190 * 0.75).astype(np.uint8)
    highlight = np.array([255, 0, 210], dtype=np.float32)
    selected = roi & vegetation
    display[selected] = np.rint(display[selected] * 0.30 + highlight * 0.70).astype(np.uint8)
    image = Image.fromarray(display)
    draw = ImageDraw.Draw(image)
    inner_radius = radius - BOUNDARY_INSET_PX
    draw.ellipse((cx - inner_radius, cy - inner_radius,
                  cx + inner_radius, cy + inner_radius),
                 outline=(255, 35, 35), width=10)
    margin = 24
    left = max(0, math.floor(cx - inner_radius - margin))
    top = max(0, math.floor(cy - inner_radius - margin))
    right = min(image.width, math.ceil(cx + inner_radius + margin))
    bottom = min(image.height, math.ceil(cy + inner_radius + margin))
    image = image.crop((left, top, right, bottom))
    image.thumbnail((MAX_QC_EDGE, MAX_QC_EDGE), Image.Resampling.LANCZOS)
    image.save(target, "WEBP", quality=88, method=4)


def write_table(records: list[dict[str, object]]) -> None:
    columns = ["sample_id", "station", "core_code", "meadow", "total_pixels",
               "seagrass_pixels", "seagrass_cover_pct", "circle_observed_pct", "quality_flag"]
    with (OUT / "seagrass-cover.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows({column: record[column] for column in columns} for record in records)

    rows = []
    for record in records:
        rows.append(
            "<tr>"
            f"<td>{record['sample_id']}</td><td>{record['station']}</td>"
            f"<td>{record['core_code']}</td><td>{record['meadow']}</td>"
            f"<td>{record['seagrass_cover_pct']:.1f}</td>"
            "</tr>"
        )
    html = (
        '<div class="cover-table-wrap"><table class="cover-table">'
        "<thead><tr><th>Sample</th><th>Station</th><th>Core code</th><th>Meadow</th>"
        "<th>Seagrass cover (%)</th>"
        "</tr></thead><tbody>" + "".join(rows) + "</tbody></table></div>\n"
    )
    (OUT / "table.html").write_text(html, encoding="utf-8")


def write_gallery(records: list[dict[str, object]]) -> None:
    figures = []
    for record in records:
        figures.append(
            '<figure class="cover-mask">'
            f'<img src="{record["qc_image"]}" '
            f'alt="Sample {record["sample_id"]}; classified seagrass pixels are highlighted in magenta." '
            'loading="lazy">'
            f'<figcaption><strong>{record["sample_id"]}</strong> · '
            f'{record["seagrass_cover_pct"]:.1f}% seagrass cover</figcaption></figure>'
        )
    (OUT / "gallery.html").write_text(
        '<div class="cover-gallery">' + "".join(figures) + "</div>\n", encoding="utf-8"
    )


def input_fingerprint(marked: list[Path]) -> str:
    parts = [VERSION, str(BOUNDARY_INSET_PX)]
    for path in marked:
        raw = RAW_DIR / f"{path.stem}.jpg"
        for item in (path, raw):
            stat = item.stat()
            parts.extend((item.relative_to(ROOT).as_posix(), str(stat.st_size), str(stat.st_mtime_ns)))
    return hashlib.sha256("|".join(parts).encode()).hexdigest()


def main() -> None:
    marked = sorted(PHOTO_DIR.glob("*.png"), key=sample_key)
    if not marked:
        raise ValueError(f"No marked quadrat photographs found in {PHOTO_DIR}")
    OUT.mkdir(parents=True, exist_ok=True)
    fingerprint = input_fingerprint(marked)
    manifest_path = OUT / "manifest.json"
    required = [OUT / "seagrass-cover.csv", OUT / "table.html", OUT / "gallery.html"]
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text(encoding="utf-8"))
        previous_images = [ROOT / record["qc_image"] for record in previous.get("samples", [])]
        if previous.get("fingerprint") == fingerprint and all(p.exists() for p in required + previous_images):
            write_table(previous["samples"])
            write_gallery(previous["samples"])
            print(f"Seagrass cover: {len(previous_images)} cached sample classifications ready.")
            return

    records: list[dict[str, object]] = []
    for marked_path in marked:
        station, core_code, meadow_code = sample_key(marked_path)
        raw_path = RAW_DIR / f"{marked_path.stem}.jpg"
        if not raw_path.exists():
            raise FileNotFoundError(f"Missing raw photograph: {raw_path}")
        marked_rgb = np.asarray(Image.open(marked_path).convert("RGB"))
        raw_rgb = np.asarray(Image.open(raw_path).convert("RGB"))
        if marked_rgb.shape != raw_rgb.shape:
            raise ValueError(f"Marked and raw photographs are not aligned: {marked_path.stem}")
        cx, cy, radius, residual = fit_circle(red_boundary(marked_rgb))
        roi = analysis_mask(raw_rgb.shape[:2], cx, cy, radius)
        vegetation = green_pixels(raw_rgb)
        total = int(roi.sum())
        green = int((roi & vegetation).sum())
        expected_area = math.pi * (radius - BOUNDARY_INSET_PX) ** 2
        observed = min(100.0, 100.0 * total / expected_area)
        qc_relative = Path("assets/seagrass-cover/generated") / f"{marked_path.stem}-classified.webp"
        qc_image(raw_rgb, roi, vegetation, (cx, cy, radius), ROOT / qc_relative)
        record = {
            "sample_id": marked_path.stem,
            "station": station,
            "core_code": core_code,
            "meadow": "Stable" if meadow_code == "S" else "Unstable",
            "total_pixels": total,
            "seagrass_pixels": green,
            "seagrass_cover_pct": round(100.0 * green / total, 2),
            "circle_observed_pct": round(observed, 2),
            "quality_flag": "ok" if observed >= 98.0 else "partial_circle",
            "circle_center_x_px": round(cx, 2),
            "circle_center_y_px": round(cy, 2),
            "circle_radius_px": round(radius - BOUNDARY_INSET_PX, 2),
            "circle_fit_median_residual_px": round(residual, 2),
            "qc_image": qc_relative.as_posix(),
        }
        records.append(record)
        print(f"Seagrass cover: {marked_path.stem} = {record['seagrass_cover_pct']:.2f}%", flush=True)

    write_table(records)
    write_gallery(records)
    manifest = {
        "schema": 1,
        "fingerprint": fingerprint,
        "method": {
            "green_rule": "G > R and G > B",
            "boundary_inset_px": BOUNDARY_INSET_PX,
            "highlight_colour": "magenta",
        },
        "samples": records,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    retained = {Path(record["qc_image"]).name for record in records}
    for old in OUT.glob("*-classified.webp"):
        if old.name not in retained:
            old.unlink()
    print(f"Seagrass cover: {len(records)} sample classifications written.")


if __name__ == "__main__":
    main()
