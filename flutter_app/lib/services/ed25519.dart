import 'dart:convert';
import 'dart:typed_data';

/// Pure-Dart Ed25519 *verification* (RFC 8032) and SHA-512 — no package, no plugin.
///
/// Used only to check the signature of the remote config (`remote_config.dart`); the app never
/// signs anything. One verification is ~2 scalar multiplications on BigInt (a few ms to tens of
/// ms on a phone), done once per changed config. Not constant-time — it handles only public data.

// ---------------------------------------------------------------- SHA-512

const List<int> _k = [
  0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
  0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
  0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
  0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
  0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
  0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
  0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
  0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
  0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
  0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
  0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
  0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
  0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
  0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
  0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
  0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
  0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
  0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
  0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
  0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
];

int _rotr(int x, int n) => (x >>> n) | (x << (64 - n));

/// SHA-512 of [data] (64 bytes). Dart's 64-bit ints wrap, which is exactly mod 2^64.
Uint8List sha512(List<int> data) {
  final h = <int>[
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1, 0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
  ];
  final len = data.length;
  final padded = Uint8List(((len + 17 + 127) ~/ 128) * 128)..setRange(0, len, data);
  padded[len] = 0x80;
  final bits = len * 8;
  final bd = ByteData.view(padded.buffer);
  bd.setUint64(padded.length - 8, bits);
  final w = List<int>.filled(80, 0);
  for (var off = 0; off < padded.length; off += 128) {
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getUint64(off + i * 8);
    }
    for (var i = 16; i < 80; i++) {
      final s0 = _rotr(w[i - 15], 1) ^ _rotr(w[i - 15], 8) ^ (w[i - 15] >>> 7);
      final s1 = _rotr(w[i - 2], 19) ^ _rotr(w[i - 2], 61) ^ (w[i - 2] >>> 6);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 80; i++) {
      final s1 = _rotr(e, 14) ^ _rotr(e, 18) ^ _rotr(e, 41);
      final ch = (e & f) ^ (~e & g);
      final t1 = hh + s1 + ch + _k[i] + w[i];
      final s0 = _rotr(a, 28) ^ _rotr(a, 34) ^ _rotr(a, 39);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = s0 + maj;
      hh = g;
      g = f;
      f = e;
      e = d + t1;
      d = c;
      c = b;
      b = a;
      a = t1 + t2;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += hh;
  }
  final out = ByteData(64);
  for (var i = 0; i < 8; i++) {
    out.setUint64(i * 8, h[i]);
  }
  return out.buffer.asUint8List();
}

// ---------------------------------------------------------------- Ed25519

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l = (BigInt.one << 252) + BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d = (BigInt.from(-121665) * _inv(BigInt.from(121666))) % _p;
final BigInt _i = BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p); // sqrt(-1)

BigInt _inv(BigInt x) => x.modPow(_p - BigInt.two, _p);

/// Extended homogeneous coordinates (X, Y, Z, T): x = X/Z, y = Y/Z, xy = T/Z.
class _Pt {
  _Pt(this.x, this.y, this.z, this.t);
  final BigInt x, y, z, t;
}

final _Pt _zero = _Pt(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);

_Pt _add(_Pt a, _Pt b) {
  final aa = (a.y - a.x) * (b.y - b.x) % _p;
  final bb = (a.y + a.x) * (b.y + b.x) % _p;
  final cc = BigInt.two * a.t * b.t * _d % _p;
  final dd = BigInt.two * a.z * b.z % _p;
  final e = bb - aa, f = dd - cc, g = dd + cc, h = bb + aa;
  return _Pt(e * f % _p, g * h % _p, f * g % _p, e * h % _p);
}

_Pt _mul(_Pt p, BigInt s) {
  var q = _zero;
  var a = p;
  var k = s;
  while (k > BigInt.zero) {
    if (k.isOdd) q = _add(q, a);
    a = _add(a, a);
    k >>= 1;
  }
  return q;
}

