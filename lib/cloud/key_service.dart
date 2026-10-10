import '../face_config.dart';
import 'cloud_key_provider.dart';
import 'key_provider.dart';
import 'worker_key_provider.dart';

/// The key provider selected by [kKeyService] in face_config.dart.
KeyProvider get keyProvider =>
    kKeyService == KeyService.worker ? WorkerKeyProvider.instance : CloudKeyProvider.instance;
