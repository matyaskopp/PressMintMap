// MintMap: map of countries/regions participating in a project (PressMint, ParlaMint, ...)
//
// usage:
//   <script src="https://cdn.jsdelivr.net/npm/d3@7.9.2/dist/d3.min.js"></script>
//   <script src="https://cdn.jsdelivr.net/npm/topojson-client@3.1.0/dist/topojson-client.min.js"></script>
//   <svg id="map"></svg>
//   <div id="controls"> ... <input type="checkbox" data-param="regions"> ... <button data-action="reset"> ... </div>
//   const map = MintMap.render("#map", config);
//
// config: see DEFAULTS below, example in pressmint.js
// styling: lib/styles.css (layout + neutral defaults), project css overrides colors
//
// url parameters (share): ?selected=PL,UA&candidates=DE&hide=regions,codes,logo

const MintMap = (() => {

  const DEFAULTS = {
    data: "data/europe.topojson", // TopoJSON/GeoJSON with properties: level (country|region), iso, name, parent
    patches: [],                  // TopoJSON/GeoJSON files whose features replace features with the same iso
    highlight: [],                // highlighted countries/regions (iso codes)
    continents: ["Europe"],       // countries drawn in the main map (by parent)
    regions: [],                  // countries drawn with their regions (iso codes)
    background: [],               // drawn first (bottom), e.g. RU
    fit: [],                      // the main map is fitted to these countries
    padding: { top: 0, right: 0, bottom: 0, left: 0 },
    insets: [],                   // [{continents, fit, scale, below, x}] - circle insets, e.g. Africa
    logo: null,                   // {src, nextTo, size: number | "inset"}
    exportFont: null,             // font css url embedded in exported SVG/PNG
    fileName: "map",              // exported file name (without extension)
    controls: "#controls",        // switches ([data-param]) and buttons ([data-action])
  };

  // switch name (url ?hide=...) -> class on svg
  const SWITCHES = { regions: "hide-reg", codes: "hide-code", logo: "hide-logo" };

  // computed styles copied to exported SVG
  const KEEP = ["fill", "stroke", "stroke-width", "opacity", "font-size", "font-weight", "font-family", "text-anchor"];

  function render(selector, userConfig) {
    const config = { ...DEFAULTS, ...userConfig };
    const highlight = new Set(config.highlight);
    const regions = new Set(config.regions);
    const background = new Set(config.background);
    const continents = new Set(config.continents);

    const svg = d3.select(selector);
    const controls = d3.select(config.controls);
    const height = window.innerHeight;
    const width = height;

    let ready = false;
    let resolveReady;
    const whenReady = new Promise(resolve => { resolveReady = resolve; });
    let toggleArea = () => {}; // set when map is drawn

    const actions = controls.selectAll("[data-action]");
    actions.filter("[data-export]").property("disabled", true);

    // web fonts are not available to an SVG rendered as an image -> embed them in the export
    let exportFontCSS = "";
    const fontReady = (config.exportFont ? loadFontCSS(config.exportFont) : Promise.resolve(""))
      .then(css => { exportFontCSS = css; })
      .catch(err => console.warn("export font not embedded:", err));

    // switches
    controls.selectAll("input[data-param]")
      .on("change", function() {
        svg.classed(SWITCHES[this.dataset.param], !this.checked);
      });

    // buttons
    const handlers = {
      reset: () => api.reset(),
      share: function() { share(this); },
      svg: () => download(new Blob([exportSVG()], { type: "image/svg+xml;charset=utf-8" }), config.fileName + ".svg"),
      png: () => renderPNG().then(blob => download(blob, config.fileName + ".png")),
    };
    actions.on("click", function() { handlers[this.dataset.action].call(this); });

    applyURLSwitches();

    Promise.all([d3.json(config.data), ...config.patches.map(f => d3.json(f))])
      .then(([map, ...patches]) => {
        const patched = new Map(patches.flatMap(featuresOf).map(f => [f.properties.iso, f]));
        const features = featuresOf(map).map(f => patched.get(f.properties.iso) || f);
        // countries below regions
        const all = [
          ...features.filter(f => f.properties.level === "country"),
          ...features.filter(f => f.properties.level === "region"),
        ];
        draw(all);
      })
      .catch(err => {
        console.error("LOAD FAILED:", err);
      });

    function draw(features) {
      const isHighlighted = d => highlight.has(d.properties.iso);
      const rank = d => background.has(d.properties.iso) ? 0 : isHighlighted(d) ? 2 : 1;
      const areaClass = d => "area " + d.properties.level + (isHighlighted(d) ? " highlight" : "");

      // countries with highlighted regions (shown highlighted when regions are hidden)
      const highlightedParents = new Set(features
        .filter(d => d.properties.level === "region" && isHighlighted(d))
        .map(d => d.properties.parent));

      const main = features.filter(d => continents.has(d.properties.parent) || regions.has(d.properties.parent));
      const byIso = iso => features.find(d => d.properties.iso === iso && d.properties.level === "country")
        || features.find(d => d.properties.iso === iso);
      const collection = isos => ({ type: "FeatureCollection", features: isos.map(byIso).filter(Boolean) });

      const { top, right, bottom, left } = { ...DEFAULTS.padding, ...config.padding };
      const projection = d3.geoMercator()
        .fitExtent([[left, top], [width - right, height - bottom]], collection(config.fit));
      const path = d3.geoPath().projection(projection);

      const defs = svg.append("defs");

      // stripes for candidate countries (colors in css: .stripe-bg, .stripe)
      const stripes = defs.append("pattern")
        .attr("id", "candidate-stripes")
        .attr("patternUnits", "userSpaceOnUse")
        .attr("width", 8)
        .attr("height", 8)
        .attr("patternTransform", "rotate(45)");
      stripes.append("rect")
        .attr("class", "stripe-bg")
        .attr("width", 8)
        .attr("height", 8);
      stripes.append("rect")
        .attr("class", "stripe")
        .attr("width", 4)
        .attr("height", 8);

      const drawAreas = (parent, data) => parent.selectAll(null)
        .data(data)
        .enter()
        .append("path")
        .attr("class", areaClass)
        .classed("has-highlighted-regions", d => d.properties.level === "country" && highlightedParents.has(d.properties.iso))
        .attr("code", d => d.properties.iso)
        .attr("id", d => d.properties.iso)
        .attr("name", d => d.properties.name)
        .attr("d", path);

      drawAreas(svg, main.sort((a, b) => rank(a) - rank(b))); // background (e.g. RU) to the bottom

      // circle insets (e.g. Africa), placed below a country of the main map
      const insetOf = new Map(); // feature -> inset placement
      const insets = config.insets.map((inset, i) => {
        const fit = collection(inset.fit);
        const [[ax0, ay0], [ax1, ay1]] = path.bounds(fit);
        const [cx, cy] = path.centroid(fit);
        const scale = inset.scale;
        const [[rx0, ry0], [rx1, ry1]] = path.bounds(byIso(inset.below));
        const targetX = rx0 + (rx1 - rx0) * inset.x;
        const targetY = ry0 + (ry1 - ry0) + (ay1 - ay0);
        const r = Math.sqrt(Math.pow(ax1 - ax0, 2) + Math.pow(ay1 - ay0, 2)) / 2 * scale;

        defs.append("clipPath")
          .attr("id", `clip-inset-${i}`)
          .append("circle")
          .attr("cx", cx)
          .attr("cy", cy)
          .attr("r", r);

        const g = svg.append("g").attr("clip-path", `url(#clip-inset-${i})`);
        const data = features.filter(d => inset.continents.includes(d.properties.parent));
        drawAreas(g, data);
        g.append("circle")
          .attr("class", "inset-frame")
          .attr("cx", cx)
          .attr("cy", cy)
          .attr("r", r);
        g.attr("transform", `
          translate(${targetX}, ${targetY})
          scale(${scale})
          translate(${-cx}, ${-cy})
        `);

        const placement = { targetX, targetY, cx, cy, scale, r };
        data.forEach(d => insetOf.set(d, placement));
        return placement;
      });

      // click toggles highlighting: highlighted area -> selected, other country -> candidate (striped + code)
      toggleArea = (node, on) => {
        const el = d3.select(node);
        const d = el.datum();
        const cls = el.classed("highlight") ? "selected" : "candidate";
        if (on === undefined) on = !el.classed(cls);
        if (el.classed(cls) === on) return;
        el.classed(cls, on);
        if (cls === "candidate") {
          if (on) {
            svg.append("text")
              .datum(d)
              .attr("data-candidate", d.properties.iso)
              .call(label);
          } else {
            svg.selectAll(`text[data-candidate="${d.properties.iso}"]`).remove();
          }
        }
      };

      svg.selectAll("path.area")
        .on("click", function() { toggleArea(this); });

      // labels of highlighted areas
      svg.selectAll(null)
        .data([...main, ...insetOf.keys()].filter(isHighlighted))
        .enter()
        .append("text")
        .call(label);

      // highlighted countries from url (?selected=PL,UA&candidates=DE)
      const urlParams = new URLSearchParams(location.search);
      ["selected", "candidates"].forEach(param => {
        (urlParams.get(param) || "").split(",").filter(Boolean).forEach(iso => {
          const node = svg.select(`path.area[id="${CSS.escape(iso)}"]`).node();
          if (node) toggleArea(node, true);
          else console.warn(`unknown area in url (${param}):`, iso);
        });
      });

      function label(selection) {
        selection
          .attr("x", d => projectPoint(d)[0])
          .attr("y", d => projectPoint(d)[1])
          .attr("class", d => "label " + d.properties.level)
          .attr("text-anchor", "middle")
          .attr("alignment-baseline", "middle")
          .text(d => d.properties.iso);
      }

      function projectPoint(d) {
        const [x, y] = getMainlandCentroid(d);
        const inset = insetOf.get(d);
        if (inset) {
          return [
            inset.targetX + (x - inset.cx) * inset.scale,
            inset.targetY + (y - inset.cy) * inset.scale
          ];
        }
        return [x, y];
      }

      // centroid of the largest polygon (mainland)
      function getMainlandCentroid(feature) {
        if (feature.geometry.type === "MultiPolygon") {
          let maxArea = 0;
          let bestPolygon = null;
          feature.geometry.coordinates.forEach(polygon => {
            const area = d3.geoArea({ type: "Polygon", coordinates: polygon });
            if (area > maxArea) {
              maxArea = area;
              bestPolygon = polygon;
            }
          });
          return path.centroid({ type: "Feature", geometry: { type: "Polygon", coordinates: bestPolygon } });
        }
        return path.centroid(feature);
      }

      // logo next to a country of the main map, size in px or "inset" (diameter of the first inset)
      const logoReady = !config.logo ? Promise.resolve() : fetch(config.logo.src)
        .then(res => res.blob())
        .then(blobToDataURL)
        .then(base64 => {
          const [, [rx1]] = path.bounds(byIso(config.logo.nextTo));
          const size = config.logo.size === "inset" ? 2 * insets[0].r : config.logo.size;
          svg.append("image")
            .attr("href", base64)
            .attr("x", rx1)
            .attr("y", top)
            .attr("width", size)
            .attr("height", size);
        });

      Promise.all([logoReady, fontReady]).then(() => requestAnimationFrame(() => {
        ready = true;
        actions.filter("[data-export]").property("disabled", false);
        resolveReady(api);
      }));
    }

    // share: current setup stored in url, e.g. ?selected=PL,UA&candidates=DE&hide=regions
    function stateURL() {
      const ids = cls => svg.selectAll(`path.${cls}`).nodes().map(e => e.id).sort().join(",");
      const params = new URLSearchParams();
      const selected = ids("selected");
      const candidates = ids("candidate");
      const hide = controls.selectAll("input[data-param]").nodes()
        .filter(i => !i.checked).map(i => i.dataset.param).join(",");
      if (selected) params.set("selected", selected);
      if (candidates) params.set("candidates", candidates);
      if (hide) params.set("hide", hide);
      const query = params.toString().replace(/%2C/g, ",");
      return location.origin + location.pathname + (query ? "?" + query : "");
    }

    function share(btn) {
      const url = stateURL();
      history.replaceState(null, "", url);
      const label = btn.textContent;
      const done = text => {
        btn.textContent = text;
        setTimeout(() => { btn.textContent = label; }, 1500);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(url).then(() => done("✓ Copied"), () => prompt("Map link:", url));
      } else {
        prompt("Map link:", url);
      }
    }

    // switches from url (?hide=regions,codes,logo)
    function applyURLSwitches() {
      const hide = new Set((new URLSearchParams(location.search).get("hide") || "").split(","));
      controls.selectAll("input[data-param]")
        .property("checked", function() { return !hide.has(this.dataset.param); })
        .dispatch("change");
    }

    function exportSVG() {
      if (!ready) {
        console.warn("Map not ready yet");
        return;
      }
      // clone so you don’t destroy live DOM
      const clone = svg.node().cloneNode(true);

      document.body.appendChild(clone);
      inlineStyles(clone);

      // remove hidden elements (css classes, stylesheets and inline styles)
      const allElements = clone.getElementsByTagName("*");
      for (let i = allElements.length - 1; i >= 0; i--) {
        const el = allElements[i];
        if (window.getComputedStyle(el).display === "none") {
          el.remove();
        }
      }

      document.body.removeChild(clone);
      clone.removeAttribute("style");
      clone.style.background = "white";
      clone.setAttribute("viewBox", `0 0 ${width} ${height}`);
      if (exportFontCSS) {
        const style = document.createElementNS("http://www.w3.org/2000/svg", "style");
        style.textContent = exportFontCSS;
        clone.insertBefore(style, clone.firstChild);
      }

      const source = new XMLSerializer().serializeToString(clone);
      return '<?xml version="1.0" standalone="no"?>\n' + source;
    }

    // render map as PNG, returns Promise<Blob>
    function renderPNG(scale = 2) { // 2 = retina quality
      const svgString = exportSVG();

      return new Promise((resolve, reject) => {
        const img = new Image();
        const url = URL.createObjectURL(new Blob([svgString], { type: "image/svg+xml;charset=utf-8" }));

        img.onerror = reject;
        img.onload = function () {
          const canvas = document.createElement("canvas");
          const ctx = canvas.getContext("2d");

          canvas.width = width * scale;
          canvas.height = height * scale;

          ctx.scale(scale, scale);
          ctx.drawImage(img, 0, 0, width, height);

          URL.revokeObjectURL(url);

          canvas.toBlob(resolve, "image/png");
        };

        img.src = url;
      });
    }

    const api = {
      config,
      whenReady,
      isReady: () => ready,
      // toggle highlighting of an area (on: true/false, undefined = toggle)
      toggle: (iso, on) => {
        const node = svg.select(`path.area[id="${CSS.escape(iso)}"]`).node();
        if (node) toggleArea(node, on);
      },
      // reset to defaults: no highlighted/candidate countries, all switches on
      reset: () => {
        svg.selectAll(".selected").classed("selected", false);
        svg.selectAll(".candidate").classed("candidate", false);
        svg.selectAll("text[data-candidate]").remove();
        controls.selectAll("input[data-param]")
          .property("checked", true)
          .dispatch("change");
        history.replaceState(null, "", location.pathname);
      },
      stateURL,
      exportSVG,
      renderPNG,
    };

    MintMap.current = api; // used by render-map.mjs (make map.png)
    return api;
  }

  // features of GeoJSON or TopoJSON (first object)
  function featuresOf(data) {
    if (data.type === "Topology") {
      const object = data.objects[Object.keys(data.objects)[0]];
      return topojson.feature(data, object).features;
    }
    return data.features;
  }

  function inlineStyles(svg) {
    svg.querySelectorAll("*").forEach(el => {
      const computed = window.getComputedStyle(el);
      let style = "";
      KEEP.forEach(prop => {
        // computed url() may be absolute (page url + #id), standalone SVG needs local reference
        const value = computed.getPropertyValue(prop).replace(/url\(["']?[^"')]*#([^"')]+)["']?\)/g, 'url(#$1)');
        if (value) style += `${prop}:${value};`;
      });
      el.setAttribute("style", style);
    });
  }

  function blobToDataURL(blob) {
    return new Promise(resolve => {
      const reader = new FileReader();
      reader.onloadend = () => resolve(reader.result);
      reader.readAsDataURL(blob);
    });
  }

  // fetch font CSS (e.g. Google Fonts) and replace font file urls with data urls
  async function loadFontCSS(url) {
    const css = await fetch(url).then(res => res.text());
    const urls = [...new Set([...css.matchAll(/url\((['"]?)(.*?)\1\)/g)].map(m => m[2]))];
    const data = await Promise.all(urls.map(u => fetch(u).then(res => res.blob()).then(blobToDataURL)));
    return urls.reduce((acc, u, i) => acc.split(u).join(data[i]), css);
  }

  function download(blob, name) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    a.click();
    URL.revokeObjectURL(url);
  }

  return { render, current: null };
})();

window.MintMap = MintMap; // explicit global (top-level const is not visible e.g. to puppeteer)
