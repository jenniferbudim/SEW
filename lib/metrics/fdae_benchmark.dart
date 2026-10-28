/// On-device measurements for the thesis. Everything here is plain Dart and runs in a background isolate
/// (call it through [runAnalysis] / [runScalingBench]). Methods mirror benchmark_fdae.py so phone numbers are
/// comparable with the PC numbers.
library;

import 'dart:io' show ProcessInfo;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../detection/face_box.dart';
import '../detection/tflite_face_detector.dart';
import '../fdae/fdae_cipher.dart';
import '../fdae/key_derivation.dart';
import 'image_metrics.dart';

/// Valid domain of each of the six key parameters (name, low, high).
const kKeyParams = <(String, double, double)>[
  ('x0', 0.0, 1.0),
  ('mu1', 0.0, 0.5),
  ('z0', 0.0, 1.0),
  ('r', 3.57, 4.0),
  ('y0', 0.0, 1.0),
  ('mu2', 0.0, 0.5),
];

/// Theoretical key space in bits: product over the six parameters of (range / 1e-15). n0 is not counted.
double theoreticalKeyspaceLog2() {
  var s = 0.0;
  for (final p in kKeyParams) {
    s += math.log((p.$3 - p.$2) / 1e-15) / math.ln2;
  }
  return s;
}

class TrialInput {
  TrialInput({
    required this.photo,
    required this.restoredPng,
    required this.model,
    required this.kind,
    required this.conf,
    required this.boxes,
    required this.seed,
    this.n0 = 1000,
    this.minFace = 32,
    this.maxFaces = 10,
    this.sensSize = 64,
    this.detRepeats = 3,
  });
  final Uint8List photo; // the captured file (JPEG)
  final Uint8List restoredPng; // output of unprotect(), for the round-trip check
  final Uint8List model;
  final DetectorKind kind;
  final double conf;
  final List<List<int>> boxes; // faces found by the app's protect(): [x1,y1,x2,y2]
  final int seed, n0, minFace, maxFaces, sensSize, detRepeats;
}

// Results are rebuilt after the isolate hop so the generic types are exactly what the callers expect.
Future<Map<String, double>> runAnalysis(TrialInput i) async => (await runAnalysisWithImages(i)).row;

/// The metric row plus PNGs of the face that was measured (plaintext crop and its cipher image).
class TrialResult {
  TrialResult(this.row, this.plainFacePng, this.cipherFacePng);
  final Map<String, double> row;
  final Uint8List? plainFacePng, cipherFacePng;
}

Future<TrialResult> runAnalysisWithImages(TrialInput i) async {
  final Map raw = await Isolate.run<Map>(() {
    final images = <String, Uint8List>{};
    final row = analyseTrial(i, images: images);
    return {'row': row, 'images': images};
  });
  final r = raw['row'] as Map;
  final im = raw['images'] as Map;
  return TrialResult(
    {for (final e in r.entries) '${e.key}': (e.value as num).toDouble()},
    im['plain'] as Uint8List?,
    im['cipher'] as Uint8List?,
  );
}

Future<Map<String, dynamic>> runScalingBench() async {
  final Map raw = await Isolate.run<Map>(scalingBench);
  final rows = [
    for (final r in raw['rows'] as List) {for (final e in (r as Map).entries) '${e.key}': (e.value as num).toDouble()}
  ];
  return {for (final e in raw.entries) '${e.key}': e.key == 'rows' ? rows : e.value};
}

FdaeKeys _perturb(FdaeKeys k, String name, double hi, double delta) {
  double get(String n) => switch (n) {
        'x0' => k.x0,
        'mu1' => k.mu1,
        'z0' => k.z0,
        'r' => k.r,
        'y0' => k.y0,
        _ => k.mu2,
      };
  final v = get(name);
  final nv = v + delta < hi ? v + delta : v - delta; // stay inside the domain
  return FdaeKeys(
    x0: name == 'x0' ? nv : k.x0, mu1: name == 'mu1' ? nv : k.mu1,
    z0: name == 'z0' ? nv : k.z0, r: name == 'r' ? nv : k.r,
    y0: name == 'y0' ? nv : k.y0, mu2: name == 'mu2' ? nv : k.mu2,
    n0: k.n0,
  );
}

