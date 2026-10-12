/// Metric functions for the thesis, on 8-bit data. Definitions follow benchmark_fdae.py / evaluation_suite.py
/// (information entropy, chi-square histogram test, adjacent-pixel correlation, NPCR, UACI, MSE, PSNR, SSIM).
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// H = -sum p log2 p over the 256 grey levels (ideal 8.0).
double entropy(Uint8List ch) {
  final h = List<int>.filled(256, 0);
  for (final v in ch) {
    h[v]++;
  }
  final n = ch.length;
  var e = 0.0;
  for (final c in h) {
    if (c > 0) {
      final p = c / n;
      e -= p * math.log(p) / math.ln2;
    }
  }
  return e;
}

/// NPCR and UACI in percent between two equal-size ciphertexts (ideal 99.6094 / 33.4635).
(double, double) npcrUaci(Uint8List a, Uint8List b) {
  if (a.length != b.length) throw ArgumentError('size mismatch');
  var diff = 0;
  var abs = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) diff++;
    abs += (a[i] - b[i]).abs();
  }
  return (100.0 * diff / a.length, 100.0 * abs / (255.0 * a.length));
}

double mse(Uint8List a, Uint8List b) {
  if (a.length != b.length) throw ArgumentError('size mismatch');
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).toDouble();
    s += d * d;
  }
  return s / a.length;
}

/// PSNR in dB, MAX = 255. Returns double.infinity when the images are identical (MSE = 0).
double psnrFromMse(double m) => m == 0 ? double.infinity : 10.0 * math.log(255.0 * 255.0 / m) / math.ln10;

/// SSIM of one grey channel: 7x7 uniform window, sample covariance, K1=0.01, K2=0.03, L=255, mean over the
/// valid (fully inside) windows. This is scikit-image's structural_similarity(..., data_range=255) default.
double ssimGray(Uint8List a, Uint8List b, int w, int h) {
  const win = 7;
  if (w < win || h < win) return double.nan;
  final iw = w + 1;
  final sx = Float64List(iw * (h + 1)),
      sy = Float64List(iw * (h + 1)),
      sxx = Float64List(iw * (h + 1)),
      syy = Float64List(iw * (h + 1)),
      sxy = Float64List(iw * (h + 1));
  for (var y = 0; y < h; y++) {
    var rx = 0.0, ry = 0.0, rxx = 0.0, ryy = 0.0, rxy = 0.0;
    for (var x = 0; x < w; x++) {
      final p = a[y * w + x].toDouble(), q = b[y * w + x].toDouble();
      rx += p;
      ry += q;
      rxx += p * p;
      ryy += q * q;
      rxy += p * q;
      final i = (y + 1) * iw + x + 1, up = y * iw + x + 1;
      sx[i] = sx[up] + rx;
      sy[i] = sy[up] + ry;
      sxx[i] = sxx[up] + rxx;
      syy[i] = syy[up] + ryy;
      sxy[i] = sxy[up] + rxy;
    }
  }
  double box(Float64List s, int x, int y) =>
      s[(y + win) * iw + x + win] - s[y * iw + x + win] - s[(y + win) * iw + x] + s[y * iw + x];

  const np = 49.0;
  const covNorm = np / (np - 1);
  const c1 = (0.01 * 255) * (0.01 * 255), c2 = (0.03 * 255) * (0.03 * 255);
  var total = 0.0;
  var count = 0;
  for (var y = 0; y + win <= h; y++) {
    for (var x = 0; x + win <= w; x++) {
      final ux = box(sx, x, y) / np, uy = box(sy, x, y) / np;
      final vx = covNorm * (box(sxx, x, y) / np - ux * ux);
      final vy = covNorm * (box(syy, x, y) / np - uy * uy);
      final vxy = covNorm * (box(sxy, x, y) / np - ux * uy);
      total += ((2 * ux * uy + c1) * (2 * vxy + c2)) / ((ux * ux + uy * uy + c1) * (vx + vy + c2));
      count++;
    }
  }
  return total / count;
}

/// Interleaved RGB -> the three separate channels.
List<Uint8List> splitRgb(Uint8List rgb) {
  final n = rgb.length ~/ 3;
  final out = [Uint8List(n), Uint8List(n), Uint8List(n)];
  for (var i = 0; i < n; i++) {
    out[0][i] = rgb[i * 3];
    out[1][i] = rgb[i * 3 + 1];
    out[2][i] = rgb[i * 3 + 2];
  }
  return out;
}

Uint8List mergeRgb(List<Uint8List> c) {
  final n = c[0].length;
  final out = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    out[i * 3] = c[0][i];
    out[i * 3 + 1] = c[1][i];
    out[i * 3 + 2] = c[2][i];
  }
  return out;
}

/// SSIM of two colour images = mean of the three channel SSIMs.
double ssimRgb(List<Uint8List> a, List<Uint8List> b, int w, int h) {
  var s = 0.0;
  for (var c = 0; c < 3; c++) {
    s += ssimGray(a[c], b[c], w, h);
  }
  return s / 3;
}

