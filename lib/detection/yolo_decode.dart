/// Pure-Dart (no TFLite) letterbox + output decoding + NMS, so it can be
/// unit-tested and mirrors pipeline_test.py's _letterbox / Yolo26 / Yolov7
/// detectors.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'face_box.dart';

class Letterbox {
  Letterbox(this.blobHwc, this.ratio, this.padX, this.padY, this.size);
  final Float32List blobHwc; // size*size*3, RGB, 0..1
  final double ratio;
  final int padX, padY, size;
}

/// Aspect-preserving resize + gray(114) padding, same as Python _letterbox.
Letterbox letterbox(img.Image src, int size) {
  final ratio = math.min(size / src.height, size / src.width);
  final nw = (src.width * ratio).round(), nh = (src.height * ratio).round();
  final resized = img.copyResize(src,
      width: nw, height: nh, interpolation: img.Interpolation.linear);
  final x0 = ((size - nw) / 2 - 0.1).round(), y0 = ((size - nh) / 2 - 0.1).round();
  final out = Float32List(size * size * 3)..fillRange(0, size * size * 3, 114 / 255);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      final p = resized.getPixel(x, y);
      final i = ((y0 + y) * size + (x0 + x)) * 3;
      out[i] = p.r / 255;
      out[i + 1] = p.g / 255;
      out[i + 2] = p.b / 255;
    }
  }
  return Letterbox(out, ratio, x0, y0, size);
}

Float32List hwcToChw(Float32List hwc, int size) {
  final out = Float32List(hwc.length), plane = size * size;
  for (var i = 0; i < plane; i++) {
    out[i] = hwc[i * 3];
    out[plane + i] = hwc[i * 3 + 1];
    out[2 * plane + i] = hwc[i * 3 + 2];
  }
  return out;
}

/// Accessor that tolerates [1,rows,cols] or channel-first [1,cols,rows].
class _Grid {
  _Grid._(this.d, this.rows, this.cols, this.channelFirst);
  final Float32List d;
  final int rows, cols;
  final bool channelFirst;
  double at(int r, int c) => channelFirst ? d[c * rows + r] : d[r * cols + c];

  factory _Grid.from(Float32List d, List<int> shape, int expectedCols) {
    final a = shape[shape.length - 2], b = shape[shape.length - 1];
    if (b == expectedCols) return _Grid._(d, a, b, false);
    if (a == expectedCols) return _Grid._(d, b, a, true);
    throw StateError('Unexpected output shape $shape (wanted $expectedCols channels)');
  }
}

class _Cand {
  _Cand(this.x1, this.y1, this.x2, this.y2, this.score, [this.lm]);
  double x1, y1, x2, y2;
  final double score;
  final List<double>? lm; // 10 values, letterbox space
}

List<FaceBox> _finish(List<_Cand> c, Letterbox lb, int imgW, int imgH) {
  if (c.isEmpty) return const [];
  // TFLite exports from some toolchains emit 0..1 normalised coords.
  var mx = 0.0;
  for (final b in c) {
    mx = math.max(mx, math.max(math.max(b.x1, b.x2), math.max(b.y1, b.y2)));
  }
  final k = mx <= 2.0 ? lb.size.toDouble() : 1.0;
  final res = <FaceBox>[];
  for (final b in c) {
    final x1 = ((b.x1 * k - lb.padX) / lb.ratio).toInt().clamp(0, imgW);
    final y1 = ((b.y1 * k - lb.padY) / lb.ratio).toInt().clamp(0, imgH);
    final x2 = ((b.x2 * k - lb.padX) / lb.ratio).toInt().clamp(0, imgW);
    final y2 = ((b.y2 * k - lb.padY) / lb.ratio).toInt().clamp(0, imgH);
    List<double>? lm;
    if (b.lm != null) {
      lm = [
        for (var i = 0; i < 10; i += 2) ...[
          (b.lm![i] * k - lb.padX) / lb.ratio,
          (b.lm![i + 1] * k - lb.padY) / lb.ratio,
        ]
      ];
    }
    if (x2 > x1 && y2 > y1) res.add(FaceBox(x1, y1, x2, y2, b.score, lm));
  }
  return res;
}

/// YOLO26 end-to-end head: rows of [x1,y1,x2,y2,conf,cls], already NMS-free.
List<FaceBox> decodeYolo26(Float32List out, List<int> shape, Letterbox lb,
    int imgW, int imgH, {double conf = 0.3}) {
  final g = _Grid.from(out, shape, 6);
  final c = <_Cand>[];
  for (var r = 0; r < g.rows; r++) {
    final s = g.at(r, 4);
    if (s < conf) continue;
    c.add(_Cand(g.at(r, 0), g.at(r, 1), g.at(r, 2), g.at(r, 3), s));
  }
  return _finish(c, lb, imgW, imgH);
}

/// YOLOv7-face (--grid): rows of [cx,cy,w,h,obj,cls, 5x(kx,ky,kconf)]. Needs NMS.
List<FaceBox> decodeYolov7(Float32List out, List<int> shape, Letterbox lb,
    int imgW, int imgH, {double conf = 0.4, double iou = 0.5}) {
  final g = _Grid.from(out, shape, 21);
  final c = <_Cand>[];
  for (var r = 0; r < g.rows; r++) {
    final s = g.at(r, 4) * g.at(r, 5);
    if (s < conf) continue;
    final cx = g.at(r, 0), cy = g.at(r, 1), w = g.at(r, 2), h = g.at(r, 3);
    final lm = <double>[
      for (var k = 0; k < 5; k++) ...[g.at(r, 6 + 3 * k), g.at(r, 7 + 3 * k)]
    ];
    c.add(_Cand(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, s, lm));
  }
  return _finish(_nms(c, iou), lb, imgW, imgH);
}

List<_Cand> _nms(List<_Cand> boxes, double iouThresh) {
  boxes.sort((a, b) => b.score.compareTo(a.score));
  final keep = <_Cand>[];
  for (final b in boxes) {
    var ok = true;
    for (final k in keep) {
      final ix = math.max(0.0, math.min(b.x2, k.x2) - math.max(b.x1, k.x1));
      final iy = math.max(0.0, math.min(b.y2, k.y2) - math.max(b.y1, k.y1));
      final inter = ix * iy;
      final u = (b.x2 - b.x1) * (b.y2 - b.y1) + (k.x2 - k.x1) * (k.y2 - k.y1) - inter;
      if (u > 0 && inter / u > iouThresh) {
        ok = false;
        break;
      }
    }
    if (ok) keep.add(b);
  }
  return keep;
}