BigInt _bytesToInt(List<int> b) {
  var r = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

Uint8List _encode(_Pt p) {
  final zi = _inv(p.z);
  final x = p.x * zi % _p, y = p.y * zi % _p;
  final out = Uint8List(32);
  var v = y;
  final ff = BigInt.from(255);
  for (var i = 0; i < 32; i++) {
    out[i] = (v & ff).toInt();
    v >>= 8;
  }
  if (x.isOdd) out[31] |= 0x80;
  return out;
}

_Pt? _decode(List<int> s) {
  if (s.length != 32) return null;
  final sign = (s[31] >> 7) & 1;
  final yb = List<int>.of(s)..[31] &= 0x7f;
  final y = _bytesToInt(yb);
  if (y >= _p) return null;
  final y2 = y * y % _p;
  final u = (y2 - BigInt.one) % _p;
  final v = (_d * y2 + BigInt.one) % _p;
  final x2 = u * _inv(v) % _p;
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) x = x * _i % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if (x == BigInt.zero && sign == 1) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = (_p - x) % _p;
  return _Pt(x, y, BigInt.one, x * y % _p);
}

final _Pt _base = () {
  final y = BigInt.from(4) * _inv(BigInt.from(5)) % _p;
  final b = Uint8List(32);
  var v = y;
  for (var i = 0; i < 32; i++) {
    b[i] = (v & BigInt.from(255)).toInt();
    v >>= 8;
  }
  return _decode(b)!; // sign bit 0 = the even x of the standard base point
}();

/// True when [sig] (64 bytes) is a valid Ed25519 signature of [message] for [publicKey] (32 bytes).
/// Never throws: any malformed input is simply "not valid".
bool ed25519Verify(List<int> publicKey, List<int> message, List<int> sig) {
  try {
    if (publicKey.length != 32 || sig.length != 64) return false;
    final a = _decode(publicKey);
    final r = _decode(sig.sublist(0, 32));
    if (a == null || r == null) return false;
    final s = _bytesToInt(sig.sublist(32));
    if (s >= _l) return false;
    final h = _bytesToInt(sha512([...sig.sublist(0, 32), ...publicKey, ...message])) % _l;
    final lhs = _encode(_mul(_base, s));
    final rhs = _encode(_add(r, _mul(a, h)));
    for (var i = 0; i < 32; i++) {
      if (lhs[i] != rhs[i]) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------- canonical JSON

/// The text the server signs: keys sorted by UTF-16 code units, arrays in order, no whitespace,
/// `JSON.stringify` escaping. Mirrors `canonical()` in the admin server (src/util.js).
String canonicalJson(Object? v) {
  final b = StringBuffer();
  _canon(v, b);
  return b.toString();
}

void _canon(Object? v, StringBuffer b) {
  if (v == null) {
    b.write('null');
  } else if (v is bool) {
    b.write(v ? 'true' : 'false');
  } else if (v is num) {
    b.write(_num(v));
  } else if (v is String) {
    _str(v, b);
  } else if (v is List) {
    b.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) b.write(',');
      _canon(v[i], b);
    }
    b.write(']');
  } else if (v is Map) {
    final keys = [for (final k in v.keys) '$k']..sort(); // String.compareTo = UTF-16 code units
    b.write('{');
    var first = true;
    for (final k in keys) {
      if (!first) b.write(',');
      first = false;
      _str(k, b);
      b.write(':');
      _canon(v[k], b);
    }
    b.write('}');
  } else {
    throw ArgumentError('not JSON: ${v.runtimeType}');
  }
}

String _num(num n) {
  if (n is int) return '$n';
  final d = n.toDouble();
  if (d.isNaN || d.isInfinite) return 'null';
  if (d == d.truncateToDouble() && d.abs() < 1e21) return d.toInt().toString();
  return d.toString();
}

void _str(String s, StringBuffer b) {
  b.write('"');
  final u = s.codeUnits;
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    switch (c) {
      case 0x22:
        b.write(r'\"');
      case 0x5c:
        b.write(r'\\');
      case 0x08:
        b.write(r'\b');
      case 0x0c:
        b.write(r'\f');
      case 0x0a:
        b.write(r'\n');
      case 0x0d:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        if (c < 0x20) {
          b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < u.length && u[i + 1] >= 0xdc00 && u[i + 1] <= 0xdfff) {
          b.writeCharCode(c);
          b.writeCharCode(u[++i]);
        } else if (c >= 0xd800 && c <= 0xdfff) {
          b.write('\\u${c.toRadixString(16)}'); // lone surrogate (well-formed JSON.stringify)
        } else {
          b.writeCharCode(c);
        }
    }
  }
  b.write('"');
}

/// The UTF-8 bytes of [canonicalJson].
Uint8List canonicalBytes(Object? v) => Uint8List.fromList(utf8.encode(canonicalJson(v)));
