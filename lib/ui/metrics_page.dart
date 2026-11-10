import 'dart:convert';
import 'dart:io' show File, Platform, ProcessInfo;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' hide Summary;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import '../camera_capture.dart';
import '../face_config.dart';
import '../face_privacy.dart';
import '../metrics/fdae_benchmark.dart';
import '../metrics/image_metrics.dart';
import 'app_theme.dart';

/// Show the Metrics entry on the dashboard (a thesis tool; set to false to hide it).
const bool kShowMetrics = true;

/// Detector confidence used for the measurements. KEEP EQUAL to the value in protect_demo.dart (confThreshold).
const double kBenchConf = 0.15;

/// Uploaded photos are shrunk so their longest side is at most this many pixels, to match what the app itself captures
/// (the camera's "high" preset is 1280x720). Full 12 MP photos would give much slower and much larger measurements and
/// can run the phone out of memory. 0 = use the uploaded photos as they are.
const int kUploadMaxSide = 1280;

/// At most this many photos are processed from one ZIP (the rest are ignored).
const int kMaxUploadPhotos = 100;

bool _isImageName(String n) {
  final b = n.split('/').last.toLowerCase();
  if (b.startsWith('.') || n.contains('__MACOSX')) return false;
  return b.endsWith('.jpg') || b.endsWith('.jpeg') || b.endsWith('.png') || b.endsWith('.bmp');
}

String _extOf(String n) {
  final e = n.split('.').last.toLowerCase();
  return e == 'jpeg' ? 'jpg' : e;
}

/// Top level on purpose: the closure given to Isolate.run must not capture the page (State) object.
Future<({Uint8List bytes, bool resized})> _fitInIsolate(Uint8List raw) => Isolate.run(() => _fitPhoto(raw, kUploadMaxSide));

/// Runs in a background isolate: shrinks [b] if its longest side is above [maxSide] (re-encoded as JPEG, quality 95).
({Uint8List bytes, bool resized}) _fitPhoto(Uint8List b, int maxSide) {
  if (maxSide <= 0) return (bytes: b, resized: false);
  var im = img.decodeImage(b);
  if (im == null) throw const FormatException('Unsupported or corrupt image');
  im = img.bakeOrientation(im);
  final m = math.max(im.width, im.height);
  if (m <= maxSide) return (bytes: b, resized: false);
  final k = maxSide / m;
  im = img.copyResize(im,
      width: (im.width * k).round(), height: (im.height * k).round(), interpolation: img.Interpolation.linear);
  return (bytes: Uint8List.fromList(img.encodeJpg(im, quality: 95)), resized: true);
}

class _M {
  const _M(this.key, this.label, {this.note = '', this.dec = 2});
  final String key, label, note;
  final int dec;
}

