// Headless-Chrome benchmark of the Photo Highlighter page served by the app's local server.
// usage: node tool/hl_bench.mjs <label> [cpuThrottle=4]
// Persistent profile = the WebView's HTTP + code cache across opens. Runs: 1 cold open, then 3 warm opens.
import puppeteer from '/tmp/hlbench/node_modules/puppeteer-core/lib/esm/puppeteer/puppeteer-core.js';
import fs from 'fs';
import { execSync } from 'child_process';
const label = process.argv[2] || 'run';
const cpu = Number(process.argv[3] || 4);
const port = fs.readFileSync('/tmp/hlbench/port', 'utf8').trim();
const url = `http://127.0.0.1:${port}/`;
const prof = `/tmp/hlbench/profile-${label}`;
fs.rmSync(prof, { recursive: true, force: true });
const photo = '/tmp/hlbench/photo.jpg';
if (!fs.existsSync(photo)) execSync(`python3 -c "
from PIL import Image, ImageDraw
import random
random.seed(1)
im = Image.new('RGB',(4000,3000),(240,235,220)); d = ImageDraw.Draw(im)
for i in range(400): d.text((random.randint(0,3900),random.randint(0,2950)),'ग्रंथ प्रबंधन text %d'%i,fill=(20,20,20))
for i in range(300): x=random.randint(0,3800); y=random.randint(0,2800); d.rectangle([x,y,x+random.randint(5,200),y+random.randint(5,200)],outline=(random.randint(0,255),0,90))
im.save('${photo}',quality=92)"`);
const out = [];
for (let n = 0; n < 4; n++) {
  const b = await puppeteer.launch({ executablePath: '/usr/bin/google-chrome', headless: true, userDataDir: prof, args: ['--no-sandbox', '--disable-gpu-shader-disk-cache'] });
  const pg = await b.newPage();
  await pg.setViewport({ width: 412, height: 800, deviceScaleFactor: 2.6, isMobile: true, hasTouch: true });
  const cdp = await pg.createCDPSession();
  await cdp.send('Network.enable');
  let net = 0, cache = 0, bytes = 0;
  cdp.on('Network.requestServedFromCache', () => cache++);
  cdp.on('Network.loadingFinished', (e) => { net++; bytes += e.encodedDataLength; });
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: cpu });
  const t0 = Date.now();
  await pg.goto(url, { waitUntil: 'load' });
  const tLoad = Date.now() - t0;
  await pg.waitForFunction('window.cv && cv.Mat', { timeout: 120000 }).catch(() => {});
  const tCv = Date.now() - t0;
  // representative ops
  const inp = await pg.$('#gal');
  let t1 = Date.now();
  await inp.uploadFile(photo);
  await pg.waitForFunction('typeof images !== "undefined" && images.length > 0', { timeout: 60000 });
  const tPhoto = Date.now() - t1;
  t1 = Date.now();
  await pg.evaluate(async () => { const a = document.createElement('a'); window.__c = 0; HTMLAnchorElement.prototype.click = function () { window.__c++; }; await downloadPDF(); });
  const tPdf = Date.now() - t1;
  t1 = Date.now();
  const tOcr = await pg.evaluate(async () => {
    const t = performance.now();
    const w = await Tesseract.createWorker('eng');
    const ready = performance.now() - t;
    await w.terminate();
    return ready;
  }).catch((e) => -1);
  const tOcrTotal = Date.now() - t1;
  out.push({ open: n === 0 ? 'cold' : 'warm' + n, load_ms: tLoad, opencv_ready_ms: tCv, photo4000x3000_ms: tPhoto, mergedPdf_ms: tPdf, ocr_worker_ready_ms: Math.round(tOcr), ocr_total_ms: tOcrTotal, reqs_over_http: net, served_from_cache: cache, MB_over_http: +(bytes / 1048576).toFixed(2) });
  await b.close();
}
console.log(JSON.stringify({ label, cpuThrottle: cpu, runs: out }, null, 1));
fs.writeFileSync(`/tmp/hlbench/result-${label}.json`, JSON.stringify({ label, cpuThrottle: cpu, runs: out }, null, 1));
