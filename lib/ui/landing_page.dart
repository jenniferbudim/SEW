import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'sign_in_page.dart';
import 'sign_up_page.dart';

class LandingPage extends StatelessWidget {
  const LandingPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const AppLogo(height: 220),
              const SizedBox(height: 12),
              const Text('Secure\nEncrypted\nVerification',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kPlum, fontSize: 18, fontWeight: FontWeight.w800, height: 1.3, letterSpacing: 1)),
              const SizedBox(height: 48),
              FilledButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SignInPage())),
                  child: const Text('Sign In')),
              const SizedBox(height: 24),
              FilledButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SignUpPage())),
                  child: const Text('Sign Up')),
            ]),
          ),
        ),
      );
}
