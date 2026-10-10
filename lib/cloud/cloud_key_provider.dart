import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'key_provider.dart';

/// Gets the signed-in user's 32-byte data key from the `getOrCreateFaceKey` Cloud Function. The server stores
/// that key only wrapped by Cloud KMS. It is kept in memory for the session and NEVER written to the phone's
/// disk. Everything that needs the key must go through here.
class CloudKeyProvider implements KeyProvider {
  CloudKeyProvider._();
  static final instance = CloudKeyProvider._();

  /// Must equal OPTS.region in firebase/functions/index.js.
  static const region = 'us-central1';

  FirebaseFunctions get _fn => FirebaseFunctions.instanceFor(region: region);
  Uint8List? _key;
  String? _uid;

  @override
  Future<Uint8List> getKey() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in first.');
    final cached = _key;
    if (cached != null && _uid == uid) return cached;
    final res = await _fn.httpsCallable('getOrCreateFaceKey').call();
    final data = Map<String, dynamic>.from(res.data as Map);
    final key = base64.decode(data['key'] as String);
    if (key.length != 32) throw StateError('Key service returned an invalid key.');
    _key = key;
    _uid = uid;
    return key;
  }

  /// Forget the key (call on sign-out).
  @override
  void clear() {
    _key?.fillRange(0, _key!.length, 0);
    _key = null;
    _uid = null;
  }

  /// "Delete my face data": the server removes the wrapped key and the stored template.
  @override
  Future<void> deleteMyFaceData() async {
    await _fn.httpsCallable('deleteFaceData').call();
    clear();
  }
}
