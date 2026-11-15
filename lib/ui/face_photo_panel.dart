import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'app_theme.dart';

/// One button of the two-action mode of [FacePhotoPanel].
class PanelAction {
  const PanelAction(this.label, this.onTap);
  final String label;

  /// Gets the photo currently taken (null if none). Returns an error text to show, or null on success. null = disabled.
  final Future<String?> Function(Uint8List? shot)? onTap;
}

/// The grey "Foto Wajah" box + Retake / Confirm buttons from the mockup.
/// Live preview with shutter and front/back switch inside the box. After the shutter the photo is shown;
/// Retake goes back to the preview, Confirm hands the JPEG bytes to [onConfirm].
/// [onConfirm] returns an error text to show (and stay on the same photo), or null on success; after a success the
/// panel goes back to live preview, ready for the next photo (the camera stays open: no reopen race between photos).
///
/// Two-action mode (Encrypt Photo Demo): pass [leftAction] and [rightAction] instead of [onConfirm]. The buttons then
/// run those actions (Retake is replaced by the camera icon that appears on the photo), [shownImage] replaces the photo
/// in the box (e.g. the encrypted result) and [info] is a small result text under the box.
class FacePhotoPanel extends StatefulWidget {
  const FacePhotoPanel({
    super.key,
    this.onConfirm,
    this.front = true,
    this.caption,
    this.confirmLabel = 'Confirm',
    this.leftAction,
    this.rightAction,
    this.shownImage,
    this.info,
    this.onBackToCamera,
  }) : assert(onConfirm != null || (leftAction != null && rightAction != null));
  final Future<String?> Function(Uint8List jpeg)? onConfirm;
  final bool front;
  final String? caption;
  final String confirmLabel;
  final PanelAction? leftAction, rightAction;
  final Uint8List? shownImage;
  final String? info;
  final VoidCallback? onBackToCamera;
  bool get _twoAction => leftAction != null && rightAction != null;
  @override
  State<FacePhotoPanel> createState() => _FacePhotoPanelState();
}

class _FacePhotoPanelState extends State<FacePhotoPanel> with WidgetsBindingObserver {
  CameraController? _c;
  List<CameraDescription> _cams = const [];
  late CameraLensDirection _lens;
  Uint8List? _shot;
  String? _error; // camera problem
  String? _message; // result of the last Confirm
  bool _shooting = false, _switching = false, _working = false;