Uint8List _chan(Uint8List rgb, int imgW, FaceBox b, int c) {
  final w = b.width, h = b.height, ch = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      ch[y * w + x] = rgb[((b.y1 + y) * imgW + b.x1 + x) * 3 + c];
    }
  }
  return ch;
}

img.Image _rgb8(img.Image im) =>
    im.numChannels == 3 && im.format == img.Format.uint8 ? im : im.convert(numChannels: 3, format: img.Format.uint8);

double _nanMean(List<double> v) {
  final f = [for (final x in v) if (!x.isNaN) x];
  return f.isEmpty ? double.nan : f.reduce((a, b) => a + b) / f.length;
}

double _mb(int bytes) => bytes / 1048576.0;

/// One trial = one photo. Returns metric name -> value. `n_faces == 0` means "nothing usable in this photo".
Map<String, double> analyseTrial(TrialInput t, {Map<String, Uint8List>? images}) {
  final row = <String, double>{};
  final sw = Stopwatch();
  double ms() => sw.elapsedMicroseconds / 1000.0;

  var decoded = img.decodeImage(t.photo);
  if (decoded == null) throw const FormatException('Unsupported or corrupt image');
  decoded = _rgb8(img.bakeOrientation(decoded));
  final imgW = decoded.width, imgH = decoded.height;
  final rgb = Uint8List.fromList(decoded.getBytes(order: img.ChannelOrder.rgb));
  row['img_w'] = imgW.toDouble();
  row['img_h'] = imgH.toDouble();

  // ---- lossless round trip of the app's own protect -> restore ----
  final back = _rgb8(img.decodePng(t.restoredPng)!);
  final backRgb = back.getBytes(order: img.ChannelOrder.rgb);
  var same = back.width == imgW && back.height == imgH && backRgb.length == rgb.length;
  if (same) {
    for (var i = 0; i < rgb.length; i++) {
      if (rgb[i] != backRgb[i]) {
        same = false;
        break;
      }
    }
  }
  row['roundtrip_ok'] = same ? 1.0 : 0.0;

  // ---- detection time with the model already loaded (median of repeats after a warm-up) ----
  sw
    ..reset()
    ..start();
  final det = TfliteFaceDetector.fromBuffer(t.model, kind: t.kind, confThreshold: t.conf);
  row['detector_load_ms'] = ms();
  try {
    det.detect(decoded); // warm-up, not timed
    final times = <double>[];
    for (var i = 0; i < t.detRepeats; i++) {
      sw
        ..reset()
        ..start();
      det.detect(decoded);
      times.add(ms());
    }
    times.sort();
    row['detect_warm_ms'] = times[times.length ~/ 2];
  } finally {
    det.close();
  }

  // ---- faces to measure: those found by protect(), at least minFace px, largest first ----
  final boxes = [for (final b in t.boxes) FaceBox(b[0], b[1], b[2], b[3])];
  final used = boxes.where((b) => math.min(b.width, b.height) >= t.minFace).toList()
    ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
  final take = used.take(t.maxFaces).toList();
  row['n_faces'] = take.length.toDouble();
  if (take.isEmpty) return row;

  final rng = math.Random(t.seed);
  FdaeKeys randomKeys() => FdaeKeys(
        x0: 0.01 + rng.nextDouble() * 0.98, mu1: 0.05 + rng.nextDouble() * 0.40,
        z0: 0.01 + rng.nextDouble() * 0.98, r: 3.6 + rng.nextDouble() * 0.4,
        y0: 0.01 + rng.nextDouble() * 0.98, mu2: 0.05 + rng.nextDouble() * 0.40,
        n0: t.n0,
      );

  // ---- encrypt + decrypt every used face, single thread, timed (the app runs the 3 channels in parallel isolates) ----
  var encTotal = 0.0, decTotal = 0.0, faceBytes = 0, roundtrip = true;
  late List<Uint8List> pc, ec, dc;
  late FdaeKeys keys;
  late FaceBox big;
  for (var f = 0; f < take.length; f++) {
    final b = take[f];
    final plain = [for (var c = 0; c < 3; c++) _chan(rgb, imgW, b, c)];
    final k = randomKeys();
    sw
      ..reset()
      ..start();
    final cts = [for (var c = 0; c < 3; c++) fdaeEncrypt(plain[c], b.height, b.width, k)];
    final e = ms();
    sw
      ..reset()
      ..start();
    final dec = [for (var c = 0; c < 3; c++) fdaeDecrypt(cts[c], b.height, b.width, k)];
    final d = ms();
    encTotal += e;
    decTotal += d;
    faceBytes += b.width * b.height * 3;
    for (var c = 0; c < 3; c++) {
      for (var i = 0; i < plain[c].length; i++) {
        if (plain[c][i] != dec[c][i]) {
          roundtrip = false;
          break;
        }
      }
    }
    if (f == 0) {
      big = b;
      pc = plain;
      ec = [for (final c in cts) c.image];
      dc = dec;
      keys = k;
      row['enc_ms_face'] = e;
      row['dec_ms_face'] = d;
    }
  }
  row['cipher_roundtrip_ok'] = roundtrip ? 1.0 : 0.0;
  row['enc_ms_frame_seq'] = encTotal;
  row['dec_ms_frame_seq'] = decTotal;
  row['enc_mbps'] = faceBytes / (encTotal / 1000.0) / 1e6; // MB of face pixels per second
  row['dec_mbps'] = faceBytes / (decTotal / 1000.0) / 1e6;
  final bw = big.width, bh = big.height, n = bw * bh;
  row['face_w'] = bw.toDouble();
  row['face_h'] = bh.toDouble();
  row['est_cipher_ws_kb'] = 64.0 * n / 1024.0; // ~8 bit-plane arrays of 4N bytes + 2 index arrays of 4N int32, per channel
  row['rss_after_mb'] = _mb(ProcessInfo.currentRss);

  // ---- NPCR / UACI: flip the LSB of one random pixel per channel, re-encrypt with the same keys ----
  final npcrs = <double>[], uacis = <double>[];
  for (var c = 0; c < 3; c++) {
    final flipped = Uint8List.fromList(pc[c]);
    flipped[rng.nextInt(n)] ^= 1;
    final ct2 = fdaeEncrypt(flipped, bh, bw, keys);
    final (np, ua) = npcrUaci(ec[c], ct2.image);
    npcrs.add(np);
    uacis.add(ua);
  }
  row['npcr_pt'] = _nanMean(npcrs);
  row['uaci_pt'] = _nanMean(uacis);

  // ---- entropy (plus the entropy of uniformly random bytes of the SAME size as the honest reference) ----
  row['entropy_plain'] = _nanMean([for (final c in pc) entropy(c)]);
  row['entropy_cipher'] = _nanMean([for (final c in ec) entropy(c)]);
  final ideal = <double>[];
  for (var c = 0; c < 3; c++) {
    final r = Uint8List(n);
    for (var i = 0; i < n; i++) {
      r[i] = rng.nextInt(256);
    }
    ideal.add(entropy(r));
  }
  row['entropy_ideal_ref'] = _nanMean(ideal);

  // ---- raw 256-bin histograms (R, G, B) of the plain and the cipher face, for the histogram figure ----
  for (var c = 0; c < 3; c++) {
    final hp = List<int>.filled(256, 0), hc = List<int>.filled(256, 0);
    for (final v in pc[c]) {
      hp[v]++;
    }
    for (final v in ec[c]) {
      hc[v]++;
    }
    for (var b = 0; b < 256; b++) {
      row['h_p${c}_$b'] = hp[b].toDouble();
      row['h_c${c}_$b'] = hc[b].toDouble();
    }
  }

  // ---- histogram analysis: chi-square vs uniform (critical value for p = 0.05, 255 dof = 293.2478) ----
  final chiP = [for (final c in pc) chi2Uniform(c)];
  final chiC = [for (final c in ec) chi2Uniform(c)];
  row['chi2_plain'] = _nanMean([for (final r in chiP) r.$1]);
  row['chi2_cipher'] = _nanMean([for (final r in chiC) r.$1]);
  row['chi2_cipher_p'] = _nanMean([for (final r in chiC) r.$2]);
  row['chi2_cipher_pass'] = _nanMean([for (final r in chiC) r.$2 > 0.05 ? 1.0 : 0.0]);

  // ---- inter-pixel correlation (2000 random adjacent pairs per direction and channel) ----
  final cabs = <double>[];
  for (final d in const ['h', 'v', 'd']) {
    final rp = [for (final c in pc) adjacentCorrelation(c, bw, bh, 2000, d, rng)];
    final rc = [for (final c in ec) adjacentCorrelation(c, bw, bh, 2000, d, rng)];
    row['corr_plain_$d'] = _nanMean(rp);
    row['corr_cipher_$d'] = _nanMean(rc);
    cabs.addAll(rc.map((v) => v.abs()));
  }
  row['corr_cipher_abs'] = _nanMean(cabs);

  // ---- MSE / PSNR / SSIM on the full 3-channel crop ----
  final plainI = mergeRgb(pc), cipherI = mergeRgb(ec), decI = mergeRgb(dc);
  if (images != null) {
    Uint8List png(Uint8List rgbBytes) => img.encodePng(
        img.Image.fromBytes(width: bw, height: bh, bytes: Uint8List.fromList(rgbBytes).buffer, numChannels: 3));
    images['plain'] = png(plainI);
    images['cipher'] = png(cipherI);
  }
  final m1 = mse(plainI, cipherI), m2 = mse(plainI, decI);
  row['mse_plain_cipher'] = m1;
  row['psnr_plain_cipher'] = psnrFromMse(m1);
  row['ssim_plain_cipher'] = ssimRgb(pc, ec, bw, bh);
  row['mse_plain_dec'] = m2;
  row['psnr_plain_dec'] = psnrFromMse(m2); // infinity when decryption is lossless
  row['ssim_plain_dec'] = ssimRgb(pc, dc, bw, bh);

  // ---- key sensitivity + empirical key space (green channel, top-left patch) ----
  final s = math.min(t.sensSize, math.min(bw, bh));
  final sens = Uint8List(s * s);
  for (var y = 0; y < s; y++) {
    for (var x = 0; x < s; x++) {
      sens[y * s + x] = pc[1][y * bw + x];
    }
  }
  final base = fdaeEncrypt(sens, s, s, keys);
  var log2Space = 0.0;
  final ksN = <double>[], ksU = <double>[], wM = <double>[], wP = <double>[], wS = <double>[];
  for (final p in kKeyParams) {
    var contiguous = true;
    var kmax = 7;
    for (var k = 8; k <= 16; k++) {
      final ct = fdaeEncrypt(sens, s, s, _perturb(keys, p.$1, p.$3, math.pow(10, -k).toDouble()));
      final (np, ua) = npcrUaci(base.image, ct.image);
      if (k == 10) {
        row['ks_npcr_${p.$1}'] = np;
        row['ks_uaci_${p.$1}'] = ua;
        ksN.add(np);
        ksU.add(ua);
      }
      if (contiguous && np >= 99.0) {
        kmax = k;
      } else {
        contiguous = false;
      }
    }
    row['ksp_exp_${p.$1}'] = kmax.toDouble();
    log2Space += math.log((p.$3 - p.$2) / math.pow(10, -kmax)) / math.ln2;
    final wrong = fdaeDecrypt(base, s, s, _perturb(keys, p.$1, p.$3, 1e-10));
    final wm = mse(sens, wrong);
    wM.add(wm);
    wP.add(psnrFromMse(wm));
    wS.add(ssimGray(sens, wrong, s, s));
  }
  row['ks_npcr_mean'] = _nanMean(ksN);
  row['ks_uaci_mean'] = _nanMean(ksU);
  row['ks_wrongkey_mse_mean'] = _nanMean(wM);
  row['ks_wrongkey_psnr_mean'] = _nanMean([for (final v in wP) if (v.isFinite) v]);
  row['ks_wrongkey_ssim_mean'] = _nanMean(wS);
  row['keyspace_log2_empirical'] = log2Space;
  row['rss_peak_mb'] = _mb(ProcessInfo.maxRss);
  return row;
}

