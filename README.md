# REWRITE BB Experiment

## Rendering

`quarto render` builds the website in `docs/`, including the standalone drone map viewer.
The Quarto/R pages require `sf`, `terra`, `ggplot2`, `leaflet`, `htmlwidgets`,
`htmltools`, `knitr`, and `rmarkdown`. The drone preview builder requires Python
with `rasterio`, `numpy`, and `Pillow` (`python -m pip install -r requirements-viewer.txt`).

## Drone time series

`scripts/build-drone-viewer.py` runs before rendering. It discovers monthly products
named `{Stable|Unstable}_MMYYYY_{RGB|NDVI}.tif` under `Data/MS_DRONE`, rejecting
duplicate site/month/type combinations. Months come from the processed filenames;
July 2026 is confirmed despite the parent folders being labelled `25062026`.

Full raster footprints are reprojected to Web Mercator for Leaflet. WebP previews
are at most 2,048 pixels on their longest edge. RGB uses bilinear resampling and
the source alpha band; NDVI uses nearest-neighbour resampling, honours source
no-data, and applies the batlow colour scale over one fixed 0–0.8 interval. Valid
negative values are clamped to the 0 colour and valid values above 0.8 to the 0.8
colour. Non-finite and source no-data values are transparent. The supplied NDVI
rasters declare zero as no-data.
These previews are for visual comparison; source GeoTIFFs remain unchanged and
must be used for numerical analyses.

The generated manifest records source filenames, coordinate systems, source and
preview dimensions, bounds, and cache fingerprints. Unchanged source files reuse
their previews. `python scripts/build-drone-viewer.py` can also run independently.
Changes to conversion logic require an increment to its `VERSION` cache key.

`drone-viewer.html` displays four mosaics. All maps of a meadow synchronize centre
and zoom across both RGB and NDVI. Relative asset URLs and locally bundled
Leaflet 1.9.4 support GitHub Pages project subpaths without a map server or CDN.
Quarto copies the viewer and `assets/` into `docs/`; raw drone TIFFs are not copied.

`python -m unittest discover -s tests -v` checks full-extent reprojection, NDVI
no-data handling and fixed colours, and RGB transparency with valid zero channels.

## Field-photograph percentage cover

`scripts/estimate-seagrass-cover.py` runs before rendering and processes the 24
September photographs in `Data/Sept_2026/Quadrat_September2026`. It fits the red
sample boundary from each annotated PNG, applies the resulting circle to the aligned
raw JPEG, and classifies pixels for which green is the dominant RGB channel. The
four-pixel inward offset follows the inner edge of the
drawn boundary. Results, circle-coverage checks, and magenta quality-control masks
are written to `assets/seagrass-cover/generated/`. A source fingerprint avoids
reprocessing unchanged photographs.

`scripts/build-ndvi-calibration.py` matches the 24 cover observations to the core
points, extracts mean September NDVI from raster-cell centres within 0.10 m buffers,
and fits the bounded logistic relationship shown on the results page. The source
point layer has two unstable pairs named 5AU/5NU and no 6AU/6NU; the script assigns
the northern duplicate pair to station 6 and validates the resulting 24 identifiers.
Windowed raster reads avoid loading either orthomosaic in full. The generated CSVs
contain the matched observations, fitted curve, confidence interval, and model
coefficients used by the `ggiraph` figure.

`scripts/build-ndvi-timeseries.py` applies the same 0.10 m extraction to the eight
processed June–September NDVI orthomosaics. It writes one record per core and month
to `ndvi-timeseries.csv`, using N as Control and A as Treatment. The results page
summarizes these 96 observations by meadow and by treatment within meadow in two
interactive `ggiraph` figures.
