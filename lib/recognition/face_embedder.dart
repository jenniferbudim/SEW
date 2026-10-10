import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'align.dart';

/// Wraps a face-embedding TFLite model (MobileFaceNet / ArcFace style):
/// input 112x112 RGB chip, output a D-dim vector, returned L2-normalised so a
/// dot product is the cosine similarity.
///
/// [mean]/[std]/[bgr] MUST match how YOUR model was trained. insightface-style
/// models use (x-127.5)/127.5 on RGB; some MobileFaceNet ports use /128 or BGR.
/// Wrong values still "run" but accuracy collapses -- check with known pairs.
class TfliteFaceEmbedder {
  TfliteFaceEmbedder.fromBuffer(Uint8List model,
      {this.mean = 127.5, this.std = 127.5, this.bgr = false, int threads = 2})
      : _interp = Interpreter.fromBuffer(model, options: InterpreterOptions()..threads = threads) {
    final s = _interp.getInputTensor(0).shape;
    _batch = s[0]; // the MobileFaceNet file we ship has a FIXED batch of 2: feed the chip twice, use row 0
    _nchw = s[1] == 3 && s[3] != 3;
    final size = _nchw ? s[2] : s[1];
    if (size != kChipSize) {
      throw StateError('Embedder expects ${size}x$size input; this app aligns to ${kChipSize}x$kChipSize.');
    }
  }

  final Interpreter _interp;
  final double mean, std;
  final bool bgr;
  late final bool _nchw;
  late final int _batch;

  Float32List embed(Uint8List chipRgb) {
    const plane = kChipSize * kChipSize;
    final one = Float32List(plane * 3);
    final blob = Float32List(plane * 3 * _batch);
    for (var i = 0; i < plane; i++) {
      final r = chipRgb[i * 3], g = chipRgb[i * 3 + 1], b = chipRgb[i * 3 + 2];
      final c0 = bgr ? b : r, c2 = bgr ? r : b;
      if (_nchw) {
        one[i] = (c0 - mean) / std;
        one[plane + i] = (g - mean) / std;
        one[2 * plane + i] = (c2 - mean) / std;
      } else {
        one[i * 3] = (c0 - mean) / std;
        one[i * 3 + 1] = (g - mean) / std;
        one[i * 3 + 2] = (c2 - mean) / std;
      }
    }
    for (var b = 0; b < _batch; b++) {
      blob.setRange(b * one.length, (b + 1) * one.length, one);
    }
    _interp.getInputTensor(0).data = blob.buffer.asUint8List();
    _interp.invoke();
    final all = Uint8List.fromList(_interp.getOutputTensor(0).data).buffer.asFloat32List();
    final v = Float32List.sublistView(all, 0, all.length ~/ _batch); // first row
    var n = 0.0;
    for (final x in v) {
      n += x * x;
    }
    final inv = 1.0 / math.sqrt(n + 1e-12);
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] * inv;
    }
    return out;
  }

  void close() => _interp.close();
}

double cosine(Float32List a, Float32List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}
