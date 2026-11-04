// PressMint map settings (see ../lib/map.js for all options)

const config = {
  data: "../data/europe.topojson",

  // PressMint countries and regions
  highlight: [
    "AT",
    "BG",
    "CZ",
    "ES-GA",
    "ES-MD",
    "ES-PV",
    "FI",
    "FR",
    "GB",
    "GR",
    "HU",
    "IS",
    "IT-BZ",
    "LV",
    "NL",
    "PL",
    "PT",
    "SI",
    "UA",
    "ZA",
  ],

  continents: ["Europe", "Asia"],       // countries in the main map
  regions: ["ES", "IT"],                // countries shown with regions
  background: ["RU"],                   // drawn first
  fit: ["FI", "IS", "UA", "GR"],        // main map fitted to these countries
  padding: { top: 35, right: 5, bottom: 5, left: 15 },

  // South Africa in a circle below Iceland
  insets: [
    { continents: ["Africa"], fit: ["ZA"], scale: 0.6, below: "IS", x: 1 / 1.5 },
  ],

  logo: { src: "logo.png", nextTo: "IS", size: "inset" },

  // font embedded into exported SVG/PNG (labels use weight 600)
  exportFont: "https://fonts.googleapis.com/css2?family=Source+Sans+3:wght@600&display=swap",
};
