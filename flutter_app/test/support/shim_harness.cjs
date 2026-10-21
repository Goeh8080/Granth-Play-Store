// Runs assets/highlighter/hl-shim.js with tiny DOM stubs and prints what reached the app.
const fs = require('fs');
const posted = [];
class EventTarget_ { dispatchEvent(ev) { return 'native-dispatch'; } }
class HTMLAnchorElement_ extends EventTarget_ {
  constructor() { super(); this.attrs = {}; this.href = ''; }
  hasAttribute(n) { return n in this.attrs; }
  getAttribute(n) { return this.attrs[n]; }
  setAttribute(n, v) { this.attrs[n] = v; }
  click() { posted.push({ t: 'native-click' }); }
}
global.EventTarget = EventTarget_;
global.HTMLAnchorElement = HTMLAnchorElement_;
global.location = { origin: 'http://127.0.0.1:47811' };
global.navigator = global.navigator || {};
global.window = global;
global.GranthHL = { postMessage: (s) => posted.push(JSON.parse(s)) };
global.DOMException = class extends Error {};
global.FileReader = class {
  readAsDataURL(blob) { blob.arrayBuffer().then((b) => { this.result = 'data:x;base64,' + Buffer.from(b).toString('base64'); this.onload(); }); }
};
let created = null;
global.Tesseract = { createWorker: (l, o, opts) => { created = opts; return 'worker'; } };
eval(fs.readFileSync(process.argv[2], 'utf8'));
(async () => {
  const w = Tesseract.createWorker('eng+hin');
  const big = Buffer.alloc(2000000, 7); // > 2 slices
  const a = new HTMLAnchorElement();
  a.href = 'data:application/pdf;base64,' + big.toString('base64');
  a.setAttribute('download', 'Album.pdf');
  a.click();
  const b = new HTMLAnchorElement();
  b.href = 'https://example.com/x';
  b.click(); // not a download: the normal click
  const c = new HTMLAnchorElement();
  c.href = 'data:image/jpeg;base64,/9j/2Q==';
  c.setAttribute('download', 'p.jpg');
  const r = c.dispatchEvent({ type: 'click' }); // FileSaver style
  await new Promise((ok) => setTimeout(ok, 300));
  const can = navigator.canShare({ files: [new Blob(['x'])] });
  console.log(JSON.stringify({ worker: w, opts: created, dispatchResult: r, canShare: can,
    posted: posted.map((p) => (p.t === 'chunk' ? { t: 'chunk', id: p.id, len: Buffer.from(p.b64, 'base64').length } : p)) }));
})();
