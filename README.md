# SEW — Sistem Enkripsi Wajah (Face Encryption System)

A Flutter (Android) app that protects faces in two ways:

1. **Face privacy for photos.** It detects every face in a photo on the device, encrypts only those face regions with the
   FDAE cipher (chaotic maps + DNA-style bit operations), and saves a lossless PNG. The original pixels can be restored
   exactly with the right key.
2. **Face login.** Three aligned 112×112 face crops are stored **encrypted** in Firestore. At sign-in the app decrypts
   them in memory, compares embeddings (cosine similarity), and discards them.

This repository is the implementation for an undergraduate thesis on the encryption implementation. It is a research
prototype, not a vetted security product (see [Limitations](#limitations-read-before-reusing)).

---

## 1. How it works

```
photo -> bake EXIF -> detect faces (TFLite) -> expand box 10 % -> FDAE-encrypt each face box (R, G, B)
      -> lossless PNG + manifest in a tEXt chunk

register: 3 selfies -> detect 1 face -> 5-point align to 112x112 -> embed (consistency check)
          -> FDAE-encrypt each crop -> Firestore  faceTemplates/{uid}
sign in : selfie -> liveness check -> detect/align/embed
          -> decrypt the 3 stored crops IN MEMORY -> embed -> cosine -> accept if >= threshold
key     : app sends its Firebase ID token to a Cloudflare Worker -> Worker returns a per-user 32-byte key
          (HKDF-SHA256 of a secret MASTER_KEY and the uid); the key is kept in memory only
```

Cipher details (see `lib/fdae/fdae_cipher.dart`): Piecewise Linear Chaotic Map (x0, μ1, y0, μ2) and Logistic map
(z0, r in (3.57, 4]); bit-plane diffusion and confusion; the DNA-XOR layer is implemented as bitwise XOR. Each face
gets its own six key parameters, derived from the master key with HMAC-SHA256 (`deriveFaceKeys`, `lib/fdae/key_derivation.dart`).
Keys whose Logistic orbit is periodic (Lyapunov exponent below 0.1) are rejected and re-derived, because they make the
keystream independent of z0.

## 2. Repository layout

| Path | What it is |
|---|---|
| `lib/fdae/` | The cipher, key derivation, PNG manifest, face-chip encryption |
| `lib/detection/` | TFLite detector wrapper and YOLO output decoders (YOLO26, YOLO26-pose, YOLOv7-face) |
| `lib/pipeline/` | Protect / unprotect a whole photo |
| `lib/recognition/` | Alignment, embedder, liveness, face sign-up / sign-in service |
| `lib/cloud/` | Firestore store, score log, key providers (Cloudflare Worker or Firebase Function) |
| `lib/security/` | Failed-attempt limiter (client side) |
| `lib/metrics/`, `lib/ui/metrics_page.dart` | The on-device benchmark that produced the thesis results |
| `lib/face_config.dart`, `lib/recognition/liveness_config.dart` | The settings you will most likely change |
| `worker/` | Cloudflare Worker that releases per-user keys (tested on Node 22) |
| `tools/` | Python helpers: golden vectors, plots, FAR/FRR report, Firestore log export |
| `test/` | Dart tests and golden vectors from the Python reference |
| `assets/models/` | The three TFLite models (see [Models](#4-models)) |

## 3. Reproducing it

### 3.1 Requirements
* Flutter stable (pubspec asks for Flutter ≥ 3.19 and Dart ≥ 3.3), Android SDK, **JDK 17** (the Gradle files target Java/Kotlin 17).
* A physical Android phone is recommended; timings in the thesis come from a phone, not an emulator.
* For the backend: a Google/Firebase account and a Cloudflare account (both free plans are enough), Node.js 22 for the Worker tests.
* For the Python tools: Python 3.10+, `numpy`, `pillow`, `matplotlib`; `firebase-admin` for `fetch_facelogs.py`.

### 3.2 Build and run the tests
```bash
git clone https://github.com/jenniferbudim/SEW.git
cd SEW
flutter pub get
flutter test            # checks the Dart cipher and key derivation against the Python golden vectors
```
The golden tests (`test/golden.json`, `test/kdf_golden.json`, `test/align_golden.json`) fail immediately if the Dart port
differs from the Python reference.

### 3.3 Use your own Firebase project
The repository's `firebase_options.dart` and `google-services.json` belong to the author's project, so you need your own:
1. Create a Firebase project, enable **Authentication → Email/Password** and **Cloud Firestore**.
2. Run `flutterfire configure` (replaces `lib/firebase_options.dart` and `android/app/google-services.json`) and update `.firebaserc`.
3. Publish Firestore rules that let a signed-in user touch only their own data. The app needs at least:
   ```
   rules_version = '2';
   service cloud.firestore {
     match /databases/{db}/documents {
       match /faceTemplates/{uid} { allow read, write: if request.auth != null && request.auth.uid == uid; }
       match /faceLogs/{id}       { allow create: if request.auth != null && request.resource.data.uid == request.auth.uid;
                                    allow read, update, delete: if false; }
     }
   }
   ```
   Note: the `firestore.rules` file currently committed denies everything, which would block the app. Use the rules above
   (or update that file) before publishing. `faceTemplates` stores only ciphertext; `faceLogs` stores scores and decisions, never images.

### 3.4 Deploy the key service
```bash
cd worker
npm install
npm test                          # node --test
npx wrangler secret put MASTER_KEY   # a long random secret; never commit it
npx wrangler deploy
```
Set `FIREBASE_PROJECT_ID` in `worker/wrangler.toml` to your project id, then put the URL printed by `wrangler deploy`
(with `/key` on the end) in `kWorkerUrl` in `lib/face_config.dart`. If `MASTER_KEY` is lost, every stored face becomes unreadable.

### 3.5 Run the app
```bash
flutter run --release            # profile/release mode; debug mode is far slower for the cipher
```
First run: register with email and password, accept the consent screen, take 3 selfies. Then sign in with your face.

### 3.6 Reproduce the benchmark numbers
1. Open the **Metrics** page in the app, pick 30 photos (or a ZIP), and run. It exports a JSON, a CSV and (optionally) a ZIP of
   plain, encrypted and decrypted faces per trial.
2. What it measures per trial (random keys seeded from `1000 + trial`): NPCR and UACI (one-bit change of one random pixel per
   channel), key sensitivity (1e-10 change of each of the six parameters), information entropy, chi-square, adjacent-pixel
   correlation, PSNR/SSIM, exact-restore check, key-space probe, detection and encryption time, memory.
3. Plots from the exported files:
   ```bash
   python tools/plot_histograms.py results.json --trial all --out hist
   python tools/plot_correlation.py fdae_trial_photos_xxx.zip --trial 1 --dir h --out corr
   ```
   (`pip install numpy pillow matplotlib`)
4. Face-login error rates: export the logs with `python tools/fetch_facelogs.py --key serviceAccount.json --out facelogs.csv`
   (the service-account key is a **secret**: keep it out of git and delete it afterwards), then
   `python tools/far_frr_report.py facelogs.csv`. Use `kCalibrating = true` in `face_config.dart` while collecting
   genuine/impostor scores and set it back to `false` afterwards.

### 3.6.1 Detector accuracy (AP)
Detector accuracy was measured with a separate script, `compare_detectors.py` (ONNX Runtime, same letterbox/NMS/AP code for
both models): AP50 and AP50-95 with COCO-style 101-point interpolation on a validation split of the author's own
labelled data, plus precision/recall at a chosen confidence and landmark error.
> **Not yet in this repository:** `compare_detectors.py`, the model training scripts and the dataset split list.
> Add them (for example under `tools/` and `training/`) so these numbers can be reproduced. Settings used in the thesis runs:
> 500 validation images, 640 px input, NMS IoU 0.6, confidence 0.001 for AP.

### 3.7 What is *not* in this repository
* Training code and the exact image lists for the detector models.
* `fdae_encryption.py` (the original Python reference) and `pipeline_test.py`, which `tools/mirror_and_golden.py` and
  `tools/evaluation_suite.py` import. The golden JSON files they produced are included, so the Dart tests still run.
* The photos used in the benchmark (they are personal photos).

## 4. Models

| File | Purpose | Source / licence |
|---|---|---|
| `assets/models/yolo26n_face.tflite` | Face detector (YOLO26n-pose with 5 landmarks, 640×640, float) | Trained by the author with Ultralytics YOLO26 on WIDER FACE + CelebA. **Ultralytics is AGPL-3.0; check what that means for this model and for the app.** |
| `assets/models/face_embedder_112.tflite` | Face embedding for matching (MobileFaceNet style, 112×112) | TODO: state the exact source and licence |
| `assets/models/FaceAntiSpoofing.tflite` | Print/replay liveness check | [syaringan357/Android-MobileFaceNet-MTCNN-FaceAntiSpoofing](https://github.com/syaringan357/Android-MobileFaceNet-MTCNN-FaceAntiSpoofing), MIT (licence copied to `assets/models/syaringan357_LICENSE.txt`) |

`DetectorKind.yolov7` (YOLOv7-face) is also supported by the decoder and was the comparison detector in the thesis; its weights
are not shipped. Export float32 or float16, **not int8**. Check shapes once:
```bash
python -c "import tensorflow as tf;i=tf.lite.Interpreter('m.tflite');i.allocate_tensors();print(i.get_input_details()[0]['shape'],i.get_output_details()[0]['shape'])"
```
Expected: input `[1,640,640,3]`; output `[1,20,8400]` for YOLO26-pose or `[1,N,21]` for YOLOv7-face.

### Datasets used for training
* **WIDER FACE** — Yang, Luo, Loy, Tang, CVPR 2016.
* **CelebA** — Liu, Luo, Wang, Tang, "Deep Learning Face Attributes in the Wild", ICCV 2015. Both datasets have their own
  terms (research / non-commercial); read them before reusing the trained weights.

## 5. Settings you will change

| Where | Setting | Current value / meaning |
|---|---|---|
| `lib/face_config.dart` | `kDetectorAsset`, `kDetectorKind` | `yolo26n_face.tflite`, `DetectorKind.yolo26pose` |
| | `kMatchThreshold` | cosine ≥ 0.60 accepts (chosen deliberately; **false-accept rate not measured**) |
| | `kCalibrating` | `true` = nobody is accepted (threshold 2.0) but every score is logged. Keep `false` for normal use |
| | `kKeyService`, `kWorkerUrl` | Cloudflare Worker (or Firebase Function + KMS) |
| `lib/recognition/liveness_config.dart` | `kLivenessMode` | `off` / `logOnly` / `enforce` (currently `enforce`) |
| | `kLiveThreshold`, `kMinSharpness`, `kLiveCropScale` | **provisional**, not calibrated on real attacks |
| `lib/fdae/key_derivation.dart` | `kPbkdf2Iterations` | 210 000 |
| `lib/security/attempt_limiter.dart` | lockout | 5 free tries, then 30 s doubling to 15 min, disabled after 10 failures |

## Limitations (read before reusing)
* **FDAE is a research cipher.** Statistical tests (NPCR, UACI, entropy, correlation, key sensitivity) show no weakness on the
  tested photos, but no cryptanalysis was done. For real protection use a vetted cipher such as AES-GCM.
* **Matching is done after decryption.** An encrypted chaotic image cannot be compared directly, so the stored crops are
  decrypted in memory. The key is fetched from the Worker with a Firebase token and is never stored on the phone.
* **Liveness is weak.** The model is a small open model for print and replay attacks only, with no published error rates, and its
  thresholds have not been calibrated. Spoofing is outside the thesis scope.
* **Attempt limiting is client side** and can be reset by clearing app data.
* **PNG only.** JPEG or messaging-app recompression destroys the ciphertext; some share paths strip the PNG chunk.
* **Key derivation changed after testing** (weak logistic keys are now re-derived), so about 12 % of keys differ from older
  builds. Data registered before that change must be re-registered.
* **Tested on one Android phone.** Benchmark photos contained one face each; partially overlapping faces are handled
  (reverse-order decrypt, nested boxes dropped) but were not part of the measured runs.
* Memory use rose from trial to trial in the benchmark; the cause has not been found.
* Biometric data is special-category personal data in many places (for example UU PDP in Indonesia and the GDPR). Consent,
  retention and deletion rules apply; the app asks for consent and has a Delete button.

## Credits and references
* **Ultralytics YOLO** (YOLO26 / YOLO26-pose) for detector training and export.
* **YOLOv7** (Wang, Bochkovskiy, Liao, CVPR 2023) and its face/landmark variant, used as the comparison detector.
  TODO: name the exact YOLOv7-face repository and licence you trained from.
* **syaringan357/Android-MobileFaceNet-MTCNN-FaceAntiSpoofing** (MIT) for the liveness model.
* **InsightFace** for the ArcFace 112×112 five-point alignment template used in `lib/recognition/align.dart`
  (verified against skimage/OpenCV in `tools/align_golden.py`).
* **WIDER FACE** (Yang et al., 2016) and **CelebA** (Liu et al., 2015) for training data.
* **MTCNN** (Zhang et al., 2016) is the precedent for combining WIDER FACE (detection) and CelebA (landmarks).
* **FDAE cipher design:** TODO: cite the paper(s) the cipher is based on (PWLCM + Logistic + DNA encoding).
* **Metrics:** NPCR/UACI as defined by Wu, Noonan and Agaian (2011); AP with 101-point interpolation as in the COCO protocol (Lin et al., 2014) and
  the PASCAL VOC definition (Everingham et al., 2010). TODO: add full references.
* **Libraries:** Flutter, `tflite_flutter`, `camera`, `image`, `crypto`, `archive`, `flutter_secure_storage`,
  `firebase_core`, `firebase_auth`, `cloud_firestore`, `cloud_functions`, `http`, `file_picker`, `flutter_svg`; Firebase and Cloudflare Workers for the backend.
* Icons in `assets/icons/`: TODO: state the icon set and its licence.

## Author
Jennifer (GitHub: jenniferbudim), UKRIDA