/// Single-frame presentation-attack check using FaceAntiSpoofing.tflite (256x256 RGB in [0,1] -> 8 class scores + 8
/// leaf-node masks; spoof score = sum(|score_i| * mask_i), LOWER = more live). Preprocessing mirrors the model
/// author's Android code: square face crop, resize to 256x256, /255. A Laplacian sharpness gate runs first.
///
/// It is a weak check: it can be fooled (high-quality replay, video, masks, adversarial images) and it has no
/// published error rates. Treat it as a speed bump, say so in the thesis, and measure it with the score log.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import '../detection/face_box.dart';
import '../detection/tflite_face_detector.dart';
import 'liveness.dart';
import 'liveness_config.dart';

class LivenessResult {
  const LivenessResult({required this.live, this.score, this.sharpness, this.reason, this.faceFound = true});
  final bool live;
  final double? score; // spoof score, lower = more live (null if no face / not run)
  final int? sharpness; // Laplacian count on the 256x256 crop
  final String? reason; // human-readable, when live == false
  final bool faceFound;
}

class _Job {
  _Job(this.detModel, this.kind, this.detConf, this.spoofModel, this.threshold, this.minSharpness);
  final Uint8List detModel, spoofModel;
  final DetectorKind kind;
  final double detConf, threshold;
  final int minSharpness;
}

class TfliteLiveness implements LivenessCheck {
  TfliteLiveness({
    required this.detectorModel,
    required this.detectorKind,
    required this.spoofModel,
    this.mode = kLivenessMode,
    this.threshold = kLiveThreshold,
    this.minSharpness = kMinSharpness,
    this.detectorConf = 0.25,
  });

  final Uint8List detectorModel, spoofModel;
  final DetectorKind detectorKind;
  final LivenessMode mode;
  final double threshold, detectorConf;
  final int minSharpness;

  /// Worst result (not live first, then highest score) of the most recent [isLive] call, for logging and messages.
  LivenessResult? last;

  Future<LivenessResult> evaluate(Uint8List frame) {
    final j = _Job(detectorModel, detectorKind, detectorConf, spoofModel, threshold, minSharpness);
    return Isolate.run(() => _work(j, frame));
  }

  static bool _worse(LivenessResult a, LivenessResult b) {
    if (a.live != b.live) return !a.live;
    return (a.score ?? -1) > (b.score ?? -1);
  }

  @override
  Future<bool> isLive(List<Uint8List> frames) async {
    if (mode == LivenessMode.off) return true;
    try {
      final rs = await Future.wait([for (final f in frames) evaluate(f)]);
      var worst = rs.first;
      for (final r in rs.skip(1)) {
        if (_worse(r, worst)) worst = r;
      }
      last = worst;
      return mode == LivenessMode.logOnly ? true : rs.every((r) => r.live);
    } catch (e) {
      debugPrint('Liveness check error: $e');
      last = LivenessResult(live: false, reason: 'liveness check could not run ($e)');
      return mode == LivenessMode.logOnly; // enforce: fail closed
    }
  }
}

LivenessResult _work(_Job j, Uint8List frame) {
  var im = img.decodeImage(frame);
  if (im == null) throw const FormatException('Unsupported or corrupt image');
  im = img.bakeOrientation(im);
  if (!(im.numChannels == 3 && im.format == img.Format.uint8)) {
    im = im.convert(numChannels: 3, format: img.Format.uint8);
  }

  final det = TfliteFaceDetector.fromBuffer(j.detModel, kind: j.kind, confThreshold: 0.05);
  final List<FaceBox> faces;
  try {
    faces = det.detect(im);
  } finally {
    det.close();
  }
  final good = faces.where((f) => f.confidence >= j.detConf).toList()
    ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
  if (good.isEmpty) {
    // No face: the normal pipeline reports "no face found"; do not hide that behind a liveness message.
    return const LivenessResult(live: true, faceFound: false);
  }

  // Square crop around the largest face, kept inside the image (as the author's limitSquare does).
  final b = good.first;
  var side = math.max(b.width, b.height);
  side = math.min(side, math.min(im.width, im.height));
  final cx = (b.x1 + b.x2) ~/ 2, cy = (b.y1 + b.y2) ~/ 2;
  final x0 = (cx - side ~/ 2).clamp(0, im.width - side);
  final y0 = (cy - side ~/ 2).clamp(0, im.height - side);
  final crop = img.copyCrop(im, x: x0, y: y0, width: side, height: side);
  final small = img.copyResize(crop, width: 256, height: 256, interpolation: img.Interpolation.linear);
  final rgb = small.getBytes(order: img.ChannelOrder.rgb);

  final sharp = _laplacian(rgb, 256, 256);
  if (sharp < j.minSharpness) {
    return LivenessResult(live: false, sharpness: sharp, reason: 'photo too blurry or dark (sharpness $sharp, needs ${j.minSharpness})');
  }

  final input = Float32List(256 * 256 * 3);
  for (var i = 0; i < input.length; i++) {
    input[i] = rgb[i] / 255.0;
  }
  final interp = Interpreter.fromBuffer(j.spoofModel, options: InterpreterOptions()..threads = 2);
  double score;
  try {
    interp.getInputTensor(0).data = input.buffer.asUint8List();
    interp.invoke();
    // Output tensors are "Identity" (8 class scores) and "Identity_1" (8 leaf masks); find them by name.
    var predIdx = 0, maskIdx = 1;
    if (interp.getOutputTensor(0).name.contains('Identity_1')) {
      predIdx = 1;
      maskIdx = 0;
    }
    final pred = Uint8List.fromList(interp.getOutputTensor(predIdx).data).buffer.asFloat32List();
    final mask = Uint8List.fromList(interp.getOutputTensor(maskIdx).data).buffer.asFloat32List();
    score = 0;
    for (var i = 0; i < 8; i++) {
      score += pred[i].abs() * mask[i];
    }
  } finally {
    interp.close();
  }
  final live = score < j.threshold;
  return LivenessResult(
      live: live,
      score: score,
      sharpness: sharp,
      reason: live ? null : 'looks like a photo or a screen (spoof score ${score.toStringAsFixed(2)}, must be below ${j.threshold})');
}

/// Number of pixels where the 3x3 Laplacian of the grey image exceeds 50 (author's sharpness measure).
int _laplacian(Uint8List rgb, int w, int h) {
  final g = Int32List(w * h);
  for (var i = 0; i < w * h; i++) {
    g[i] = (rgb[i * 3] * 0.3 + rgb[i * 3 + 1] * 0.59 + rgb[i * 3 + 2] * 0.11).toInt();
  }
  var score = 0;
  for (var y = 0; y < h - 2; y++) {
    for (var x = 0; x < w - 2; x++) {
      final r = g[y * w + x + 1] + g[(y + 1) * w + x] + g[(y + 1) * w + x + 2] + g[(y + 2) * w + x + 1] - 4 * g[(y + 1) * w + x + 1];
      if (r > 50) score++;
    }
  }
  return score;
}
