import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const RoadRushApp());
}

class RoadRushApp extends StatelessWidget {
  const RoadRushApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Road Rush',
      debugShowCheckedModeBanner: false,
      home: GamePage(),
    );
  }
}

enum Phase { ready, playing, over }

class Car {
  Car(this.lane, this.y, this.color);
  final int lane;
  double y;
  final Color color;
}

class Coin {
  Coin(this.lane, this.y);
  final int lane;
  double y;
  bool taken = false;
}

const trafficColors = [
  Color(0xFF1E88E5),
  Color(0xFF8E24AA),
  Color(0xFFFDD835),
  Color(0xFF00ACC1),
  Color(0xFFFB8C00),
  Color(0xFFECEFF1),
  Color(0xFF43A047),
];

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final Random _rng = Random();
  Size size = Size.zero;

  Phase phase = Phase.ready;
  int lane = 1;
  double playerX = -1;
  double tilt = 0;
  double t = 0;
  double scroll = 0;
  double runTime = 0;
  double dist = 0;
  double spawnTimer = 0;
  double coinTimer = 0;
  double deadTimer = 0;
  double flash = 0;
  double crashX = 0;
  double crashY = 0;
  int coins = 0;
  int best = 0;
  bool newBest = false;
  final List<Car> cars = [];
  final List<Coin> coinList = [];
  final List<int> lastLanes = [];

  double get w => size.width;
  double get h => size.height;
  double get roadL => w * 0.12;
  double get roadR => w * 0.88;
  double get laneW => (roadR - roadL) / 3;
  double laneX(int i) => roadL + laneW * (i + 0.5);
  double get carW => laneW * 0.56;
  double get carH => carW * 1.85;
  double get playerY => h * 0.8;
  double get speed =>
      phase == Phase.playing ? h * (0.62 + min(runTime, 70) * 0.011) : h * 0.35;
  int get score => (dist / h * 10).floor() + coins * 25;
  int get kmh => (speed / h * 160).round();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => best = p.getInt('best') ?? 0);
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    double dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt > 1 / 30) dt = 1 / 30;
    if (size == Size.zero) return;
    setState(() => _update(dt));
  }

  void _update(double dt) {
    t += dt;
    if (flash > 0) flash = max(0, flash - dt * 3);
    if (playerX < 0) playerX = laneX(lane);

    if (phase == Phase.over) {
      deadTimer += dt;
      return;
    }

    final sp = speed;
    scroll += sp * dt;

    // Smooth steering toward the chosen lane, with a little body tilt.
    final dx = laneX(lane) - playerX;
    playerX += dx * min(1.0, dt * 14);
    tilt = (dx / laneW).clamp(-1.0, 1.0).toDouble() * 0.25;

    if (phase == Phase.ready) return;

    runTime += dt;
    dist += sp * dt;

    for (final c in cars) {
      c.y += sp * 0.55 * dt; // traffic is slower than you, so you overtake it
    }
    cars.removeWhere((c) => c.y > h + carH);
    for (final c in coinList) {
      c.y += sp * dt;
    }
    coinList.removeWhere((c) => c.taken || c.y > h + carW);

    spawnTimer -= dt;
    if (spawnTimer <= 0) {
      _spawnCar();
      spawnTimer = max(0.42, 1.05 - runTime * 0.009);
    }
    coinTimer -= dt;
    if (coinTimer <= 0) {
      _spawnCoin();
      coinTimer = 1.4 + _rng.nextDouble() * 1.2;
    }

    final me = Rect.fromCenter(
        center: Offset(playerX, playerY), width: carW * 0.85, height: carH * 0.88);
    for (final c in cars) {
      final r = Rect.fromCenter(
          center: Offset(laneX(c.lane), c.y), width: carW * 0.85, height: carH * 0.88);
      if (me.overlaps(r)) {
        _crash();
        return;
      }
    }
    for (final c in coinList) {
      final d = (Offset(laneX(c.lane), c.y) - Offset(playerX, playerY)).distance;
      if (!c.taken && d < carW * 0.8) {
        c.taken = true;
        coins++;
        HapticFeedback.selectionClick();
      }
    }
  }

  void _spawnCar() {
    int l = _rng.nextInt(3);
    // Never let three cars in a row block all three lanes.
    if (lastLanes.length >= 2 && lastLanes[0] != lastLanes[1]) {
      l = lastLanes[_rng.nextInt(2)];
    }
    cars.add(Car(l, -carH, trafficColors[_rng.nextInt(trafficColors.length)]));
    lastLanes.add(l);
    if (lastLanes.length > 2) lastLanes.removeAt(0);
  }

  void _spawnCoin() {
    final free = [0, 1, 2]
        .where((l) => !cars.any((c) => c.lane == l && c.y < carH * 2))
        .toList();
    if (free.isEmpty) return;
    coinList.add(Coin(free[_rng.nextInt(free.length)], -carW));
  }

  void _crash() {
    phase = Phase.over;
    deadTimer = 0;
    flash = 1;
    crashX = playerX;
    crashY = playerY - carH * 0.4;
    HapticFeedback.heavyImpact();
    newBest = score > best;
    if (newBest) {
      best = score;
      SharedPreferences.getInstance().then((p) => p.setInt('best', best));
    }
  }

  void _resetRun() {
    cars.clear();
    coinList.clear();
    lastLanes.clear();
    runTime = 0;
    dist = 0;
    coins = 0;
    spawnTimer = 0.8;
    coinTimer = 1.5;
  }

  void _tap(double x) {
    if (phase == Phase.ready) {
      _resetRun();
      phase = Phase.playing;
    } else if (phase == Phase.playing) {
      if (x < w / 2) {
        lane = max(0, lane - 1);
      } else {
        lane = min(2, lane + 1);
      }
    } else if (deadTimer > 0.8) {
      _resetRun();
      phase = Phase.ready;
      lane = 1;
      playerX = laneX(1);
      newBest = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          size = constraints.biggest;
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _tap(e.localPosition.dx),
            child: CustomPaint(size: size, painter: GamePainter(this)),
          );
        },
      ),
    );
  }
}

