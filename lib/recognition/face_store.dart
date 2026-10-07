import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../fdae/fdae_chip.dart';

/// One registered person. Face pixels exist ONLY as FDAE ciphertext;
/// id/name/createdAt are plaintext metadata.
class EnrolledUser {
  EnrolledUser({
    required this.id, required this.name, required this.createdAtMs,
    required this.salt, required this.n0, required this.samples,
    this.w = 112, this.h = 112,
  });
  final String id, name;
  final int createdAtMs, n0, w, h;
  final Uint8List salt; // per-enrollment, feeds deriveUserKey
  final List<EncryptedChip> samples;

  Uint8List toBytes() => utf8.encode(jsonEncode({
        'v': 1, 'id': id, 'name': name, 'created': createdAtMs, 'n0': n0, 'w': w, 'h': h,
        'salt': base64.encode(salt), 'samples': [for (final s in samples) s.toJson()],
      }));

  factory EnrolledUser.fromBytes(Uint8List b) {
    final j = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    return EnrolledUser(
      id: j['id'] as String, name: j['name'] as String, createdAtMs: j['created'] as int,
      n0: j['n0'] as int, w: j['w'] as int, h: j['h'] as int,
      salt: base64.decode(j['salt'] as String),
      samples: [for (final s in j['samples'] as List) EncryptedChip.fromJson(s as Map<String, dynamic>)],
    );
  }
}

/// Swap this for a server-backed implementation if the DB is remote. The server
/// then only ever holds ciphertext (it cannot match faces); matching stays on
/// the device that holds the device key.
abstract class FaceStore {
  Future<void> save(EnrolledUser u);
  Future<List<EnrolledUser>> all();
  Future<EnrolledUser?> get(String id);
  Future<void> delete(String id);
}

class SqfliteFaceStore implements FaceStore {
  SqfliteFaceStore._(this._db);
  final Database _db;

  static Future<SqfliteFaceStore> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'faces.db'),
      version: 1,
      onCreate: (db, _) => db.execute(
          'CREATE TABLE face_users(id TEXT PRIMARY KEY, name TEXT NOT NULL, '
          'created_at INTEGER NOT NULL, record BLOB NOT NULL)'),
    );
    return SqfliteFaceStore._(db);
  }

  @override
  Future<void> save(EnrolledUser u) => _db.insert(
      'face_users',
      {'id': u.id, 'name': u.name, 'created_at': u.createdAtMs, 'record': u.toBytes()},
      conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<List<EnrolledUser>> all() async => [
        for (final r in await _db.query('face_users', orderBy: 'created_at'))
          EnrolledUser.fromBytes(r['record'] as Uint8List)
      ];

  @override
  Future<EnrolledUser?> get(String id) async {
    final rows = await _db.query('face_users', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : EnrolledUser.fromBytes(rows.first['record'] as Uint8List);
  }

  @override
  Future<void> delete(String id) => _db.delete('face_users', where: 'id = ?', whereArgs: [id]);
}

/// 32 random bytes kept in the OS secure store (Android Keystore-wrapped /
/// iOS Keychain). The app must read it WITHOUT a user secret -- that is what
/// makes "log in with just your face" possible, and also why this protects
/// data at rest (stolen DB file) but not against someone using the unlocked app.
/// Uninstalling the app loses the key and with it every enrolment.
class DeviceKeyStore {
  static const _name = 'fdae_device_key_v1';
  static Future<Uint8List> getOrCreate(
      {FlutterSecureStorage storage = const FlutterSecureStorage()}) async {
    final existing = await storage.read(key: _name);
    if (existing != null) return base64.decode(existing);
    final rnd = math.Random.secure();
    final key = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    await storage.write(key: _name, value: base64.encode(key));
    return key;
  }
}