const _groups = <(String, List<_M>)>[
  ('Detection and time (ms)', [
    _M('detector_load_ms', 'Model load', dec: 1),
    _M('detect_cold_ms', 'Detection, first call (incl. model load)', note: 'what the app does per photo', dec: 1),
    _M('detect_warm_ms', 'Detection, model already loaded', note: 'median of repeats', dec: 1),
    _M('enc_ms_face', 'Encrypt, largest face, 1 thread', dec: 1),
    _M('dec_ms_face', 'Decrypt, largest face, 1 thread', dec: 1),
    _M('enc_ms_frame_seq', 'Encrypt, all faces, 1 thread', dec: 1),
    _M('dec_ms_frame_seq', 'Decrypt, all faces, 1 thread', dec: 1),
    _M('enc_pipeline_ms', 'Encrypt in the app (3 isolates)', dec: 1),
    _M('dec_pipeline_ms', 'Decrypt in the app (3 isolates)', dec: 1),
    _M('decode_ms', 'Image decode', dec: 1),
    _M('png_encode_ms', 'PNG encode', dec: 1),
    _M('protect_total_ms', 'TOTAL protect', note: 'decode+detect+kdf+encrypt+PNG', dec: 1),
    _M('unprotect_total_ms', 'TOTAL restore', dec: 1),
    _M('total_ms', 'TOTAL protect + restore', dec: 1),
  ]),
  ('Throughput', [
    _M('fps_detect_warm', 'Detection FPS (model loaded)', note: 'live-preview relevant', dec: 1),
    _M('fps_protect', 'Whole protect pipeline, photos/s', dec: 2),
    _M('mpx_per_s_protect', 'Whole protect pipeline, megapixels/s', dec: 2),
    _M('enc_mbps', 'Encryption, MB/s of face pixels, 1 thread', dec: 3),
    _M('dec_mbps', 'Decryption, MB/s of face pixels, 1 thread', dec: 3),
  ]),
  ('Memory (MB)', [
    _M('rss_before_mb', 'Process memory (RSS) before', note: 'whole app, incl. Flutter engine', dec: 0),
    _M('rss_after_mb', 'RSS after the crypto step', dec: 0),
    _M('rss_peak_mb', 'RSS peak since app start', dec: 0),
    _M('est_cipher_ws_kb', 'Estimated cipher working set (KB, 1 channel)', note: 'analytic: 64 bytes x pixels', dec: 0),
  ]),
  ('Randomness and diffusion', [
    _M('npcr_pt', 'NPCR (%)', note: 'ideal 99.6094', dec: 4),
    _M('uaci_pt', 'UACI (%)', note: 'ideal 33.4635', dec: 4),
    _M('entropy_plain', 'Entropy, plain', dec: 4),
    _M('entropy_cipher', 'Entropy, cipher', note: 'compare with the reference below, not with 8', dec: 4),
    _M('entropy_ideal_ref', 'Entropy, random bytes of same size', dec: 4),
    _M('chi2_plain', 'Chi-square, plain', dec: 1),
    _M('chi2_cipher', 'Chi-square, cipher', note: 'uniform if < 293.25 (p = 0.05)', dec: 1),
    _M('chi2_cipher_p', 'Chi-square p-value, cipher', note: '> 0.05 = uniform', dec: 3),
    _M('chi2_cipher_pass', 'Fraction of channels passing', dec: 2),
    _M('corr_plain_h', 'Correlation plain, horizontal', dec: 4),
    _M('corr_plain_v', 'Correlation plain, vertical', dec: 4),
    _M('corr_plain_d', 'Correlation plain, diagonal', dec: 4),
    _M('corr_cipher_h', 'Correlation cipher, horizontal', dec: 4),
    _M('corr_cipher_v', 'Correlation cipher, vertical', dec: 4),
    _M('corr_cipher_d', 'Correlation cipher, diagonal', dec: 4),
    _M('corr_cipher_abs', 'Mean |correlation|, cipher', dec: 4),
  ]),
  ('Quality (plain vs cipher / decrypted)', [
    _M('mse_plain_cipher', 'MSE plain-cipher', dec: 1),
    _M('psnr_plain_cipher', 'PSNR plain-cipher (dB)', dec: 2),
    _M('ssim_plain_cipher', 'SSIM plain-cipher', dec: 4),
    _M('mse_plain_dec', 'MSE plain-decrypted', note: '0 = lossless', dec: 2),
    _M('psnr_plain_dec', 'PSNR plain-decrypted (dB)', note: 'infinite when lossless', dec: 2),
    _M('ssim_plain_dec', 'SSIM plain-decrypted', dec: 4),
    _M('roundtrip_ok', 'App round trip restores the exact pixels', note: '1 = yes', dec: 2),
    _M('cipher_roundtrip_ok', 'Cipher round trip exact', note: '1 = yes', dec: 2),
  ]),
  ('Keys (64x64 patch, change of 1e-10)', [
    _M('ks_npcr_mean', 'Key sensitivity NPCR (%)', note: 'ideal 99.6094', dec: 4),
    _M('ks_uaci_mean', 'Key sensitivity UACI (%)', note: 'ideal 33.4635', dec: 4),
    _M('ks_wrongkey_mse_mean', 'Wrong-key decryption MSE', dec: 1),
    _M('ks_wrongkey_psnr_mean', 'Wrong-key decryption PSNR (dB)', dec: 2),
    _M('ks_wrongkey_ssim_mean', 'Wrong-key decryption SSIM', dec: 4),
    _M('keyspace_log2_empirical', 'Key space, empirical (log2)', note: 'theoretical shown above', dec: 1),
  ]),
];

