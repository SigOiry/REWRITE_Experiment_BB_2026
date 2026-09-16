# REWRITE BB Experiment

Quarto website for sharing experimental methods and results with collaborators.

## Site content

- `index.qmd`: materials and methods (the landing page).
- `remote-sensing.qmd`: remote sensing results.
- `sampling.qmd`: field sampling and laboratory results.
- `_quarto.yml`: shared website settings and navigation.
- `styles.css`: optional custom styling.
- `references.bib`: sources cited in the scientific text.
- `R/site-map.R`: interactive Leaflet map built from `Data/SHP/Candidate_areas.shp` and `Data/SHP/Points.shp`.
- `R/site-selection.R`: native-grid raster extraction, metric map, and distribution plots from `Data/raster/`.
- `artifacts/`: generated box-plots (PNG/SVG), cell values, summary statistics, and raster metadata, rebuilt by `quarto render`.

The landing page contains the introduction, objectives, site selection, and initial experimental design. Clearly marked placeholders identify details and results still to be supplied.

## Preview and render

Install [Quarto](https://quarto.org/docs/get-started/), then run these commands from the project directory.

The maps and summaries are rebuilt during rendering using R and the following packages. Install missing packages in R with:

```r
install.packages(c("sf", "terra", "ggplot2", "leaflet", "htmlwidgets", "htmltools", "knitr", "rmarkdown"))
```

Keep the shapefile sidecars (`.dbf`, `.shx`, `.prj`, and `.cpg`) alongside each `.shp`. Coordinates are read from the geometries and transformed using their declared coordinate reference systems. The published map runs in the browser without an R server; internet access is needed for the map and satellite background tiles.

Raster summaries use finite cell values whose centres lie within each polygon, at each file's native resolution. The supplied rasters have 19.9 m cells, including the resampled bathymetry. Web reprojection uses nearest neighbours and does not affect the summaries. Elevation units and the vertical datum remain to be confirmed. The historical filename `Freq_above_50.tif` is retained; the confirmed stability definition includes annual cover values equal to 50%.

The metric map displays both rasters over their complete extents, with no cropping or outlier filtering. Elevation has a full-range colour scale and an optional scale emphasizing the site values; the latter saturates colours outside the site interval while preserving all raster values. Statistics and box-plots always use the native cell values within the polygons.

For a local preview that updates as you edit:

```sh
quarto preview
```

To build all three pages:

```sh
quarto render
```

The rendered website is written to `docs/`, with `docs/index.html` as its landing page. Edit the source `.qmd` files, then render again; files in `docs/` are generated output.

## Publish with GitHub Pages

This project uses Quarto's [render to docs workflow](https://quarto.org/docs/publishing/github-pages.html#render-to-docs).

1. Run `quarto render`.
2. Commit and push the website source files and the complete `docs/` directory to GitHub.
3. In the repository's **Settings → Pages**, select **Deploy from a branch**, choose the branch containing the rendered site, and select **/docs** as the folder.
4. Save the settings and use the website URL shown by GitHub Pages.

The `.nojekyll` file is included in the rendered output to disable Jekyll processing. Keep `docs/` in version control for this publishing workflow. After each content update, render again and commit and push the updated output.
