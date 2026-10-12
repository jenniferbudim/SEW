import 'dart:convert';
import 'dart:io' show Platform, ProcessInfo;
import 'package:flutter/foundation.dart' hide Summary;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  int _skipped = 0;
  Map<String, dynamic>? _scaling;
  bool _busy = false;
  String _status = 'Take one photo per trial. For the thesis use about 30 different photos '
      '(different pose, light, distance), like the 30 trials of the PC benchmark.';

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
      final svc = FacePrivacyService(
          modelBytes: model, kind: kDetectorKind, pbkdf2Iterations: 1, confThreshold: kBenchConf);
      final rssBefore = ProcessInfo.currentRss;
      final wall = Stopwatch()..start();
      final p = await svc.protect(photo, _secret);
      if (p.faces.isEmpty) {
        _skipped++;
        _status = 'No face found in that photo, so the trial was skipped (not counted).';
        return;
      }
      final u = await svc.unprotect(p.png, _secret);
      final wallMs = wall.elapsedMilliseconds;
      if (mounted) setState(() => _status = 'Trial ${_rows.length + 1}: measuring NPCR, entropy, key sensitivity ... (can take up to a minute)');
      final row = await runAnalysis(TrialInput(
        photo: photo,
        restoredPng: u.png,
        model: model,
        kind: kDetectorKind,
        conf: kBenchConf,
        boxes: [for (final f in p.faces) [f.x1, f.y1, f.x2, f.y2]],
        seed: 1000 + _rows.length,
      ));
      if ((row['n_faces'] ?? 0) == 0) {
        _skipped++;
        _status = 'The face was smaller than 32 px, so the trial was skipped. Move closer.';
        return;
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
      _status = 'Trial ${_rows.length} done (${p.faces.length} face(s), '
          'total ${row['total_ms']!.toStringAsFixed(0)} ms). Take the next photo.';
    } catch (e) {
      _status = 'Trial failed: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final b = StringBuffer('trial,${keys.join(',')}\n');
    for (var i = 0; i < _rows.length; i++) {
      b.write('${i + 1}');
      for (final k in keys) {
        final v = _rows[i][k];
        b.write(',${v == null || v.isNaN ? '' : (v.isInfinite ? 'inf' : v)}');
      }
      b.write('\n');
    }
    return b.toString();
  }

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
        },
        'keyspace_theoretical_log2': theoreticalKeyspaceLog2(),
        'summary': {for (final e in _summaries().entries) e.key: e.value.toJson()},
        'scaling': _scaling,
        'rows': _rows,
      }));

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied to the clipboard.')));
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
          FilledButton(onPressed: _busy ? null : _scale, child: const Text('Scaling + complexity')),
          FilledButton(onPressed: _rows.isEmpty ? null : () => _copy(_csv(), 'CSV'), child: const Text('Copy CSV')),
          FilledButton(onPressed: _rows.isEmpty && _scaling == null ? null : () => _copy(_json(), 'JSON'), child: const Text('Copy JSON')),
          TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _rows.clear();
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