# Native-grid summaries and figures; display reprojection never enters statistics.
read_selection_metrics <- function(raster_dir = "Data/raster", shp_dir = "Data/SHP") {
  areas <- sf::st_read(file.path(shp_dir, "Candidate_areas.shp"), quiet = TRUE)
  stopifnot(setequal(areas$Site, c("Stable", "Unstable")), all(sf::st_is_valid(areas)))
  files <- c(Stability = "Freq_above_50.tif", Elevation = "Bathy_meadow_cropped.tif")
  rasters <- lapply(files, function(f) terra::rast(file.path(raster_dir, f)))
  values <- list()
  display <- list()
  metadata <- list()
  for (metric in names(rasters)) {
    r <- rasters[[metric]]
    stopifnot(terra::nlyr(r) == 1L, nzchar(terra::crs(r)))
    names(r) <- "Value"
    polygons <- terra::project(terra::vect(areas), terra::crs(r))
    # Equal-weight cells whose centres fall inside each polygon; no interpolation.
    extracted <- terra::extract(r, polygons, cells = TRUE, xy = TRUE,
      touches = FALSE, small = FALSE)
    extracted$Site <- areas$Site[extracted$ID]
    extracted$Metric <- metric
    extracted$Valid <- is.finite(extracted$Value)
    if (metric == "Stability") {
      stopifnot(all(extracted$Value[extracted$Valid] >= 0 & extracted$Value[extracted$Valid] <= 100))
    }
    values[[metric]] <- extracted[, c("Metric", "Site", "cell", "x", "y", "Value", "Valid")]
    # Preserve the complete raster extent and every source value for the map.
    display[[metric]] <- r
    metadata[[metric]] <- data.frame(Metric = metric, Source = files[[metric]],
      Resolution_x = terra::res(r)[1], Resolution_y = terra::res(r)[2],
      CRS = terra::crs(r, proj = TRUE),
      Raster_min = terra::global(r, "min", na.rm = TRUE)[1, 1],
      Raster_max = terra::global(r, "max", na.rm = TRUE)[1, 1])
  }
  values <- do.call(rbind, values)
  values$Site <- factor(values$Site, levels = c("Stable", "Unstable"))
  summary <- do.call(rbind, lapply(split(values, list(values$Metric, values$Site)), function(d) {
    x <- d$Value[d$Valid]
    stopifnot(length(x) >= 2L)
    q <- stats::quantile(x, c(0, .25, .5, .75, 1), names = FALSE, type = 7)
    data.frame(Metric = d$Metric[1], Site = as.character(d$Site[1]),
      Cells = nrow(d), Valid_cells = length(x), Missing_cells = sum(!d$Valid),
      Mean = mean(x), SD = stats::sd(x), Min = q[1], Q1 = q[2],
      Median = q[3], Q3 = q[4], Max = q[5])
  }))
  rownames(summary) <- NULL
  list(areas = sf::st_transform(areas, 4326), values = values,
    summary = summary, display = display, metadata = do.call(rbind, metadata))
}

