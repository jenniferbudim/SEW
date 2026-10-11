import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../detection/face_box.dart';
import '../detection/tflite_face_detector.dart';
import '../fdae/fdae_chip.dart';
import 'align.dart';
import 'face_embedder.dart';
import 'face_store.dart';
import 'liveness.dart';

// ------------------------------------------------------------------ config
class FaceAuthConfig {
  FaceAuthConfig({
    required this.matchThreshold, // cosine; MUST be calibrated for YOUR embedder
    this.minMargin = 0.0, // identify(): best must beat 2nd best by this much
    // 0.6 rejected real faces with the weakly trained smoke-test detector ('no face found'); raise it once the
    // detector is trained properly on the GPU PC.
    this.minDetectionConf = 0.25,
    // Enrollment sanity check only (are the 3 photos plausibly the same person?). It must NOT reuse matchThreshold:
    // in calibration mode that is 2.0, which rejects every enrollment. 0.3 is a rough guess, not calibrated.
    this.minEnrollSimilarity = 0.3,
    this.minFacePx = 100,
    this.enrollSamples = 3,
    this.n0 = 1000,
  }) {
    if (matchThreshold.isNaN) {
      throw StateError('matchThreshold is not set. Calibrate it on your own data '
          '(genuine vs impostor cosine scores) before using face login.');
    }
  }
  final double matchThreshold, minMargin, minDetectionConf, minEnrollSimilarity;
  final int minFacePx, enrollSamples, n0;
}

// -------------------------------------------------------------- exceptions
class FaceAuthException implements Exception {
  FaceAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NoFaceException extends FaceAuthException {
  NoFaceException([double? best, double? required])
      : super(best == null
            ? 'No face found (the detector saw nothing at all).'
            : 'No face found: best detection ${best.toStringAsFixed(2)}, needs ${required?.toStringAsFixed(2)}. '
                'Face the camera more directly, in even light.');
}

class MultipleFacesException extends FaceAuthException {
  MultipleFacesException(int n) : super('$n faces found; exactly one is required.');
}

class FaceTooSmallException extends FaceAuthException {
  FaceTooSmallException(int px, int min) : super('Face is ${px}px; need at least ${min}px. Move closer.');
}

class EnrollmentInconsistentException extends FaceAuthException {
  EnrollmentInconsistentException(double s) : super(
      'Enrollment photos do not look like the same person (min similarity ${s.toStringAsFixed(2)}).');
}

class NotLiveException extends FaceAuthException {
  NotLiveException() : super('Liveness check failed.');
}

class NotEnrolledException extends FaceAuthException {
  NotEnrolledException() : super('No enrolled users.');
}

// ----------------------------------------------------------------- results
class UserScore {
  UserScore(this.userId, this.name, this.score, [this.error]);
  final String userId, name;
  final double? score; // best cosine over that user's samples
  final String? error;
}

class AuthResult {
  AuthResult(this.accepted, this.matched, this.scores, this.timingsMs);
  final bool accepted;
  final UserScore? matched; // only when accepted
  final List<UserScore> scores; // best first
  final Map<String, int> timingsMs;
}

class EnrollResult {
  EnrollResult(this.userId, this.minPairSimilarity, this.timingsMs);
  final String userId;
  final double minPairSimilarity;
  final Map<String, int> timingsMs;
}

// ----------------------------------------------------------------- service
class FaceAuthService {
  FaceAuthService({
    required this.detectorModel,
    required this.embedderModel,
    required this.store,
    required this.deviceKey, // from DeviceKeyStore.getOrCreate()
    required this.liveness, // pass const NoLiveness() ONLY if you accept spoofing
    required this.config,
    this.detectorKind = DetectorKind.yolov7, // yolov7 => landmarks => proper alignment
    this.embedderMean = 127.5,
    this.embedderStd = 127.5,
    this.embedderBgr = false,
  });

  final Uint8List detectorModel, embedderModel, deviceKey;
  final FaceStore store;
  final LivenessCheck liveness;
  final FaceAuthConfig config;
  final DetectorKind detectorKind;
  final double embedderMean, embedderStd;
  final bool embedderBgr;

