/// Dart port of fdae_encryption.py (FDAE, You et al., IEEE Access 2025,
/// eqs. 4-22) including the `iv_bit` fix for the paper's undecryptable
/// eq.(7)/(8) chain.
///
/// Verified against the Python reference (see test/golden.json).
///
/// IMPLEMENTATION NOTE: the Python reference builds DNA strings. With
/// rule-1 (00=A,01=C,10=G,11=T) and the paper's DNA-XOR table, base XOR is
/// exactly 2-bit XOR, so encode -> DNA-XOR -> decode == plain bitwise XOR.
/// This port therefore XORs bits directly (same output, far less work than string manipulation; speed not benchmarked here).
/// Consequence worth knowing: the "DNA" layer adds no cryptographic
/// strength beyond a bitwise XOR with the chaotic keystream.
library;

import 'dart:typed_data';

class FdaeKeys {
  const FdaeKeys({
    required this.x0, required this.mu1, // PWLCM  -> b1
    required this.z0, required this.r, //   Logistic -> b2
    required this.y0, required this.mu2, // PWLCM  -> confusion indices
    this.n0 = 1000,
  });
  final double x0, mu1, z0, r, y0, mu2;
  final int n0;

  factory FdaeKeys.fromJson(Map<String, dynamic> j) => FdaeKeys(
        x0: (j['x0'] as num).toDouble(), mu1: (j['mu1'] as num).toDouble(),
        z0: (j['z0'] as num).toDouble(), r: (j['r'] as num).toDouble(),
        y0: (j['y0'] as num).toDouble(), mu2: (j['mu2'] as num).toDouble(),
        n0: (j['n0'] as num).toInt(),
      );
}

class FdaeCiphertext {
  const FdaeCiphertext(this.image, this.ivBit);
  final Uint8List image; // h*w bytes, row-major
  final int ivBit; // A11(1); must travel with the ciphertext
}

// ------------------------------------------------------------ chaotic maps
class _Pwlcm {
  _Pwlcm(double x0, this._p, int n0) : _x = x0 {
    if (!(x0 > 0.0 && x0 < 1.0)) throw ArgumentError('x0 must be in (0,1)');
    if (!(_p > 0.0 && _p < 0.5)) throw ArgumentError('p must be in (0,0.5)');
    for (var i = 0; i < n0; i++) {
      next();
    }
  }
  final double _p;
  double _x;
  double next() {
    var x = _x;
    if (x >= 0.5) x = 1.0 - x;
    x = x < _p ? x / _p : (x - _p) / (0.5 - _p);
    _x = x;
    return x;
  }
}

class _Logistic {
  _Logistic(double x0, this._mu, int n0) : _x = x0 {
    if (!(x0 > 0.0 && x0 < 1.0)) throw ArgumentError('z0 must be in (0,1)');
    if (!(_mu > 3.57 && _mu <= 4.0)) throw ArgumentError('r must be in (3.57,4.0]');
    for (var i = 0; i < n0; i++) {
      next();
    }
  }
  final double _mu;
  double _x;
  double next() {
    _x = _mu * _x * (1 - _x); // (mu*x)*(1-x): same evaluation order as Python
    return _x;
  }
}

/// eq(4)/(5) then the odd-bit-plane stream (bits 7,5,3,1), length 4*n.
Uint8List _keystream(double Function() next, int n) {
  final out = Uint8List(4 * n);
  const bps = [7, 5, 3, 1];
  for (var i = 0; i < n; i++) {
    final b = (next() * 1e14).floor() % 256;
    for (var k = 0; k < 4; k++) {
      out[k * n + i] = (b >> bps[k]) & 1;
    }
  }
  return out;
}

// ------------------------------------------------------------ bit planes
/// planes [lo, lo+4) of gray, plane 0 = MSB, flattened plane-major.
Uint8List _planes(Uint8List gray, int lo, int hw) {
  final out = Uint8List(4 * hw);
  for (var k = 0; k < 4; k++) {
    final sh = 7 - (lo + k);
    for (var i = 0; i < hw; i++) {
      out[k * hw + i] = (gray[i] >> sh) & 1;
    }
  }
  return out;
}

Uint8List _recompose(Uint8List high, Uint8List low, int hw) {
  final out = Uint8List(hw);
  for (var k = 0; k < 8; k++) {
    final src = k < 4 ? high : low;
    final off = (k % 4) * hw;
    final sh = 7 - k;
    for (var i = 0; i < hw; i++) {
      out[i] |= src[off + i] << sh;
    }
  }
  return out;
}

int _sum(Uint8List a) {
  var s = 0;
  for (final v in a) {
    s += v;
  }
  return s;
}

