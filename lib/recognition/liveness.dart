import 'dart:typed_data';

/// Presentation-attack (photo / screen replay / mask) detection hook.
/// This package ships NO real implementation: without one, a printed photo or
/// a phone screen showing the enrolled person can pass the face match.
abstract class LivenessCheck {
  Future<bool> isLive(List<Uint8List> frames);
}

/// Explicit opt-out so the choice is visible in code. NOT secure.
class NoLiveness implements LivenessCheck {
  const NoLiveness();
  @override
  Future<bool> isLive(List<Uint8List> frames) async => true;
}
