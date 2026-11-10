/// Passphrase -> per-face FdaeKeys. All sync so it can run inside the
/// background isolate. Cross-checked against Python hashlib/hmac
/// (test/kdf_golden.json).
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'fdae_cipher.dart';

const kPbkdf2Iterations = 210000; // OWASP 2023 guidance for PBKDF2-HMAC-SHA256

/// PBKDF2-HMAC-SHA256, 32-byte output (a single block).
Uint8List pbkdf2Sha256(String password, Uint8List salt, int iterations) {
  final prf = Hmac(sha256, utf8.encode(password));
  final first = Uint8List(salt.length + 4)
    ..setRange(0, salt.length, salt)
    ..[salt.length + 3] = 1; // INT(1), big-endian
  var u = Uint8List.fromList(prf.convert(first).bytes);
  final t = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = Uint8List.fromList(prf.convert(u).bytes);
    for (var j = 0; j < 32; j++) {
      t[j] ^= u[j];
    }
  }
  return t;
}

/// 8-byte key-check value so a wrong passphrase is detected up front
/// instead of silently "decrypting" to noise.
Uint8List keyCheck(Uint8List master) => Uint8List.fromList(
    Hmac(sha256, master).convert(utf8.encode('fdae-v2|check')).bytes.sublist(0, 8));

FdaeKeys deriveFaceKeys(Uint8List master, int faceIndex, {int n0 = 1000}) {
  final prf = Hmac(sha256, master);
  // Attempt 0 uses the original labels, so every key that was already good is unchanged. If its logistic (z0, r) pair
  // is weak (periodic orbit, z0 has no effect), draw again with a '|retry<N>' label. Deterministic: the decrypt side
  // makes the same choice. Probability of 64 weak draws in a row is negligible.
  for (var attempt = 0; attempt < 64; attempt++) {
    final raw = BytesBuilder();
    for (var c = 0; c < 2; c++) {
      final label = attempt == 0 ? 'fdae-v2|face|$faceIndex|$c' : 'fdae-v2|face|$faceIndex|$c|retry$attempt';
      raw.add(prf.convert(utf8.encode(label)).bytes);
    }
    final bd = ByteData.sublistView(raw.toBytes());
    double u(int j) => (bd.getUint64(8 * j) >>> 11) / 9007199254740992.0; // 2^53
    double m(int j, double lo, double hi) => lo + u(j) * (hi - lo);
    final keys = FdaeKeys(
      x0: m(0, 0.01, 0.99), mu1: m(1, 0.05, 0.45),
      z0: m(2, 0.01, 0.99), r: m(3, 3.6, 4.0),
      y0: m(4, 0.01, 0.99), mu2: m(5, 0.05, 0.45),
      n0: n0,
    );
    if (!logisticKeyIsWeak(keys.z0, keys.r, n0)) return keys;
  }
  throw StateError('could not derive a non-weak key');
}