build_selection_map <- function(selection) {
  areas <- selection$areas
  colours <- c(Stable = "#0072B2", Unstable = "#D55E00")
  areas$colour <- unname(colours[areas$Site])
  areas$popup <- vapply(areas$Site, function(site) {
    s <- subset(selection$summary, Site == site)
    a <- s[s$Metric == "Stability", ]
    b <- s[s$Metric == "Elevation", ]
    paste0("<strong>", site, " meadow</strong><br>",
      sprintf("Cover persistence: %.1f &plusmn; %.1f%%<br>", a$Mean, a$SD),
      sprintf("Elevation: %.3f &plusmn; %.3f (source units)<br>", b$Mean, b$SD),
      sprintf("Valid cells: %d stability; %d elevation<br>", a$Valid_cells, b$Valid_cells),
      "Values are mean &plusmn; SD.")
  }, character(1))
  stability_pal <- leaflet::colorNumeric("viridis", domain = c(0, 100), na.color = "transparent")
  elevation_domain <- range(selection$values$Value[selection$values$Metric == "Elevation" & selection$values$Valid])
  elevation_pal <- leaflet::colorNumeric("YlGnBu", domain = elevation_domain, na.color = "transparent")
  elevation_global <- selection$metadata[selection$metadata$Metric == "Elevation", ]
  full_domain <- c(elevation_global$Raster_min, elevation_global$Raster_max)
  full_pal <- leaflet::colorNumeric("YlGnBu", domain = full_domain, na.color = "transparent")
  # Saturation applies only to the optional colour scale, never to raster values.
  detail_pal <- function(x) elevation_pal(pmin(pmax(x, elevation_domain[1]), elevation_domain[2]))
  detail_breaks <- seq(elevation_domain[1], elevation_domain[2], length.out = 5)
  detail_labels <- sprintf("%.3f", detail_breaks)
  detail_labels[c(1, 5)] <- paste(c("&le;", "&ge;"), detail_labels[c(1, 5)])
  groups <- c("Cover persistence (%)", "Elevation (full range)", "Elevation (site contrast)")
  coverage <- do.call(rbind, lapply(selection$display, function(r) {
    sf::st_transform(sf::st_as_sf(terra::as.polygons(terra::ext(r), crs = terra::crs(r))), 4326)
  }))
  bbox <- sf::st_bbox(coverage)
  map <- leaflet::leaflet(width = "100%", height = 560,
    elementId = "site-selection-map",
    options = leaflet::leafletOptions(scrollWheelZoom = FALSE, maxZoom = 22)) |>
    leaflet::addProviderTiles(leaflet::providers$OpenStreetMap,
      options = leaflet::providerTileOptions(maxZoom = 22, maxNativeZoom = 19)) |>
    leaflet::addRasterImage(selection$display$Stability, colors = stability_pal,
      opacity = .85, method = "ngb", group = groups[1], maxBytes = 4 * 1024 * 1024) |>
    leaflet::addRasterImage(selection$display$Elevation, colors = full_pal,
      opacity = .85, method = "ngb", group = groups[2], maxBytes = 4 * 1024 * 1024) |>
    leaflet::addRasterImage(selection$display$Elevation, colors = detail_pal,
      opacity = .85, method = "ngb", group = groups[3], maxBytes = 4 * 1024 * 1024) |>
    leaflet::addPolygons(data = areas, color = ~colour, weight = 3,
      fill = FALSE, group = "Study polygons", label = ~paste(Site, "meadow"),
      popup = ~popup) |>
    leaflet::addLegend(pal = stability_pal, values = c(0, 100),
      title = "Cover persistence (%)", position = "bottomright",
      className = "info legend selection-legend-stability") |>
    leaflet::addLegend(pal = full_pal, values = full_domain,
      title = "Elevation: full range<br>(source units)", position = "bottomright",
      className = "info legend selection-legend-elevation-full") |>
    leaflet::addLegend(colors = elevation_pal(detail_breaks), labels = detail_labels,
      title = "Elevation: site contrast<br>(source units; saturated)", position = "bottomright",
      className = "info legend selection-legend-elevation-detail", opacity = .85) |>
    leaflet::addLegend(colors = unname(colours), labels = paste(names(colours), "meadow"),
      title = "Study polygons", position = "bottomleft") |>
    leaflet::addScaleBar(position = "bottomleft", options = leaflet::scaleBarOptions(imperial = FALSE)) |>
    leaflet::addLayersControl(baseGroups = groups, overlayGroups = "Study polygons",
      options = leaflet::layersControlOptions(collapsed = FALSE)) |>
    leaflet::hideGroup(groups[2]) |>
    leaflet::hideGroup(groups[3]) |>
    leaflet::fitBounds(bbox[["xmin"]], bbox[["ymin"]], bbox[["xmax"]], bbox[["ymax"]])
  bounds <- function(x) {
    b <- sf::st_bbox(x)
    list(c(unname(b["ymin"]), unname(b["xmin"])), c(unname(b["ymax"]), unname(b["xmax"])))
  }
  htmlwidgets::onRender(map, "function(el, x, data) {
    var map = this;
    el.setAttribute('role', 'region');
    el.setAttribute('aria-label', 'Site-selection metrics: cover persistence and elevation');
    var control = L.control({position:'topleft'});
    control.onAdd = function() {
      var box = L.DomUtil.create('div', 'site-map-views leaflet-bar');
      L.DomEvent.disableClickPropagation(box);
      L.DomEvent.disableScrollPropagation(box);
      [['Full raster extent', data.extent], ['Both areas', data.all], ['Stable area', data.stable], ['Unstable area', data.unstable]].forEach(function(item) {
        var button = L.DomUtil.create('button', '', box);
        button.type = 'button'; button.textContent = item[0];
        button.onclick = function() {map.fitBounds(item[1], {padding:[35,35]});};
      });
      return box;
    };
    control.addTo(map);
    var legends = ['selection-legend-stability', 'selection-legend-elevation-full', 'selection-legend-elevation-detail'];
    function showLegend(name) {
      legends.forEach(function(cls, i) {
        el.querySelector('.' + cls).style.display = data.groups[i] === name ? '' : 'none';
      });
      el.querySelectorAll('.leaflet-image-layer').forEach(function(img) {img.style.imageRendering = 'pixelated';});
    }
    map.on('baselayerchange', function(e) {showLegend(e.name);});
    showLegend(data.groups[0]);
    el.querySelectorAll('.leaflet-image-layer').forEach(function(img) {img.style.imageRendering = 'pixelated';});
  }", data = list(extent = bounds(coverage), groups = groups,
    all = bounds(areas), stable = bounds(areas[areas$Site == "Stable", ]),
    unstable = bounds(areas[areas$Site == "Unstable", ])))
}