const _extraCsv = ['img_w', 'img_h', 'face_w', 'face_h', 'n_faces', 'n_faces_detected', 'input_kb', 'png_kb', 'wall_ms'];

String _fmt(double v, int dec) => v.isNaN ? '-' : (v.isInfinite ? '∞' : v.toStringAsFixed(dec));

Object? _clean(Object? v) {
  if (v is double) return v.isNaN ? null : (v.isInfinite ? 'inf' : v);
  if (v is Map) return {for (final e in v.entries) '${e.key}': _clean(e.value)};
  if (v is List) return [for (final e in v) _clean(e)];
  return v;
}

class MetricsPage extends StatefulWidget {
  const MetricsPage({super.key});
  @override
  State<MetricsPage> createState() => _MetricsPageState();
}

class _MetricsPageState extends State<MetricsPage> {
  static const _secret = 'bench-secret-not-a-real-key'; // local only; the real app derives it from the cloud key
  final _rows = <Map<String, double>>[];
  // Per trial: original photo (JPEG), full protected PNG, decrypted (restored) PNG, plaintext face crop, encrypted face crop.
  final _photos =
      <({Uint8List original, String ext, Uint8List protectedPng, Uint8List restoredPng, Uint8List? plainFace, Uint8List? cipherFace})>[];
  final _sources = <String>[]; // one per trial: 'camera' or the file name inside the uploaded ZIP
  final _skippedNames = <String>[]; // photos that were not counted, with the reason
  bool _batch = false, _stop = false;
  int _skipped = 0;
  Map<String, dynamic>? _scaling;
  bool _busy = false;
  String _status = 'Take one photo per trial, or upload a ZIP of photos. For the thesis use about 30 different photos '
      '(different pose, light, distance), like the 30 trials of the PC benchmark.';

  /// Protect + restore + measure ONE photo and store the result. Throws on an unreadable photo.
  /// Returns whether the trial was counted, and a message.
  Future<({bool counted, String message})> _runTrial(Uint8List photo, String source,
      {required String ext, required Uint8List model, required FacePrivacyService svc, String? label}) async {
    final tag = label ?? 'Trial ${_rows.length + 1}';
    final rssBefore = ProcessInfo.currentRss;
    final wall = Stopwatch()..start();
    final p = await svc.protect(photo, _secret);
    if (p.faces.isEmpty) {
      _skipped++;
      _skippedNames.add('$source: no face found');
      return (counted: false, message: 'No face found in that photo, so the trial was skipped (not counted).');
    }
    final u = await svc.unprotect(p.png, _secret);
    final wallMs = wall.elapsedMilliseconds;
    if (mounted) setState(() => _status = '$tag: measuring NPCR, entropy, key sensitivity ... (can take up to a minute)');
    final res = await runAnalysisWithImages(TrialInput(
      photo: photo,
      restoredPng: u.png,
      model: model,
      kind: kDetectorKind,
      conf: kBenchConf,
      boxes: [for (final f in p.faces) [f.x1, f.y1, f.x2, f.y2]],
      seed: 1000 + _rows.length,
    ));
    final row = res.row;
    if ((row['n_faces'] ?? 0) == 0) {
      _skipped++;
      _skippedNames.add('$source: face smaller than 32 px');
      return (counted: false, message: 'The face was smaller than 32 px, so the trial was skipped. Move closer.');
    }
    final pt = p.timingsMs, ut = u.timingsMs;
    double d(int? v) => (v ?? 0).toDouble();
    row['decode_ms'] = d(pt['decode']);
    row['detect_cold_ms'] = d(pt['detect']);
    row['enc_pipeline_ms'] = d(pt['encrypt']);
    row['png_encode_ms'] = d(pt['png_encode']);
    row['protect_total_ms'] = d(pt['total']);
    row['dec_pipeline_ms'] = d(ut['decrypt']);
    row['unprotect_total_ms'] = d(ut['total']);
    row['total_ms'] = d(pt['total']) + d(ut['total']);
    row['wall_ms'] = wallMs.toDouble();
    row['fps_detect_warm'] = 1000.0 / row['detect_warm_ms']!;
    row['fps_protect'] = 1000.0 / d(pt['total']).clamp(1, double.infinity);
    row['mpx_per_s_protect'] =
        row['img_w']! * row['img_h']! / 1e6 / (d(pt['total']).clamp(1, double.infinity) / 1000.0);
    row['rss_before_mb'] = rssBefore / 1048576.0;
    row['input_kb'] = photo.length / 1024.0;
    row['png_kb'] = p.png.length / 1024.0;
    row['n_faces_detected'] = p.faces.length.toDouble();
    _rows.add(row);
    _sources.add(source);
    _photos.add((original: photo, ext: ext, protectedPng: p.png, restoredPng: u.png, plainFace: res.plainFacePng, cipherFace: res.cipherFacePng));
    return (
      counted: true,
      message: 'Trial ${_rows.length} done (${p.faces.length} face(s), total ${row['total_ms']!.toStringAsFixed(0)} ms).'
    );
  }