  /// Register: [frames] = photos of the same person. Stores FDAE-encrypted
  /// aligned face chips; no plaintext face pixels are persisted.
  Future<EnrollResult> enroll({
    required String userId, required String name, required List<Uint8List> frames,
  }) async {
    if (frames.isEmpty) throw FaceAuthException('No photos given.');
    if (!await liveness.isLive(frames)) throw NotLiveException();
    final salt = Uint8List.fromList(List.generate(16, (_) => math.Random.secure().nextInt(256)));
    final job = _Job(detectorModel, embedderModel, detectorKind, config, embedderMean,
        embedderStd, embedderBgr);
    final userKey = deriveUserKey(deviceKey, userId, salt);
    final out = await Isolate.run(() => _enrollWork(job, frames, userKey));
    await store.save(EnrolledUser(
        id: userId, name: name, createdAtMs: DateTime.now().millisecondsSinceEpoch,
        salt: salt, n0: config.n0, samples: out.samples));
    return EnrollResult(userId, out.minSim, out.timingsMs);
  }

  /// Debug only: what the pipeline sees for ONE photo -- the detected box, the 112x112 chip that goes into the
  /// embedder, and its embedding (compare chips of several shots with [cosine]).
  Future<DebugCrop> debugCrop(Uint8List frame) {
    final job = _Job(detectorModel, embedderModel, detectorKind, config, embedderMean,
        embedderStd, embedderBgr);
    return Isolate.run(() => _debugWork(job, frame));
  }

  /// 1:1 -- is this face the enrolled user [userId]?  (cheap: one user decrypted)
  Future<AuthResult> verify({required String userId, required Uint8List frame}) async {
    final u = await store.get(userId);
    if (u == null) throw NotEnrolledException();
    return _auth([u], frame, requireMargin: false);
  }

  /// 1:N -- who is this? Decrypts EVERY enrolled user's chips per attempt, so
  /// latency grows linearly with users; fine for a handful, not for hundreds.
  Future<AuthResult> identify(Uint8List frame) async {
    final users = await store.all();
    if (users.isEmpty) throw NotEnrolledException();
    return _auth(users, frame, requireMargin: true);
  }

