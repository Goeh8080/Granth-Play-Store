import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/ed25519.dart';

Uint8List hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String toHex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('SHA-512 known answers (incl. multi-block)', () {
    expect(toHex(sha512(<int>[])), 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e');
    expect(toHex(sha512(utf8.encode('abc'))), 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f');
    expect(toHex(sha512(utf8.encode('a' * 200))).substring(0, 16), '4b11459c33f52a22'); // verified with hashlib
  });

  test('RFC 8032 vectors verify; tampering fails', () {
    final pk = hex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
    final sig = hex('e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b');
    expect(ed25519Verify(pk, <int>[], sig), isTrue);
    expect(ed25519Verify(pk, [1], sig), isFalse);
    final bad = Uint8List.fromList(sig)..[10] ^= 1;
    expect(ed25519Verify(pk, <int>[], bad), isFalse);
    expect(ed25519Verify(pk, <int>[], sig.sublist(0, 63)), isFalse);
    // vector 2
    final pk2 = hex('3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c');
    final sig2 = hex('92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00');
    expect(ed25519Verify(pk2, [0x72], sig2), isTrue);
  });

  test('canonical JSON: sorted keys, no spaces, JSON.stringify escapes', () {
    expect(canonicalJson({'b': 1, 'a': [true, null, 'x"\n\u0001ह'], 'A': 0.5, 'c': 2.0}), '{"A":0.5,"a":[true,null,"x\\"\\n\\u0001ह"],"b":1,"c":2}');
  });

  test('the real published config verifies', () {
    final j = jsonDecode(File('test/fixtures/live_config.json').readAsStringSync()) as Map<String, dynamic>;
    final sig = base64Decode(j.remove('sig') as String);
    final pk = base64Decode('kdPKX/LfjdbPxugpPnpeEejTZlXKzrcoOg88IK83Fb4=');
    expect(ed25519Verify(pk, canonicalBytes(j), sig), isTrue);
    j['version'] = 99;
    expect(ed25519Verify(pk, canonicalBytes(j), sig), isFalse);
  });
}
