// Model files and the accept threshold for face verification.
import 'detection/tflite_face_detector.dart' show DetectorKind;

const kDetectorAsset = 'assets/models/yolo26n_face.tflite'; // match with model used
// enum DetectorKind { yolo26, yolo26pose, yolov7 } 
const kDetectorKind = DetectorKind.yolo26pose;
const kEmbedderAsset = 'assets/models/face_embedder_112.tflite';

/// If true, nobody will be accepted
const bool kCalibrating = false;
const double kCalibratedThreshold = 0.60;
const double kMatchThreshold = kCalibrating ? 2.0 : kCalibratedThreshold;

/// Where the per-user data key comes from
enum KeyService {
  /// Cloudflare Worker 
  worker,

  /// Firebase Cloud Function + Cloud KMS 
  firebaseFunction,
}

const kKeyService = KeyService.worker;

/// URL printed by `wrangler deploy`, with /key on the end
const kWorkerUrl = 'https://face-key.encryption-verification.workers.dev/key';