  Future<FacePrivacyService> _newService(Uint8List model) async => FacePrivacyService(
      modelBytes: model, kind: kDetectorKind, pbkdf2Iterations: 1, confThreshold: kBenchConf);

  Future<void> _trial() async {
    final photo = await captureFromCamera(context,
        front: true, title: 'Trial ${_rows.length + 1}', hint: 'Change pose, light or distance for every trial.');
    if (photo == null || !mounted) return;
    setState(() {
      _busy = true;
      _status = 'Trial ${_rows.length + 1}: protect + restore ...';
    });
    try {
      final model = (await rootBundle.load(kDetectorAsset)).buffer.asUint8List();
      final r = await _runTrial(photo, 'camera', ext: 'jpg', model: model, svc: await _newService(model));
      _status = r.counted ? '${r.message} Take the next photo.' : r.message;
    } catch (e) {
      _status = 'Trial failed: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pick a ZIP of photos and run every photo through the same trial as the camera does (protect, restore, all the
  /// measurements). Results are added to the same table, so CSV / JSON / photo ZIP / scaling work as usual afterwards.
  Future<void> _uploadZip() async {
    FilePickerResult? pick;
    try {
      pick = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['zip'], withData: true);
    } catch (e) {
      setState(() => _status = 'Could not open the file picker: $e');
      return;
    }
    if (pick == null || pick.files.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _batch = true;
      _stop = false;
      _status = 'Reading the ZIP ...';
    });
    var counted = 0, skippedNow = 0;
    try {
      final f = pick.files.single;
      final zipBytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (zipBytes == null) throw 'the file could not be read';
      final all = ZipDecoder().decodeBytes(zipBytes);
      final files = [for (final e in all.files) if (e.isFile && _isImageName(e.name)) e]
        ..sort((a, b) => a.name.compareTo(b.name));
      if (files.isEmpty) {
        _status = 'No photos (.jpg, .jpeg, .png, .bmp) found in that ZIP.';
        return;
      }
      final extra = files.length > kMaxUploadPhotos ? files.length - kMaxUploadPhotos : 0;
      final todo = files.take(kMaxUploadPhotos).toList();
      final model = (await rootBundle.load(kDetectorAsset)).buffer.asUint8List();
      final svc = await _newService(model);
      for (var i = 0; i < todo.length; i++) {
        if (_stop || !mounted) break;
        final e = todo[i];
        final label = 'Photo ${i + 1}/${todo.length} (${e.name.split('/').last})';
        if (mounted) setState(() => _status = '$label: protect + restore ...');
        try {
          final dynamic c = e.content;
          final raw = c is Uint8List ? c : Uint8List.fromList((c as List).cast<int>());
          final fit = await _fitInIsolate(raw);
          final r = await _runTrial(fit.bytes, e.name,
              ext: fit.resized ? 'jpg' : _extOf(e.name), model: model, svc: svc, label: label);
          if (r.counted) {
            counted++;
          } else {
            skippedNow++;
          }
        } catch (err) {
          _skipped++;
          skippedNow++;
          _skippedNames.add('${e.name}: could not be processed ($err)');
        }
      }
      _status = 'Upload finished: $counted photo(s) counted, $skippedNow skipped'
          '${_stop ? ' (stopped early)' : ''}${extra > 0 ? ', $extra more in the ZIP were ignored (limit $kMaxUploadPhotos)' : ''}. '
          'Skipped photos are listed in the JSON under config.skipped_files.';
    } catch (e) {
      _status = 'Upload failed: $e';
    } finally {
      if (mounted) setState(() {
        _busy = false;
        _batch = false;
      });
    }
  }

