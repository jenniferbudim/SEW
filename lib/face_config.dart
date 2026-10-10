// Model files and the accept threshold for face verification.
import 'detection/tflite_face_detector.dart' show DetectorKind;

/// Face detector used by register/verify. YOLO26n has no landmarks, so faces are aligned with a plain square crop
/// (less accurate for matching than 5-point alignment). To use YOLOv7-face instead, change both lines below.
const kDetectorAsset = 'assets/models/yolo26n_face.tflite';
const kDetectorKind = DetectorKind.yolo26;
const kEmbedderAsset = 'assets/models/face_embedder_112.tflite';

/// Cosine-similarity accept threshold. Deliberately NaN: face verification refuses to start until you set a
/// value calibrated on genuine/impostor pairs for YOUR embedding model (no universal default exists).
const double kMatchThreshold = double.nan;

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
