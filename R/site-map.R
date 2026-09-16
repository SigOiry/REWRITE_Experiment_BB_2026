# Rebuild the map from the supplied spatial data whenever Quarto renders.
build_site_map <- function(shp_dir = "Data/SHP") {
  areas <- sf::st_read(file.path(shp_dir, "Candidate_areas.shp"), quiet = TRUE)
  points <- sf::st_read(file.path(shp_dir, "Points.shp"), quiet = TRUE)
  stopifnot(!is.na(sf::st_crs(areas)), !is.na(sf::st_crs(points)))
  areas <- sf::st_transform(areas, 4326)
  points <- sf::st_transform(points, 4326)
  stopifnot(all(sf::st_is_valid(areas)), all(sf::st_is_valid(points)))
  points$Name <- trimws(points$Name)
  points <- points[!grepl("Edge|poll", points$Name, ignore.case = TRUE), ]

  colours <- c(Stable = "#0072B2", Unstable = "#D55E00")
  stopifnot(setequal(areas$Site, names(colours)))
  areas$colour <- unname(colours[areas$Site])
  areas$description <- ifelse(
    areas$Site == "Stable",
    "Seagrass cover reached at least 50% in most observations of the Sentinel-2 time series.",
    "Seagrass cover reached at least 50% inconsistently through the Sentinel-2 time series."
  )

  # Use point geometries, not the rounded x/y attribute fields.
  membership <- sf::st_intersects(points, areas)
  points$Site <- vapply(membership, function(i) {
    if (length(i) == 1L) areas$Site[i] else "Boundary"
  }, character(1))
  stopifnot(all(points$Site %in% names(colours)))
  points$colour <- unname(colours[points$Site])
  points$colour[is.na(points$colour)] <- "#666666"
  points$label <- paste(points$Site, points$Name, sep = " | ")
  xy <- sf::st_coordinates(points)
  points$popup <- paste0(
    "<strong>", htmltools::htmlEscape(points$Name), "</strong><br>",
    htmltools::htmlEscape(points$Site), " meadow<br>",
    "Experimental core<br>",
    sprintf("Latitude: %.6f<br>Longitude: %.6f", xy[, 2], xy[, 1])
  )
  # Preserve repeated source labels and all distinct geometries pending confirmation.
  duplicate_name <- duplicated(points$Name) | duplicated(points$Name, fromLast = TRUE)
  points$popup[duplicate_name] <- paste0(points$popup[duplicate_name],
    "<br><em>This identifier occurs at more than one location in the source file.</em>")

  bbox <- sf::st_bbox(areas)
  as_bounds <- function(x) {
    b <- sf::st_bbox(x)
    list(c(unname(b["ymin"]), unname(b["xmin"])),
         c(unname(b["ymax"]), unname(b["xmax"])))
  }
  map <- leaflet::leaflet(options = leaflet::leafletOptions(
    scrollWheelZoom = FALSE, maxZoom = 22
  ), width = "100%", height = 560, elementId = "experiment-site-map") |>
    leaflet::addProviderTiles(leaflet::providers$OpenStreetMap,
      group = "Map", options = leaflet::providerTileOptions(maxZoom = 22, maxNativeZoom = 19)) |>
    leaflet::addProviderTiles(leaflet::providers$Esri.WorldImagery,
      group = "Satellite", options = leaflet::providerTileOptions(maxZoom = 22, maxNativeZoom = 19)) |>
    leaflet::addPolygons(data = areas, group = "Meadow areas",
      color = ~colour, fillColor = ~colour, weight = 2, fillOpacity = 0.16,
      label = ~paste(Site, "meadow"),
      popup = ~paste0("<strong>", Site, " meadow</strong><br>", description)) |>
    leaflet::addCircleMarkers(data = points,
      group = "Cores", radius = 5, color = "#ffffff", weight = 1,
      fillColor = ~colour, fillOpacity = 1, label = ~label, popup = ~popup) |>
    leaflet::addLayersControl(baseGroups = c("Map", "Satellite"),
      overlayGroups = c("Meadow areas", "Cores"),
      options = leaflet::layersControlOptions(collapsed = TRUE)) |>
    leaflet::addLegend(position = "bottomleft", colors = unname(colours),
      labels = c("Stable meadow", "Unstable meadow"), opacity = 1,
      title = "Meadow cover persistence") |>
    leaflet::addScaleBar(position = "bottomleft",
      options = leaflet::scaleBarOptions(imperial = FALSE)) |>
    leaflet::addMiniMap(tiles = leaflet::providers$OpenStreetMap,
      position = "bottomright", width = 150, height = 120,
      zoomLevelFixed = 9, toggleDisplay = TRUE) |>
    leaflet::fitBounds(bbox[["xmin"]], bbox[["ymin"]], bbox[["xmax"]], bbox[["ymax"]])

  htmlwidgets::onRender(map, "function(el, x, data) {
    var map = this;
    el.setAttribute('role', 'region');
    el.setAttribute('aria-label', 'Interactive map of the Bourgneuf Bay experimental sites');
    var control = L.control({position: 'topleft'});
    control.onAdd = function() {
      var box = L.DomUtil.create('div', 'site-map-views leaflet-bar');
      L.DomEvent.disableClickPropagation(box);
      L.DomEvent.disableScrollPropagation(box);
      [['Both sites', data.all], ['Stable', data.stable], ['Unstable', data.unstable],
       ['Bay overview', null]].forEach(function(item) {
        var button = L.DomUtil.create('button', '', box);
        button.type = 'button';
        button.textContent = item[0];
        button.setAttribute('aria-label', 'Show ' + item[0]);
        button.onclick = function() {
          if (item[1]) map.fitBounds(item[1], {padding: [30, 30]});
          else map.setView(data.center, 10);
        };
      });
      return box;
    };
    control.addTo(map);
  }", data = list(all = as_bounds(areas),
    stable = as_bounds(areas[areas$Site == "Stable", ]),
    unstable = as_bounds(areas[areas$Site == "Unstable", ]),
    center = c(mean(bbox[c("ymin", "ymax")]), mean(bbox[c("xmin", "xmax")]))))
}
