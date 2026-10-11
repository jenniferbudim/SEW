import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'camera_capture.dart';
import 'cloud/key_service.dart';
import 'face_config.dart';
import 'face_privacy.dart';

class ProtectDemo extends StatefulWidget {
  const ProtectDemo({super.key});
  @override
  State<ProtectDemo> createState() => _DemoState();
}

class _DemoState extends State<ProtectDemo> {
  // Same detector as the face login: change it in ONE place, face_config.dart.
  static const _modelAsset = kDetectorAsset;
  static const _kind = kDetectorKind;

  // The photo secret now comes from the signed-in user's cloud key (32 random bytes derived per user by the key
  // service), not from a fixed passphrase. It is already high-entropy, so stretching it adds nothing: 1 round.
  static const _kdfRounds = 1;

  /// Needs a connection + login the first time per session (the key is then cached in memory only).
  Future<String> _secret() async {
    final key = await keyProvider.getKey();
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'fdae-photo|$hex'; // separate label from the face-template use of the same user key
  }

  FacePrivacyService? _svc;
  Uint8List? _shown; // what is on screen right now
  Uint8List? _protectedPng; // the last encrypted result, kept for Restore
  bool _showingRestored = false;
  String _status = 'Tap "Take photo & protect".';
  bool _busy = false;

  Future<FacePrivacyService> _service() async => _svc ??= FacePrivacyService(
      modelBytes: (await rootBundle.load(_modelAsset)).buffer.asUint8List(),
      kind: _kind,
      pbkdf2Iterations: _kdfRounds,
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
      _status = 'Cannot decrypt: this photo was protected by a different account (or the key changed).';
    } on NoManifestException catch (e) {
      _status = e.toString();
    } catch (e) {
      _status = 'Failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Live camera -> detect faces -> encrypt them -> keep + save the encrypted PNG.
  Future<void> _protect() async {
    final photo = await captureFromCamera(context);
    if (photo == null || !mounted) return;
    await _run(() async {
      final r = await (await _service()).protect(photo, await _secret());
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
    Uint8List? src = _protectedPng;
    if (src == null) {
      final f = await _savedFile();
      if (await f.exists()) src = await f.readAsBytes();
    }
    if (src == null) return setState(() => _status = 'Nothing to restore yet: take a photo and protect it first.');
    final png = src;
    await _run(() async {
      final r = await (await _service()).unprotect(png, await _secret());
      _protectedPng = png;
      _shown = r.png;
      _showingRestored = true;
      _status = 'Restored. timings ms: ${r.timingsMs}';
    });
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Encrypt faces in a photo'), actions: [
          IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout),
              onPressed: _busy
                  ? null
                  : () async {
                      keyProvider.clear(); // wipe the key from memory
                      await FirebaseAuth.instance.signOut();
                      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                    }),
        ]),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
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
