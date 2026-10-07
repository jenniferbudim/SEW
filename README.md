# face_privacy — Flutter implementation of the pipeline

pick image -> bake EXIF -> detect faces (TFLite, isolate) -> expand box 10% ->
FDAE-encrypt each face box per R/G/B -> lossless PNG with manifest in a tEXt chunk.

## Status (be aware)
* VERIFIED here (Python): your reference == flat-array mirror of this Dart port
  (tools/mirror_and_golden.py), and KDF golden values (tools/kdf_golden.py).
* NOT RUN here: the Dart code itself (no Dart SDK in the sandbox). First step on
  your machine: `flutter pub get && flutter test` — the golden tests will tell
  you immediately if the port diverges from Python.
* NOT VERIFIED: tflite_flutter API details for your installed version
  (Tensor.data get/set, invoke), and your exported model's real I/O shapes.

## Models
Export FLOAT32 or FLOAT16 (not int8: this code feeds float input). Put in
assets/models/ and set `_modelAsset`/`_kind` in main.dart. Check shapes once:
    python -c "import tensorflow as tf;i=tf.lite.Interpreter('m.tflite');i.allocate_tensors();print(i.get_input_details()[0]['shape'],i.get_output_details()[0]['shape'])"
Expect input [1,640,640,3]; output [1,300,6] (YOLO26) or [1,25200,21] (YOLOv7).
The decoder auto-handles channel-first outputs and 0..1 normalised boxes.

## Must-know constraints
1. Output MUST stay PNG. JPEG/WhatsApp/Instagram recompression destroys the
   ciphertext bits -> unrecoverable. Some gallery/share paths also strip PNG
   chunks; test restore on real devices (Files/share-sheet is safest).
2. Orientation is baked before detection; boxes are in that pixel space.
3. Speed: cost ~ face pixels (4 bit-planes x 3 channels). Run on device in
   release mode; 12MP decode/PNG encode in package:image takes seconds.
4. No imageQuality/maxWidth on image_picker (lossy re-encode).

## Measuring on-device
`ProtectResult.timingsMs` / `UnprotectResult.timingsMs` report decode, detect,
kdf, encrypt/decrypt, png_encode, total (ms), shown in the demo UI.
* `detect` currently INCLUDES loading the TFLite model (a fresh Interpreter is
  built in each isolate call), so detectFps is pessimistic versus steady state.
  For true per-frame inference time/FPS keep a long-lived isolate with the
  Interpreter loaded once.
* `kdf` is PBKDF2 (210k iterations) and is a fixed cost per image.
* Encryption cost grows linearly with face pixels; use release/profile mode.
* Python-side reference suite: tools/evaluation_suite.py (`pytest` for unit
  tests, CLI for detection time / FPS / AP / entropy / correlation).

---
# Face register + face login (new)

Flow: register (3 selfies) -> detect single face -> 5-point align to 112x112 ->
embed (for an enrolment consistency check) -> FDAE-encrypt each chip -> store in
SQLite. Login: selfie -> detect/align/embed -> for each enrolled user decrypt
chips IN MEMORY -> embed -> cosine -> accept if >= threshold (and beats runner-up
by `minMargin` for 1:N).

## What "matching against the encrypted image" really means
FDAE ciphertext cannot be compared directly (a chaotic cipher destroys all
structure). The stored image is decrypted in memory, embedded, compared, and
discarded. Consequences:
* the key must be readable by the app WITHOUT a user secret (else it isn't
  "login with your face"): it lives in the OS secure store (DeviceKeyStore).
  This protects a stolen DB file / server copy; it does NOT protect against
  someone operating your unlocked app, or a rooted device.
* login latency = decrypt + embed per stored chip (3 per user), per user (1:N).
  Measure on device (`timings ms` in the demo); prefer `verify(userId)` (1:1)
  when you can ask for a username.
* uninstalling loses the device key -> all enrolments unreadable.

## You must supply / decide
1. An embedding model (112x112 in, D-dim out) converted to TFLite. NOT verified
   here (no weights downloadable in the sandbox). CHECK THE LICENCE: e.g.
   insightface's pretrained models are non-commercial research only.
   Set `embedderMean/Std/Bgr` to match its training preprocessing.
2. `kMatchThreshold` (left NaN on purpose): pick it from genuine/impostor score
   distributions on your model + camera, targeting a false-accept rate.
3. Liveness: none is included (`NoLiveness`). A printed photo or a screen replay
   of the enrolled user will pass. The OS-camera still-photo demo cannot do
   liveness; use the `camera` package stream + a real PAD model for production.
4. Detector: use Model A (YOLOv7-face) -- it returns the 5 landmarks needed for
   alignment. With YOLO26 the code falls back to a square crop (less accurate;
   crop margin 1.3 is a guess).
5. Platform: camera permission strings (Info.plist NSCameraUsageDescription,
   Android CAMERA), flutter_secure_storage min-SDK per its README.

## Security notes (read before shipping)
* Biometrics can't be rotated if leaked, and FDAE is a research cipher, not a
  vetted one. For real protection store an AES-GCM-encrypted EMBEDDING (not the
  image) -- also much faster at login. Re-extract from images only if you need
  to upgrade the embedding model.
* If a backend trusts "the app says the face matched", anyone who can call the
  API can claim that. Remote auth needs a server-verifiable proof (e.g. a
  hardware-backed key released only after a successful local match).
* Biometric data is special-category personal data in many jurisdictions
  (e.g. Indonesia's UU PDP, GDPR): consent, retention and deletion rules apply.
* No attempt limiter / lockout is implemented.
