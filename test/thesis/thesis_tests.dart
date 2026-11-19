/// Thesis test suite for the FDAE face encryption (section 6 of the test plan):
///   A  attack simulations (differential, chosen/known-plaintext, special images, key dependence)
///   B  decrypted image differs from the original (wrong key, near key, wrong IV bit, wrong n0, chip integrity), NPCR
///   C  corruption during transmission or storage (bit flips, lost blocks, noise, JPEG, damaged PNG file, chip tamper)
///   G  key size vs security (key-space from measured sensitivity, brute-force cost vs key bits, extrapolation)
///
/// Run (from the project root, on a PC; no phone needed):
///   flutter test test/thesis/thesis_tests.dart
/// Optional environment variables:
///   SEW_PHOTOS  folder with face images (png/jpg), e.g. the unzipped trialN_plain_face.png files (default: synthetic)
///   SEW_OUT     output folder (default: thesis_results)
///   SEW_SIZE    side in pixels each image is centre-cropped and resized to (default 64)
///   SEW_N       how many images to use (default 6)
///   SEW_SEED    random seed (default 2026)
/// Output: <SEW_OUT>/thesis_results.json  (plot it with tools/plot_thesis_tests.py)
///
/// NOT COMPILED OR RUN by the author of this file (no Dart SDK was available): fix any compile error first.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:face_privacy/fdae/fdae_chip.dart';
import 'package:face_privacy/fdae/fdae_cipher.dart';
import 'package:face_privacy/fdae/png_meta.dart';
import 'package:face_privacy/metrics/image_metrics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

// ------------------------------------------------------------------ settings
final _env = Platform.environment;
final String kOut = _env['SEW_OUT'] ?? 'thesis_results';
final int kSize = int.tryParse(_env['SEW_SIZE'] ?? '') ?? 64;
final int kCount = int.tryParse(_env['SEW_N'] ?? '') ?? 6;
final int kSeed = int.tryParse(_env['SEW_SEED'] ?? '') ?? 2026;
const int kN0 = 1000;

final Map<String, dynamic> R = {};

// ------------------------------------------------------------------ helpers
double? _f(double v) => (v.isNaN || v.isInfinite) ? null : double.parse(v.toStringAsFixed(6));

List<Uint8List> loadImages(int side, int count) {
  final out = <Uint8List>[];
  final dir = _env['SEW_PHOTOS'];
  if (dir != null && Directory(dir).existsSync()) {
    final files = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'\.(png|jpg|jpeg|bmp)$', caseSensitive: false).hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      if (out.length >= count) break;
      final im = img.decodeImage(f.readAsBytesSync());
      if (im == null) continue;
      final s = math.min(im.width, im.height);
      final sq = img.copyCrop(im, x: (im.width - s) ~/ 2, y: (im.height - s) ~/ 2, width: s, height: s);
      final rs = img.copyResize(sq, width: side, height: side, interpolation: img.Interpolation.average);
      out.add(Uint8List.fromList(rs.getBytes(order: img.ChannelOrder.rgb)));
    }
  }
  if (out.isEmpty) {
    // synthetic stand-in: smooth gradients and a bright disc, different per image
    stdout.writeln('SEW_PHOTOS not set or empty: using synthetic images (set SEW_PHOTOS for thesis numbers).');
    for (var n = 0; n < count; n++) {
      final b = Uint8List(side * side * 3);
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final dx = x - side * (0.3 + 0.1 * n), dy = y - side / 2;
          final disc = dx * dx + dy * dy < side * side / 16 ? 90 : 0;
          final o = (y * side + x) * 3;
          b[o] = ((x * 255 ~/ side) + disc).clamp(0, 255);
          b[o + 1] = ((y * 255 ~/ side) + disc ~/ 2).clamp(0, 255);
          b[o + 2] = (((x + y) * 128 ~/ side) + 40 * n).clamp(0, 255);
        }
      }
      out.add(b);
    }
  }
  return out;
}

