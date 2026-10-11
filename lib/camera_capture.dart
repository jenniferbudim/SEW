import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'ui/app_theme.dart' show SvgIcon;

/// Opens a LIVE camera preview and returns the JPEG bytes of the photo taken
/// when the user presses the shutter, or null if they back out.
/// [front] only chooses which camera opens FIRST; the user can flip between
/// front and back with the switch button (shown when the device has both).
/// [title]/[hint] let a multi-photo flow say which photo this is ("Photo 2 of 3").
Future<Uint8List?> captureFromCamera(BuildContext context,
        {bool front = false, String? title, String? hint}) =>
    Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(builder: (_) => CameraCaptureScreen(front: front, title: title, hint: hint)));

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key, this.front = false, this.title, this.hint});
  final bool front;
  final String? title, hint;
  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> with WidgetsBindingObserver {
  CameraController? _c;
  List<CameraDescription> _cams = const [];
  late CameraLensDirection _lens; // camera currently open (or wanted)
  String? _error;
  bool _busy = false; // taking a picture
  bool _switching = false; // changing camera

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

  bool get _canSwitch =>
      _pick(CameraLensDirection.front) != null && _pick(CameraLensDirection.back) != null;

  Future<void> _init() async {
    try {
      if (_cams.isEmpty) _cams = await availableCameras();
      if (_cams.isEmpty) {
        if (mounted) setState(() => _error = 'No camera found on this device.');
        return;
      }
      await _open(_pick(_lens) ?? _cams.first);
    } on CameraException catch (e) {
      _showError(e);
    }
  }

  Future<void> _open(CameraDescription cam) async {
    // "high" (~720p) on purpose: far faster to decode/encrypt than the max resolution
    final c = CameraController(cam, ResolutionPreset.high, enableAudio: false);
    try {
      await c.initialize();
    } on CameraException catch (e) {
      await c.dispose();
      _showError(e);
      return;
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
  }

  void _showError(CameraException e) {
    if (!mounted) return;
    setState(() {
      _switching = false;
      _error = e.code.startsWith('CameraAccess')
          ? 'Camera permission denied. Enable it for this app in the phone settings.'
          : 'Camera error: ${e.code} ${e.description ?? ''}';
    });
  }

  /// Release the current camera FIRST, then open the other one.
  Future<void> _switchCamera() async {
    if (_busy || _switching || !_canSwitch) return;
    final target = _pick(
        _lens == CameraLensDirection.front ? CameraLensDirection.back : CameraLensDirection.front);
    if (target == null) return;
    final old = _c;
    setState(() {
      _c = null; // stop showing the old preview before it is disposed
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
      _init(); // reopens the lens that was active
    }
  }

  Future<void> _capture() async {
    final c = _c;
    if (c == null || _busy || _switching || !c.value.isInitialized) return;
    setState(() => _busy = true);
    try {
      final shot = await c.takePicture();
      final bytes = await shot.readAsBytes();
      // Release the camera completely BEFORE leaving. If the next screen (register photo 2, 3) opens while this
      // controller is still being disposed in the background, the new preview comes up blank.
      if (mounted) setState(() => _c = null);
      await c.dispose();
      if (mounted) Navigator.of(context).pop(bytes);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Capture failed: ${e.code}')));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && _error == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? (_lens == CameraLensDirection.front ? 'Front camera' : 'Back camera')),
        actions: [
          if (_canSwitch)
            IconButton(
              tooltip: 'Switch camera',
              icon: const SvgIcon('flip', size: 28, fallback: Icons.cameraswitch),
              onPressed: (_busy || _switching) ? null : _switchCamera,
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : c == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(alignment: Alignment.topCenter, children: [
                  Center(child: CameraPreview(c)),
                  if (widget.hint != null)
                    Container(
                        width: double.infinity,
                        color: Colors.black54,
                        padding: const EdgeInsets.all(8),
                        child: Text(widget.hint!,
                            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white))),
                ]),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: !ready
          ? null
          : FloatingActionButton.large(
              onPressed: _busy ? null : _capture,
              child: _busy ? const CircularProgressIndicator() : const Icon(Icons.camera_alt)),
    );
  }
}