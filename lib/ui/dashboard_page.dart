import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../cloud/firestore_face_store.dart';
import '../cloud/key_service.dart';
import '../cloud_auth_demo.dart' show FaceHome;
import '../face_config.dart';
import '../protect_demo.dart';
import 'app_theme.dart';
import 'landing_page.dart';
import 'metrics_page.dart';
import 'sign_up_page.dart';

/// Screen 3 of the mockup.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool? _hasFace;
  User? get _user => FirebaseAuth.instance.currentUser;

  String get _name {
    final u = _user;
    if (u == null) return '';
    if (u.displayName != null && u.displayName!.isNotEmpty) return u.displayName!;
    return (u.email ?? 'user').split('@').first;
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final u = _user;
    if (u == null) return;
    try {
      final rec = await FirestoreFaceStore().get(u.uid);
      if (mounted) setState(() => _hasFace = rec != null);
    } catch (_) {
      if (mounted) setState(() => _hasFace = null);
    }
  }

  void _toLanding() => Navigator.pushAndRemoveUntil(
      context, MaterialPageRoute(builder: (_) => const LandingPage()), (r) => false);

  /// Log out: forget the key and return to the start. The phone keeps the account, so the next sign-in is face only.
  void _logout() {
    keyProvider.clear();
    _toLanding();
  }

  /// Fully forget the account on this phone (the next sign-in asks for email + password).
  Future<void> _switchAccount() async {
    keyProvider.clear();
    await FirebaseAuth.instance.signOut();
    if (mounted) _toLanding();
  }

  void _profile() => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(_name),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Email', style: TextStyle(fontSize: 12)),
            Text(_user?.email ?? '-'),
          ]),
          actionsAlignment: MainAxisAlignment.spaceBetween,
          actions: [
            TextButton(
                onPressed: () {
                  Navigator.pop(c);
                  _switchAccount();
                },
                child: const Text('Switch account')),
            FilledButton(
                onPressed: () {
                  Navigator.pop(c);
                  _logout();
                },
                child: const Text('Log out')),
          ],
        ),
      );

  /// The "Debugging" icon: checks each part of the cloud chain and reports it in a pop-up.
  Future<void> _debug() async {
    final lines = ValueNotifier<List<String>>(['Checking...']);
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Connection check'),
        content: ValueListenableBuilder<List<String>>(
            valueListenable: lines,
            builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [for (final l in v) Text(l)])),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
    final out = <String>[];
    Future<void> step(String name, Future<String> Function() f) async {
      try {
        out.add('✓ $name: ${await f()}');
      } catch (e) {
        out.add('✗ $name: $e');
      }
      lines.value = List.of(out);
    }

    out.clear();
    await step('Account', () async => _user == null ? throw 'not signed in' : 'signed in as ${_user!.email}');
    await step('Key service', () async => 'connected (${(await keyProvider.getKey()).length}-byte key)');
    await step('Face data (Firestore)', () async {
      final rec = await FirestoreFaceStore().get(_user!.uid);
      if (mounted) setState(() => _hasFace = rec != null);
      return rec == null ? 'reachable, no face registered yet' : 'reachable, ${rec.samples.length} encrypted samples';
    });
    await step('Face models', () async {
      final d = await rootBundle.load(kDetectorAsset);
      final e = await rootBundle.load(kEmbedderAsset);
      return 'detector ${(d.lengthInBytes / 1024).round()} KB, embedder ${(e.lengthInBytes / 1024).round()} KB';
    });
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete face data?'),
        content: const Text('Removes your encrypted face from the cloud. You will need to register again to sign in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await keyProvider.deleteMyFaceData();
      if (!mounted) return;
      setState(() => _hasFace = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your face data was deleted.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Row(children: [
                InkResponse(onTap: _profile, child: const SvgIcon('profile', size: 48)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Welcome,', style: TextStyle(color: kPlum, fontSize: 14)),
                    Text(_name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kPlum, fontSize: 24, fontWeight: FontWeight.w500)),
                  ]),
                ),
              ]),
              if (_hasFace == false)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Row(children: [
                    const Expanded(child: Text('No face registered. You cannot sign in with your face until you register.', style: TextStyle(color: kPlum))),
                    FilledButton(
                        onPressed: () async {
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterFacePage()));
                          _refresh();
                        },
                        child: const Text('Register')),
                  ]),
                ),
              const Spacer(),
              const AppLogo(height: 200),
              const Spacer(),
              Wrap(spacing: 28, runSpacing: 24, alignment: WrapAlignment.center, children: [
                IconAction(svg: 'search-bug', label: 'Debugging', onTap: _debug),
                IconAction(svg: 'delete', label: 'Delete', onTap: _delete),
                // Not in the mockup: the thesis' photo-encryption feature has to be reachable from somewhere.
                IconAction(
                    svg: 'encrypt',
                    label: 'Encrypt photo',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProtectDemo()))),
                // Thesis measurements (NPCR, UACI, entropy, timing, memory ...). Hide with kShowMetrics in metrics_page.dart.
                if (kShowMetrics)
                  IconAction(
                      icon: Icons.analytics_outlined,
                      label: 'Metrics',
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MetricsPage()))),
                // Only while the match threshold is being calibrated (kCalibrating in face_config.dart).
                if (kCalibrating)
                  IconAction(
                      icon: Icons.tune,
                      label: 'Calibrate',
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FaceHome(user: _user!)))),
              ]),
              const SizedBox(height: 16),
            ]),
          ),
        ),
      );
}