  @override
  void initState() {
    super.initState();
    _lens = widget.front ? CameraLensDirection.front : CameraLensDirection.back;
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  CameraDescription? _pick(CameraLensDirection d) {
    for (final c in _cams) {
      if (c.lensDirection == d) return c;
    }
    return null;
  }

  bool get _canSwitch => _pick(CameraLensDirection.front) != null && _pick(CameraLensDirection.back) != null;

  Future<void> _init() async {
    try {
      if (_cams.isEmpty) _cams = await availableCameras();
      if (_cams.isEmpty) {
        if (mounted) setState(() => _error = 'No camera found on this device.');
        return;
      }
      await _open(_pick(_lens) ?? _cams.first);
    } on CameraException catch (e) {
      _fail(e);
    }
  }

  /// Resolutions tried in order. Some phones (typically the front camera of mid-range models) cannot run a 720p preview
  /// together with a photo capture and fail with "No supported surface combination is found"; a lower resolution works.
  static const _presets = [ResolutionPreset.high, ResolutionPreset.medium, ResolutionPreset.low];

  Future<void> _open(CameraDescription cam) async {
    CameraException? last;
    for (var i = 0; i < _presets.length; i++) {
      final c = CameraController(cam, _presets[i], enableAudio: false);
      try {
        await c.initialize();
      } on CameraException catch (e) {
        last = e;
        await c.dispose();
        if (e.code.startsWith('CameraAccess')) break; // permission problem: a lower resolution will not help
        if (!mounted) return;
        await Future<void>.delayed(const Duration(milliseconds: 400)); // let the camera release before the next try
        continue;
      }
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _lens = cam.lensDirection;
        _error = null;
        _switching = false;
      });
      return;
    }
    _fail(last!);
  }

  void _fail(CameraException e) {
    if (!mounted) return;
    setState(() {
      _switching = false;
      _error = e.code.startsWith('CameraAccess')
          ? 'Camera permission denied. Enable it for this app in the phone settings.'
          : 'Camera error: ${e.code} ${e.description ?? ''}';
    });
  }

  /// "Try again" on the error text: reopen the camera without leaving the screen.
  Future<void> _retry() async {
    setState(() {
      _error = null;
      _c = null;
    });
    await _init();
  }

  Future<void> _switch() async {
    if (_shooting || _switching || _working || !_canSwitch) return;
    final target = _pick(_lens == CameraLensDirection.front ? CameraLensDirection.back : CameraLensDirection.front);
    if (target == null) return;
    final old = _c;
    setState(() {
      _c = null;
      _switching = true;
    });
    await old?.dispose();
    await _open(target);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final c = _c;
      if (c != null) {
        setState(() => _c = null);
        c.dispose();
      }
    } else if (state == AppLifecycleState.resumed && _c == null && _error == null && !_switching) {
      _init();
    }
  }

  Future<void> _snap() async {
    final c = _c;
    if (c == null || _shooting || _switching || _working || !c.value.isInitialized) return;
    setState(() => _shooting = true);
    try {
      final f = await c.takePicture();
      final b = await f.readAsBytes();
      if (mounted) setState(() => _shot = b);
    } on CameraException catch (e) {
      _message = 'Capture failed: ${e.code}';
    }
    if (mounted) setState(() => _shooting = false);
  }

  Future<void> _confirm() async {
    final s = _shot;
    if (s == null || _working) return;
    setState(() {
      _working = true;
      _message = null;
    });
    String? err;
    try {
      err = await widget.onConfirm!(s);
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _message = err;
      if (err == null) _shot = null; // success: ready for the next photo
    });
  }

  /// Two-action mode: run one of the two buttons. The photo stays on screen afterwards.
  Future<void> _runAction(PanelAction a) async {
    final tap = a.onTap;
    if (tap == null || _working) return;
    setState(() {
      _working = true;
      _message = null;
    });
    String? err;
    try {
      err = await tap(_shot);
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _message = err;
    });
  }

  /// Two-action mode: back to the live preview for a new photo.
  void _backToCamera() {
    if (_working) return;
    setState(() {
      _shot = null;
      _message = null;
    });
    widget.onBackToCamera?.call();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c?.dispose();
    super.dispose();
  }

  Widget _preview() {
    final c = _c;
    if (_error != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!, textAlign: TextAlign.center, maxLines: 6, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _retry, child: const Text('Try again')),
              ])));
    }
    if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator());
    final ps = c.value.previewSize!; // landscape size; the portrait preview swaps the sides
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(width: ps.height, height: ps.width, child: CameraPreview(c)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shot = _shot;
    final shown = widget.shownImage ?? shot; // two-action mode can replace the photo (e.g. with the encrypted result)
    return Column(children: [
      if (widget.caption != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(widget.caption!, style: const TextStyle(color: kPlum, fontSize: 16, fontWeight: FontWeight.w600))),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            color: kPanel,
            width: double.infinity,
            child: Stack(fit: StackFit.expand, children: [
              if (shown != null) Image.memory(shown, fit: BoxFit.cover, gaplessPlayback: true) else _preview(),
              if (shown != null && widget._twoAction)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: InkResponse(onTap: _working ? null : _backToCamera, child: const SvgIcon('camera', size: 60)),
                ),
              if (shown == null && _error == null)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Row(children: [
                    InkResponse(
                      onTap: _shooting ? null : _snap,
                      child: _shooting
                          ? const SizedBox(width: 60, height: 60, child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 3)))
                          : const SvgIcon('camera', size: 60),
                    ),
                    if (_canSwitch)
                      IconButton(tooltip: 'Switch camera', onPressed: _switch, icon: const SvgIcon('flip', size: 30)),
                  ]),
                ),
              if (_working) Container(color: Colors.black26, child: const Center(child: CircularProgressIndicator())),
            ]),
          ),
        ),
      ),
      if (widget.info != null)
        Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(widget.info!, textAlign: TextAlign.center, style: const TextStyle(color: kPlum, fontSize: 15, height: 1.4))),
      if (_message != null)
        Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_message!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFB00020)))),
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: widget._twoAction
            ? Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                // Encrypt needs a photo; Decrypt needs something encrypted (the page decides via onTap == null)
                FilledButton(
                    onPressed: (shot == null || _working || widget.leftAction!.onTap == null) ? null : () => _runAction(widget.leftAction!),
                    child: Text(widget.leftAction!.label)),
                FilledButton(
                    onPressed: (_working || widget.rightAction!.onTap == null) ? null : () => _runAction(widget.rightAction!),
                    child: Text(widget.rightAction!.label)),
              ])
            : Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                FilledButton(
                    onPressed: (shot == null || _working) ? null : () => setState(() {
                          _shot = null;
                          _message = null;
                        }),
                    child: const Text('Retake')),
                FilledButton(onPressed: (shot == null || _working) ? null : _confirm, child: Text(widget.confirmLabel)),
              ]),
      ),
    ]);
  }
}