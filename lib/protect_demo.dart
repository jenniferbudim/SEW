import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'camera_capture.dart';
import 'face_privacy.dart';

class ProtectDemo extends StatefulWidget {
  const ProtectDemo({super.key});
  @override
  State<ProtectDemo> createState() => _DemoState();
}

class _DemoState extends State<ProtectDemo> {
  static const _modelAsset = 'assets/models/yolo26n_face.tflite';
  static const _kind = DetectorKind.yolo26;

  final _pass = TextEditingController();
  FacePrivacyService? _svc;
  Uint8List? _shown; // what is on screen right now
  Uint8List? _protectedPng; // the last encrypted result, kept for Restore
  bool _showingRestored = false;
  String _status = 'Enter a passphrase, then take a photo.';
  bool _busy = false;

  Future<FacePrivacyService> _service() async => _svc ??= FacePrivacyService(
      modelBytes: (await rootBundle.load(_modelAsset)).buffer.asUint8List(),
      kind: _kind,
      // low on purpose for a weakly trained smoke-test model; raise to ~0.3-0.5 once trained
      confThreshold: 0.15);

  Future<File> _savedFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/protected.png');

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _status = 'Working...';
    });
    final sw = Stopwatch()..start();
    try {
      await job();
      _status = '$_status\nwall ${sw.elapsedMilliseconds} ms';
    } on WrongPassphraseException {
      _status = 'Wrong passphrase.';
    } on NoManifestException catch (e) {
      _status = e.toString();
    } catch (e) {
      _status = 'Failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Live camera -> detect faces -> encrypt them -> keep + save the encrypted PNG.
  Future<void> _protect() async {
    if (_pass.text.isEmpty) return setState(() => _status = 'Enter a passphrase first.');
    final photo = await captureFromCamera(context);
    if (photo == null || !mounted) return;
    await _run(() async {
      final r = await (await _service()).protect(photo, _pass.text);
      final f = await _savedFile();
      await f.writeAsBytes(r.png);
      _protectedPng = r.png;
      _shown = r.png;
      _showingRestored = false;
      _status = '${r.faces.length} face(s) encrypted. Saved ${f.path}\n'
          'timings ms: ${r.timingsMs}\n'
          'detect FPS ${r.detectFps.toStringAsFixed(1)} | protect FPS ${r.protectFps.toStringAsFixed(2)}';
    });
  }

  /// Decrypts the picture that was just protected (memory, or the saved file
  /// if the app was restarted). No photo picker involved.
  Future<void> _restore() async {
    if (_pass.text.isEmpty) return setState(() => _status = 'Enter the passphrase used to protect it.');
    Uint8List? src = _protectedPng;
    if (src == null) {
      final f = await _savedFile();
      if (await f.exists()) src = await f.readAsBytes();
    }
    if (src == null) return setState(() => _status = 'Nothing to restore yet: take a photo and protect it first.');
    final png = src;
    await _run(() async {
      final r = await (await _service()).unprotect(png, _pass.text);
      _protectedPng = png;
      _shown = r.png;
      _showingRestored = true;
      _status = 'Restored. timings ms: ${r.timingsMs}';
    });
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Encrypt faces in a photo')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Passphrase',
                helperText: 'Secret key for the faces. Needed again to restore; not stored anywhere.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              FilledButton.icon(
                  onPressed: _busy ? null : _protect,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Take photo & protect')),
              OutlinedButton(
                  onPressed: _busy ? null : _restore, child: const Text('Restore (decrypt)')),
            ]),
            if (_showingRestored && _protectedPng != null)
              TextButton(
                  onPressed: () => setState(() {
                        _shown = _protectedPng;
                        _showingRestored = false;
                      }),
                  child: const Text('Show encrypted version again')),
            if (_busy) const LinearProgressIndicator(),
            Text(_status),
            Expanded(child: _shown == null ? const SizedBox() : Image.memory(_shown!)),
          ]),
        ),
      );
}
