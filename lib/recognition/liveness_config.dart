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
const kLivenessMode = LivenessMode.enforce;

/// FaceAntiSpoofing.tflite from github.com/syaringan357/Android-MobileFaceNet-MTCNN-FaceAntiSpoofing (MIT licence).
/// Trained for print and replay attacks only (no masks, no deepfakes).
const kLiveAsset = 'assets/models/FaceAntiSpoofing.tflite';

/// Spoof score below this = live. The model author's default is 0.2; raised to 0.4 as a PROVISIONAL value for phone
/// cameras. Replace it with a value between your real-face liveScores and your print/screen-attack liveScores.
const double kLiveThreshold = 0.9;

/// Minimum "sharpness" (count of strong Laplacian responses in the 256x256 face crop) before the model is trusted.
/// The author's default is 1000; lowered to a PROVISIONAL 400 for phone cameras; a blurry or dark photo is rejected as "too blurry" instead of being judged.
const int kMinSharpness = 400;

/// How much bigger than the detector's face box the square crop for the liveness model is (1.0 = the box itself,
/// 1.4 = a square with 1.4 times the side of the box, so some hair and background around the face). The model was trained on faces with some margin, so a tight crop may
/// be the reason real faces are scored as spoof. Try 1.0, 1.4 and 1.8 and keep the one that separates real faces from
/// attacks best. The crop is limited by the photo size, so a very large face may get less margin than asked.
/// During calibration this value can be changed on the sign-in screen without rebuilding; this is only the start value.
const double kLiveCropScale = 1.0;

/// The value in use right now (starts at [kLiveCropScale]; the calibration sign-in screen changes it).
double liveCropScale = kLiveCropScale;

/// Scales offered on the calibration screen.
const List<double> kLiveCropScales = [1.0, 1.4, 1.8];