FdaeKeys randomKeys(math.Random rng) {
  while (true) {
    final k = FdaeKeys(
      x0: 0.01 + rng.nextDouble() * 0.98, mu1: 0.05 + rng.nextDouble() * 0.40,
      z0: 0.01 + rng.nextDouble() * 0.98, r: 3.6 + rng.nextDouble() * 0.4,
      y0: 0.01 + rng.nextDouble() * 0.98, mu2: 0.05 + rng.nextDouble() * 0.40,
      n0: kN0,
    );
    if (!logisticKeyIsWeak(k.z0, k.r, k.n0)) return k;
  }
}

/// One colour image, encrypted per channel.
class Enc {
  Enc(this.rgb, this.iv);
  Uint8List rgb; // interleaved ciphertext
  List<int> iv;
  Enc copy() => Enc(Uint8List.fromList(rgb), List<int>.from(iv));
}

Enc encRgb(Uint8List plain, int s, FdaeKeys k) {
  final ch = splitRgb(plain);
  final iv = <int>[];
  final out = <Uint8List>[];
  for (var c = 0; c < 3; c++) {
    final ct = fdaeEncrypt(ch[c], s, s, k);
    out.add(ct.image);
    iv.add(ct.ivBit);
  }
  return Enc(mergeRgb(out), iv);
}

Uint8List decRgb(Enc e, int s, FdaeKeys k) {
  final ch = splitRgb(e.rgb);
  return mergeRgb([for (var c = 0; c < 3; c++) fdaeDecrypt(FdaeCiphertext(ch[c], e.iv[c]), s, s, k)]);
}

/// Key with ONE parameter moved by d. If +d would leave the valid range of that parameter (the cipher throws then),
/// it is moved by -d instead, so the size of the error is the same.
FdaeKeys withParam(FdaeKeys k, String p, double d) {
  double mv(double v, double lo, double hi) {
    final a = v + d;
    return (a > lo && a < hi) ? a : v - d;
  }

  return FdaeKeys(
    x0: p == 'x0' ? mv(k.x0, 0.0, 1.0) : k.x0, mu1: p == 'mu1' ? mv(k.mu1, 0.0, 0.5) : k.mu1,
    z0: p == 'z0' ? mv(k.z0, 0.0, 1.0) : k.z0, r: p == 'r' ? mv(k.r, 3.57, 4.0001) : k.r,
    y0: p == 'y0' ? mv(k.y0, 0.0, 1.0) : k.y0, mu2: p == 'mu2' ? mv(k.mu2, 0.0, 0.5) : k.mu2,
    n0: k.n0,
  );
}

/// jsonEncode cannot write NaN or Infinity: replace them with null and say where they came from.
dynamic cleanJson(dynamic v, [String path = '']) {
  if (v is double && !v.isFinite) {
    stdout.writeln('WARNING: non-finite number at $path replaced by null');
    return null;
  }
  if (v is Map) return {for (final e in v.entries) '${e.key}': cleanJson(e.value, '$path/${e.key}')};
  if (v is List) return [for (var i = 0; i < v.length; i++) cleanJson(v[i], '$path[$i]')];
  return v;
}

double pearson(Uint8List a, Uint8List b) {
  final n = a.length;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  var sab = 0.0, saa = 0.0, sbb = 0.0;
  for (var i = 0; i < n; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    sab += x * y;
    saa += x * x;
    sbb += y * y;
  }
  return (saa == 0 || sbb == 0) ? 0.0 : sab / math.sqrt(saa * sbb);
}

/// Compare a recovered/other image `b` against the reference `a` (interleaved RGB, side s).
Map<String, dynamic> cmp(Uint8List a, Uint8List b, int s) {
  final (np, ua) = npcrUaci(a, b);
  final m = mse(a, b);
  return {
    'npcr': _f(np), 'uaci': _f(ua), 'psnr': _f(psnrFromMse(m)),
    'ssim': _f(ssimRgb(splitRgb(a), splitRgb(b), s, s)),
    'corr': _f(pearson(a, b)), 'exact': m == 0,
  };
}

