import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'camera_capture.dart';
import 'recognition/face_auth_service.dart';

class AuthDemo extends StatefulWidget {
  const AuthDemo({super.key, required this.service});
  final FaceAuthService service;
  @override
  State<AuthDemo> createState() => _AuthDemoState();
}

class _AuthDemoState extends State<AuthDemo> {
  final _name = TextEditingController();
  String _log = '';
  bool _busy = false;

  // Live in-app camera preview (front camera); returns the captured JPEG.
  Future<Uint8List?> _shot() async {
    if (!mounted) return null;
    return captureFromCamera(context, front: true);
  }

  Future<void> _run(Future<String> Function() job) async {
    setState(() { _busy = true; _log = 'Working...'; });
    try {
      _log = await job();
    } on FaceAuthException catch (e) {
      _log = e.toString();
    } catch (e) {
      _log = 'Error: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _register() => _run(() async {
        if (_name.text.trim().isEmpty) return 'Enter a name first.';
        final frames = <Uint8List>[];
        for (var i = 0; i < widget.service.config.enrollSamples; i++) {
          final f = await _shot();
          if (f == null) return 'Cancelled.';
          frames.add(f);
        }
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        final r = await widget.service.enroll(userId: id, name: _name.text.trim(), frames: frames);
        return 'Registered "${_name.text.trim()}" (min pair similarity '
            '${r.minPairSimilarity.toStringAsFixed(2)}).\ntimings ms: ${r.timingsMs}';
      });

  Future<void> _login() => _run(() async {
        final f = await _shot();
        if (f == null) return 'Cancelled.';
        final r = await widget.service.identify(f);
        final scores = r.scores
            .map((s) => '${s.name}: ${s.score?.toStringAsFixed(3) ?? s.error}')
            .join('\n');
        return '${r.accepted ? "LOGIN OK: ${r.matched!.name}" : "NOT RECOGNISED"}\n'
            '$scores\ntimings ms: ${r.timingsMs}';
      });

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Face register / login')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              FilledButton(onPressed: _busy ? null : _register, child: const Text('Register (3 photos)')),
              OutlinedButton(onPressed: _busy ? null : _login, child: const Text('Login')),
            ]),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(_log),
          ]),
        ),
      );
}
