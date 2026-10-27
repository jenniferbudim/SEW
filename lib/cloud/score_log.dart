import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Turn off (false) to stop writing scores to Firestore.
const bool kLogScores = true;

/// Appends one document to Firestore `faceLogs` per sign-in attempt / enrollment: the score and the decision only.
/// NO image, NO face crop, NO embedding is ever written. Fire-and-forget: it never delays or breaks a login, and a
/// failure (offline, rules not published) only prints a line in the console.
void logScore({
  required String event, // 'verify' | 'enroll'
  required String label, // who was in front of the camera: 'me', 'friend A', ...
  double? score,
  bool? accepted,
  double? threshold,
  String? error,
  Map<String, int>? timingsMs,
  double? liveScore, // spoof score, lower = more live
  int? sharpness,
  String? liveVerdict, // 'live' | 'spoof' | 'too-blurry' | 'error' | null if not run
  String? liveMode, // off | logOnly | enforce
  int? failCount, // consecutive failed attempts after this one
}) {
  if (!kLogScores) return;
  final u = FirebaseAuth.instance.currentUser;
  if (u == null) return;
  FirebaseFirestore.instance.collection('faceLogs').add({
    'uid': u.uid,
    'event': event,
    'label': label.trim().isEmpty ? 'me' : label.trim(),
    'score': score,
    'accepted': accepted,
    'threshold': threshold,
    'error': error,
    'timingsMs': timingsMs,
    'liveScore': liveScore,
    'sharpness': sharpness,
    'liveVerdict': liveVerdict,
    'liveMode': liveMode,
    'failCount': failCount,
    'createdAt': FieldValue.serverTimestamp(),
  }).then<void>((_) {}, onError: (Object e) => debugPrint('Score log failed: $e'));
}
