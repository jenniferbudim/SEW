import 'package:flutter/material.dart';
import '../cloud/score_log.dart';
import 'app_theme.dart';
import 'sign_up_page.dart';

/// Shown before any face photo is taken. Explicit, unticked-by-default consent (GDPR Art. 9(2)(a): biometric data
/// needs explicit consent that is specific, informed and as easy to withdraw as to give). Withdrawal = the Delete
/// button on the dashboard.
class ConsentPage extends StatefulWidget {
  const ConsentPage({super.key});
  @override
  State<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends State<ConsentPage> {
  bool _agree = false;

  void _continue() {
    logScore(event: 'consent', label: 'me', accepted: true); // proof of when consent was given; no biometric data
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RegisterFacePage()));
  }

  Widget _row(IconData i, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i, color: kIconColor),
          const SizedBox(width: 12),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: kPlum)),
            Text(body),
          ])),
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Before we register your face')),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
          child: Column(children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _row(Icons.photo_camera_outlined, 'What is stored',
                      'Three small face crops (112 x 112 px) taken now, kept only in encrypted form, plus the numeric '
                      'face template used for matching. Your full photos are not stored.'),
                  _row(Icons.cloud_outlined, 'Where',
                      'In the cloud database (Firebase), under your account only. The encryption key is held by a '
                      'separate key service and is never saved with the data.'),
                  _row(Icons.lock_outline, 'What it is used for',
                      'Only to check that the person signing in is you. Nothing else, and it is not shared.'),
                  _row(Icons.delete_outline, 'You stay in control',
                      'Press Delete on the dashboard at any time to remove your face data. Face login then stops '
                      'working until you register again. Signing in with your password does not need your face.'),
                  _row(Icons.info_outline, 'Be aware',
                      'Face matching is not perfect: it can wrongly reject you, and rarely accept someone who looks '
                      'very similar. Too many failed attempts temporarily lock face login.'),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _agree,
                    onChanged: (v) => setState(() => _agree = v ?? false),
                    title: const Text('I agree to my face data being stored and used as described.'),
                  ),
                ]),
              ),
            ),
            FilledButton(onPressed: _agree ? _continue : null, child: const Text('Agree and continue')),
            TextButton(onPressed: () => Navigator.maybePop(context), child: const Text('Not now')),
          ]),
        ),
      );
}
