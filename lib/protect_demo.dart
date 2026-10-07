import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'face_privacy.dart';

class ProtectDemo extends StatefulWidget {
  const ProtectDemo({super.key});
  @override
  State<ProtectDemo> createState() => _DemoState();
}

class _DemoState extends State<ProtectDemo> {
  // Change to DetectorKind.yolov7 + your model file to use Model A.
  static const _modelAsset = 'assets/models/yolo26n_face_float32.tflite';
  static const _kind = DetectorKind.yolo26;

  final _pass = TextEditingController();
  FacePrivacyService? _svc;
  Uint8List? _shown;
  String _status = 'Pick an image.';
  bool _busy = false;

  Future<FacePrivacyService> _service() async => _svc ??= FacePrivacyService(
      modelBytes: (await rootBundle.load(_modelAsset)).buffer.asUint8List(), kind: _kind,
      // low on purpose for a weakly trained smoke-test model; raise to ~0.3-0.5 once trained
      confThreshold: 0.15);

  // NOTE: no imageQuality/maxWidth here -- those re-encode to lossy JPEG.
  Future<Uint8List?> _pick() async =>
      (await ImagePicker().pickImage(source: ImageSource.gallery))?.readAsBytes();

  Future<void> _run(Future<void> Function(Uint8List) job) async {
    if (_pass.text.isEmpty) return setState(() => _status = 'Enter a passphrase first.');
    final bytes = await _pick();
    if (bytes == null) return;
    setState(() { _busy = true; _status = 'Working...'; });
    final sw = Stopwatch()..start();
    try {
      await job(bytes);
      _status = '${_status}\nwall ${sw.elapsedMilliseconds} ms';
    } catch (e) {
      _status = 'Failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _protect() => _run((bytes) async {
        final r = await (await _service()).protect(bytes, _pass.text);
        final f = File('${(await getApplicationDocumentsDirectory()).path}/protected.png');
        await f.writeAsBytes(r.png);
        _shown = r.png;
        _status = '${r.faces.length} face(s) encrypted. Saved ${f.path}\n'
            'timings ms: ${r.timingsMs}\n'
            'detect FPS ${r.detectFps.toStringAsFixed(1)} | protect FPS ${r.protectFps.toStringAsFixed(2)}';
      });

  Future<void> _restore() => _run((bytes) async {
        final r = await (await _service()).unprotect(bytes, _pass.text);
        _shown = r.png;
        _status = 'Restored. timings ms: ${r.timingsMs}';
      });

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Face privacy (FDAE)')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(controller: _pass, obscureText: true,
                decoration: const InputDecoration(labelText: 'Passphrase')),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              FilledButton(onPressed: _busy ? null : _protect, child: const Text('Protect')),
              OutlinedButton(onPressed: _busy ? null : _restore, child: const Text('Restore')),
            ]),
            if (_busy) const LinearProgressIndicator(),
            Text(_status),
            Expanded(child: _shown == null ? const SizedBox() : Image.memory(_shown!)),
          ]),
        ),
      );
}
