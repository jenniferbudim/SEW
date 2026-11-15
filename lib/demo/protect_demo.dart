import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../cloud/key_service.dart';
import '../face_config.dart';
import '../face_privacy.dart';
import '../ui/face_photo_panel.dart';

/// Encrypt Photo Demo. Same screen as the face sign-in (live preview, shutter + flip inside the box), but the two
/// buttons are Encrypt and Decrypt instead of Retake and Confirm.
/// Take a photo, press Encrypt to scramble the faces in it, press Decrypt to get them back.
/// The camera icon that shows on the photo (bottom right) goes back to the live preview for a new photo.
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
  Uint8List? _shown; // encrypted / decrypted result shown in the box (null = show the photo that was taken)
  Uint8List? _protectedPng; // the last encrypted result, kept for Decrypt
  String? _info; // "Face(s) encrypted: 1 / Total time taken: 2266 ms"

  Future<FacePrivacyService> _service() async => _svc ??= FacePrivacyService(
      modelBytes: (await rootBundle.load(_modelAsset)).buffer.asUint8List(),
      kind: _kind,
      pbkdf2Iterations: _kdfRounds,
      // low on purpose for a weakly trained smoke-test model; raise to ~0.3-0.5 once trained
      confThreshold: 0.15);

  Future<File> _savedFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/protected.png');

  /// Runs [job]; returns the error text for the panel to show, or null when it worked.
  Future<String?> _run(Future<void> Function() job) async {
    try {
      await job();
      return null;
    } on WrongPassphraseException {
      return 'Cannot decrypt: this photo was protected by a different account (or the key changed).';
    } on NoManifestException catch (e) {
      return e.toString();
    } catch (e) {
      return 'Failed: $e';
    }
  }

  /// Photo taken in the box -> detect faces -> encrypt them -> keep + save the encrypted PNG.
  Future<String?> _encrypt(Uint8List? photo) async {
    if (photo == null) return 'Take a photo first.';
    return _run(() async {
      final r = await (await _service()).encrypt(photo, await _secret());
      await (await _savedFile()).writeAsBytes(r.png);
      if (!mounted) return;
      setState(() {
        _protectedPng = r.png;
        _shown = r.png;
        _info = 'Face(s) encrypted: ${r.faces.length}\n'
            'Total time taken: ${r.timingsMs['total']} ms';
      });
    });
  }

  /// Decrypts the picture that was just encrypted (memory, or the saved file if the app was restarted).
  Future<String?> _decrypt(Uint8List? _) async {
    Uint8List? src = _protectedPng;
    if (src == null) {
      final f = await _savedFile();
      if (await f.exists()) src = await f.readAsBytes();
    }
    if (src == null) return 'Nothing to decrypt yet: take a photo and encrypt it first.';
    final png = src;
    return _run(() async {
      final r = await (await _service()).decrypt(png, await _secret());
      if (!mounted) return;
      setState(() {
        _protectedPng = png;
        _shown = r.png;
        _info = 'Face(s) decrypted: ${r.faceCount}\n'
            'Total time taken: ${r.timingsMs['total']} ms';
      });
    });
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Encrypt Photo Demo')),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
          child: FacePhotoPanel(
            leftAction: PanelAction('Encrypt', _encrypt),
            rightAction: PanelAction('Decrypt', _decrypt),
            shownImage: _shown,
            info: _info,
            onBackToCamera: () => setState(() {
              _shown = null;
              _info = null;
            }),
          ),
        ),
      );
}