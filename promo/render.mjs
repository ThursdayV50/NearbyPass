// render.mjs
//   node render.mjs stills 0.2 1.6 ...      → out/stills/t_<sec>.png
//   node render.mjs frames [fps] [workers]  → out/frames/NNNNNN.png, 3 subframes per frame (t-1/240, t, t+1/240)
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const url = pathToFileURL(path.join(here, 'film.html')).href;
const [mode = 'stills', ...rest] = process.argv.slice(2);

async function openPage(browser) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  page.on('pageerror', e => { console.error('pageerror', e.message); process.exitCode = 1; });
  await page.goto(url);
  await page.evaluate(() => window.ready);
  return page;
}
const shot = (page, t, file) => page.evaluate(t => window.seek(t), t)
  .then(() => page.locator('#c').screenshot({ path: file, type: 'png', animations: 'disabled' }));

const browser = await chromium.launch({ channel: 'chrome', args: ['--force-color-profile=srgb', '--disable-lcd-text'] });
if (mode === 'stills') {
  const dir = path.join(here, 'out/stills'); fs.mkdirSync(dir, { recursive: true });
  const page = await openPage(browser);
  for (const s of rest) await shot(page, Number(s), path.join(dir, `t_${Number(s).toFixed(3)}.png`));
} else {
  const fps = Number(rest[0] || 60), workers = Number(rest[1] || 8);
  const probe = await openPage(browser); const dur = await probe.evaluate(() => window.END); await probe.close();
  console.log('duration', dur.toFixed(3));
  const dir = path.join(here, 'out/frames'); fs.mkdirSync(dir, { recursive: true });
  const total = Math.round(dur * fps), offs = [-1 / 240, 0, 1 / 240];
  const jobs = []; for (let f = 0; f < total; f++) for (let k = 0; k < 3; k++) jobs.push([f * 3 + k, f / fps + offs[k]]);
  let next = 0, done = 0; const t0 = Date.now();
  await Promise.all(Array.from({ length: workers }, async () => {
    const page = await openPage(browser);
    while (next < jobs.length) {
      const [i, t] = jobs[next++];
      const file = path.join(dir, String(i).padStart(6, '0') + '.png');
      if (!fs.existsSync(file)) await shot(page, Math.max(0, t), file);
      if (++done % 300 === 0) console.log(`${done}/${jobs.length} ${((Date.now() - t0) / 1000).toFixed(0)}s`);
    }
  }));
}
await browser.close();
