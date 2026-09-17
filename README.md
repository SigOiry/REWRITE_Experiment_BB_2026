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
