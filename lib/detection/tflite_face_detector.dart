import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'face_box.dart';
import 'yolo_decode.dart';

enum DetectorKind { yolo26, yolov7 }

/// Synchronous detector -- construct and call it INSIDE a background isolate
/// (FacePrivacyService does this) so the UI thread never blocks.
class TfliteFaceDetector {
  TfliteFaceDetector.fromBuffer(
    Uint8List modelBytes, {
    this.kind = DetectorKind.yolo26,
    this.confThreshold,
    this.iouThreshold = 0.5,
    this.boxMargin = 0.10,
    int threads = 2,
  }) : _interp = Interpreter.fromBuffer(modelBytes,
            options: InterpreterOptions()..threads = threads) {
    final s = _interp.getInputTensor(0).shape; // [1,H,W,3] or [1,3,H,W]
    _nchw = s[1] == 3 && s[3] != 3;
    _size = _nchw ? s[2] : s[1];
  }

  final Interpreter _interp;
  final DetectorKind kind;
  final double? confThreshold;
  final double iouThreshold;
  final double boxMargin;
  late final bool _nchw;
  late final int _size;

  /// [rgb] must be orientation-baked, 3-channel uint8.
  List<FaceBox> detect(img.Image rgb) {
    final lb = letterbox(rgb, _size);
    final blob = _nchw ? hwcToChw(lb.blobHwc, _size) : lb.blobHwc;

    _interp.getInputTensor(0).data = blob.buffer.asUint8List();
    _interp.invoke();

    final outT = _interp.getOutputTensor(0);
    final f = Uint8List.fromList(outT.data).buffer.asFloat32List(); // aligned copy
    final shape = outT.shape;

    final raw = kind == DetectorKind.yolo26
        ? decodeYolo26(f, shape, lb, rgb.width, rgb.height, conf: confThreshold ?? 0.3)
        : decodeYolov7(f, shape, lb, rgb.width, rgb.height,
            conf: confThreshold ?? 0.4, iou: iouThreshold);
    return [for (final b in raw) b.expanded(boxMargin, rgb.width, rgb.height)];
  }

  void close() => _interp.close();
}
