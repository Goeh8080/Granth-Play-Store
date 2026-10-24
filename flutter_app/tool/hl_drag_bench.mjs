// Headless-Chrome pointer-drag benchmark for the Photo Highlighter "move a colour layer" path.
// usage: node tool/hl_drag_bench.mjs <label> [cpuThrottle=4]
//   ocr400 puts the 400 word boxes in the top strip (they have pointer-events:auto, so they must not sit under the finger).
// Needs the bench host running (HL_BENCH=1 flutter test test/hl_bench_test.dart) -> /tmp/hlbench/port.
// Real touch input through CDP (Input.dispatchTouchEvent) at ~120 Hz, so Chrome's own input pipeline
// (frame-aligned pointermove) is in the path. Scenarios:
//   plain      : 1 rect layer, no OCR words
//   layers15   : 15 layers (mix of rect / free)
//   ocr400     : 1 layer + 400 OCR word boxes in the overlay (a page after "Detect text")
import puppeteer from '/tmp/hlbench/node_modules/puppeteer-core/lib/esm/puppeteer/puppeteer-core.js';
import fs from 'fs';
const label = process.argv[2] || 'run';
const cpu = Number(process.argv[3] || 4);
const port = fs.readFileSync('/tmp/hlbench/port', 'utf8').trim();
const url = `http://127.0.0.1:${port}/`;
const photo = '/tmp/hlbench/photo.jpg';
const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : 0; };
const scenarios = (process.argv[4] || 'plain,layers15,ocr400').split(',');
const results = {};
for (const sc of scenarios) {
  const b = await puppeteer.launch({ executablePath: '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] });
  const pg = await b.newPage();
  await pg.setViewport({ width: 412, height: 800, deviceScaleFactor: 2.6, isMobile: true, hasTouch: true });
  pg.on('pageerror', (e) => console.error('ERR', e.message.slice(0, 160)));
  pg.on('error', (e) => console.error('PAGECRASH', e.message));
  const cdp = await pg.createCDPSession();
  await pg.goto(url, { waitUntil: 'load' });
  await (await pg.$('#gal')).uploadFile(photo);
  await pg.waitForFunction('typeof images !== "undefined" && images.length > 0', { timeout: 60000 });
  await pg.evaluate(() => new Promise((r) => { openScan(0, 'highlight'); const t = setInterval(() => { if (scanModal.classList.contains('open')) { clearInterval(t); r(); } }, 50); }));
  await new Promise((r) => setTimeout(r, 500));
  const setup = await pg.evaluate((sc) => {
    const sw = scanCanvas.width / dpr, sh = scanCanvas.height / dpr;
    const shapes = [];
    const n = sc === 'layers15' ? 15 : 1;
    for (let i = 0; i < n; i++) {
      const ox = n === 1 ? 0 : (i % 5 - 2) * (sw / 6), oy = n === 1 ? 0 : (Math.floor(i / 5) - 1) * (sh / 5);
      if (i % 3 === 2) {
        const pts = []; for (let k = 0; k < 120; k++) pts.push({ x: ox - 60 + k, y: oy + 20 * Math.sin(k / 6) });
        shapes.push({ type: 'free', color: 'rgba(255,60,0,0.35)', pts, start: pts[0], current: pts[pts.length - 1], thickness: 14, angle: 0, blendMode: 'multiply' });
      } else shapes.push({ type: 'rect', color: 'rgba(255,230,0,0.45)', start: { x: ox - 80, y: oy - 50 }, current: { x: ox + 80, y: oy + 50 }, thickness: 8, angle: 0, blendMode: 'multiply' });
    }
    origImgObj.hlShapes = shapes;
    if (sc === 'ocr400') {
      origImgObj.ocrWords = [];
      for (let i = 0; i < 400; i++) origImgObj.ocrWords.push({ text: 'word' + i, x: -sw / 2 + (i % 80) * (sw / 80), y: -sh / 2 + 14 + Math.floor(i / 80) * 14, w: sw / 96, h: 12, highlighted: false });
      renderOCROverlay();
    }
    selectedShapeIndex = 0;
    document.getElementById('shapeType').value = 'select';
    handleShapeTypeChange();
    drawScan();
    const r = scanCanvas.getBoundingClientRect();
    const s0 = shapes[0];
    window.__c0 = { x: (s0.start.x + s0.current.x) / 2, y: (s0.start.y + s0.current.y) / 2 };
    return { cx: r.left + sw / 2 + (s0.start.x + s0.current.x) / 2, cy: r.top + sh / 2 + (s0.start.y + s0.current.y) / 2, sw, sh, canvasPx: scanCanvas.width + 'x' + scanCanvas.height };
  }, sc);
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: cpu });
  await pg.evaluate(() => {
    window.__d = []; window.__mv = []; window.__fr = []; window.__run = true;
    const od = window.drawScan;
    window.drawScan = function () { const t = performance.now(); const r = od.apply(this, arguments); window.__d.push(performance.now() - t); return r; };
    scanCanvas.addEventListener('pointermove', (e) => window.__mv.push(performance.now() - e.timeStamp), true);
    let last = performance.now();
    (function f(t) { if (!window.__run) return; window.__fr.push(t - last); last = t; requestAnimationFrame(f); })(last);
  });
    const N = 120, STEP = 1.2, DT = 8;
  const t0 = Date.now();
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: setup.cx, y: setup.cy, id: 1 }] });
  for (let i = 1; i <= N; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: setup.cx + i * STEP, y: setup.cy + i * STEP * 0.4, id: 1 }] });
    await new Promise((r) => setTimeout(r, DT));
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  const wall = Date.now() - t0;
  await new Promise((r) => setTimeout(r, 300));
  const m = await pg.evaluate((a) => {
    window.__run = false;
    const s0 = origImgObj.hlShapes[0];
    const cx = (s0.start.x + s0.current.x) / 2, cy = (s0.start.y + s0.current.y) / 2;
    return { d: window.__d, mv: window.__mv, fr: window.__fr, moved: { dx: +(cx - window.__c0.x).toFixed(2), dy: +(cy - window.__c0.y).toFixed(2) } };
  }, {});
  // expected centre displacement is N*STEP (zoom 1) -> compare
  const o = {
    canvas: setup.canvasPx,
    dispatched_moves: N,
    delivered_pointermoves: m.mv.length,
    drawScan_calls: m.d.length,
    drawScan_ms: { mean: +(m.d.reduce((a, c) => a + c, 0) / Math.max(1, m.d.length)).toFixed(2), p95: +q(m.d, 0.95).toFixed(2), max: +Math.max(...m.d).toFixed(2) },
    input_to_handler_ms: { mean: +(m.mv.reduce((a, c) => a + c, 0) / Math.max(1, m.mv.length)).toFixed(2), p95: +q(m.mv, 0.95).toFixed(2) },
    frame_interval_ms: { mean: +(m.fr.reduce((a, c) => a + c, 0) / Math.max(1, m.fr.length)).toFixed(2), p95: +q(m.fr, 0.95).toFixed(2), max: +Math.max(...m.fr).toFixed(2) },
    frames_over_33ms: m.fr.filter((x) => x > 33.4).length,
    wall_ms_for_drag: wall,
    final_layer_offset_px: m.moved,
    expected_offset_px: { dx: N * STEP, dy: +(N * STEP * 0.4).toFixed(1) },
  };
  if (sc === 'ocr400') {
    // functional check of the memoised overlay: tapping a word box must still toggle + redraw it
    o.ocr_tap_check = await pg.evaluate(() => {
      const before = document.querySelectorAll('.ocr-word-box.highlighted').length, n = document.querySelectorAll('.ocr-word-box').length;
      document.querySelectorAll('.ocr-word-box')[5].click();
      const on = document.querySelectorAll('.ocr-word-box.highlighted').length;
      document.querySelectorAll('.ocr-word-box')[5].click();
      const off = document.querySelectorAll('.ocr-word-box.highlighted').length;
      return { boxes: n, highlighted_before: before, after_tap: on, after_second_tap: off };
    });
  }
  results[sc] = o;
  await b.close();
}
const out = { label, cpuThrottle: cpu, scenarios: results };
console.log(JSON.stringify(out, null, 1));
fs.writeFileSync(`/tmp/hlbench/drag-${label}.json`, JSON.stringify(out, null, 1));
