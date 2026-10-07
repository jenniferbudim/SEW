import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'detection/tflite_face_detector.dart';
import 'auth_demo.dart';
import 'protect_demo.dart';
import 'recognition/face_auth_service.dart';
import 'recognition/face_store.dart';
import 'recognition/liveness.dart';

// ---- configure for YOUR models -------------------------------------------
const kDetectorAsset = 'assets/models/yolov7_face.tflite'; // needs landmarks => Model A
const kEmbedderAsset = 'assets/models/face_embedder_112.tflite';
/// Cosine-similarity accept threshold. Deliberately NaN: the app refuses to
/// start face login until you set a value calibrated on genuine/impostor
/// pairs for YOUR embedding model (no universal default exists).
const double kMatchThreshold = double.nan;
// ---------------------------------------------------------------------------

Future<FaceAuthService> buildService() async => FaceAuthService(
      detectorModel: (await rootBundle.load(kDetectorAsset)).buffer.asUint8List(),
      embedderModel: (await rootBundle.load(kEmbedderAsset)).buffer.asUint8List(),
      store: await SqfliteFaceStore.open(),
      deviceKey: await DeviceKeyStore.getOrCreate(),
      liveness: const NoLiveness(), // NOT secure: replace with a real liveness check
      config: FaceAuthConfig(matchThreshold: kMatchThreshold),
      detectorKind: DetectorKind.yolov7,
    );

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(home: Home(service: buildService())));
}

class Home extends StatelessWidget {
  const Home({super.key, required this.service});
  final Future<FaceAuthService> service;

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Face privacy + face login')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FutureBuilder<FaceAuthService>(
              future: service,
              builder: (c, snap) {
                if (snap.hasError) {
                  return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Face login unavailable:\n${snap.error}',
                          textAlign: TextAlign.center));
                }
                if (!snap.hasData) return const CircularProgressIndicator();
                return FilledButton(
                    onPressed: () => Navigator.push(c,
                        MaterialPageRoute(builder: (_) => AuthDemo(service: snap.data!))),
                    child: const Text('Register / Login with face'));
              },
            ),
            const SizedBox(height: 12),
            OutlinedButton(
                onPressed: () => Navigator.push(
                    c, MaterialPageRoute(builder: (_) => const ProtectDemo())),
                child: const Text('Encrypt faces in a photo')),
          ]),
        ),
      );
}
