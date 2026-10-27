import 'dart:async';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../cloud/firestore_face_store.dart';
import '../cloud/score_log.dart';
import '../face_config.dart';
import '../recognition/face_auth_service.dart';
import '../recognition/liveness_config.dart';
import '../recognition/tflite_liveness.dart';
import '../security/attempt_limiter.dart';
import '../security/logout_flag.dart';
import 'app_theme.dart';
import 'consent_page.dart';
import 'dashboard_page.dart';
import 'face_photo_panel.dart';
import 'face_service_factory.dart';

/// Screen 2 of the mockup: verify the face against the cloud template, then log in.
/// The phone remembers the account (Firebase session); if there is none yet (new phone, or after "Switch account"),
/// an email + password step comes first. After too many failed face attempts the face is locked for a while, and
/// after 10 in a row face login is disabled until the password is entered again.
class SignInPage extends StatefulWidget {
  const SignInPage({super.key});
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  FaceAuthService? _svc;
  AttemptLimiter? _limiter;
  LimiterState _lim = LimiterState.none;
  Timer? _tick;
  bool? _hasFace; // null = still checking
  bool _needPassword = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _checkTemplate();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _checkTemplate() async {
    if (await LogoutFlag.isSet()) {
      // the user logged out on purpose: drop any leftover session so the email + password step is shown
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
      if (mounted) setState(() {});
    }
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    try {
      _limiter = AttemptLimiter(u.uid);
      final st = await _limiter!.state();
      final rec = await FirestoreFaceStore().get(u.uid);
      if (!mounted) return;
      setState(() {
        _hasFace = rec != null;
        _needPassword = st.disabled;
      });
      _setLim(st);
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Could not reach the cloud: $e');
    }
  }

  void _setLim(LimiterState st) {
    if (!mounted) return;
    setState(() => _lim = st);
    _tick?.cancel();
    if (st.locked) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (!_lim.locked) _tick?.cancel();
      });
    }
  }

  /// Counts one failed attempt and returns the text to append to the message.
  Future<String> _fail(AttemptLimiter limiter) async {
    if (kCalibrating) return '';
    final st = await limiter.recordFailure();
    _setLim(st);
    if (st.disabled) {
      if (mounted) setState(() => _needPassword = true);
      return '\nFace login is disabled after ${st.fails} failed attempts in a row. Sign in with your password.';
    }
    if (st.locked) return '\n${st.fails} failed in a row. Locked for ${st.secondsLeft} s.';
    return '\n${st.fails} of ${AttemptLimiter.freeTries} free attempts used.';
  }

  LivenessResult? _lastLive(FaceAuthService? svc) {
    final lv = svc?.liveness;
    return lv is TfliteLiveness ? lv.last : null;
  }

  Future<String?> _onConfirm(Uint8List jpeg) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return 'Signed out.';
    final limiter = _limiter ??= AttemptLimiter(u.uid);
    if (!kCalibrating) {
      final st = await limiter.state();
      if (st.disabled) {
        setState(() => _needPassword = true);
        return null;
      }
      if (st.locked) {
        _setLim(st);
        return 'Too many failed attempts. Try again in ${st.secondsLeft} s.';
      }
    }
    FaceAuthService? svc;
    try {
      final s = _svc ??= await buildCloudService();
      svc = s;
      final r = await s.verify(userId: u.uid, frame: jpeg);
      final score = r.scores.isEmpty ? null : r.scores.first;
      final live = _lastLive(svc);
      logScore(
          event: 'verify',
          label: 'me',
          score: score?.score,
          accepted: kCalibrating ? false : r.accepted,
          threshold: kMatchThreshold,
          error: score?.error,
          timingsMs: r.timingsMs,
          liveScore: live?.score,
          sharpness: live?.sharpness,
          liveVerdict: live?.verdict,
          liveMode: kLivenessMode.name);
      if (kCalibrating) {
        return 'Calibration mode: login is switched off while the match threshold is being set.'
            '${score?.score != null ? "\nScore ${score!.score!.toStringAsFixed(3)}" : ""}';
      }
      if (!r.accepted) {
        final more = await _fail(limiter);
        return '${score?.error ?? "Face does not match. Try again in even light, facing the camera."}$more';
      }
      await limiter.reset();
      if (!mounted) return null;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const DashboardPage()), (r) => r.isFirst);
      return null;
    } on NotEnrolledException {
      setState(() => _hasFace = false);
      return null;
    } on NotLiveException {
      final live = _lastLive(svc);
      logScore(
          event: 'verify',
          label: 'me',
          accepted: false,
          threshold: kMatchThreshold,
          error: 'not live',
          liveScore: live?.score,
          sharpness: live?.sharpness,
          liveVerdict: live?.verdict ?? 'error',
          liveMode: kLivenessMode.name);
      final more = await _fail(limiter);
      return 'Liveness check failed${live?.reason != null ? ": ${live!.reason}" : "."}$more';
    } on FaceAuthException catch (e) {
      // no face / several faces / face too small: not an authentication attempt, so it is not counted as a failure
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
            _needPassword = false;
            _checkTemplate();
          }));
    } else if (_needPassword) {
      body = _EmailStep(
        initialEmail: user.email,
        headline: 'Face login is switched off after too many failed attempts. '
            'Enter your password to switch it back on.',
        onDone: () async {
          final u2 = FirebaseAuth.instance.currentUser;
          if (u2 != null) await AttemptLimiter(u2.uid).reset();
          if (!mounted) return;
          setState(() {
            _needPassword = false;
            _lim = LimiterState.none;
            _hasFace = null;
          });
          _checkTemplate();
        },
      );
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
              onPressed: () => Navigator.pushReplacement(
                  context, MaterialPageRoute(builder: (_) => const ConsentPage())),
              child: const Text('Register my face')),
        ]),
      );
    } else {
      body = Column(children: [
        if (_lim.locked)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            color: const Color(0xFFFFF3CD),
            child: Text('Too many failed attempts (${_lim.fails} in a row). Face login is locked for ${_lim.secondsLeft} s.',
                style: const TextStyle(fontSize: 13)),
          ),
        Expanded(child: FacePhotoPanel(caption: user.email, onConfirm: _onConfirm)),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Sign In')),
      body: Padding(padding: const EdgeInsets.fromLTRB(28, 4, 28, 24), child: body),
    );
  }
}

class _EmailStep extends StatefulWidget {
  const _EmailStep({required this.onDone, this.initialEmail, this.headline});
  final VoidCallback onDone;
  final String? initialEmail, headline;
  @override
  State<_EmailStep> createState() => _EmailStepState();
}

class _EmailStepState extends State<_EmailStep> {
  late final _email = TextEditingController(text: widget.initialEmail ?? '');
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: _email.text.trim(), password: _pw.text);
      await LogoutFlag.clear();
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
          Text(widget.headline ?? 'This phone does not know you yet. Enter your account first, then verify your face.',
              style: const TextStyle(color: kPlum)),
          const SizedBox(height: 16),
          TextField(controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: null, enableSuggestions: false, autocorrect: false, decoration: const InputDecoration(hintText: 'Email')),
          const SizedBox(height: 12),
          TextField(controller: _pw, obscureText: true, decoration: const InputDecoration(hintText: 'Password')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFB00020)))),
          const SizedBox(height: 20),
          Center(child: FilledButton(onPressed: _busy ? null : _go, child: const Text('Continue'))),
        ]),
      );
}
