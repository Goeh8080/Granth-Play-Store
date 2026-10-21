/* Granth app ↔ Photo Highlighter bridge (Android WebView compatibility only; no feature
 * changes). Loaded right after tesseract.min.js, before the page's own script.
 *  1. Tesseract worker / core / language data come through the app's local cache, so OCR
 *     works offline after the first use.
 *  2. <a download> clicks with blob:/data: links (jsPDF save, photo download) are handed to
 *     the app, which saves the file into Downloads (WebView itself cannot download them).
 *  3. navigator.share({files}) opens the Android share sheet (WebView has no Web Share).
 */
(function () {
  'use strict';
  var O = location.origin;
  var CH = window.GranthHL;
  function post(o) {
    try { CH && CH.postMessage(JSON.stringify(o)); } catch (e) {}
  }

  // 1. Tesseract paths → local cache (same files and versions the CDN defaults use).
  if (window.Tesseract && typeof Tesseract.createWorker === 'function') {
    var createWorker = Tesseract.createWorker;
    Tesseract.createWorker = function (langs, oem, options, config) {
      var o = Object.assign({
        workerPath: O + '/cdn/cdn.jsdelivr.net/npm/tesseract.js@v5.1.1/dist/worker.min.js',
        corePath: O + '/cdn/cdn.jsdelivr.net/npm/tesseract.js-core@v5.1.1',
        langPath: O + '/tessdata'
      }, options || {});
      return createWorker.call(Tesseract, langs, oem, o, config);
    };
  }

  // 2. Downloads.
  var seq = 0;
  var SLICE = 786432; // multiple of 3 bytes: every slice is whole base64
  function readSlice(blob) {
    return new Promise(function (ok, fail) {
      var r = new FileReader();
      r.onload = function () { var s = String(r.result); ok(s.slice(s.indexOf(',') + 1)); };
      r.onerror = function () { fail(r.error); };
      r.readAsDataURL(blob);
    });
  }
  async function deliverBlob(blob, name, mode) {
    var id = ++seq;
    post({ t: 'begin', id: id, name: name, mime: blob.type || '', size: blob.size, mode: mode });
    try {
      for (var i = 0; i < blob.size; i += SLICE) {
        post({ t: 'chunk', id: id, b64: await readSlice(blob.slice(i, i + SLICE)) });
      }
      post({ t: 'end', id: id });
    } catch (e) {
      post({ t: 'fail', id: id, error: String(e) });
    }
  }
  async function deliverHref(href, name, mode) {
    try {
      var blob = await (await fetch(href)).blob();
      await deliverBlob(blob, name, mode);
    } catch (e) {
      post({ t: 'fail', id: 0, error: String(e) });
    }
  }
  window.__granthDeliver = deliverBlob;
  function grab(a) {
    if (!a || !a.hasAttribute || !a.hasAttribute('download')) return false;
    var h = a.href || '';
    if (!/^(blob:|data:)/i.test(h)) return false;
    deliverHref(h, a.getAttribute('download') || 'file', 'save');
    return true;
  }
  var click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (grab(this)) return;
    return click.apply(this, arguments);
  };
  var dispatch = EventTarget.prototype.dispatchEvent;
  EventTarget.prototype.dispatchEvent = function (ev) {
    if (ev && ev.type === 'click' && this instanceof HTMLAnchorElement && grab(this)) return false;
    return dispatch.apply(this, arguments);
  };

  // 3. Share sheet.
  if (!navigator.share) {
    navigator.canShare = function (d) { return !!(d && d.files && d.files.length); };
    navigator.share = async function (d) {
      if (!d || !d.files || !d.files.length) throw new DOMException('nothing to share', 'TypeError');
      for (var i = 0; i < d.files.length; i++) await deliverBlob(d.files[i], d.files[i].name || 'photo.jpg', 'share');
    };
  }
})();
