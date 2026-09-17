"use strict";

(async function () {
  const status = document.getElementById("viewer-status");
  const groups = { stable: [], unstable: [] };
  const groupBounds = {};
  const syncing = { stable: false, unstable: false };

  function synchronize(source, site) {
    if (syncing[site]) return;
    syncing[site] = true;
    try {
      const center = source.getCenter();
      const zoom = source.getZoom();
      for (const target of groups[site]) {
        if (target !== source) target.setView(center, zoom, { animate: false });
        // Visible map state also makes synchronization inspectable without private Leaflet APIs.
        const node = target.getContainer();
        node.dataset.center = `${center.lat.toFixed(9)},${center.lng.toFixed(9)}`;
        node.dataset.zoom = String(zoom);
      }
    } finally { syncing[site] = false; }
  }

  function reset(site) {
    const maps = groups[site];
    if (!maps.length) return;
    const bounds = groupBounds[site];
    const zoom = Math.min(...maps.map(map => map.getBoundsZoom(bounds, false, [12, 12])));
    maps[0].setView(bounds.getCenter(), zoom, { animate: false });
    synchronize(maps[0], site);
  }

  try {
    if (!window.L) throw new Error("The Leaflet library could not be loaded.");
    const response = await fetch("assets/drone/generated/manifest.json");
    if (!response.ok) throw new Error("The map catalogue could not be loaded.");
    const manifest = await response.json();
    if (!manifest.maps?.length) throw new Error("No drone imagery is available.");
    const periods = [...new Set(manifest.maps.map(record => record.period))].sort();
    const labels = new Map(manifest.maps.map(record => [record.period, record.label]));
    document.getElementById("period-range").textContent = `${labels.get(periods[0])} – ${labels.get(periods.at(-1))}`;
    let loaded = 0, failed = 0;
    const report = () => {
      status.textContent = `${loaded} / ${manifest.maps.length} maps loaded${failed ? ` · ${failed} unavailable` : ""}`;
    };
    report();
    for (const section of document.querySelectorAll(".mosaic")) {
      const { site, kind } = section.dataset;
      const grid = section.querySelector(".map-grid");
      for (const period of periods) {
        const record = manifest.maps.find(item => item.site === site && item.kind === kind && item.period === period);
        const card = document.createElement("article");
        card.className = "map-card";
        const heading = document.createElement("h3");
        heading.textContent = labels.get(period);
        const north = document.createElement("span");
        north.className = "north";
        north.textContent = "N ↑";
        heading.append(north);
        card.append(heading);
        grid.append(card);
        if (!record) {
          const missing = document.createElement("div");
          missing.className = "missing-map";
          missing.textContent = "No imagery available";
          card.append(missing);
          continue;
        }
        const node = document.createElement("div");
        node.className = "drone-map";
        node.id = `map-${site}-${kind.toLowerCase()}-${period}`;
        node.setAttribute("role", "region");
        node.setAttribute("aria-label", `${site} meadow ${kind}, ${record.label}`);
        card.append(node);
        const message = document.createElement("div");
        message.className = "map-message";
        message.textContent = "Loading imagery…";
        card.append(message);
        const map = L.map(node, { minZoom: 14, maxZoom: 24, zoomSnap: 0.25,
          zoomDelta: 0.5, zoomAnimation: false, fadeAnimation: false, inertia: false });
        map.attributionControl.setPrefix('<a href="https://leafletjs.com">Leaflet</a>');
        L.control.scale({ imperial: false, maxWidth: 65 }).addTo(map);
        const bounds = L.latLngBounds(record.bounds);
        groupBounds[site] = groupBounds[site] ? groupBounds[site].extend(bounds) : L.latLngBounds(record.bounds);
        map.fitBounds(bounds);
        L.imageOverlay(record.image, bounds, { alt: `${site} meadow ${kind}, ${record.label}` })
          .on("load", () => { loaded++; message.hidden = true; report(); })
          .on("error", () => { failed++; message.textContent = "Image unavailable. Reload to retry."; report(); })
          .addTo(map);
        groups[site].push(map);
      }
    }
    for (const site of Object.keys(groups)) {
      for (const map of groups[site]) map.on("move zoom", () => synchronize(map, site));
      reset(site);
    }
    for (const button of document.querySelectorAll("[data-reset]")) {
      button.addEventListener("click", () => reset(button.dataset.reset));
    }
    // Resizing must preserve the shared geographic view, including after full screen.
    let resizeFrame;
    const resize = () => {
      cancelAnimationFrame(resizeFrame);
      resizeFrame = requestAnimationFrame(() => {
        for (const site of Object.keys(groups)) {
          if (!groups[site].length) continue;
          const center = groups[site][0].getCenter();
          const zoom = groups[site][0].getZoom();
          syncing[site] = true;
          for (const map of groups[site]) map.invalidateSize({ pan: false });
          syncing[site] = false;
          groups[site][0].setView(center, zoom, { animate: false });
          synchronize(groups[site][0], site);
        }
      });
    };
    new ResizeObserver(resize).observe(document.querySelector(".mosaic-layout"));
  } catch (error) {
    status.textContent = error.message;
    const message = document.createElement("p");
    message.className = "fatal-error";
    message.setAttribute("role", "alert");
    message.textContent = `${error.message} The results page remains available through the Results link.`;
    document.querySelector(".mosaic-layout").prepend(message);
  }

  const dialog = document.getElementById("map-information");
  document.getElementById("about-button").addEventListener("click", () => dialog.showModal());
  const fullscreen = document.getElementById("fullscreen-button");
  fullscreen.hidden = !document.fullscreenEnabled;
  fullscreen.addEventListener("click", async () => {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else await document.documentElement.requestFullscreen();
    } catch { status.textContent = "Full-screen mode is unavailable in this browser."; }
  });
  document.addEventListener("fullscreenchange", () => {
    fullscreen.textContent = document.fullscreenElement ? "Exit full screen" : "Full screen";
  });
})();