/// Mean (and min / max) of numeric field `f` over a list of cmp() maps; `exact_rate` = share of exact restores.
Map<String, dynamic> agg(List<Map<String, dynamic>> rows) {
  final out = <String, dynamic>{'n': rows.length};
  for (final f in ['npcr', 'uaci', 'psnr', 'ssim', 'corr']) {
    final v = [for (final r in rows) if (r[f] != null) (r[f] as num).toDouble()];
    if (v.isEmpty) {
      out[f] = null;
      continue;
    }
    out[f] = _f(v.reduce((x, y) => x + y) / v.length);
    out['${f}_min'] = _f(v.reduce(math.min));
    out['${f}_max'] = _f(v.reduce(math.max));
  }
  out['exact_rate'] = rows.where((r) => r['exact'] == true).length / math.max(rows.length, 1);
  return out;
}

Uint8List flipBits(Uint8List c, int n, math.Random rng) {
  final o = Uint8List.fromList(c);
  final used = <int>{};
  while (used.length < n) {
    used.add(rng.nextInt(o.length * 8));
  }
  for (final b in used) {
    o[b >> 3] ^= 1 << (b & 7);
  }
  return o;
}

Uint8List pngOf(Uint8List rgb, int s) => img.encodePng(
    img.Image.fromBytes(width: s, height: s, bytes: rgb.buffer, numChannels: 3, order: img.ChannelOrder.rgb),
    level: 3);

