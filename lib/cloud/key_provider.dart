import 'dart:typed_data';

/// Where the user's 32-byte data key comes from. Implementations: [WorkerKeyProvider] (free: Cloudflare Worker) and
/// [CloudKeyProvider] (Firebase Cloud Function + Cloud KMS; needs the Blaze billing plan).
abstract class KeyProvider {
  Future<Uint8List> getKey();

  /// Forget the in-memory key (call on sign-out).
  void clear();

  /// "Delete my face data".
  Future<void> deleteMyFaceData();
}