/// Pearson correlation of [pairs] randomly sampled adjacent pixels. [dir]: 'h', 'v' or 'd'.
double adjacentCorrelation(Uint8List ch, int w, int h, int pairs, String dir, math.Random rng) {
  final maxY = dir == 'h' ? h : h - 1, maxX = dir == 'v' ? w : w - 1;
  if (maxY < 1 || maxX < 1) return double.nan;
  final dy = dir == 'h' ? 0 : 1, dx = dir == 'v' ? 0 : 1;
  var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
  for (var i = 0; i < pairs; i++) {
    final y = rng.nextInt(maxY), x = rng.nextInt(maxX);
    final p = ch[y * w + x].toDouble(), q = ch[(y + dy) * w + x + dx].toDouble();
    sa += p;
    sb += q;
    saa += p * p;
    sbb += q * q;
    sab += p * q;
  }
  final n = pairs.toDouble();
  final cov = sab - sa * sb / n, va = saa - sa * sa / n, vb = sbb - sb * sb / n;
  if (va <= 0 || vb <= 0) return double.nan; // constant data: correlation undefined
  return cov / math.sqrt(va * vb);
}

/// Chi-square test of the histogram against a uniform one (255 degrees of freedom).
/// Returns (statistic, p-value). p > 0.05 means "cannot reject uniform".
(double, double) chi2Uniform(Uint8List ch) {
  final h = List<int>.filled(256, 0);
  for (final v in ch) {
    h[v]++;
  }
  final e = ch.length / 256.0;
  var s = 0.0;
  for (final c in h) {
    s += (c - e) * (c - e) / e;
  }
  return (s, gammaQ(127.5, s / 2));
}

// ---- regularised upper incomplete gamma Q(a, x) (Numerical Recipes gser/gcf) ----
double _lnGamma(double x) {
  const cof = [
    76.18009172947146, -86.50532032941677, 24.01409824083091,
    -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5,
  ];
  var y = x;
  var tmp = x + 5.5;
  tmp -= (x + 0.5) * math.log(tmp);
  var ser = 1.000000000190015;
  for (final c in cof) {
    y += 1;
    ser += c / y;
  }
  return -tmp + math.log(2.5066282746310005 * ser / x);
}

double gammaQ(double a, double x) {
  if (x <= 0) return 1.0;
  final gln = _lnGamma(a);
  if (x < a + 1) {
    var ap = a, sum = 1.0 / a, del = sum;
    for (var n = 0; n < 1000; n++) {
      ap += 1;
      del *= x / ap;
      sum += del;
      if (del.abs() < sum.abs() * 1e-15) break;
    }
    return 1.0 - sum * math.exp(-x + a * math.log(x) - gln);
  }
  const tiny = 1e-300;
  var b = x + 1 - a, c = 1 / tiny, d = 1 / b, h = d;
  for (var i = 1; i <= 1000; i++) {
    final an = -i * (i - a);
    b += 2;
    d = an * d + b;
    if (d.abs() < tiny) d = tiny;
    c = b + an / c;
    if (c.abs() < tiny) c = tiny;
    d = 1 / d;
    final del = d * c;
    h *= del;
    if ((del - 1).abs() < 1e-15) break;
  }
  return math.exp(-x + a * math.log(x) - gln) * h;
}

// ---- summary statistics over trials ----
const _t975 = [
  12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.160, 2.145, 2.131,
  2.120, 2.110, 2.101, 2.093, 2.086, 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042,
];

class Summary {
  Summary(this.n, this.mean, this.std, this.min, this.max, this.ci95, this.infinite);
  final int n; // finite values used
  final double mean, std, min, max, ci95; // ci95 = half-width of the 95% confidence interval of the mean
  final int infinite; // values that were +infinity (e.g. PSNR of a lossless decryption), not averaged
  Map<String, dynamic> toJson() =>
      {'n': n, 'mean': mean, 'std': std, 'min': min, 'max': max, 'ci95': ci95, 'infinite': infinite};
}

Summary summarize(List<double> values) {
  final fin = [for (final v in values) if (v.isFinite) v];
  final inf = values.where((v) => v == double.infinity).length;
  if (fin.isEmpty) return Summary(0, double.nan, double.nan, double.nan, double.nan, double.nan, inf);
  final n = fin.length;
  final mean = fin.reduce((a, b) => a + b) / n;
  var ss = 0.0;
  for (final v in fin) {
    ss += (v - mean) * (v - mean);
  }
  final std = n > 1 ? math.sqrt(ss / (n - 1)) : 0.0;
  final t = n < 2 ? double.nan : (n - 1 <= 30 ? _t975[n - 2] : 1.96);
  return Summary(n, mean, std, fin.reduce(math.min), fin.reduce(math.max), n < 2 ? double.nan : t * std / math.sqrt(n), inf);
}
