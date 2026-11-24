import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const int kPort = 8080;
const teal = Color(0xFF00897B);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HomeCamApp());
}

class HomeCamApp extends StatelessWidget {
  const HomeCamApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Home Cam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: teal, primary: teal),
        scaffoldBackgroundColor: const Color(0xFF263238),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ------------------------------------------------------------- home / mode

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 30),
              const Icon(Icons.videocam, size: 72, color: Color(0xFF4FC3F7)),
              const SizedBox(height: 12),
              const Text('Home Cam',
                  style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 8),
              const Text('Use a spare phone as a home camera on your WiFi',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Colors.white60)),
              const SizedBox(height: 40),
              _card(
                context,
                Icons.photo_camera,
                const Color(0xFF00897B),
                'Use as camera',
                'Set up this (spare) phone as the camera. Place it where you want to watch and keep it on power.',
                () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const CameraScreen())),
              ),
              const SizedBox(height: 18),
              _card(
                context,
                Icons.smartphone,
                const Color(0xFF1565C0),
                'Use as viewer',
                'Watch and listen to the camera live from this phone.',
                () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ViewerScreen())),
              ),
              const Spacer(),
              const Text('Same WiFi, or link both phones with Tailscale.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 13)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, IconData icon, Color color, String title,
      String body, VoidCallback onTap) {
    return Card(
      color: const Color(0xFF37474F),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              CircleAvatar(
                  radius: 28,
                  backgroundColor: color,
                  child: Icon(icon, color: Colors.white, size: 30)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    const SizedBox(height: 4),
                    Text(body,
                        style: const TextStyle(
                            fontSize: 13, color: Colors.white54, height: 1.3)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- camera

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  HttpServer? _server;
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription? _micSub;
  StreamController<Uint8List>? _audioHub;
  final int _audioRate = 16000;
  Uint8List? _latestJpeg;
  bool _processing = false;
  int _lastMs = 0;
  String _status = 'Starting camera...';
  String _url = '';
  int _viewers = 0;
  bool _ready = false;
  bool _audioOn = false;
  bool _screenOff = false;
  List<CameraDescription> _cameras = [];
  CameraLensDirection _lens = CameraLensDirection.back;
  ResolutionPreset _preset = ResolutionPreset.low;
  bool _reinitializing = false;

  bool get _hasFront =>
      _cameras.any((c) => c.lensDirection == CameraLensDirection.front);

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _status = 'No camera found on this phone.');
        return;
      }
      await _initController();
      await WakelockPlus.enable();
      await _startAudio();
      await _startServer();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = 'Live';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Camera error: $e');
    }
  }

  Future<void> _initController() async {
    final cam = _cameras.firstWhere((c) => c.lensDirection == _lens,
        orElse: () => _cameras.first);
    final c = CameraController(cam, _preset,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
    await c.initialize();
    await c.startImageStream(_onFrame);
    _controller = c;
  }

  Future<void> _reinit() async {
    if (_reinitializing) return;
    _reinitializing = true;
    setState(() => _ready = false);
    try {
      await _controller?.stopImageStream();
    } catch (_) {}
    await _controller?.dispose();
    _controller = null;
    try {
      await _initController();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _status = 'Camera error: $e');
    }
    _reinitializing = false;
  }

  void _switchLens() {
    if (!_hasFront) return;
    _lens = _lens == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    _reinit();
  }

  void _setPreset(ResolutionPreset p) {
    if (p == _preset || _reinitializing) return;
    _preset = p;
    _reinit();
  }

  PopupMenuItem<ResolutionPreset> _qualityItem(
      ResolutionPreset p, String label) {
    return PopupMenuItem(
      value: p,
      child: Row(
        children: [
          Icon(p == _preset ? Icons.check : Icons.circle_outlined,
              size: 18, color: p == _preset ? teal : Colors.black26),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  Future<void> _startAudio() async {
    try {
      if (!await _rec.hasPermission()) return;
      final stream = await _rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _audioRate,
        numChannels: 1,
      ));
      final hub = StreamController<Uint8List>.broadcast();
      _micSub = stream.listen((d) => hub.add(Uint8List.fromList(d)),
          onError: (_) {});
      _audioHub = hub;
      _audioOn = true;
    } catch (_) {
      _audioOn = false;
    }
  }

  void _onFrame(CameraImage image) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_processing || now - _lastMs < 120) return;
    _processing = true;
    _lastMs = now;
    try {
      _latestJpeg =
          _yuvToJpeg(image, _lens == CameraLensDirection.front);
    } catch (_) {
    } finally {
      _processing = false;
    }
  }

  Future<void> _startServer() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, kPort);
    final ip = await _lanIp();
    _url = 'http://$ip:$kPort';
    _server!.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    try {
      if (path == '/video') {
        res.headers.set('Content-Type',
            'multipart/x-mixed-replace; boundary=frame');
        res.headers.set('Cache-Control', 'no-cache');
        res.headers.set('Connection', 'close');
        if (mounted) setState(() => _viewers++);
        try {
          while (true) {
            final jpg = _latestJpeg;
            if (jpg != null) {
              res.add(_ascii(
                  '--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpg.length}\r\n\r\n'));
              res.add(jpg);
              res.add(const [13, 10]);
              await res.flush();
            }
            await Future.delayed(const Duration(milliseconds: 120));
          }
        } catch (_) {
        } finally {
          if (mounted) setState(() => _viewers = (_viewers - 1).clamp(0, 999));
        }
      } else if (path == '/audio') {
        res.headers.set('Content-Type', 'audio/wav');
        res.headers.set('Cache-Control', 'no-cache');
        res.headers.set('Connection', 'close');
        res.add(_wavHeader(_audioRate, 1, 16));
        await res.flush();
        final hub = _audioHub;
        if (hub == null) {
          await res.close();
          return;
        }
        try {
          await for (final chunk in hub.stream) {
            res.add(chunk);
            await res.flush();
          }
        } catch (_) {}
      } else if (path == '/photo') {
        final jpg = _latestJpeg;
        if (jpg == null) {
          res.statusCode = 503;
        } else {
          res.headers.set('Content-Type', 'image/jpeg');
          res.add(jpg);
        }
        await res.close();
      } else {
        res.headers.set('Content-Type', 'text/html');
        res.write(
            '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>Home Cam</title><style>html,body{margin:0;background:#000;height:100%}'
            'img{width:100%;height:auto;display:block}</style></head>'
            '<body><img src="/video">'
            '<audio id="a" src="/audio" autoplay playsinline></audio>'
            '</body></html>');
        await res.close();
      }
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _controller?.stopImageStream().catchError((_) {});
    _controller?.dispose();
    _micSub?.cancel();
    _rec.stop().catchError((_) => null);
    _audioHub?.close();
    _server?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_screenOff) {
      return GestureDetector(
        onTap: () => setState(() => _screenOff = false),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.nightlight_round,
                    color: Colors.white.withOpacity(0.08), size: 40),
                const SizedBox(height: 14),
                Text('Streaming — screen off',
                    style: TextStyle(color: Colors.white.withOpacity(0.12))),
                const SizedBox(height: 4),
                Text('Tap to wake',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.10), fontSize: 12)),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Camera'),
        backgroundColor: teal,
        foregroundColor: Colors.white,
        actions: [
          if (_hasFront)
            IconButton(
              tooltip: 'Switch camera',
              icon: const Icon(Icons.cameraswitch),
              onPressed: _ready ? _switchLens : null,
            ),
          PopupMenuButton<ResolutionPreset>(
            tooltip: 'Video quality',
            icon: const Icon(Icons.high_quality),
            onSelected: _setPreset,
            itemBuilder: (_) => [
              _qualityItem(ResolutionPreset.low, 'Low (smoothest)'),
              _qualityItem(ResolutionPreset.medium, 'Medium'),
              _qualityItem(ResolutionPreset.high, 'High (slower)'),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              width: double.infinity,
              child: _ready && _controller != null
                  ? CameraPreview(_controller!)
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(color: Colors.white),
                          const SizedBox(height: 16),
                          Text(_status,
                              style: const TextStyle(color: Colors.white70)),
                        ],
                      ),
                    ),
            ),
          ),
          Container(
            width: double.infinity,
            color: const Color(0xFF263238),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _ready
                              ? const Color(0xFF66BB6A)
                              : Colors.orange),
                    ),
                    const SizedBox(width: 8),
                    Text(_ready ? 'LIVE' : _status,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1)),
                    const SizedBox(width: 10),
                    Icon(_audioOn ? Icons.mic : Icons.mic_off,
                        size: 16,
                        color: _audioOn ? const Color(0xFF66BB6A) : Colors.orange),
                    const Spacer(),
                    if (_ready)
                      Text('$_viewers watching',
                          style: const TextStyle(color: Colors.white54)),
                  ],
                ),
                if (_ready) ...[
                  const SizedBox(height: 16),
                  const Text('On your other phone, open the viewer and enter:',
                      style: TextStyle(color: Colors.white60, fontSize: 13)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(_url,
                              style: const TextStyle(
                                  color: Color(0xFF4FC3F7),
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy,
                              color: Colors.white54, size: 20),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _url));
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Address copied')));
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF455A64)),
                      onPressed: () => setState(() => _screenOff = true),
                      icon: const Icon(Icons.dark_mode),
                      label: const Text('Screen off (keep streaming)'),
                    ),
                  ),
                  if (!_audioOn)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text(
                          'Microphone is off — allow the mic permission to send sound.',
                          style: TextStyle(color: Colors.orange, fontSize: 12)),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- viewer

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});
  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _ctrl = TextEditingController();
  WebViewController? _web;
  bool _watching = false;
  bool _muted = false;
  List<Map<String, String>> _saved = [];

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final last = p.getString('lastUrl');
      final raw = p.getString('cameras');
      if (!mounted) return;
      setState(() {
        if (last != null) _ctrl.text = last;
        if (raw != null) {
          _saved = (json.decode(raw) as List)
              .map((e) => Map<String, String>.from(e as Map))
              .toList();
        }
      });
    });
  }

  Future<void> _persistSaved() async {
    final p = await SharedPreferences.getInstance();
    p.setString('cameras', json.encode(_saved));
  }

  void _saveCurrent() {
    final addr = _ctrl.text.trim();
    if (addr.isEmpty) return;
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Save this camera'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Name', hintText: 'e.g. Living room'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                final name =
                    nameCtrl.text.trim().isEmpty ? addr : nameCtrl.text.trim();
                setState(() {
                  _saved.removeWhere((c) => c['addr'] == addr);
                  _saved.add({'name': name, 'addr': addr});
                });
                _persistSaved();
                Navigator.pop(context);
              },
              child: const Text('Save')),
        ],
      ),
    );
  }

  void _deleteSaved(int i) {
    setState(() => _saved.removeAt(i));
    _persistSaved();
  }

  String _normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    if (uri != null && !uri.hasPort) {
      s = 'http://${uri.host}:$kPort';
    }
    return s;
  }

  Future<void> _connect() async {
    final url = _normalize(_ctrl.text);
    if (url.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    p.setString('lastUrl', _ctrl.text.trim());
    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..loadRequest(Uri.parse(url));
    // Allow the audio to start without a manual tap.
    if (web.platform is AndroidWebViewController) {
      (web.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
    setState(() {
      _web = web;
      _watching = true;
      _muted = false;
    });
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _web?.runJavaScript(
        "document.querySelectorAll('audio').forEach(function(a){a.muted=$_muted;});");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_watching ? 'Live view' : 'Viewer'),
        backgroundColor: teal,
        foregroundColor: Colors.white,
        actions: [
          if (_watching)
            IconButton(
              tooltip: _muted ? 'Listen' : 'Mute',
              icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
              onPressed: _toggleMute,
            ),
          if (_watching)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _web?.reload(),
            ),
          if (_watching)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _watching = false;
                _web = null;
              }),
            ),
        ],
      ),
      body: _watching && _web != null
          ? WebViewWidget(controller: _web!)
          : Padding(
              padding: const EdgeInsets.all(24),
              child: ListView(
                children: [
                  const SizedBox(height: 24),
                  const Icon(Icons.cast_connected,
                      size: 64, color: Color(0xFF4FC3F7)),
                  const SizedBox(height: 20),
                  const Text('Enter the camera address',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text(
                      'It shows on the camera phone, like  192.168.1.5:8080',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _ctrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '192.168.1.5:8080',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: const Color(0xFF37474F),
                      prefixIcon:
                          const Icon(Icons.link, color: Colors.white54),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Watch & listen'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _saveCurrent,
                    icon: const Icon(Icons.bookmark_add_outlined,
                        color: Colors.white70),
                    label: const Text('Save this address',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  if (_saved.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Saved cameras',
                          style: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(height: 6),
                    ..._saved.asMap().entries.map((e) => Card(
                          color: const Color(0xFF37474F),
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const Icon(Icons.videocam,
                                color: Color(0xFF4FC3F7)),
                            title: Text(e.value['name'] ?? '',
                                style: const TextStyle(color: Colors.white)),
                            subtitle: Text(e.value['addr'] ?? '',
                                style: const TextStyle(color: Colors.white54)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.white38),
                              onPressed: () => _deleteSaved(e.key),
                            ),
                            onTap: () {
                              _ctrl.text = e.value['addr'] ?? '';
                              _connect();
                            },
                          ),
                        )),
                  ],
                  const SizedBox(height: 14),
                  const Text('Tap the speaker icon up top to mute the sound.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
    );
  }
}

// ------------------------------------------------------------- helpers

List<int> _ascii(String s) => s.codeUnits;

Uint8List _wavHeader(int sampleRate, int channels, int bits) {
  final byteRate = sampleRate * channels * bits ~/ 8;
  final blockAlign = channels * bits ~/ 8;
  final b = BytesBuilder();
  void u32(int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  b.add(_ascii('RIFF'));
  u32(0xFFFFFFFF);
  b.add(_ascii('WAVE'));
  b.add(_ascii('fmt '));
  u32(16);
  u16(1); // PCM
  u16(channels);
  u32(sampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bits);
  b.add(_ascii('data'));
  u32(0xFFFFFFFF);
  return b.toBytes();
}

Future<String> _lanIp() async {
  try {
    final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    for (final i in interfaces) {
      for (final a in i.addresses) {
        final ip = a.address;
        if (ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            ip.startsWith('172.')) {
          return ip;
        }
      }
    }
    for (final i in interfaces) {
      for (final a in i.addresses) {
        if (!a.isLoopback) return a.address;
      }
    }
  } catch (_) {}
  return '0.0.0.0';
}

/// Convert a YUV420 camera frame to JPEG bytes.
Uint8List? _yuvToJpeg(CameraImage image, bool front) {
  final width = image.width;
  final height = image.height;
  if (image.planes.length < 3) return null;
  final out = img.Image(width: width, height: height);
  final yP = image.planes[0];
  final uP = image.planes[1];
  final vP = image.planes[2];
  final yRow = yP.bytesPerRow;
  final uvRow = uP.bytesPerRow;
  final uvPix = uP.bytesPerPixel ?? 1;
  final yB = yP.bytes;
  final uB = uP.bytes;
  final vB = vP.bytes;
  for (int y = 0; y < height; y++) {
    final yr = y * yRow;
    final uvr = (y >> 1) * uvRow;
    for (int x = 0; x < width; x++) {
      final yi = yr + x;
      final uvi = uvr + (x >> 1) * uvPix;
      if (yi >= yB.length || uvi >= uB.length || uvi >= vB.length) continue;
      final yv = yB[yi];
      final uv = uB[uvi] - 128;
      final vv = vB[uvi] - 128;
      int r = (yv + 1.402 * vv).round();
      int g = (yv - 0.344136 * uv - 0.714136 * vv).round();
      int b = (yv + 1.772 * uv).round();
      out.setPixelRgb(x, y, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
    }
  }
  var rotated = img.copyRotate(out, angle: 90);
  // Front cameras deliver a mirrored image; flip it so it reads normally.
  if (front) rotated = img.flipHorizontal(rotated);
  return Uint8List.fromList(img.encodeJpg(rotated, quality: 70));
}