  Future<AuthResult> _auth(List<EnrolledUser> users, Uint8List frame, {required bool requireMargin}) async {
    if (!await liveness.isLive([frame])) throw NotLiveException();
    final job = _Job(detectorModel, embedderModel, detectorKind, config, embedderMean,
        embedderStd, embedderBgr);
    final key = deviceKey;
    final out = await Isolate.run(() => _authWork(job, frame, users, key));
    final scored = out.scores.where((s) => s.score != null).toList()
      ..sort((a, b) => b.score!.compareTo(a.score!));
    final all = [...scored, ...out.scores.where((s) => s.score == null)];
    if (scored.isEmpty) return AuthResult(false, null, all, out.timingsMs);
    final top = scored.first.score!;
    final second = scored.length > 1 ? scored[1].score! : -1.0;
    final ok = top >= config.matchThreshold &&
        (!requireMargin || scored.length == 1 || top - second >= config.minMargin);
    return AuthResult(ok, ok ? scored.first : null, all, out.timingsMs);
  }
}

class DebugCrop {
  DebugCrop(this.chipPng, this.framePng, this.embedding, this.info);
  final Uint8List chipPng, framePng; // 112x112 aligned chip; downscaled photo with boxes drawn
  final Float32List embedding;
  final String info;
}

// ------------------------------------------------------- isolate-side work
class _Job {
  _Job(this.detModel, this.embModel, this.kind, this.cfg, this.mean, this.std, this.bgr);
  final Uint8List detModel, embModel;
  final DetectorKind kind;
  final FaceAuthConfig cfg;
  final double mean, std;
  final bool bgr;
}

class _EnrollOut {
  _EnrollOut(this.samples, this.minSim, this.timingsMs);
  final List<EncryptedChip> samples;
  final double minSim;
  final Map<String, int> timingsMs;
}

class _AuthOut {
  _AuthOut(this.scores, this.timingsMs);
  final List<UserScore> scores;
  final Map<String, int> timingsMs;
}

/// A weak detector often draws 2+ overlapping boxes on ONE face. Keep the most confident box and drop any box that
/// overlaps it a lot (IoU >= 0.3) or sits mostly inside it / around it (intersection >= 50% of the smaller box).
/// Two genuinely separate faces barely overlap, so they still count as two and are rejected.
List<FaceBox> _dedupe(List<FaceBox> boxes) {
  final sorted = [...boxes]..sort((a, b) => b.confidence.compareTo(a.confidence));
  final kept = <FaceBox>[];
  for (final b in sorted) {
    var dup = false;
    for (final k in kept) {
      final iw = math.min(b.x2, k.x2) - math.max(b.x1, k.x1);
      final ih = math.min(b.y2, k.y2) - math.max(b.y1, k.y1);
      if (iw <= 0 || ih <= 0) continue;
      final inter = iw * ih;
      final areaB = b.width * b.height, areaK = k.width * k.height;
      final iou = inter / (areaB + areaK - inter);
      if (iou >= 0.3 || inter / math.min(areaB, areaK) >= 0.5) {
        dup = true;
        break;
      }
    }
    if (!dup) kept.add(b);
  }
  return kept;
}

Uint8List _prepareChip(Uint8List frame, TfliteFaceDetector det, FaceAuthConfig cfg) {
  var im = img.decodeImage(frame);
  if (im == null) throw FaceAuthException('Unsupported or corrupt image.');
  im = img.bakeOrientation(im);
  if (im.numChannels != 3 || im.format != img.Format.uint8) {
    im = im.convert(numChannels: 3, format: img.Format.uint8);
  }
  final all = det.detect(im); // detector runs with a LOW floor so we can report how close a miss was
  final faces = _dedupe(all.where((f) => f.confidence >= cfg.minDetectionConf).toList());
  if (faces.isEmpty) {
    throw NoFaceException(all.isEmpty ? null : all.map((f) => f.confidence).reduce(math.max), cfg.minDetectionConf);
  }
  if (faces.length > 1) throw MultipleFacesException(faces.length);
  final f = faces.first;
  final side = math.min(f.width, f.height);
  if (side < cfg.minFacePx) throw FaceTooSmallException(side, cfg.minFacePx);
  final rgb = Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb));
  return faceChip(rgb, im.width, im.height, f);
}

_EnrollOut _enrollWork(_Job j, List<Uint8List> frames, Uint8List userKey) {
  final sw = Stopwatch()..start();
  final t = <String, int>{};
  final det = TfliteFaceDetector.fromBuffer(j.detModel, kind: j.kind, confThreshold: 0.05);
  final emb = TfliteFaceEmbedder.fromBuffer(j.embModel, mean: j.mean, std: j.std, bgr: j.bgr);
  try {
    final chips = <Uint8List>[], embs = <Float32List>[];
    for (final f in frames) {
      final chip = _prepareChip(f, det, j.cfg);
      chips.add(chip);
      embs.add(emb.embed(chip));
    }
    t['detect_align_embed'] = sw.elapsedMilliseconds;
    sw.reset();
    var minSim = 1.0;
    for (var a = 0; a < embs.length; a++) {
      for (var b = a + 1; b < embs.length; b++) {
        minSim = math.min(minSim, cosine(embs[a], embs[b]));
      }
    }
    if (embs.length > 1 && minSim < j.cfg.minEnrollSimilarity) throw EnrollmentInconsistentException(minSim);
    final enc = [
      for (var i = 0; i < chips.length; i++)
        encryptChip(chips[i], kChipSize, kChipSize, userKey, i, n0: j.cfg.n0)
    ];
    t['encrypt'] = sw.elapsedMilliseconds;
    return _EnrollOut(enc, minSim, t);
  } finally {
    det.close();
    emb.close();
  }
}

