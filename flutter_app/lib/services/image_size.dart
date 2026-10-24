import 'dart:io';
import 'dart:typed_data';

/// Shape (width ÷ height) of a saved picture, read from its file header without decoding.
///
/// A picture list is only as tall as its pictures are decoded; going back to a list rebuilds
/// it from the top with nothing decoded yet, so every row would be short and the saved scroll
/// position could not be reached. Giving a picture its final height before it is decoded
/// makes the list the same height every time.
class ImageSizes {
  ImageSizes._();
  static final ImageSizes I = ImageSizes._();

  final Map<String, double> _ratio = {};

  /// Width ÷ height of the picture in [f] (null: unknown — it is then sized when decoded).
  double? ratioOf(File f) {
    final k = f.path;
    final hit = _ratio[k];
    if (hit != null) return hit > 0 ? hit : null;
    double r = 0;
    try {
      final raf = f.openSync();
      try {
        for (final n in const [16 << 10, 96 << 10]) {
          raf.setPositionSync(0);
          final b = raf.readSync(n);
          final rr = ratioOfHeader(b);
          if (rr != null) {
            r = rr;
            break;
          }
          if (b.length < n) break;
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    _ratio[k] = r;
    return r > 0 ? r : null;
  }

  /// A size learned from the decoded picture (for files whose header says too little).
  void learn(File f, double ratio) {
    if (ratio.isFinite && ratio > 0) _ratio[f.path] = ratio;
  }

  void forget(File f) => _ratio.remove(f.path);

  void clear() => _ratio.clear();
}

/// width ÷ height from the first bytes of a PNG / JPEG / GIF / WebP; null when it cannot be
/// told for sure (including rotated JPEGs: EXIF orientation 5–8 swaps the sides, so those are
/// measured after decoding instead).
double? ratioOfHeader(Uint8List b) {
  int u16(int i) => (b[i] << 8) | b[i + 1];
  int u32(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int le24(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  double? of(int w, int h) => w > 0 && h > 0 ? w / h : null;
  final n = b.length;
  if (n < 24) return null;
  // PNG
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return of(u32(16), u32(20));
  // GIF
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return of(le16(6), le16(8));
  // WebP
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    if (n < 30) return null;
    final t = String.fromCharCodes(b.sublist(12, 16));
    if (t == 'VP8 ' && n >= 30) return of(le16(26) & 0x3FFF, le16(28) & 0x3FFF);
    if (t == 'VP8L' && n >= 25) {
      final v = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return of((v & 0x3FFF) + 1, ((v >> 14) & 0x3FFF) + 1);
    }
    if (t == 'VP8X' && n >= 30) return of(le24(24) + 1, le24(27) + 1);
    return null;
  }
  // JPEG
  if (b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    var orientation = 1;
    while (i + 4 <= n) {
      if (b[i] != 0xFF) return null;
      while (i < n && b[i] == 0xFF) {
        i++;
      }
      if (i >= n) return null;
      final m = b[i++];
      if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) continue;
      if (m == 0xD9 || m == 0xDA) return null;
      if (i + 2 > n) return null;
      final len = u16(i);
      if (len < 2) return null;
      if (m == 0xE1 && i + 2 + 14 <= n && b[i + 2] == 0x45 && b[i + 3] == 0x78 && b[i + 4] == 0x69 && b[i + 5] == 0x66) {
        orientation = _exifOrientation(b, i + 8, (i + len).clamp(0, n));
      }
      final sof = m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;
      if (sof) {
        if (i + 7 > n) return null;
        if (orientation >= 5) return null;
        return of(u16(i + 5), u16(i + 3));
      }
      i += len;
    }
  }
  return null;
}

/// EXIF orientation (1–8) from the TIFF block starting at [t] (1 when absent).
int _exifOrientation(Uint8List b, int t, int end) {
  if (t + 8 > end) return 1;
  final le = b[t] == 0x49;
  int r16(int i) => le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1];
  int r32(int i) => le ? b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24) : (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  final ifd = t + r32(t + 4);
  if (ifd + 2 > end) return 1;
  final cnt = r16(ifd);
  for (var k = 0; k < cnt; k++) {
    final e = ifd + 2 + k * 12;
    if (e + 12 > end) break;
    if (r16(e) == 0x0112) {
      final v = r16(e + 8);
      return v >= 1 && v <= 8 ? v : 1;
    }
  }
  return 1;
}
