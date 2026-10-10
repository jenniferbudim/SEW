import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'camera_capture.dart';
import 'cloud/key_service.dart';
import 'cloud/firestore_face_store.dart';
import 'face_config.dart';
import 'recognition/face_auth_service.dart';
import 'recognition/liveness.dart';

/// Builds the face service with the user's data key from the key service (Worker or Cloud KMS) and the encrypted
/// templates in Firestore. Fails (with a readable message) if the key service, models or threshold are missing.
Future<FaceAuthService> buildCloudService() async {
  final key = Uint8List.fromList(await keyProvider.getKey()); // copy: cache can be zeroed on sign-out
  return FaceAuthService(
    detectorModel: (await rootBundle.load(kDetectorAsset)).buffer.asUint8List(),
    embedderModel: (await rootBundle.load(kEmbedderAsset)).buffer.asUint8List(),
    store: FirestoreFaceStore(),
    deviceKey: key, // name is historical: this is the per-user cloud data key
    liveness: const NoLiveness(), // NOT secure: replace with a real liveness check
    config: FaceAuthConfig(matchThreshold: kMatchThreshold),
    detectorKind: kDetectorKind,
  );
}

/// Account first, face second: signed out -> sign-in page, signed in -> face page.
class CloudGate extends StatelessWidget {
  const CloudGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (c, s) {
          if (s.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final u = s.data;
          return u == null ? const SignInPage() : FaceHome(user: u);
        },
      );
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _email = TextEditingController();
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit({required bool create}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = FirebaseAuth.instance;
      if (create) {
        await auth.createUserWithEmailAndPassword(email: _email.text.trim(), password: _pw.text);
      } else {
        await auth.signInWithEmailAndPassword(email: _email.text.trim(), password: _pw.text);
      }
    } on FirebaseAuthException catch (e) {
      _error = e.message ?? e.code;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sign in')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email')),
            TextField(
                controller: _pw,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password (6+ characters)')),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              FilledButton(onPressed: _busy ? null : () => _submit(create: false), child: const Text('Sign in')),
              OutlinedButton(onPressed: _busy ? null : () => _submit(create: true), child: const Text('Create account')),
            ]),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!)),
          ]),
        ),
      );
}

class FaceHome extends StatefulWidget {
  const FaceHome({super.key, required this.user});
  final User user;
  @override
  State<FaceHome> createState() => _FaceHomeState();
}

class _FaceHomeState extends State<FaceHome> {
  Future<FaceAuthService>? _svc;
  String _log = 'Signed in. Use "Check cloud connection" first.';
  bool _busy = false;

  Future<FaceAuthService> _service() => _svc ??= buildCloudService();

  Future<void> _run(Future<String> Function() job) async {
    setState(() {
      _busy = true;
      _log = 'Working...';
    });
    try {
      _log = await job();
    } on FaceAuthException catch (e) {
      _log = e.toString();
    } catch (e) {
      _svc = null; // let the next attempt rebuild (e.g. after fixing a missing model)
      _log = 'Error: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Works without any model: tests sign-in, the Cloud Function, KMS and the Firestore rules.
  Future<void> _check() => _run(() async {
        final key = await keyProvider.getKey();
        final rec = await FirestoreFaceStore().get(widget.user.uid);
        return 'Key service OK (received a ${key.length}-byte key).\n'
            'Face template in cloud: ${rec == null ? "none yet" : "${rec.samples.length} encrypted samples"}';
      });

  Future<void> _register() => _run(() async {
        final svc = await _service();
        final frames = <Uint8List>[];
        for (var i = 0; i < svc.config.enrollSamples; i++) {
          if (!mounted) return 'Cancelled.';
          final f = await captureFromCamera(context, front: true);
          if (f == null) return 'Cancelled.';
          frames.add(f);
        }
        final r = await svc.enroll(
            userId: widget.user.uid, name: widget.user.email ?? widget.user.uid, frames: frames);
        return 'Face registered and uploaded (encrypted).\n'
            'min pair similarity ${r.minPairSimilarity.toStringAsFixed(2)}\ntimings ms: ${r.timingsMs}';
      });

  Future<void> _verify() => _run(() async {
        final svc = await _service();
        if (!mounted) return 'Cancelled.';
        final f = await captureFromCamera(context, front: true);
        if (f == null) return 'Cancelled.';
        final r = await svc.verify(userId: widget.user.uid, frame: f);
        final s = r.scores.isEmpty ? null : r.scores.first;
        final detail = s == null ? '' : (s.score == null ? '\n${s.error}' : '\nscore ${s.score!.toStringAsFixed(3)}');
        return '${r.accepted ? "FACE MATCH" : "NO MATCH"}$detail\ntimings ms: ${r.timingsMs}';
      });

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete face data?'),
        content: const Text('Removes your encrypted face from the cloud. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await keyProvider.deleteMyFaceData();
      _svc = null;
      return 'Your face data and key were deleted.';
    });
  }

  Future<void> _signOut() async {
    keyProvider.clear();
    await FirebaseAuth.instance.signOut();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.user.email ?? 'Face login'), actions: [
          IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: _busy ? null : _signOut),
        ]),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              OutlinedButton(onPressed: _busy ? null : _check, child: const Text('Check cloud connection')),
              FilledButton(onPressed: _busy ? null : _register, child: const Text('Register my face')),
              FilledButton(onPressed: _busy ? null : _verify, child: const Text('Verify my face')),
              TextButton(onPressed: _busy ? null : _delete, child: const Text('Delete my face data')),
            ]),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(_log),
          ]),
        ),
      );
}