plot_selection_metrics <- function(selection) {
  d <- selection$values[selection$values$Valid, ]
  d$Metric <- factor(d$Metric, levels = c("Stability", "Elevation"),
    labels = c("Cover persistence (%)", "Elevation (source units)"))
  counts <- aggregate(Value ~ Metric + Site, d, length)
  ggplot2::ggplot(d, ggplot2::aes(Site, Value, fill = Site)) +
    ggplot2::geom_boxplot(width = .48, outlier.shape = NA, alpha = .35, linewidth = .5) +
    ggplot2::geom_point(ggplot2::aes(colour = Site), size = 2, alpha = .8,
      position = ggplot2::position_jitter(width = .08, height = 0, seed = 2026)) +
    ggplot2::geom_point(data = selection$summary |>
      transform(Metric = factor(Metric, levels = c("Stability", "Elevation"),
        labels = c("Cover persistence (%)", "Elevation (source units)"))),
      ggplot2::aes(Site, Mean), inherit.aes = FALSE, shape = 23,
      fill = "white", colour = "#222222", size = 3) +
    ggplot2::geom_text(data = counts, ggplot2::aes(Site, Inf, label = paste0("n = ", Value)),
      inherit.aes = FALSE, vjust = 1.4, size = 3.6) +
    ggplot2::facet_wrap(~Metric, scales = "free_y", nrow = 1) +
    ggplot2::scale_fill_manual(values = c(Stable = "#0072B2", Unstable = "#D55E00")) +
    ggplot2::scale_colour_manual(values = c(Stable = "#0072B2", Unstable = "#D55E00")) +
    ggplot2::scale_y_continuous(expand = ggplot2::expansion(mult = c(.1, .25))) +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme_bw(base_size = 12) +
    ggplot2::theme(legend.position = "none", panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major.x = ggplot2::element_blank(),
      strip.background = ggplot2::element_rect(fill = "#f0f3f5"),
      strip.text = ggplot2::element_text(face = "bold"),
      plot.margin = ggplot2::margin(10, 14, 10, 10))
}
