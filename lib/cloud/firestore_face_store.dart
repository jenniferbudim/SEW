import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../recognition/face_store.dart';

/// Cloud implementation of [FaceStore]: one document per user, `faceTemplates/{uid}`.
/// The document holds only FDAE ciphertext; the Firestore security rules let a user read/write only their own
/// document, so [all] returns at most the signed-in user's template. Use `verify(userId)`, NOT 1:N `identify()`.
class FirestoreFaceStore implements FaceStore {
  FirestoreFaceStore({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _ref(String id) => _db.collection('faceTemplates').doc(id);

  @override
  Future<void> save(EnrolledUser u) => _ref(u.id).set({
        'record': Blob(u.toBytes()), // ~150 KB for 3 samples; Firestore's limit is 1 MiB per document
        'v': 1,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  @override
  Future<EnrolledUser?> get(String id) async {
    final snap = await _ref(id).get();
    if (!snap.exists) return null;
    return EnrolledUser.fromBytes((snap.get('record') as Blob).bytes);
  }

  @override
  Future<List<EnrolledUser>> all() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const [];
    final u = await get(uid);
    return u == null ? const [] : [u];
  }

  @override
  Future<void> delete(String id) => _ref(id).delete();
}
