import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../detection/face_box.dart';
import '../detection/tflite_face_detector.dart';
import '../fdae/fdae_cipher.dart';
import '../fdae/key_derivation.dart';
import '../fdae/png_meta.dart';

class WrongPassphraseException implements Exception {
  @override
  String toString() => 'Wrong passphrase (key check failed).';
}

class NoManifestException implements Exception {
  @override
  String toString() => 'No FDAE manifest found in this PNG (was it re-encoded or stripped?).';
}

class ProtectResult {
  ProtectResult(this.png, this.faces, this.timingsMs);
  final Uint8List png; // lossless PNG with the manifest embedded (tEXt "fdae")
  final List<FaceBox> faces;

  /// decode, detect (model load + letterbox + inference + decode), kdf,
  /// encrypt (all faces), png_encode, total -- all in milliseconds.
  final Map<String, int> timingsMs;

  /// Single-image throughput of the compute stages only (detect + encrypt).
  /// For a LIVE camera preview use detect-only FPS: 1000 / timingsMs['detect'].
  double get protectFps => 1000.0 / (timingsMs['detect']! + timingsMs['encrypt']!).clamp(1, 1 << 30);
  double get detectFps => 1000.0 / timingsMs['detect']!.clamp(1, 1 << 30);
}

class UnprotectResult {
  UnprotectResult(this.png, this.timingsMs);
  final Uint8List png;

  /// decode, kdf, decrypt (all faces), png_encode, total -- milliseconds.
  final Map<String, int> timingsMs;
}

/// Entry point for the app. Everything heavy runs in a background isolate.
class FacePrivacyService {
  FacePrivacyService({
    required this.modelBytes,
    this.kind = DetectorKind.yolo26,
    this.n0 = 1000,
    this.pbkdf2Iterations = kPbkdf2Iterations,
    this.confThreshold, // null = detector default (0.3 YOLO26 / 0.4 YOLOv7)
  });

  final Uint8List modelBytes; // rootBundle.load(...) -> buffer.asUint8List()
  final DetectorKind kind;
  final int n0;
  final int pbkdf2Iterations;
  final double? confThreshold;

  /// Decode -> detect -> encrypt face boxes -> lossless PNG (+manifest).
  Future<ProtectResult> protect(Uint8List imageFileBytes, String passphrase) {
    final model = modelBytes, k = kind, n = n0, it = pbkdf2Iterations, conf = confThreshold;
    return Isolate.run(() => _protect(imageFileBytes, passphrase, model, k, n, it, conf));
  }

  /// Read manifest from PNG, re-derive keys, restore the original pixels.
  Future<UnprotectResult> unprotect(Uint8List protectedPng, String passphrase) =>
      Isolate.run(() => _unprotect(protectedPng, passphrase));
}

// ------------------------------------------------------------------ helpers
img.Image _toRgb8(img.Image im) =>
    im.numChannels == 3 && im.format == img.Format.uint8
        ? im
        : im.convert(numChannels: 3, format: img.Format.uint8);

Future<FdaeCiphertext> _encChannel(Uint8List ch, int h, int w, FdaeKeys k) =>
    Isolate.run(() => fdaeEncrypt(ch, h, w, k));
Future<Uint8List> _decChannel(Uint8List ch, int iv, int h, int w, FdaeKeys k) =>
    Isolate.run(() => fdaeDecrypt(FdaeCiphertext(ch, iv), h, w, k));

Uint8List _extract(Uint8List rgb, int imgW, FaceBox b, int c) {
  final w = b.width, h = b.height, ch = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      ch[y * w + x] = rgb[((b.y1 + y) * imgW + b.x1 + x) * 3 + c];
    }
  }
  return ch;
}

void _writeBack(Uint8List rgb, int imgW, FaceBox b, int c, Uint8List src) {
  final w = b.width, h = b.height;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      rgb[((b.y1 + y) * imgW + b.x1 + x) * 3 + c] = src[y * w + x];
    }
  }
}

/// R, G and B of a face box are independent given the same key material
/// (as in pipeline_test.py), so the three channels run in parallel isolates.
/// Output is byte-identical to the sequential version; ivBit is per channel.
Future<Map<String, int>> _encryptRegion(Uint8List rgb, int imgW, FaceBox b, FdaeKeys keys) async {
  const names = ['R', 'G', 'B'];
  final cts = await Future.wait([
    for (var c = 0; c < 3; c++) _encChannel(_extract(rgb, imgW, b, c), b.height, b.width, keys)
  ]);
  final iv = <String, int>{};
  for (var c = 0; c < 3; c++) {
    iv[names[c]] = cts[c].ivBit;
    _writeBack(rgb, imgW, b, c, cts[c].image);
  }
  return iv;
}

