import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'firebase_options.dart';
import 'ui/app_theme.dart';
import 'ui/landing_page.dart';

String? firebaseInitError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    firebaseInitError = e.toString();
  }
  runApp(MaterialApp(
    title: 'Secure Encrypted Verification',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: firebaseInitError == null
        ? const LandingPage()
        : Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Firebase is not set up yet:\n$firebaseInitError', textAlign: TextAlign.center)))),
  ));
}
