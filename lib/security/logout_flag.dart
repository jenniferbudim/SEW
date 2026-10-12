import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Remembers that the user pressed "Log out" on purpose. While it is set, the app will not trust any leftover
/// session: the next sign-in must start with email + password. Closing the app normally does NOT set it, so the
/// quick "face only" sign-in still works after a normal restart.
class LogoutFlag {
  static const _s = FlutterSecureStorage();
  static const _k = 'userLoggedOut';

  static Future<void> set() async {
    try {
      await _s.write(key: _k, value: '1');
    } catch (e) {
      debugPrint('LogoutFlag.set failed: $e');
    }
  }

  static Future<void> clear() async {
    try {
      await _s.delete(key: _k);
    } catch (e) {
      debugPrint('LogoutFlag.clear failed: $e');
    }
  }

  static Future<bool> isSet() async {
    try {
      return (await _s.read(key: _k)) == '1';
    } catch (_) {
      return false;
    }
  }
}
