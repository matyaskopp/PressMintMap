// Render map.png from index.htm in headless Firefox (same output as the "PNG" button)
//   node render-map.mjs <url> <output.png> [size] [scale] [firefox]
import puppeteer from "puppeteer-core";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const [url, output, size = "1081", scale = "2", firefox = "/usr/bin/firefox"] = process.argv.slice(2);
if (!url || !output) {
  console.error("usage: node render-map.mjs <url> <output.png> [size] [scale] [firefox]");
  process.exit(1);
}

// profile inside the repo: snap Firefox cannot read the system /tmp
const profile = resolve("tmp/firefox-profile");
mkdirSync(profile, { recursive: true });

const browser = await puppeteer.launch({
  browser: "firefox",
  executablePath: firefox,
  headless: true,
  userDataDir: profile,
  defaultViewport: { width: Number(size), height: Number(size) },
  extraPrefsFirefox: { "browser.shell.checkDefaultBrowser": false },
});

try {
  const page = await browser.newPage();
  page.on("pageerror", err => console.error("page error:", err.message));
  await page.goto(url);
  await page.waitForFunction(() => window.mapReady === true, { polling: 500, timeout: 120000 });
  await fontsReady(page);
  const b64 = await page.evaluate(async s => {
    const blob = await renderPNG(s);
    const buf = new Uint8Array(await blob.arrayBuffer());
    let bin = "";
    for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
    return btoa(bin);
  }, Number(scale));
  writeFileSync(output, Buffer.from(b64, "base64"));
  console.log(`Wrote ${output}`);
} finally {
  await browser.close();
}

async function fontsReady(page) {
  await page.evaluate(() => document.fonts.ready.then(() => true));
}