class GamePainter extends CustomPainter {
  GamePainter(this.g);
  final _GamePageState g;

  @override
  void paint(Canvas canvas, Size size) {
    final w = g.w, h = g.h;
    if (w == 0) return;

    // Grass with moving stripes
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF66BB6A));
    final band = h * 0.1;
    final grass2 = Paint()..color = const Color(0xFF5CAD60);
    for (double y = -band * 2 + g.scroll % (band * 2); y < h; y += band * 2) {
      canvas.drawRect(Rect.fromLTWH(0, y, w, band), grass2);
    }

    // Trees along the roadside
    for (int i = 0; i < 6; i++) {
      final y = (i * h * 0.22 + g.scroll) % (h * 1.32) - h * 0.16;
      final x = i.isEven ? w * 0.055 : w - w * 0.055;
      canvas.drawCircle(Offset(x + 3, y + 4), w * 0.05, Paint()..color = Colors.black26);
      canvas.drawCircle(Offset(x, y), w * 0.05, Paint()..color = const Color(0xFF2E7D32));
      canvas.drawCircle(Offset(x - w * 0.012, y - w * 0.012), w * 0.03,
          Paint()..color = const Color(0xFF43A047));
    }

    // Road
    canvas.drawRect(Rect.fromLTRB(g.roadL, 0, g.roadR, h),
        Paint()..color = const Color(0xFF455A64));

    // Red and white curbs
    final cl = h * 0.04;
    final cw = w * 0.025;
    int idx = 0;
    for (double y = -cl * 2 + g.scroll % (cl * 2); y < h; y += cl, idx++) {
      final p = Paint()
        ..color = idx.isEven ? const Color(0xFFE53935) : Colors.white;
      canvas.drawRect(Rect.fromLTWH(g.roadL - cw, y, cw, cl), p);
      canvas.drawRect(Rect.fromLTWH(g.roadR, y, cw, cl), p);
    }

    // Lane dashes
    final period = h * 0.12;
    final dash = Paint()..color = Colors.white70;
    for (int i = 1; i < 3; i++) {
      final x = g.roadL + g.laneW * i;
      for (double y = -period + g.scroll % period; y < h; y += period) {
        canvas.drawRect(Rect.fromLTWH(x - w * 0.008, y, w * 0.016, h * 0.06), dash);
      }
    }

    // Coins
    for (final c in g.coinList) {
      final o = Offset(g.laneX(c.lane), c.y);
      final r = g.carW * 0.28;
      canvas.drawCircle(o, r, Paint()..color = const Color(0xFFFFA000));
      canvas.drawCircle(o, r * 0.78, Paint()..color = const Color(0xFFFFD54F));
      canvas.drawCircle(o + Offset(-r * 0.25, -r * 0.25), r * 0.18,
          Paint()..color = Colors.white70);
    }

    // Traffic and the player's car
    for (final c in g.cars) {
      _car(canvas, Offset(g.laneX(c.lane), c.y), c.color, false);
    }
    _car(canvas, Offset(g.playerX, g.playerY), const Color(0xFFE53935), true);

    // Crash explosion
    if (g.phase == Phase.over && g.deadTimer < 0.9) {
      final k = g.deadTimer;
      final a = max(0.0, 1 - k * 1.1);
      final r = g.carW * (0.6 + min(k, 0.5) * 2.4);
      final o = Offset(g.crashX, g.crashY);
      canvas.drawCircle(o, r, Paint()..color = const Color(0xFFFF6F00).withOpacity(a * 0.8));
      canvas.drawCircle(o, r * 0.6, Paint()..color = const Color(0xFFFFEB3B).withOpacity(a));
    }

    // HUD
    if (g.phase != Phase.ready) {
      _text(canvas, '${g.score}', h * 0.06, Offset(w / 2, h * 0.07));
      final cy = h * 0.075;
      canvas.drawCircle(Offset(w * 0.07, cy), h * 0.014, Paint()..color = const Color(0xFFFFA000));
      canvas.drawCircle(Offset(w * 0.07, cy), h * 0.010, Paint()..color = const Color(0xFFFFD54F));
      _text(canvas, '${g.coins}', h * 0.026, Offset(w * 0.07 + h * 0.035, cy), left: true);
      _text(canvas, '${g.kmh} km/h', h * 0.022, Offset(w * 0.96, cy), right: true);
    }

    if (g.phase == Phase.ready) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black26);
      _text(canvas, 'Road Rush', h * 0.065, Offset(w / 2, h * 0.24));
      _text(canvas, 'Tap left or right to steer', h * 0.024, Offset(w / 2, h * 0.32));
      _text(canvas, 'Dodge traffic, grab coins', h * 0.024, Offset(w / 2, h * 0.36));
      final pulse = 0.6 + 0.4 * sin(g.t * 4).abs();
      _text(canvas, 'Tap to start', h * 0.034, Offset(w / 2, h * 0.56),
          color: Colors.white.withOpacity(pulse));
      if (g.best > 0) {
        _text(canvas, 'Best: ${g.best}', h * 0.026, Offset(w / 2, h * 0.63));
      }
    }

    if (g.phase == Phase.over) {
      final panel = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(w / 2, h * 0.42), width: w * 0.78, height: h * 0.34),
        const Radius.circular(24),
      );
      canvas.drawRRect(panel, Paint()..color = const Color(0xEEFFF8E1));
      canvas.drawRRect(
          panel,
          Paint()
            ..color = const Color(0xFFE53935)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5);
      final c = panel.center;
      _text(canvas, 'Crash!', h * 0.055, c + Offset(0, -h * 0.11), color: const Color(0xFFD32F2F));
      _text(canvas, 'Score: ${g.score}', h * 0.032, c + Offset(0, -h * 0.04),
          color: const Color(0xFF5D4037), shadow: false);
      _text(canvas, 'Coins: ${g.coins}', h * 0.024, c + Offset(0, h * 0.008),
          color: const Color(0xFFFF8F00), shadow: false);
      _text(canvas, g.newBest ? 'New best!' : 'Best: ${g.best}', h * 0.028,
          c + Offset(0, h * 0.052),
          color: g.newBest ? const Color(0xFF2E7D32) : const Color(0xFF5D4037),
          shadow: false);
      if (g.deadTimer > 0.8) {
        _text(canvas, 'Tap to race again', h * 0.024, c + Offset(0, h * 0.11),
            color: const Color(0xFF1565C0), shadow: false);
      }
    }

    if (g.flash > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h),
          Paint()..color = Colors.white.withOpacity(g.flash * 0.6));
    }
  }

  void _car(Canvas c, Offset center, Color color, bool player) {
    final cw = g.carW, ch = g.carH;
    c.save();
    c.translate(center.dx, center.dy);
    if (player) c.rotate(g.tilt);

    RRect rr(double x, double y, double ww, double hh, double r) =>
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, y), width: ww, height: hh),
            Radius.circular(r));

    c.drawRRect(rr(4, 6, cw, ch, cw * 0.3), Paint()..color = Colors.black26);
    final wheel = Paint()..color = const Color(0xFF212121);
    for (final sx in [-1.0, 1.0]) {
      for (final sy in [-1.0, 1.0]) {
        c.drawRRect(rr(sx * cw * 0.48, sy * ch * 0.3, cw * 0.22, ch * 0.2, 3), wheel);
      }
    }
    c.drawRRect(rr(0, 0, cw, ch, cw * 0.3), Paint()..color = color);
    if (player) {
      final stripe = Paint()..color = Colors.white;
      c.drawRect(Rect.fromLTWH(-cw * 0.14, -ch * 0.5, cw * 0.08, ch), stripe);
      c.drawRect(Rect.fromLTWH(cw * 0.06, -ch * 0.5, cw * 0.08, ch), stripe);
    }
    c.drawRRect(rr(0, -ch * 0.12, cw * 0.74, ch * 0.2, cw * 0.12),
        Paint()..color = const Color(0xFF263238));
    c.drawRRect(rr(0, ch * 0.08, cw * 0.66, ch * 0.22, cw * 0.1),
        Paint()..color = Color.lerp(color, Colors.black, 0.2)!);
    c.drawRRect(rr(0, ch * 0.28, cw * 0.62, ch * 0.1, cw * 0.08),
        Paint()..color = const Color(0xFF37474F));
    final head = Paint()..color = const Color(0xFFFFF59D);
    c.drawCircle(Offset(-cw * 0.3, -ch * 0.45), cw * 0.09, head);
    c.drawCircle(Offset(cw * 0.3, -ch * 0.45), cw * 0.09, head);
    final tail = Paint()..color = const Color(0xFFD50000);
    c.drawRect(Rect.fromCenter(center: Offset(-cw * 0.3, ch * 0.47), width: cw * 0.2, height: ch * 0.04), tail);
    c.drawRect(Rect.fromCenter(center: Offset(cw * 0.3, ch * 0.47), width: cw * 0.2, height: ch * 0.04), tail);
    c.restore();
  }

  void _text(Canvas canvas, String s, double fontSize, Offset at,
      {Color color = Colors.white, bool shadow = true, bool left = false, bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: FontWeight.w900,
          shadows: shadow
              ? const [Shadow(color: Colors.black54, offset: Offset(2, 3), blurRadius: 4)]
              : null,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = left ? 0.0 : (right ? tp.width : tp.width / 2);
    tp.paint(canvas, at - Offset(dx, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