  Future<void> _scale() async {
    setState(() {
      _busy = true;
      _status = 'Running the size-scaling and key-derivation benchmark ... (about a minute)';
    });
    try {
      _scaling = await runScalingBench();
      _status = 'Scaling benchmark done.';
    } catch (e) {
      _status = 'Scaling benchmark failed: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, Summary> _summaries() {
    final out = <String, Summary>{};
    for (final g in _groups) {
      for (final m in g.$2) {
        final v = [for (final r in _rows) if (r[m.key] != null) r[m.key]!];
        if (v.isNotEmpty) out[m.key] = summarize(v);
      }
    }
    return out;
  }

  Map<String, dynamic> _device() => {
        'build_mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
        'os': Platform.operatingSystemVersion,
        'cpu_cores': Platform.numberOfProcessors,
        'dart': Platform.version,
      };

  String _csv() {
    final keys = [for (final g in _groups) for (final m in g.$2) m.key, ..._extraCsv];
    final b = StringBuffer('trial,${keys.join(',')},source\n');
    for (var i = 0; i < _rows.length; i++) {
      b.write('${i + 1}');
      for (final k in keys) {
        final v = _rows[i][k];
        b.write(',${v == null || v.isNaN ? '' : (v.isInfinite ? 'inf' : v)}');
      }
      b.write(',"${(i < _sources.length ? _sources[i] : '').replaceAll('"', '""')}"\n');
    }
    return b.toString();
  }

  bool _isHist(String k) => k.startsWith('h_p') || k.startsWith('h_c');

  /// One entry per trial: {plain: [[256 R], [256 G], [256 B]], cipher: [...]}, taken out of the rows.
  List<Map<String, dynamic>> _histograms() => [
        for (final r in _rows)
          {
            for (final kind in const ['plain', 'cipher'])
              kind: [
                for (var c = 0; c < 3; c++)
                  [for (var b = 0; b < 256; b++) (r['h_${kind == 'plain' ? 'p' : 'c'}${c}_$b'] ?? 0).toInt()]
              ],
            // true gray (BT.601 luma) histograms, written by the benchmark as h_pg_* / h_cg_*
            'plain_gray': [for (var b = 0; b < 256; b++) (r['h_pg_$b'] ?? 0).toInt()],
            'cipher_gray': [for (var b = 0; b < 256; b++) (r['h_cg_$b'] ?? 0).toInt()],
          }
      ];

  String _json() => const JsonEncoder.withIndent('  ').convert(_clean({
        'device': _device(),
        'config': {
          'detector_asset': kDetectorAsset,
          'detector_kind': kDetectorKind.name,
          'detector_conf': kBenchConf,
          'n0': 1000,
          'photo_kdf_rounds': 1,
          'min_face_px': 32,
          'max_faces': 10,
          'sens_patch': 64,
          'trials': _rows.length,
          'skipped': _skipped,
          'skipped_files': _skippedNames,
          'upload_max_side': kUploadMaxSide,
        },
        'keyspace_theoretical_log2': theoreticalKeyspaceLog2(),
        'summary': {for (final e in _summaries().entries) e.key: e.value.toJson()},
        'scaling': _scaling,
        'histograms': _histograms(),
        'rows': [
          for (var i = 0; i < _rows.length; i++)
            <String, Object>{
              for (final e in _rows[i].entries) if (!_isHist(e.key)) e.key: e.value,
              'source': i < _sources.length ? _sources[i] : '',
            }
        ],
      }));

  /// Opens the system "save as" dialog so the file goes to a folder the user picks (e.g. Downloads).
  Future<void> _download(String text, String what, String ext) async {
    final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(RegExp('[:T]'), '-');
    try {
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Save $what',
        fileName: 'fdae_metrics_$stamp.$ext',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(saved == null && !Platform.isAndroid ? 'Save cancelled.' : '$what saved.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save $what: $e')));
    }
  }

