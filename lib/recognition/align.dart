/// ArcFace-style 5-point alignment. Verified against skimage / cv2.warpAffine
/// (tools/align_golden.py): same least-squares similarity as insightface's
/// face_align.estimate_norm, and a bilinear warp with constant-0 border like
/// cv2.warpAffine(..., borderValue=0).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import '../detection/face_box.dart';

/// insightface `arcface_dst` (112x112), copied from insightface/utils/face_align.py.
const arcfaceTemplate112 = <double>[
  38.2946, 51.6963, // left eye
  73.5318, 51.5014, // right eye
  56.0252, 71.7366, // nose
  41.5493, 92.3655, // left mouth corner
  70.7299, 92.2041, // right mouth corner
];

/// z -> a*z + b on complex numbers z = x + iy (rotation+uniform scale+shift).
class Similarity {
  const Similarity(this.ar, this.ai, this.br, this.bi);
  final double ar, ai, br, bi;
}

/// Least-squares similarity mapping [src] points onto [dst] (flat x,y lists).
Similarity estimateSimilarity(List<double> src, List<double> dst) {
  final n = src.length ~/ 2;
  double smx = 0, smy = 0, dmx = 0, dmy = 0;
  for (var i = 0; i < n; i++) {
    smx += src[2 * i];
    smy += src[2 * i + 1];
    dmx += dst[2 * i];
    dmy += dst[2 * i + 1];
  }
  smx /= n;
  smy /= n;
  dmx /= n;
  dmy /= n;
  double nr = 0, ni = 0, den = 0;
  for (var i = 0; i < n; i++) {
    final sx = src[2 * i] - smx, sy = src[2 * i + 1] - smy;
    final dx = dst[2 * i] - dmx, dy = dst[2 * i + 1] - dmy;
    nr += sx * dx + sy * dy; // Re(conj(s) * d)
    ni += sx * dy - sy * dx; // Im(conj(s) * d)
    den += sx * sx + sy * sy;
  }
  final ar = nr / den, ai = ni / den;
  return Similarity(ar, ai, dmx - (ar * smx - ai * smy), dmy - (ar * smy + ai * smx));
}

/// Inverse-mapped bilinear warp of an interleaved RGB image; pixels sampled
/// outside the source are 0.
Uint8List warpSimilarity(Uint8List rgb, int w, int h, Similarity t, int outW, int outH) {
  final out = Uint8List(outW * outH * 3);
  final n = t.ar * t.ar + t.ai * t.ai;
  final ir = t.ar / n, ii = -t.ai / n; // 1/a
  for (var y = 0; y < outH; y++) {
    for (var x = 0; x < outW; x++) {
      final dx = x - t.br, dy = y - t.bi;
      final sx = dx * ir - dy * ii, sy = dx * ii + dy * ir;
      final x0 = sx.floor(), y0 = sy.floor();
      final fx = sx - x0, fy = sy - y0;
      final w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy);
      final w01 = (1 - fx) * fy, w11 = fx * fy;
      final o = (y * outW + x) * 3;
      for (var c = 0; c < 3; c++) {
        double v = 0;
        if (x0 >= 0 && x0 < w && y0 >= 0 && y0 < h) v += w00 * rgb[(y0 * w + x0) * 3 + c];
        if (x0 + 1 >= 0 && x0 + 1 < w && y0 >= 0 && y0 < h) v += w10 * rgb[(y0 * w + x0 + 1) * 3 + c];
        if (x0 >= 0 && x0 < w && y0 + 1 >= 0 && y0 + 1 < h) v += w01 * rgb[((y0 + 1) * w + x0) * 3 + c];
        if (x0 + 1 >= 0 && x0 + 1 < w && y0 + 1 >= 0 && y0 + 1 < h) {
          v += w11 * rgb[((y0 + 1) * w + x0 + 1) * 3 + c];
        }
        out[o + c] = (v + 0.5).floor().clamp(0, 255);
      }
    }
  }
  return out;
}

const kChipSize = 112;

/// 112x112 RGB chip. Uses landmarks when present (accurate); otherwise falls
/// back to a square crop around the box, which is LESS accurate for matching.
Uint8List faceChip(Uint8List rgb, int w, int h, FaceBox f) {
  final Similarity t;
  if (f.landmarks != null) {
    t = estimateSimilarity(f.landmarks!, arcfaceTemplate112);
  } else {
    final side = math.max(f.width, f.height) * 1.3; // heuristic margin, not tuned
    final s = kChipSize / side;
    final cx = (f.x1 + f.x2) / 2, cy = (f.y1 + f.y2) / 2;
    t = Similarity(s, 0, kChipSize / 2 - s * cx, kChipSize / 2 - s * cy);
  }
  return warpSimilarity(rgb, w, h, t, kChipSize, kChipSize);
}
