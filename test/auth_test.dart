import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:face_privacy/fdae/fdae_chip.dart';
import 'package:face_privacy/recognition/align.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> flat(List p) => [for (final e in p) ...(e as List).map((v) => (v as num).toDouble())];

void main() {
  test('similarity + warp match Python/skimage/cv2 golden', () {
    final cases = jsonDecode(File('test/align_golden.json').readAsStringSync()) as List;
    for (final c in cases) {
      final t = estimateSimilarity(flat(c['src']), flat(c['dst']));
      final p = (c['params'] as List).map((e) => (e as num).toDouble()).toList();
      expect([t.ar, t.ai, t.br, t.bi], [for (final v in p) closeTo(v, 1e-9)]);
      final img = Uint8List.fromList((c['img'] as List).cast<int>());
      final out = warpSimilarity(img, c['img_w'], c['img_h'], t, c['out_w'], c['out_h']);
      final exp = (c['out'] as List).cast<int>();
      for (var i = 0; i < exp.length; i++) {
        expect((out[i] - exp[i]).abs(), lessThanOrEqualTo(1), reason: 'byte $i'); // rounding ties
      }
    }
  });

  test('chip cipher: round trip, wrong key, tamper', () {
    final rnd = List.generate(16 * 16 * 3, (i) => (i * 37 + 11) % 256);
    final rgb = Uint8List.fromList(rnd);
    final key = deriveUserKey(Uint8List(32), 'u1', Uint8List(16));
    final enc = encryptChip(rgb, 16, 16, key, 0, n0: 50);
    expect(decryptChip(enc, 16, 16, key, 0, n0: 50), rgb);
    final wrong = deriveUserKey(Uint8List(32), 'u2', Uint8List(16));
    expect(() => decryptChip(enc, 16, 16, wrong, 0, n0: 50), throwsA(isA<TemplateIntegrityException>()));
    enc.cipher[5] ^= 1;
    expect(() => decryptChip(enc, 16, 16, key, 0, n0: 50), throwsA(isA<TemplateIntegrityException>()));
  });
}
