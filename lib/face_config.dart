// Model files and the accept threshold for face verification.
import 'detection/tflite_face_detector.dart' show DetectorKind;

/// Face detector used by register/verify. YOLO26n has no landmarks, so faces are aligned with a plain square crop
/// (less accurate for matching than 5-point alignment). To use YOLOv7-face instead, change both lines below.
// POSE model (box + 5 keypoints): faces are aligned with the real eye/nose/mouth points. Needs yolo26n_face_pose.tflite.
// To go back to the plain box detector: 'assets/models/yolo26n_face.tflite' + DetectorKind.yolo26.
const kDetectorAsset = 'assets/models/yolo26n_face.tflite'; // the pose model, saved under your existing file name
const kDetectorKind = DetectorKind.yolo26pose;
const kEmbedderAsset = 'assets/models/face_embedder_112.tflite';

/// CALIBRATION MODE (true): the threshold is 2.0, above any possible cosine (max 1.0), so NOBODY is ever accepted,
/// but Register works and Verify shows every score. Collect scores, pick a value, put it in [kCalibratedThreshold],
/// then set this to false.
const bool kCalibrating = false;
const double kCalibratedThreshold = 0.60;
const double kMatchThreshold = kCalibrating ? 2.0 : kCalibratedThreshold;

/// Where the per-user data key comes from.
enum KeyService {
  /// FREE: a Cloudflare Worker (see worker/). Firebase stays on the free Spark plan.
  worker,

  /// Firebase Cloud Function + Cloud KMS (see firebase/). Needs the Blaze billing plan (credit card).
  firebaseFunction,
}

const kKeyService = KeyService.worker;

/// URL printed by `wrangler deploy`, with /key on the end.
const kWorkerUrl = 'https://face-key.encryption-verification.workers.dev/key';
