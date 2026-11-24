import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
                'Watch the camera live from this phone, on the same WiFi.',
                () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ViewerScreen())),
              ),
              const Spacer(),
              const Text('Both phones must be on the same WiFi.',
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
  Uint8List? _latestJpeg;
  bool _processing = false;
  int _lastMs = 0;
  String _status = 'Starting camera...';
  String _url = '';
  int _viewers = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _status = 'No camera found on this phone.');
        return;
      }
      final back = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.low,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      await c.startImageStream(_onFrame);
      _controller = c;
      await WakelockPlus.enable();
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

  void _onFrame(CameraImage image) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_processing || now - _lastMs < 120) return;
    _processing = true;
    _lastMs = now;
    try {
      _latestJpeg = _yuvToJpeg(image);
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
        res.headers.contentType = null;
        res.headers.set('Content-Type',
            'multipart/x-mixed-replace; boundary=frame');
        res.headers.set('Cache-Control', 'no-cache');
        res.headers.set('Connection', 'close');
        if (mounted) setState(() => _viewers++);
        try {
          while (true) {
            final jpg = _latestJpeg;
            if (jpg != null) {
              res.add(ascii.encode(
                  '--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpg.length}\r\n\r\n'));
              res.add(jpg);
              res.add(const [13, 10]);
              await res.flush();
            }
            await Future.delayed(const Duration(milliseconds: 120));
          }
        } catch (_) {
          // client disconnected
        } finally {
          if (mounted) setState(() => _viewers = (_viewers - 1).clamp(0, 999));
        }
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
            '<body><img src="/video"></body></html>');
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
    _controller?.stopImageStream().catchError((_) {});
    _controller?.dispose();
    _server?.close(force: true);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Camera'),
        backgroundColor: teal,
        foregroundColor: Colors.white,
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
                  const SizedBox(height: 8),
                  const Text(
                      'Keep this phone on this screen and plugged in. Any browser on the same WiFi can open that address too.',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
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

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final last = p.getString('lastUrl');
      if (last != null && mounted) setState(() => _ctrl.text = last);
    });
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
    setState(() {
      _web = web;
      _watching = true;
    });
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
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
                    label: const Text('Watch live'),
                  ),
                ],
              ),
            ),
    );
  }
}

// ------------------------------------------------------------- helpers

Future<String> _lanIp() async {
  try {
    final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    // Prefer a private 192.168.x / 10.x / 172.x address (the WiFi LAN).
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
Uint8List? _yuvToJpeg(CameraImage image) {
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
  // Camera frames are landscape; rotate so the view is upright.
  final rotated = img.copyRotate(out, angle: 90);
  return Uint8List.fromList(img.encodeJpg(rotated, quality: 70));
}

const ascii = _Ascii();

class _Ascii {
  const _Ascii();
  List<int> encode(String s) => s.codeUnits;
}