Future<void> _decryptRegion(
    Uint8List rgb, int imgW, FaceBox b, FdaeKeys keys, Map<String, dynamic> iv) async {
  const names = ['R', 'G', 'B'];
  final pts = await Future.wait([
    for (var c = 0; c < 3; c++)
      _decChannel(_extract(rgb, imgW, b, c), iv[names[c]] as int, b.height, b.width, keys)
  ]);
  for (var c = 0; c < 3; c++) {
    _writeBack(rgb, imgW, b, c, pts[c]);
  }
}

Uint8List _encodePng(Uint8List rgb, int w, int h) {
  final im = img.Image.fromBytes(
      width: w, height: h, bytes: rgb.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
  return img.encodePng(im, level: 3);
}

// ------------------------------------------------------------------ protect
Future<ProtectResult> _protect(Uint8List fileBytes, String pass, Uint8List model,
    DetectorKind kind, int n0, int iterations, double? conf) async {
  final total = Stopwatch()..start();
  final sw = Stopwatch()..start();
  final t = <String, int>{};
  int lap(String k) {
    t[k] = sw.elapsedMilliseconds;
    sw.reset();
    return t[k]!;
  }

  var decoded = img.decodeImage(fileBytes);
  if (decoded == null) throw const FormatException('Unsupported or corrupt image');
  decoded = _toRgb8(img.bakeOrientation(decoded)); // EXIF rotation baked in FIRST
  final w = decoded.width, h = decoded.height;
  lap('decode');

  final detector = TfliteFaceDetector.fromBuffer(model, kind: kind, confThreshold: conf);
  final List<FaceBox> faces;
  try {
    faces = detector.detect(decoded);
  } finally {
    detector.close();
  }
  lap('detect');

  final rgb = Uint8List.fromList(decoded.getBytes(order: img.ChannelOrder.rgb));
  final rnd = math.Random.secure();
  final salt = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
  final master = pbkdf2Sha256(pass, salt, iterations);
  lap('kdf');

  final entries = <Map<String, dynamic>>[];
  for (var i = 0; i < faces.length; i++) {
    final b = faces[i];
    final iv = await _encryptRegion(rgb, w, b, deriveFaceKeys(master, i, n0: n0));
    entries.add({
      'bbox': {'x1': b.x1, 'y1': b.y1, 'x2': b.x2, 'y2': b.y2},
      'iv_bits': iv,
    });
  }

  lap('encrypt');

  final manifest = {
    'version': 2,
    'image': [w, h],
    'kdf': {'name': 'pbkdf2-hmac-sha256', 'iterations': iterations, 'salt': base64.encode(salt)},
    'check': base64.encode(keyCheck(master)),
    'n0': n0,
    'faces': entries,
  };
  final png = injectTextChunk(
      _encodePng(rgb, w, h), 'fdae', base64.encode(utf8.encode(jsonEncode(manifest))));
  lap('png_encode');
  t['total'] = total.elapsedMilliseconds;
  return ProtectResult(png, faces, t);
}

// ------------------------------------------------------------------ unprotect
Future<UnprotectResult> _unprotect(Uint8List pngBytes, String pass) async {
  final total = Stopwatch()..start();
  final sw = Stopwatch()..start();
  final t = <String, int>{};
  int lap(String k) {
    t[k] = sw.elapsedMilliseconds;
    sw.reset();
    return t[k]!;
  }

  final b64 = readTextChunk(pngBytes, 'fdae');
  if (b64 == null) throw NoManifestException();
  final m = jsonDecode(utf8.decode(base64.decode(b64))) as Map<String, dynamic>;

  final kdf = m['kdf'] as Map<String, dynamic>;
  lap('manifest');
  final master = pbkdf2Sha256(
      pass, base64.decode(kdf['salt'] as String), kdf['iterations'] as int);
  lap('kdf');
  final expect = base64.decode(m['check'] as String);
  final got = keyCheck(master);
  var diff = 0; // constant-time compare
  for (var i = 0; i < got.length; i++) {
    diff |= got[i] ^ expect[i];
  }
  if (diff != 0) throw WrongPassphraseException();

  final png = _toRgb8(img.decodePng(pngBytes)!);
  final w = png.width, h = png.height;
  final rgb = Uint8List.fromList(png.getBytes(order: img.ChannelOrder.rgb));
  lap('decode');
  final n0 = m['n0'] as int;
  final faces = (m['faces'] as List).cast<Map<String, dynamic>>();
  for (var i = 0; i < faces.length; i++) {
    final bb = faces[i]['bbox'] as Map<String, dynamic>;
    final box = FaceBox(bb['x1'] as int, bb['y1'] as int, bb['x2'] as int, bb['y2'] as int);
    await _decryptRegion(rgb, w, box, deriveFaceKeys(master, i, n0: n0),
        faces[i]['iv_bits'] as Map<String, dynamic>);
  }
  lap('decrypt');
  final out = _encodePng(rgb, w, h); // manifest chunk intentionally dropped
  lap('png_encode');
  t['total'] = total.elapsedMilliseconds;
  return UnprotectResult(out, t);
}
