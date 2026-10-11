import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../cloud/score_log.dart';
import '../recognition/face_auth_service.dart';
import 'app_theme.dart';
import 'dashboard_page.dart';
import 'face_photo_panel.dart';
import 'face_service_factory.dart';

/// Screen 4 of the mockup: account information.
class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});
  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _email = TextEditingController(), _pw = TextEditingController(), _pw2 = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) return setState(() => _error = 'Enter a valid email.');
    if (_pw.text.length < 6) return setState(() => _error = 'Password needs at least 6 characters.');
    if (_pw.text != _pw2.text) return setState(() => _error = 'Passwords do not match.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email, password: _pw.text);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RegisterFacePage()));
      return;
    } on FirebaseAuthException catch (e) {
      _error = e.message ?? e.code;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Sign Up', style: TextStyle(color: kPlum, fontSize: 30, fontWeight: FontWeight.w500)),
            const SizedBox(height: 24),
            const _Label('Email'),
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email]),
            const SizedBox(height: 16),
            const _Label('Password'),
            TextField(controller: _pw, obscureText: true),
            const SizedBox(height: 16),
            const _Label('Confirm Password'),
            TextField(controller: _pw2, obscureText: true),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFB00020)))),
            const SizedBox(height: 28),
            Center(
                child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Sign Up'))),
          ]),
        ),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.t);
  final String t;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(t, style: const TextStyle(color: kPlum, fontSize: 15)));
}

/// Screen 5 of the mockup: register the face (3 photos, slightly different angles), stored encrypted in the cloud.
/// Also reached from the dashboard / sign-in when the account has no face yet.
class RegisterFacePage extends StatefulWidget {
  const RegisterFacePage({super.key});
  @override
  State<RegisterFacePage> createState() => _RegisterFacePageState();
}

class _RegisterFacePageState extends State<RegisterFacePage> {
  final _frames = <Uint8List>[];
  FaceAuthService? _svc;
  int _need = 3;

  Future<String?> _onConfirm(Uint8List jpeg) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'Signed out. Go back and sign in again.';
    try {
      final svc = _svc ??= await buildCloudService();
      _need = svc.config.enrollSamples;
      _frames.add(jpeg);
      if (_frames.length < _need) {
        setState(() {});
        return null; // panel returns to live preview for the next photo
      }
      final frames = List<Uint8List>.of(_frames);
      _frames.clear();
      final r = await svc.enroll(userId: user.uid, name: user.email ?? user.uid, frames: frames);
      logScore(event: 'enroll', label: 'me', score: r.minPairSimilarity, timingsMs: r.timingsMs); // score = min pair similarity
      if (!mounted) return null;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const DashboardPage()), (r) => r.isFirst);
      return null;
    } on FaceAuthException catch (e) {
      _frames.clear(); // a failed set must be retaken as a whole (the photos are checked against each other)
      setState(() {});
      return '$e\nPlease retake all $_need photos.';
    } catch (e) {
      _frames.clear();
      _svc = null;
      setState(() {});
      return 'Error: $e';
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sign Up')),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
          child: FacePhotoPanel(
            caption: 'Face photo ${_frames.length + 1} of $_need — slightly turn your head each time',
            onConfirm: _onConfirm,
          ),
        ),
      );
}
