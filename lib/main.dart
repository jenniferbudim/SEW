import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'cloud_auth_demo.dart';
import 'firebase_options.dart';

String? firebaseInitError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    firebaseInitError = e.toString(); // the encrypt demo still works without Firebase
  }
  runApp(const MaterialApp(home: Home()));
}

class Home extends StatelessWidget {
  const Home({super.key});

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Face privacy + face login')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FilledButton(
                  onPressed: firebaseInitError != null
                      ? null
                      : () => Navigator.push(c, MaterialPageRoute(builder: (_) => const ProtectGate())),
                  child: const Text('Encrypt faces in a photo')),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: firebaseInitError != null
                      ? null
                      : () => Navigator.push(c, MaterialPageRoute(builder: (_) => const CloudGate())),
                  child: const Text('Face login (account + cloud key)')),
              if (firebaseInitError != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Firebase is not set up yet:\n$firebaseInitError',
                        textAlign: TextAlign.center)),
            ]),
          ),
        ),
      );
}