/// Empirical complexity: time vs problem size (square grey images), the log-log slope (1.0 = linear), and the key
/// derivation cost. Single thread.
Map<String, dynamic> scalingBench({List<int> sizes = const [32, 64, 128, 256], int repeats = 3}) {
  final rng = math.Random(7);
  final sw = Stopwatch();
  double med(List<double> v) {
    v.sort();
    return v[v.length ~/ 2];
  }

  final rows = <Map<String, double>>[];
  final lnN = <double>[], lnE = <double>[], lnD = <double>[];
  for (final s in sizes) {
    final g = Uint8List(s * s);
    for (var i = 0; i < g.length; i++) {
      g[i] = rng.nextInt(256);
    }
    final k = FdaeKeys(x0: 0.37, mu1: 0.21, z0: 0.62, r: 3.9, y0: 0.55, mu2: 0.33, n0: 1000);
    fdaeEncrypt(g, s, s, k); // warm-up
    final e = <double>[], d = <double>[];
    for (var r = 0; r < repeats; r++) {
      sw
        ..reset()
        ..start();
      final ct = fdaeEncrypt(g, s, s, k);
      e.add(sw.elapsedMicroseconds / 1000.0);
      sw
        ..reset()
        ..start();
      fdaeDecrypt(ct, s, s, k);
      d.add(sw.elapsedMicroseconds / 1000.0);
    }
    final em = med(e), dm = med(d), n = s * s;
    rows.add({
      'size': s.toDouble(), 'pixels': n.toDouble(), 'enc_ms': em, 'dec_ms': dm,
      'enc_us_per_px': em * 1000 / n, 'dec_us_per_px': dm * 1000 / n,
    });
    lnN.add(math.log(n.toDouble()));
    lnE.add(math.log(em));
    lnD.add(math.log(dm));
  }
  double slope(List<double> x, List<double> y) {
    final mx = x.reduce((a, b) => a + b) / x.length, my = y.reduce((a, b) => a + b) / y.length;
    var sxy = 0.0, sxx = 0.0;
    for (var i = 0; i < x.length; i++) {
      sxy += (x[i] - mx) * (y[i] - my);
      sxx += (x[i] - mx) * (x[i] - mx);
    }
    return sxy / sxx;
  }

  final salt = Uint8List.fromList(List.generate(16, (i) => i));
  sw
    ..reset()
    ..start();
  pbkdf2Sha256('bench', salt, 1);
  final kdf1 = sw.elapsedMicroseconds / 1000.0;
  sw
    ..reset()
    ..start();
  pbkdf2Sha256('bench', salt, kPbkdf2Iterations);
  final kdfFull = sw.elapsedMicroseconds / 1000.0;
  return {
    'rows': rows,
    'enc_exponent': slope(lnN, lnE),
    'dec_exponent': slope(lnN, lnD),
    'kdf_1_round_ms': kdf1,
    'kdf_default_rounds': kPbkdf2Iterations.toDouble(),
    'kdf_default_ms': kdfFull,
  };
}
