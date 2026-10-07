import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:face_privacy/fdae/fdae_cipher.dart';
import 'package:face_privacy/fdae/key_derivation.dart';
import 'package:face_privacy/fdae/png_meta.dart';
import 'package:flutter_test/flutter_test.dart';

String hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('FDAE matches Python reference (golden vectors)', () {
    final cases = jsonDecode(File('test/golden.json').readAsStringSync()) as List;
    for (final c in cases) {
      final h = c['h'] as int, w = c['w'] as int;
      final keys = FdaeKeys.fromJson(c['keys']);
      final plain = Uint8List.fromList((c['plain'] as List).cast<int>());
      final ct = fdaeEncrypt(plain, h, w, keys);
      expect(ct.image, Uint8List.fromList((c['cipher'] as List).cast<int>()));
      expect(ct.ivBit, c['iv_bit']);
      expect(fdaeDecrypt(ct, h, w, keys), plain);
    }
  });

  test('KDF + per-face keys match Python hashlib/hmac', () {
    final g = jsonDecode(File('test/kdf_golden.json').readAsStringSync());
    final salt = Uint8List.fromList(List.generate(16, (i) => i));
    final master = pbkdf2Sha256(g['passphrase'], salt, g['iterations']);
    expect(hex(master), g['master_hex']);
    expect(hex(keyCheck(master)), g['check_hex']);
    for (final f in ['face0', 'face1']) {
      final k = deriveFaceKeys(master, f == 'face0' ? 0 : 1);
      final e = g[f];
      expect([k.x0, k.mu1, k.z0, k.r, k.y0, k.mu2],
          [e['x0'], e['mu1'], e['z0'], e['r'], e['y0'], e['mu2']]);
    }
  });

  test('PNG tEXt chunk round trip keeps PNG structure', () {
    // minimal valid PNG tail: signature + IEND
    final png = Uint8List.fromList([
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]);
    final out = injectTextChunk(png, 'fdae', 'aGVsbG8=');
    expect(readTextChunk(out, 'fdae'), 'aGVsbG8=');
    expect(out.sublist(out.length - 12), png.sublist(png.length - 12));
  });
}
