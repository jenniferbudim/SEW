/// Presentation-attack (liveness) settings. Separate from face_config.dart so that file (with your Worker URL)
/// does not have to be replaced.
library;

enum LivenessMode {
  /// No liveness check at all (a printed photo or a phone screen can pass).
  off,

  /// The check RUNS and its score is written to the score log, but it never blocks anyone. Use this while you
  /// measure real faces vs print/replay attacks on YOUR phone and pick the thresholds below.
  logOnly,

  /// A failed check blocks sign-in and registration (and counts as a failed attempt).
  enforce,
}

/// Default is logOnly ON PURPOSE: the model is a small hobby model with no published error rates, and its
/// thresholds have not been checked on your camera. Switch to [LivenessMode.enforce] after calibration
/// (see the steps in the answer / thesis notes).
const kLivenessMode = LivenessMode.logOnly;

/// FaceAntiSpoofing.tflite from github.com/syaringan357/Android-MobileFaceNet-MTCNN-FaceAntiSpoofing (MIT licence).
/// Trained for print and replay attacks only (no masks, no deepfakes).
const kLiveAsset = 'assets/models/FaceAntiSpoofing.tflite';

/// Spoof score below this = live. 0.2 is the model author's default, NOT calibrated for your phone.
const double kLiveThreshold = 0.2;

/// Minimum "sharpness" (count of strong Laplacian responses in the 256x256 face crop) before the model is trusted.
/// 1000 is the author's default; a blurry or dark photo is rejected as "too blurry" instead of being judged.
const int kMinSharpness = 1000;
