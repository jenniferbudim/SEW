class FaceBox {
  const FaceBox(this.x1, this.y1, this.x2, this.y2, [this.confidence = 1.0, this.landmarks]);
  final int x1, y1, x2, y2; // pixel coords in the (orientation-baked) source image
  final double confidence;

  /// 10 values [lx,ly, rx,ry, nx,ny, lmx,lmy, rmx,rmy] = left eye, right eye,
  /// nose, left mouth corner, right mouth corner (image-left first), in source
  /// pixels. Only YOLOv7-face provides them; null for YOLO26.
  final List<double>? landmarks;
  int get width => x2 - x1;
  int get height => y2 - y1;

  /// Grow by [fraction] of width/height on every side (forehead/chin/ears),
  /// clipped to the image.
  FaceBox expanded(double fraction, int imgW, int imgH) {
    final dx = (width * fraction).round(), dy = (height * fraction).round();
    return FaceBox(
      (x1 - dx).clamp(0, imgW), (y1 - dy).clamp(0, imgH),
      (x2 + dx).clamp(0, imgW), (y2 + dy).clamp(0, imgH), confidence, landmarks);
  }

  @override
  String toString() => 'FaceBox($x1,$y1,$x2,$y2,${confidence.toStringAsFixed(2)})';
}
