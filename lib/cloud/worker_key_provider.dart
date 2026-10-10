import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../face_config.dart';
import 'firestore_face_store.dart';
import 'key_provider.dart';

/// Free key service: POSTs the user's Firebase ID token to the Cloudflare Worker (worker/), which verifies it and
/// returns that user's key. The key lives in memory only; it is never written to the phone's disk.
class WorkerKeyProvider implements KeyProvider {
  WorkerKeyProvider._();
  static final instance = WorkerKeyProvider._();

  Uint8List? _key;
  String? _uid;

  @override
  Future<Uint8List> getKey() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in first.');
    final cached = _key;
    if (cached != null && _uid == user.uid) return cached;

    final token = await user.getIdToken();
    if (token == null) throw StateError('Could not get a sign-in token.');
    final res = await http
        .post(Uri.parse(kWorkerUrl), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw StateError('Key service answered ${res.statusCode}'
          '${res.statusCode == 500 ? " (is MASTER_KEY set?)" : res.statusCode == 401 ? " (is FIREBASE_PROJECT_ID right?)" : ""}.');
    }
    final key = base64.decode((jsonDecode(res.body) as Map<String, dynamic>)['key'] as String);
    if (key.length != 32) throw StateError('Key service returned an invalid key.');
    _key = key;
    _uid = user.uid;
    return key;
  }

  @override
  void clear() {
    _key?.fillRange(0, _key!.length, 0);
    _key = null;
    _uid = null;
  }

  /// The Worker is stateless (it stores nothing), so deleting means deleting the encrypted template in Firestore.
  @override
  Future<void> deleteMyFaceData() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in first.');
    await FirestoreFaceStore().delete(uid);
    clear();
  }
}
