import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../cloud/firestore_face_store.dart';
import '../cloud/score_log.dart';
import '../face_config.dart';
import '../recognition/face_auth_service.dart';
import 'app_theme.dart';
import 'dashboard_page.dart';
import 'face_photo_panel.dart';
import 'face_service_factory.dart';
import 'sign_up_page.dart';

/// Screen 2 of the mockup: verify the face against the cloud template, then log in.
/// The phone remembers the account (Firebase session); if there is none yet (new phone, or after "Switch account"),
/// an email + password step comes first.
class SignInPage extends StatefulWidget {
  const SignInPage({super.key});
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  FaceAuthService? _svc;
  bool? _hasFace; // null = still checking
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _checkTemplate();
  }

  Future<void> _checkTemplate() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    try {
      final rec = await FirestoreFaceStore().get(u.uid);
      if (mounted) setState(() => _hasFace = rec != null);
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Could not reach the cloud: $e');
    }
  }

  Future<String?> _onConfirm(Uint8List jpeg) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return 'Signed out.';
    try {
      final svc = _svc ??= await buildCloudService();
      final r = await svc.verify(userId: u.uid, frame: jpeg);
      final score = r.scores.isEmpty ? null : r.scores.first;
      logScore(
          event: 'verify',
          label: 'me',
          score: score?.score,
          accepted: kCalibrating ? false : r.accepted,
          threshold: kMatchThreshold,
          error: score?.error,
          timingsMs: r.timingsMs);
      if (kCalibrating) {
        return 'Calibration mode: login is switched off while the match threshold is being set.'
            '${score?.score != null ? "\nScore ${score!.score!.toStringAsFixed(3)}" : ""}';
      }
      if (!r.accepted) {
        return score?.error != null ? score!.error : 'Face does not match. Try again in even light, facing the camera.';
      }
      if (!mounted) return null;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const DashboardPage()), (r) => r.isFirst);
      return null;
    } on NotEnrolledException {
      setState(() => _hasFace = false);
      return null;
    } on FaceAuthException catch (e) {
      logScore(event: 'verify', label: 'me', accepted: false, threshold: kMatchThreshold, error: '$e');
      return '$e';
    } catch (e) {
      _svc = null;
      return 'Error: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    Widget body;
    if (user == null) {
      body = _EmailStep(onDone: () => setState(() {
            _hasFace = null;
            _checkTemplate();
          }));
    } else if (_loadError != null) {
      body = Center(child: Text(_loadError!, textAlign: TextAlign.center));
    } else if (_hasFace == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_hasFace == false) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('No face is registered for ${user.email ?? "this account"}.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: () =>
                  Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RegisterFacePage())),
              child: const Text('Register my face')),
        ]),
      );
    } else {
      body = FacePhotoPanel(caption: user.email, onConfirm: _onConfirm);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Sign In')),
      body: Padding(padding: const EdgeInsets.fromLTRB(28, 4, 28, 24), child: body),
    );
  }
}

class _EmailStep extends StatefulWidget {
  const _EmailStep({required this.onDone});
  final VoidCallback onDone;
  @override
  State<_EmailStep> createState() => _EmailStepState();
}

class _EmailStepState extends State<_EmailStep> {
  final _email = TextEditingController(), _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: _email.text.trim(), password: _pw.text);
      widget.onDone();
      return;
    } on FirebaseAuthException catch (e) {
      _error = e.message ?? e.code;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('This phone does not know you yet. Enter your account first, then verify your face.',
              style: TextStyle(color: kPlum)),
          const SizedBox(height: 16),
          TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(hintText: 'Email')),
          const SizedBox(height: 12),
          TextField(controller: _pw, obscureText: true, decoration: const InputDecoration(hintText: 'Password')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFB00020)))),
          const SizedBox(height: 20),
          Center(child: FilledButton(onPressed: _busy ? null : _go, child: const Text('Continue'))),
        ]),
      );
}
