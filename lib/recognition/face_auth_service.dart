import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
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
    this.minDetectionConf = 0.6,
    this.minFacePx = 100,
    this.enrollSamples = 3,
    this.n0 = 1000,
  }) {
    if (matchThreshold.isNaN) {
      throw StateError('matchThreshold is not set. Calibrate it on your own data '
          '(genuine vs impostor cosine scores) before using face login.');
    }
  }
  final double matchThreshold, minMargin, minDetectionConf;
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
  NoFaceException() : super('No face found.');
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

Uint8List _prepareChip(Uint8List frame, TfliteFaceDetector det, FaceAuthConfig cfg) {
  var im = img.decodeImage(frame);
  if (im == null) throw FaceAuthException('Unsupported or corrupt image.');
  im = img.bakeOrientation(im);
  if (im.numChannels != 3 || im.format != img.Format.uint8) {
    im = im.convert(numChannels: 3, format: img.Format.uint8);
  }
  final faces = det.detect(im).where((f) => f.confidence >= cfg.minDetectionConf).toList();
  if (faces.isEmpty) throw NoFaceException();
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
  final det = TfliteFaceDetector.fromBuffer(j.detModel, kind: j.kind, confThreshold: j.cfg.minDetectionConf);
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
    if (embs.length > 1 && minSim < j.cfg.matchThreshold) throw EnrollmentInconsistentException(minSim);
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
  final det = TfliteFaceDetector.fromBuffer(j.detModel, kind: j.kind, confThreshold: j.cfg.minDetectionConf);
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