(Int32List, Int32List) _confusionIndices(FdaeKeys k, int total, int L) {
  final s0 = (k.y0 + total / L) % 1.0; // eq(12)
  final g = _Pwlcm(s0, k.mu2, k.n0);
  final v = Int32List(L), w = Int32List(L);
  for (var i = 0; i < L; i++) {
    v[i] = (g.next() * 1e14).floor() % L; // eq(15), 0-indexed
  }
  for (var i = 0; i < L; i++) {
    w[i] = (g.next() * 1e14).floor() % L; // eq(16)
  }
  return (v, w);
}

// ------------------------------------------------------------ encrypt
FdaeCiphertext fdaeEncrypt(Uint8List gray, int h, int w, FdaeKeys k) {
  final hw = h * w;
  if (gray.length != hw) throw ArgumentError('gray.length != h*w');
  final L = 4 * hw;

  final a1 = _planes(gray, 0, hw);
  final a2 = _planes(gray, 4, hw);
  final b1 = _keystream(_Pwlcm(k.x0, k.mu1, k.n0).next, hw);
  final b2 = _keystream(_Logistic(k.z0, k.r, k.n0).next, hw);

  // diffusion, eqs (6)-(8)
  final shift = _sum(a2) % L;
  final a11 = Uint8List(L);
  for (var j = 0; j < L; j++) {
    var src = j - shift;
    if (src < 0) src += L;
    a11[j] = a1[src];
  }
  final bb1 = Uint8List(L);
  bb1[0] = a11[0] ^ a11[L - 1] ^ a2[0] ^ b1[0];
  for (var i = 1; i < L; i++) {
    bb1[i] = a11[i] ^ a11[i - 1] ^ a2[i] ^ b1[i];
  }
  final iv = a11[0];

  // DNA-XOR eqs (9)-(10)  ==  bitwise XOR (see library note)
  final a22 = Uint8List(L), b11 = Uint8List(L);
  var total = 0;
  for (var i = 0; i < L; i++) {
    a22[i] = a2[i] ^ b2[i];
    b11[i] = bb1[i] ^ b2[i];
    total += a22[i] + b11[i]; // eq(11)
  }

  // confusion, eqs (17)-(22)
  final (v, wv) = _confusionIndices(k, total, L);
  for (var i = 0; i < L; i++) {
    final vi = v[i];
    final t = b11[i];
    b11[i] = a22[vi];
    a22[vi] = t;
  }
  for (var j = 0; j < L; j++) {
    final wj = wv[j];
    final t = a22[j];
    a22[j] = b11[wj];
    b11[wj] = t;
  }
  // C1 = a22 -> low planes, C2 = b11 -> high planes
  return FdaeCiphertext(_recompose(b11, a22, hw), iv);
}

// ------------------------------------------------------------ decrypt
Uint8List fdaeDecrypt(FdaeCiphertext ct, int h, int w, FdaeKeys k) {
  final hw = h * w;
  if (ct.image.length != hw) throw ArgumentError('image.length != h*w');
  final L = 4 * hw;

  final b11 = _planes(ct.image, 0, hw); // C2
  final a22 = _planes(ct.image, 4, hw); // C1
  final b1 = _keystream(_Pwlcm(k.x0, k.mu1, k.n0).next, hw);
  final b2 = _keystream(_Logistic(k.z0, k.r, k.n0).next, hw);

  // total is invariant under the swaps
  final (v, wv) = _confusionIndices(k, _sum(a22) + _sum(b11), L);
  for (var j = L - 1; j >= 0; j--) {
    final wj = wv[j];
    final t = a22[j];
    a22[j] = b11[wj];
    b11[wj] = t;
  }
  for (var i = L - 1; i >= 0; i--) {
    final vi = v[i];
    final t = b11[i];
    b11[i] = a22[vi];
    a22[vi] = t;
  }

  final a2 = Uint8List(L), bb1 = Uint8List(L);
  for (var i = 0; i < L; i++) {
    a2[i] = a22[i] ^ b2[i];
    bb1[i] = b11[i] ^ b2[i];
  }

  // undo diffusion
  final a11 = Uint8List(L);
  a11[0] = ct.ivBit;
  for (var i = 1; i < L; i++) {
    a11[i] = bb1[i] ^ a11[i - 1] ^ a2[i] ^ b1[i];
  }
  final shift = _sum(a2) % L;
  final a1 = Uint8List(L);
  for (var i = 0; i < L; i++) {
    a1[i] = a11[(i + shift) % L];
  }
  return _recompose(a1, a2, hw);
}
