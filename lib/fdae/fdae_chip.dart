/// FDAE-encrypt / decrypt a small interleaved-RGB face chip, with an HMAC over
/// the PLAINTEXT so a wrong key, corruption or a cross-device float mismatch is
/// reported as TemplateIntegrityException instead of silently "not matching".
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'fdae_cipher.dart';
import 'key_derivation.dart';

class TemplateIntegrityException implements Exception {
  @override
  String toString() => 'Stored face template failed its integrity check '
      '(wrong key, corruption, or decryption mismatch).';
}

class EncryptedChip {
  EncryptedChip(this.cipher, this.ivBits, this.check);
  final Uint8List cipher; // w*h*3 interleaved RGB ciphertext
  final List<int> ivBits; // per-channel iv_bit [R,G,B]
  final Uint8List check; // 16-byte HMAC of the plaintext

  Map<String, dynamic> toJson() =>
      {'c': base64.encode(cipher), 'iv': ivBits, 'k': base64.encode(check)};
  factory EncryptedChip.fromJson(Map<String, dynamic> j) => EncryptedChip(
      base64.decode(j['c'] as String), (j['iv'] as List).cast<int>(), base64.decode(j['k'] as String));
}

/// Per-user, per-enrollment key: HMAC(deviceKey, "fdae-user|id|" || salt).
Uint8List deriveUserKey(Uint8List deviceKey, String userId, Uint8List salt) {
  final d = BytesBuilder()
    ..add(utf8.encode('fdae-user|$userId|'))
    ..add(salt);
  return Uint8List.fromList(Hmac(sha256, deviceKey).convert(d.toBytes()).bytes);
}

Uint8List _check(Uint8List userKey, int idx, Uint8List plain) {
  final d = BytesBuilder()
    ..add(utf8.encode('fdae-chip-check|$idx|'))
    ..add(plain);
  return Uint8List.fromList(Hmac(sha256, userKey).convert(d.toBytes()).bytes.sublist(0, 16));
}

EncryptedChip encryptChip(Uint8List rgb, int w, int h, Uint8List userKey, int idx, {int n0 = 1000}) {
  final keys = deriveFaceKeys(userKey, idx, n0: n0);
  final out = Uint8List(rgb.length);
  final iv = <int>[];
  for (var c = 0; c < 3; c++) {
    final ch = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      ch[i] = rgb[i * 3 + c];
    }
    final ct = fdaeEncrypt(ch, h, w, keys);
    iv.add(ct.ivBit);
    for (var i = 0; i < w * h; i++) {
      out[i * 3 + c] = ct.image[i];
    }
  }
  return EncryptedChip(out, iv, _check(userKey, idx, rgb));
}

Uint8List decryptChip(EncryptedChip e, int w, int h, Uint8List userKey, int idx, {int n0 = 1000}) {
  final keys = deriveFaceKeys(userKey, idx, n0: n0);
  final out = Uint8List(e.cipher.length);
  for (var c = 0; c < 3; c++) {
    final ch = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      ch[i] = e.cipher[i * 3 + c];
    }
    final pt = fdaeDecrypt(FdaeCiphertext(ch, e.ivBits[c]), h, w, keys);
    for (var i = 0; i < w * h; i++) {
      out[i * 3 + c] = pt[i];
    }
  }
  final got = _check(userKey, idx, out);
  var diff = 0; // constant-time compare
  for (var i = 0; i < got.length; i++) {
    diff |= got[i] ^ e.check[i];
  }
  if (diff != 0) throw TemplateIntegrityException();
  return out;
}