_AuthOut _authWork(_Job j, Uint8List frame, List<EnrolledUser> users, Uint8List deviceKey) {
  final sw = Stopwatch()..start();
  final t = <String, int>{};
  final det = TfliteFaceDetector.fromBuffer(j.detModel, kind: j.kind, confThreshold: 0.05);
  final emb = TfliteFaceEmbedder.fromBuffer(j.embModel, mean: j.mean, std: j.std, bgr: j.bgr);
  try {
    final live = emb.embed(_prepareChip(frame, det, j.cfg));
    t['detect_align_embed'] = sw.elapsedMilliseconds;
    sw.reset();
    var decryptMs = 0, embedMs = 0;
    final scores = <UserScore>[];
    for (final u in users) {
      final key = deriveUserKey(deviceKey, u.id, u.salt);
      try {
        var best = -2.0;
        for (var i = 0; i < u.samples.length; i++) {
          final s1 = sw.elapsedMilliseconds;
          final plain = decryptChip(u.samples[i], u.w, u.h, key, i, n0: u.n0);
          final s2 = sw.elapsedMilliseconds;
          final e = emb.embed(plain);
          decryptMs += s2 - s1;
          embedMs += sw.elapsedMilliseconds - s2;
          best = math.max(best, cosine(live, e));
        }
        scores.add(UserScore(u.id, u.name, best));
      } on TemplateIntegrityException {
        scores.add(UserScore(u.id, u.name, null, 'integrity check failed'));
      }
    }
    t['decrypt_templates'] = decryptMs;
    t['embed_templates'] = embedMs;
    t['users'] = users.length;
    return _AuthOut(scores, t);
  } finally {
    det.close();
    emb.close();
  }
}


DebugCrop _debugWork(_Job j, Uint8List frameBytes) {
  var im = img.decodeImage(frameBytes);
  if (im == null) throw FaceAuthException('Unsupported or corrupt image.');
  im = img.bakeOrientation(im);
  if (im.numChannels != 3 || im.format != img.Format.uint8) {
    im = im.convert(numChannels: 3, format: img.Format.uint8);
  }
  final det = TfliteFaceDetector.fromBuffer(j.detModel, kind: j.kind, confThreshold: 0.05);
  final emb = TfliteFaceEmbedder.fromBuffer(j.embModel, mean: j.mean, std: j.std, bgr: j.bgr);
  try {
    final all = [...det.detect(im)]..sort((a, b) => b.confidence.compareTo(a.confidence));
    if (all.isEmpty) throw FaceAuthException('Detector saw nothing at all (even at confidence 0.05).');
    final kept = _dedupe(all.where((f) => f.confidence >= j.cfg.minDetectionConf).toList());
    final best = kept.isNotEmpty ? kept.first : all.first; // show the best box even if below the accept bar
    final rgb = Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb));
    final chip = faceChip(rgb, im.width, im.height, best);
    final e = emb.embed(chip);

    // photo with every raw detection (grey) and the chosen one (green)
    final k = 360 / im.width;
    final small = img.copyResize(im, width: 360);
    for (final b in all) {
      img.drawRect(small,
          x1: (b.x1 * k).round(), y1: (b.y1 * k).round(), x2: (b.x2 * k).round(), y2: (b.y2 * k).round(),
          color: b == best ? img.ColorRgb8(0, 220, 0) : img.ColorRgb8(200, 200, 200), thickness: 2);
    }
    final chipImg = img.Image.fromBytes(
        width: kChipSize, height: kChipSize, bytes: chip.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
    final info = 'box ${best.width}x${best.height}px conf ${best.confidence.toStringAsFixed(2)}'
        '${best.confidence < j.cfg.minDetectionConf ? " (BELOW accept bar)" : ""}; '
        '${kept.length} face(s) after de-dup, ${all.length} raw boxes';
    return DebugCrop(Uint8List.fromList(img.encodePng(chipImg)), Uint8List.fromList(img.encodePng(small)), e, info);
  } finally {
    det.close();
    emb.close();
  }
}