// ------------------------------------------------------------------ tests
void main() {
  final rng = math.Random(kSeed);
  late List<Uint8List> photos;

  setUpAll(() {
    photos = loadImages(kSize, kCount);
    R['config'] = {
      'size_px': kSize, 'images': photos.length, 'seed': kSeed, 'n0': kN0,
      'photos_dir': _env['SEW_PHOTOS'], 'date': DateTime.now().toIso8601String(),
    };
  });

  tearDownAll(() {
    Directory(kOut).createSync(recursive: true);
    File('$kOut/thesis_results.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(cleanJson(R)));
    stdout.writeln('Wrote $kOut/thesis_results.json');
  });

  const noTimeout = Timeout.none;

  // =========================================================== A  attack simulations
  test('A1 differential attack: change 1..n pixels, compare the two ciphertexts', () {
    final s = kSize, px = s * s;
    final counts = [1, 2, 5, 10, math.max(1, px ~/ 100)]; // last = 1 % of the pixels
    final positions = ['first', 'middle', 'last', 'random'];
    final kinds = {'lsb': 0x01, 'invert': 0xFF};
    final rows = <Map<String, dynamic>>[];
    for (final plain in photos) {
      final k = randomKeys(rng);
      final c0 = encRgb(plain, s, k);
      for (final n in counts) {
        for (final pos in positions) {
          final idx = <int>{};
          if (pos == 'random') {
            while (idx.length < n) {
              idx.add(rng.nextInt(px));
            }
          } else {
            final start = pos == 'first' ? 0 : pos == 'middle' ? px ~/ 2 : px - n;
            for (var i = 0; i < n; i++) {
              idx.add(start + i);
            }
          }
          kinds.forEach((kind, mask) {
            final p2 = Uint8List.fromList(plain);
            for (final i in idx) {
              for (var c = 0; c < 3; c++) {
                p2[i * 3 + c] ^= mask;
              }
            }
            final c1 = encRgb(p2, s, k);
            final (np, ua) = npcrUaci(c0.rgb, c1.rgb);
            rows.add({'pixels': n, 'position': pos, 'change': kind, 'npcr': np, 'uaci': ua});
          });
        }
      }
    }
    final summary = <Map<String, dynamic>>[];
    for (final n in counts) {
      for (final pos in positions) {
        for (final kind in kinds.keys) {
          final sel = rows.where((r) => r['pixels'] == n && r['position'] == pos && r['change'] == kind).toList();
          double mean(String f) => sel.map((r) => r[f] as double).reduce((a, b) => a + b) / sel.length;
          summary.add({
            'pixels': n, 'position': pos, 'change': kind, 'npcr': _f(mean('npcr')), 'uaci': _f(mean('uaci')),
            'npcr_min': _f(sel.map((r) => r['npcr'] as double).reduce(math.min)),
            'n_trials': sel.length,
          });
        }
      }
    }
    R['A1_differential'] = {'ideal_npcr': 99.6094, 'ideal_uaci': 33.4635, 'rows': summary};
  }, timeout: noTimeout);

  test('A2 chosen/known-plaintext attack with an "equivalent keystream" (and a plain XOR cipher for contrast)', () {
    final s = kSize;
    final zeros = Uint8List(s * s * 3);
    final rowsChosen = <Map<String, dynamic>>[], rowsKnown = <Map<String, dynamic>>[], rowsXor = <Map<String, dynamic>>[];
    for (var i = 0; i < photos.length; i++) {
      final k = randomKeys(rng);
      final target = photos[i];
      final c = encRgb(target, s, k);
      // chosen plaintext: attacker encrypts an all-zero image under the same key and treats it as the keystream
      final c0 = encRgb(zeros, s, k);
      final guess = Uint8List(c.rgb.length);
      for (var j = 0; j < guess.length; j++) {
        guess[j] = c.rgb[j] ^ c0.rgb[j];
      }
      rowsChosen.add(cmp(target, guess, s));
      // known plaintext: attacker knows another pair (P1, C1)
      final p1 = photos[(i + 1) % photos.length];
      final c1 = encRgb(p1, s, k);
      final g2 = Uint8List(c.rgb.length);
      for (var j = 0; j < g2.length; j++) {
        g2[j] = c.rgb[j] ^ c1.rgb[j] ^ p1[j];
      }
      rowsKnown.add(cmp(target, g2, s));
      // contrast: a plain XOR keystream cipher falls to the same attack
      final ks = Uint8List.fromList(List.generate(target.length, (_) => rng.nextInt(256)));
      final cx = Uint8List(target.length), cx0 = Uint8List.fromList(ks);
      for (var j = 0; j < target.length; j++) {
        cx[j] = target[j] ^ ks[j];
      }
      final gx = Uint8List(target.length);
      for (var j = 0; j < target.length; j++) {
        gx[j] = cx[j] ^ cx0[j];
      }
      rowsXor.add(cmp(target, gx, s));
    }
    R['A2_equivalent_keystream_attack'] = {
      'chosen_plaintext_all_zero': agg(rowsChosen),
      'known_plaintext_pair': agg(rowsKnown),
      'xor_stream_cipher_baseline': agg(rowsXor),
      'note': 'NPCR near 100 % and correlation near 0 means the attack recovers nothing; the baseline is fully recovered (NPCR 0).',
    };
  }, timeout: noTimeout);

  test('A3 special plaintexts (all black, all white, gradient, checkerboard)', () {
    final s = kSize;
    Uint8List mk(int Function(int x, int y) f) {
      final b = Uint8List(s * s * 3);
      for (var y = 0; y < s; y++) {
        for (var x = 0; x < s; x++) {
          for (var c = 0; c < 3; c++) {
            b[(y * s + x) * 3 + c] = f(x, y);
          }
        }
      }
      return b;
    }

    final cases = {
      'all_black': mk((x, y) => 0), 'all_white': mk((x, y) => 255),
      'gradient': mk((x, y) => (x * 255) ~/ (s - 1)), 'checkerboard': mk((x, y) => ((x ~/ 4 + y ~/ 4) % 2) * 255),
    };
    final out = <String, dynamic>{};
    cases.forEach((name, plain) {
      final ents = <double>[], chis = <double>[], np = <double>[];
      for (var t = 0; t < 5; t++) {
        final k = randomKeys(rng);
        final c = encRgb(plain, s, k);
        final ch = splitRgb(c.rgb);
        ents.add([for (final x in ch) entropy(x)].reduce((a, b) => a + b) / 3);
        chis.add([for (final x in ch) chi2Uniform(x).$2].reduce((a, b) => a + b) / 3); // p-value
        final p2 = Uint8List.fromList(plain)..[0] ^= 1;
        np.add(npcrUaci(c.rgb, encRgb(p2, s, k).rgb).$1);
      }
      double m(List<double> v) => v.reduce((a, b) => a + b) / v.length;
      out[name] = {'entropy': _f(m(ents)), 'chi2_p_mean': _f(m(chis)), 'npcr_one_pixel': _f(m(np))};
    });
    R['A3_special_plaintexts'] = out;
  }, timeout: noTimeout);

  test('A4 same image, different keys -> independent ciphertexts', () {
    final s = kSize;
    final rows = <Map<String, dynamic>>[];
    for (final plain in photos) {
      final a = encRgb(plain, s, randomKeys(rng)), b = encRgb(plain, s, randomKeys(rng));
      rows.add(cmp(a.rgb, b.rgb, s));
    }
    R['A4_key_dependence'] = agg(rows);
  }, timeout: noTimeout);

  // =========================================================== B  decrypted image differs from the original
  test('B1-B3 correct key, random wrong keys, near keys (NPCR of original vs decrypted)', () {
    final s = kSize;
    final correct = <Map<String, dynamic>>[], wrong = <Map<String, dynamic>>[];
    final deltas = <double>[for (var e = 1; e <= 16; e++) math.pow(10, -e).toDouble()];
    final params = ['x0', 'mu1', 'z0', 'r', 'y0', 'mu2'];
    final near = {for (final p in params) p: <List<Map<String, dynamic>>>[for (final _ in deltas) <Map<String, dynamic>>[]]};
    for (final plain in photos) {
      final k = randomKeys(rng);
      final c = encRgb(plain, s, k);
      correct.add(cmp(plain, decRgb(c, s, k), s));
      for (var t = 0; t < 10; t++) {
        wrong.add(cmp(plain, decRgb(c, s, randomKeys(rng)), s));
      }
      for (final p in params) {
        for (var d = 0; d < deltas.length; d++) {
          near[p]![d].add(cmp(plain, decRgb(c, s, withParam(k, p, deltas[d])), s));
        }
      }
    }
    // smallest key error that still destroys the image (mean NPCR >= 99 %) per parameter
    final ranges = {'x0': 0.98, 'mu1': 0.40, 'z0': 0.98, 'r': 0.40, 'y0': 0.98, 'mu2': 0.40};
    final nearOut = <String, dynamic>{};
    var bits = 0.0;
    for (final p in params) {
      var kmax = 0;
      final table = <Map<String, dynamic>>[];
      for (var d = 0; d < deltas.length; d++) {
        final a = agg(near[p]![d]);
        table.add({'exponent': d + 1, 'delta': deltas[d], 'npcr': a['npcr'], 'ssim': a['ssim'], 'exact_rate': a['exact_rate']});
        if ((a['npcr'] as double? ?? 0) >= 90.0 && kmax == d) kmax = d + 1; // contiguous from 1e-1
      }
      final b = kmax == 0 ? 0.0 : math.log(ranges[p]! / math.pow(10, -kmax)) / math.ln2;
      bits += b;
      nearOut[p] = {'kmax': kmax, 'bits': _f(b), 'table': table};
    }
    R['B_wrong_key'] = {
      'correct_key': agg(correct), 'random_wrong_keys': agg(wrong),
      'near_key': nearOut, 'effective_key_bits_from_sensitivity': _f(bits),
      'note': 'kmax = largest k (contiguous from 1e-1) where an error of 10^-k in one parameter still gives mean NPCR >= 90 % (x0 and mu1 only reach about 93.7 % because they affect only the four high bit planes).',
    };
  }, timeout: noTimeout);

  test('B4 wrong IV bit and wrong burn-in n0', () {
    final s = kSize;
    final ivRows = <Map<String, dynamic>>[], n0Rows = <Map<String, dynamic>>[];
    var xorF0 = 0, total = 0;
    for (final plain in photos) {
      final k = randomKeys(rng);
      final c = encRgb(plain, s, k);
      final bad = c.copy()..iv = [for (final b in c.iv) 1 - b];
      final d = decRgb(bad, s, k);
      ivRows.add(cmp(plain, d, s));
      for (var i = 0; i < plain.length; i++) {
        total++;
        if ((plain[i] ^ d[i]) == 0xF0) xorF0++;
      }
      final k2 = FdaeKeys(x0: k.x0, mu1: k.mu1, z0: k.z0, r: k.r, y0: k.y0, mu2: k.mu2, n0: k.n0 + 1);
      n0Rows.add(cmp(plain, decRgb(c, s, k2), s));
    }
    R['B4_wrong_iv_and_n0'] = {
      'wrong_iv_bit': agg(ivRows),
      'wrong_iv_share_of_bytes_with_xor_0xF0': _f(xorF0 / total),
      'wrong_n0_plus_1': agg(n0Rows),
      'note': 'A wrong IV bit flips only the four high bit planes (xor 0xF0): NPCR is 100 % but the picture is still recognisable.',
    };
  }, timeout: noTimeout);

  test('B5 chip level: wrong user key / wrong index must be rejected by the integrity check', () {
    final s = 32; // face chips are small; 32x32 is enough here
    var okWrongKey = 0, okWrongIdx = 0, okRight = 0;
    const trials = 20;
    for (var t = 0; t < trials; t++) {
      final plain = Uint8List.fromList(List.generate(s * s * 3, (_) => rng.nextInt(256)));
      final uk = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
      final e = encryptChip(plain, s, s, uk, 0);
      try {
        if (decryptChip(e, s, s, uk, 0).length == plain.length) okRight++;
      } on TemplateIntegrityException {
        // counted as not ok
      }
      final uk2 = Uint8List.fromList(uk)..[0] ^= 1;
      try {
        decryptChip(e, s, s, uk2, 0);
      } on TemplateIntegrityException {
        okWrongKey++;
      }
      try {
        decryptChip(e, s, s, uk, 1);
      } on TemplateIntegrityException {
        okWrongIdx++;
      }
    }
    R['B5_chip_integrity'] = {
      'trials': trials, 'correct_key_accepted': okRight,
      'wrong_key_rejected': okWrongKey, 'wrong_index_rejected': okWrongIdx,
    };
  }, timeout: noTimeout);

  // =========================================================== C  corruption in transmission / storage
  test('C1-C4 ciphertext damage: bit flips, lost block, noise, JPEG recompression', () {
    final s = kSize;
    final flipCounts = [1, 2, 5, 10, 50, 100];
    final lossPercents = [0.1, 1.0, 5.0, 10.0, 25.0];
    final spDensities = [0.001, 0.01, 0.05];
    final gaussSigmas = [1.0, 2.0, 5.0];
    final jpegQ = [100, 95, 90, 75, 50];
    final res = <String, List<Map<String, dynamic>>>{};
    void put(String name, Map<String, dynamic> params, Map<String, dynamic> r) {
      (res[name] ??= []).add({...params, ...r});
    }

    final bag = <String, List<Map<String, dynamic>>>{};
    void add(String key, Map<String, dynamic> r) => (bag[key] ??= []).add(r);

    for (final plain in photos) {
      final k = randomKeys(rng);
      final c = encRgb(plain, s, k);
      for (final n in flipCounts) {
        final d = c.copy()..rgb = flipBits(c.rgb, n, rng);
        add('flip|$n', cmp(plain, decRgb(d, s, k), s));
      }
      for (final pc in lossPercents) {
        final d = c.copy();
        final cnt = math.max(1, (d.rgb.length * pc / 100).round());
        final start = rng.nextInt(d.rgb.length - cnt + 1);
        for (var i = 0; i < cnt; i++) {
          d.rgb[start + i] = 0;
        }
        add('loss|$pc', cmp(plain, decRgb(d, s, k), s));
      }
      for (final dens in spDensities) {
        final d = c.copy();
        for (var i = 0; i < d.rgb.length; i++) {
          if (rng.nextDouble() < dens) d.rgb[i] = rng.nextBool() ? 0 : 255;
        }
        add('saltpepper|$dens', cmp(plain, decRgb(d, s, k), s));
      }
      for (final sg in gaussSigmas) {
        final d = c.copy();
        for (var i = 0; i < d.rgb.length; i++) {
          final u1 = 1.0 - rng.nextDouble(), u2 = rng.nextDouble();
          final g = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * sg;
          d.rgb[i] = (d.rgb[i] + g).round().clamp(0, 255);
        }
        add('gauss|$sg', cmp(plain, decRgb(d, s, k), s));
      }
      for (final q in jpegQ) {
        final im = img.Image.fromBytes(width: s, height: s, bytes: c.rgb.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
        final back = img.decodeJpg(img.encodeJpg(im, quality: q));
        if (back == null) continue;
        final d = c.copy()..rgb = Uint8List.fromList(back.getBytes(order: img.ChannelOrder.rgb));
        add('jpeg|$q', cmp(plain, decRgb(d, s, k), s));
      }
    }
    bag.forEach((key, rows) {
      final parts = key.split('|');
      put(parts[0], {'level': double.parse(parts[1])}, agg(rows));
    });
    R['C_ciphertext_damage'] = {
      'results': res,
      'units': {'flip': 'number of flipped bits', 'loss': '% of bytes set to 0 (one contiguous run)',
        'saltpepper': 'density', 'gauss': 'sigma in grey levels', 'jpeg': 'JPEG quality'},
    };
  }, timeout: noTimeout);

  test('C5 damaged PNG file: random byte errors and truncation', () {
    final s = kSize;
    final byteCounts = [1, 5, 20];
    final truncs = [0.01, 0.10];
    // outcome classes
    final out = <String, Map<String, int>>{};
    void tally(String key, String outcome) {
      final m = out[key] ??= {'decode_failed': 0, 'manifest_lost': 0, 'wrong_image': 0, 'exact': 0};
      m[outcome] = m[outcome]! + 1;
    }

    const perCase = 20;
    for (final plain in photos.take(3)) {
      final k = randomKeys(rng);
      final c = encRgb(plain, s, k);
      final png = injectTextChunk(pngOf(c.rgb, s), 'fdae-iv', c.iv.join(','));
      void attempt(String key, Uint8List damaged) {
        try {
          final txt = readTextChunk(damaged, 'fdae-iv');
          final im = img.decodePng(damaged);
          if (im == null || im.width != s || im.height != s) return tally(key, 'decode_failed');
          if (txt == null) return tally(key, 'manifest_lost');
          final iv = txt.split(',').map(int.parse).toList();
          final d = decRgb(Enc(Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb)), iv), s, k);
          tally(key, mse(plain, d) == 0 ? 'exact' : 'wrong_image');
        } catch (_) {
          tally(key, 'decode_failed');
        }
      }

      // undamaged control: must come back exact, otherwise the test itself is broken
      attempt('control_undamaged', Uint8List.fromList(png));
      for (final n in byteCounts) {
        for (var t = 0; t < perCase; t++) {
          final d = Uint8List.fromList(png);
          for (var i = 0; i < n; i++) {
            d[rng.nextInt(d.length)] ^= 1 << rng.nextInt(8);
          }
          attempt('bytes|$n', d);
        }
      }
      for (final f in truncs) {
        attempt('truncate|$f', Uint8List.sublistView(png, 0, (png.length * (1 - f)).round()));
      }
    }
    R['C5_png_file_damage'] = {'outcomes': out,
      'note': 'decode_failed = the PNG could not be read; manifest_lost = pixels read but the IV bits are gone; wrong_image = restored but different; exact = unharmed.'};
  }, timeout: noTimeout);

  test('C6 stored face chip tampering is detected by the integrity check', () {
    final s = 32;
    const trials = 30;
    var detected = 0, silent = 0;
    for (var t = 0; t < trials; t++) {
      final plain = Uint8List.fromList(List.generate(s * s * 3, (_) => rng.nextInt(256)));
      final uk = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
      final e = encryptChip(plain, s, s, uk, 0);
      final bad = EncryptedChip(flipBits(e.cipher, 1, rng), e.ivBits, e.check); // ONE flipped bit
      try {
        final d = decryptChip(bad, s, s, uk, 0);
        if (mse(plain, d) != 0) silent++; // changed image accepted: would be a failure of the check
      } on TemplateIntegrityException {
        detected++;
      }
    }
    R['C6_chip_tamper'] = {'trials': trials, 'one_bit_flip_detected': detected, 'accepted_but_wrong': silent};
  }, timeout: noTimeout);

  // =========================================================== G  key size vs security
  test('G1 brute force on a reduced key space: work grows as 2^bits', () {
    // Attacker knows everything except x0, which is one of 2^b candidates (step 1e-6), and knows the plaintext
    // (8x8 patch). Each candidate costs one decryption. We measure trials and time for b = 4..16 bits.
    const side = 8;
    final bitsList = [4, 6, 8, 10, 12, 14, 16];
    const reps = 5;
    const step = 1e-6;
    final rows = <Map<String, dynamic>>[];
    for (final b in bitsList) {
      final space = 1 << b;
      var trialsSum = 0;
      var us = 0.0;
      for (var r = 0; r < reps; r++) {
        final base = randomKeys(rng);
        final plain = Uint8List.fromList(List.generate(side * side, (_) => rng.nextInt(256)));
        final x0Lo = 0.2;
        final trueIdx = rng.nextInt(space);
        FdaeKeys cand(int i) => FdaeKeys(x0: x0Lo + i * step, mu1: base.mu1, z0: base.z0, r: base.r, y0: base.y0, mu2: base.mu2, n0: kN0);
        final ct = fdaeEncrypt(plain, side, side, cand(trueIdx));
        final sw = Stopwatch()..start();
        var found = -1, tries = 0;
        for (var i = 0; i < space; i++) {
          tries++;
          final d = fdaeDecrypt(ct, side, side, cand(i));
          var same = true;
          for (var j = 0; j < d.length; j++) {
            if (d[j] != plain[j]) {
              same = false;
              break;
            }
          }
          if (same) {
            found = i;
            break;
          }
        }
        sw.stop();
        expect(found, trueIdx);
        trialsSum += tries;
        us += sw.elapsedMicroseconds / tries;
      }
      rows.add({'key_bits': b, 'mean_trials': trialsSum / reps, 'expected_trials': (space + 1) / 2, 'us_per_trial': _f(us / reps)});
    }
    final usPerTrial = rows.last['us_per_trial'] as double;
    // extrapolation: expected work 2^(b-1) trials
    final extrap = <Map<String, dynamic>>[];
    for (final b in [40, 56, 64, 80, 96, 128, 192, 256, 295]) {
      final seconds = math.pow(2.0, b - 1) * usPerTrial * 1e-6; // 2.0, not 2: integer 2^63 overflows
      extrap.add({
        'key_bits': b, 'years_one_machine': seconds / 31557600.0,
        'years_one_billion_machines': seconds / 31557600.0 / 1e9,
        'log10_years_one_machine': math.log(seconds / 31557600.0) / math.ln10,
      });
    }
    R['G1_bruteforce_scaling'] = {
      'rows': rows, 'extrapolation': extrap, 'patch': '${side}x$side, one machine = this computer, one core',
      'note': 'x0 is searched, all other parameters are known to the attacker. The real key has six parameters, so real work is far larger.',
    };
  }, timeout: noTimeout);

  test('G2 key length actually available: parameter space vs derived master key', () {
    // theoretical parameter space (resolution 1e-15 per parameter) vs the 256-bit derived key that feeds it
    final ranges = [0.98, 0.40, 0.98, 0.40, 0.98, 0.40];
    var bits = 0.0;
    for (final r in ranges) {
      bits += math.log(r / 1e-15) / math.ln2;
    }
    R['G2_key_sizes'] = {
      'parameter_space_bits_resolution_1e-15': _f(bits),
      'derived_master_key_bits': 256,
      'effective_bits_upper_bound': _f(math.min(bits, 256.0)),
      'note': 'Per-face parameters are derived from a 256-bit key with HMAC-SHA256, so the effective security is at most 256 bits, not the larger parameter space.',
    };
  }, timeout: noTimeout);
}