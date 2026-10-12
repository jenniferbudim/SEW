/// Limits consecutive failed face attempts, following NIST SP 800-63B's idea of throttling biometric attempts:
/// 5 free tries, then an escalating delay (30 s, 60 s, 120 s, ... up to 15 min), and after 10 consecutive failures face
/// login is DISABLED until the user signs in again with the password.
///
/// The counter lives in the phone's secure storage, so it survives restarts. It is a CLIENT-SIDE control: someone
/// who clears the app data or tampers with the app resets it, and the device clock can be changed. A real deployment
/// would also count failures on the server.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LimiterState {
  const LimiterState(this.fails, this.untilMs);
  final int fails; // consecutive failed attempts
  final int untilMs; // epoch ms until which attempts are refused (0 = not locked)
  static const none = LimiterState(0, 0);

  bool get disabled => fails >= AttemptLimiter.disableAfter;
  int get secondsLeft {
    final d = untilMs - DateTime.now().millisecondsSinceEpoch;
    return d <= 0 ? 0 : (d / 1000).ceil();
  }

  bool get locked => !disabled && secondsLeft > 0;
}

class AttemptLimiter {
  AttemptLimiter(this.userId);
  final String userId;

  static const freeTries = 5; // NIST: no more than 5 consecutive failed attempts, then delay or disable
  static const disableAfter = 10;
  static const _baseDelaySeconds = 30, _maxDelaySeconds = 900;
  static const _storage = FlutterSecureStorage();
  String get _key => 'faceFails|$userId';

  /// Delay after the n-th consecutive failure.
  static int delaySeconds(int n) {
    if (n < freeTries) return 0;
    final d = _baseDelaySeconds * (1 << (n - freeTries));
    return d > _maxDelaySeconds ? _maxDelaySeconds : d;
  }

  Future<LimiterState> state() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return LimiterState.none;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return LimiterState((m['n'] as num).toInt(), (m['until'] as num).toInt());
    } catch (e) {
      debugPrint('Attempt limiter could not read its state: $e'); // fail open: do not lock the owner out on a storage error
      return LimiterState.none;
    }
  }

  Future<LimiterState> recordFailure() async {
    final n = (await state()).fails + 1;
    final d = delaySeconds(n);
    final st = LimiterState(n, d == 0 ? 0 : DateTime.now().millisecondsSinceEpoch + d * 1000);
    try {
      await _storage.write(key: _key, value: jsonEncode({'n': st.fails, 'until': st.untilMs}));
    } catch (e) {
      debugPrint('Attempt limiter could not save its state: $e');
    }
    return st;
  }

  Future<void> reset() async {
    try {
      await _storage.delete(key: _key);
    } catch (e) {
      debugPrint('Attempt limiter could not reset: $e');
    }
  }
}