  /// All trial photos in one ZIP: trial01_plain_photo.jpg, trial01_encrypted_photo.png (whole frame as the app
  /// protects it), trial01_decrypted_photo.png (the same frame after restoring it with the key), trial01_plain_face.png, trial01_encrypted_face.png (the measured face crop).
  Future<void> _downloadPhotos() async {
    final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(RegExp('[:T]'), '-');
    try {
      final zip = Archive();
      void add(String name, Uint8List? b) {
        if (b != null) zip.addFile(ArchiveFile(name, b.length, b));
      }
      for (var i = 0; i < _photos.length; i++) {
        final n = (i + 1).toString().padLeft(2, '0');
        final p = _photos[i];
        add('trial${n}_plain_photo.${p.ext}', p.original);
        add('trial${n}_encrypted_photo.png', p.protectedPng);
        add('trial${n}_decrypted_photo.png', p.restoredPng);
        add('trial${n}_plain_face.png', p.plainFace);
        add('trial${n}_encrypted_face.png', p.cipherFace);
      }
      final src = StringBuffer('trial,source\n');
      for (var i = 0; i < _sources.length; i++) {
        src.write('${i + 1},"${_sources[i].replaceAll('"', '""')}"\n');
      }
      add('trial_sources.csv', Uint8List.fromList(utf8.encode(src.toString())));
      final data = ZipEncoder().encode(zip);
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Save trial photos',
        fileName: 'fdae_trial_photos_$stamp.zip',
        bytes: Uint8List.fromList(data!),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(saved == null && !Platform.isAndroid ? 'Save cancelled.' : 'Photos saved (${_photos.length} trials).')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save photos: $e')));
    }
  }

  TableRow _row(List<String> c, {bool head = false, String? note}) => TableRow(children: [
        for (var i = 0; i < c.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
            child: i == 0 && note != null && note.isNotEmpty
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c[i], style: const TextStyle(fontSize: 12, color: kPlum)),
                    Text(note, style: const TextStyle(fontSize: 10, color: Colors.black54)),
                  ])
                : Text(c[i],
                    style: TextStyle(fontSize: 12, color: kPlum, fontWeight: head ? FontWeight.w700 : FontWeight.w400)),
          ),
      ]);

  Widget _summaryTable() {
    final s = _summaries();
    final rows = <TableRow>[_row(['Metric', 'Mean ± std', 'Min … max', '±CI95'], head: true)];
    for (final g in _groups) {
      final present = [for (final m in g.$2) if (s[m.key] != null) m];
      if (present.isEmpty) continue;
      rows.add(_row([g.$1.toUpperCase(), '', '', ''], head: true));
      for (final m in present) {
        final x = s[m.key]!;
        final inf = x.infinite > 0 ? ' (+${x.infinite}×∞)' : '';
        rows.add(_row([
          m.label,
          x.n == 0 ? '∞' : '${_fmt(x.mean, m.dec)} ± ${_fmt(x.std, m.dec)}$inf',
          x.n == 0 ? '' : '${_fmt(x.min, m.dec)} … ${_fmt(x.max, m.dec)}',
          _fmt(x.ci95, m.dec),
        ], note: m.note));
      }
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        columnWidths: const {0: FixedColumnWidth(200), 1: FixedColumnWidth(130), 2: FixedColumnWidth(150), 3: FixedColumnWidth(60)},
        border: const TableBorder(horizontalInside: BorderSide(color: Colors.black12)),
        children: rows,
      ),
    );
  }

  Widget _scalingTable() {
    final sc = _scaling!;
    final rows = <TableRow>[_row(['Size', 'Encrypt ms', 'Decrypt ms', 'µs/pixel enc'], head: true)];
    for (final r in (sc['rows'] as List).cast<Map<String, double>>()) {
      rows.add(_row([
        '${r['size']!.toInt()}×${r['size']!.toInt()}',
        _fmt(r['enc_ms']!, 1),
        _fmt(r['dec_ms']!, 1),
        _fmt(r['enc_us_per_px']!, 2),
      ]));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Table(columnWidths: const {0: FlexColumnWidth(1.2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1.2)}, children: rows),
      const SizedBox(height: 8),
      Text(
          'Empirical time exponent (log-log slope, 1.00 = linear in pixels): encrypt ${_fmt(sc['enc_exponent'] as double, 2)}, '
          'decrypt ${_fmt(sc['dec_exponent'] as double, 2)}.\n'
          'Key derivation (PBKDF2-HMAC-SHA256): 1 round ${_fmt(sc['kdf_1_round_ms'] as double, 1)} ms, '
          '${(sc['kdf_default_rounds'] as double).toInt()} rounds ${_fmt(sc['kdf_default_ms'] as double, 0)} ms.',
          style: const TextStyle(fontSize: 12, color: kPlum)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(fontSize: 12, color: kPlum);
    return Scaffold(
      appBar: AppBar(title: const Text('Metrics')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        if (kDebugMode)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            color: const Color(0xFFFFF3CD),
            child: const Text('Debug build: timings are 5-20x too slow. Run with `flutter run --release` (or --profile) for thesis numbers.',
                style: TextStyle(fontSize: 12)),
          ),
        Text(_status, style: small),
        const SizedBox(height: 4),
        Text('Trials: ${_rows.length}   Skipped: $_skipped', style: const TextStyle(color: kPlum, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(onPressed: _busy ? null : _trial, child: const Text('Take trial photo')),
          FilledButton(onPressed: _busy ? null : _uploadZip, child: const Text('Upload trial photos (ZIP)')),
          if (_batch) OutlinedButton(onPressed: _stop ? null : () => setState(() => _stop = true), child: const Text('Stop after this photo')),
          FilledButton(onPressed: _busy ? null : _scale, child: const Text('Scaling + complexity')),
          FilledButton(onPressed: _rows.isEmpty ? null : () => _download(_csv(), 'CSV', 'csv'), child: const Text('Download CSV')),
          FilledButton(onPressed: _rows.isEmpty && _scaling == null ? null : () => _download(_json(), 'JSON', 'json'), child: const Text('Download JSON')),
          FilledButton(onPressed: _photos.isEmpty ? null : _downloadPhotos, child: const Text('Download photos (ZIP)')),
          TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _rows.clear();
                        _photos.clear();
                        _sources.clear();
                        _skippedNames.clear();
                        _skipped = 0;
                        _scaling = null;
                      }),
              child: const Text('Clear')),
        ]),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
        const SizedBox(height: 12),
        Text(
            'Theoretical key space: 2^${theoreticalKeyspaceLog2().toStringAsFixed(1)} '
            '(six parameters, precision 1e-15; the burn-in length is not counted as secret).\n'
            'Complexity (analytic): cipher time and memory are Θ(N) in the N pixels of a face (bit-plane XOR, two chaotic '
            'streams of N values, 8N permutation indices); the burn-in is a constant; key derivation is Θ(rounds), once per '
            'photo. Detection is constant per frame after letterboxing (fixed model input) plus Θ(W·H) decode and resize.\n'
            'Detector model complexity (parameters, GFLOPs) comes from the training side: run YOLO(best.pt).info() in Colab.\n'
            'AP needs ground-truth boxes, so it is not measured here: use evaluation_suite.py --annotations on WIDER FACE.',
            style: small),
        if (_rows.isNotEmpty) ...[const SizedBox(height: 12), _summaryTable()],
        if (_scaling != null) ...[const SizedBox(height: 16), const Text('Scaling', style: TextStyle(color: kPlum, fontWeight: FontWeight.w700)), const SizedBox(height: 4), _scalingTable()],
        const SizedBox(height: 12),
        Text('${_device()}', style: const TextStyle(fontSize: 10, color: Colors.black54)),
      ]),
    );
  }
}