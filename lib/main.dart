import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
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

// ---------------------------------------------------------------- model

enum Phase { ready, playing, over }

enum Control { tap, swipe, tilt }

class CarSkin {
  const CarSkin(this.name, this.color, this.price, {this.stripe = Colors.white});
  final String name;
  final Color color;
  final int price;
  final Color stripe;
}

const skins = [
  CarSkin('Red Fury', Color(0xFFE53935), 0),
  CarSkin('Blue Bolt', Color(0xFF1E88E5), 15),
  CarSkin('Green Viper', Color(0xFF43A047), 30),
  CarSkin('Sunny', Color(0xFFFDD835), 50, stripe: Color(0xFF212121)),
  CarSkin('Purple Storm', Color(0xFF8E24AA), 80),
  CarSkin('Midnight', Color(0xFF37474F), 120, stripe: Color(0xFFFFD54F)),
  CarSkin('Gold Rush', Color(0xFFFFB300), 200, stripe: Color(0xFF212121)),
];

const trafficColors = [
  Color(0xFF1E88E5),
  Color(0xFF8E24AA),
  Color(0xFFFDD835),
  Color(0xFF00ACC1),
  Color(0xFFFB8C00),
  Color(0xFFECEFF1),
  Color(0xFF43A047),
];

class Car {
  Car(this.d, this.lane, this.color);
  double d; // distance ahead of the player, world units
  final int lane;
  final Color color;
  bool smashed = false;
}

class Pickup {
  Pickup(this.d, this.lane, this.nitro);
  double d;
  final int lane;
  final bool nitro;
  bool taken = false;
}

class Burst {
  Burst(this.x, this.y);
  final double x, y;
  double age = 0;
}

// Lane centre in road space, where -1..1 spans the road.
const laneXs = [-0.6, 0.0, 0.6];
double laneX(int l) => laneXs[l];

// ---------------------------------------------------------------- page

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
  StreamSubscription? _accel;
  double _accelX = 0;
  Size size = Size.zero;

  Phase phase = Phase.ready;
  Control control = Control.tap;

  double playerX = 0; // road space, -1..1
  double targetX = 0;
  double tilt = 0;
  double t = 0;
  double worldZ = 0;
  double runTime = 0;
  double dist = 0;
  double spawnTimer = 0;
  double coinTimer = 0;
  double nitroTimer = 0;
  double nitroTime = 0;
  double deadTimer = 0;
  double flash = 0;
  double shake = 0;
  int coins = 0;
  int bonus = 0;
  int best = 0;
  int wallet = 0;
  int skin = 0;
  Set<int> owned = {0};
  bool newBest = false;
  final List<Car> cars = [];
  final List<Pickup> pickups = [];
  final List<Burst> bursts = [];
  final List<int> lastLanes = [];

  static const nitroLength = 3.5;
  static const maxX = 0.85;
  static const laneStep = 0.6;

  double get w => size.width;
  double get h => size.height;
  double get baseSpeed =>
      phase == Phase.playing ? 42 + min(runTime, 80) * 0.72 : 22;
  double get speed => baseSpeed * (nitroTime > 0 ? 1.6 : 1.0);
  int get score => (dist * 0.12).floor() + coins * 25 + bonus;
  int get kmh => (speed * 2.6).round();
  CarSkin get mySkin => skins[skin];
  bool get skinOwned => owned.contains(skin);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _accel = accelerometerEventStream().listen((e) => _accelX = e.x,
        onError: (_) {});
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        best = p.getInt('best') ?? 0;
        wallet = p.getInt('wallet') ?? 0;
        owned = {0, ...(p.getStringList('owned') ?? []).map(int.parse)};
        final s = p.getInt('skin') ?? 0;
        skin = (s >= 0 && s < skins.length && owned.contains(s)) ? s : 0;
        control = Control.values[(p.getInt('control') ?? 0).clamp(0, 2)];
      });
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _accel?.cancel();
    super.dispose();
  }

  void _save() {
    SharedPreferences.getInstance().then((p) {
      p.setInt('best', best);
      p.setInt('wallet', wallet);
      p.setInt('skin', skin);
      p.setStringList('owned', owned.map((e) => '$e').toList());
      p.setInt('control', control.index);
    });
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
    if (shake > 0) shake = max(0, shake - dt * 4);
    for (final b in bursts) {
      b.age += dt;
    }
    bursts.removeWhere((b) => b.age > 0.6);

    final sp = speed;
    worldZ += sp * dt;

    // Tilt steering reads continuously so the car feels responsive.
    if (phase == Phase.playing && control == Control.tilt) {
      targetX = (-_accelX / 6.0).clamp(-maxX, maxX);
    }
    final dx = targetX - playerX;
    playerX += dx * min(1.0, dt * 12);
    tilt = (targetX - playerX).clamp(-1.0, 1.0) * 0.4 +
        (dx).clamp(-1.0, 1.0) * 0.2;

    if (phase != Phase.playing) {
      if (phase == Phase.over) deadTimer += dt;
      return;
    }

    runTime += dt;
    dist += sp * dt;

    if (nitroTime > 0) nitroTime = max(0, nitroTime - dt);

    final closing = sp * 0.55;
    for (final c in cars) {
      c.d -= closing * dt;
    }
    cars.removeWhere((c) => c.smashed || c.d < -6);
    for (final p in pickups) {
      p.d -= closing * dt;
    }
    pickups.removeWhere((p) => p.taken || p.d < -6);

    spawnTimer -= dt;
    if (spawnTimer <= 0) {
      _spawnCar();
      spawnTimer = max(0.5, 1.15 - runTime * 0.008);
    }
    coinTimer -= dt;
    if (coinTimer <= 0) {
      _spawnPickup(false);
      coinTimer = 1.4 + _rng.nextDouble() * 1.2;
    }
    nitroTimer -= dt;
    if (nitroTimer <= 0) {
      _spawnPickup(true);
      nitroTimer = 10 + _rng.nextDouble() * 8;
    }

    for (final c in cars) {
      if (c.smashed) continue;
      if (c.d < 4.5 && c.d > -3 && (playerX - laneX(c.lane)).abs() < 0.42) {
        if (nitroTime > 0) {
          c.smashed = true;
          bonus += 10;
          shake = 0.5;
          bursts.add(Burst(w / 2 + laneX(c.lane) * w * 0.3, h * 0.78));
          HapticFeedback.mediumImpact();
        } else {
          _crash();
          return;
        }
      }
    }
    for (final p in pickups) {
      if (p.taken) continue;
      if (p.d < 4.5 && p.d > -3 && (playerX - laneX(p.lane)).abs() < 0.45) {
        p.taken = true;
        if (p.nitro) {
          nitroTime = nitroLength;
          HapticFeedback.mediumImpact();
        } else {
          coins++;
          HapticFeedback.selectionClick();
        }
      }
    }
  }

  void _spawnCar() {
    int l = _rng.nextInt(3);
    if (lastLanes.length >= 2 && lastLanes[0] != lastLanes[1]) {
      l = lastLanes[_rng.nextInt(2)];
    }
    cars.add(Car(110, l, trafficColors[_rng.nextInt(trafficColors.length)]));
    lastLanes.add(l);
    if (lastLanes.length > 2) lastLanes.removeAt(0);
  }

  void _spawnPickup(bool nitro) {
    final free = [0, 1, 2]
        .where((l) =>
            !cars.any((c) => c.lane == l && c.d > 90) &&
            !pickups.any((p) => p.lane == l && p.d > 90))
        .toList();
    if (free.isEmpty) return;
    pickups.add(Pickup(115, free[_rng.nextInt(free.length)], nitro));
  }

  void _crash() {
    phase = Phase.over;
    deadTimer = 0;
    flash = 1;
    shake = 1;
    nitroTime = 0;
    bursts.add(Burst(w / 2 + playerX * w * 0.3, h * 0.82));
    HapticFeedback.heavyImpact();
    wallet += coins;
    newBest = score > best;
    if (newBest) best = score;
    _save();
  }

  void _resetRun() {
    cars.clear();
    pickups.clear();
    bursts.clear();
    lastLanes.clear();
    runTime = 0;
    dist = 0;
    coins = 0;
    bonus = 0;
    nitroTime = 0;
    playerX = 0;
    targetX = 0;
    spawnTimer = 0.6;
    coinTimer = 1.2;
    nitroTimer = 6;
  }

  // -------------------------------------------------------- input

  void _tapAt(Offset pos) {
    if (phase == Phase.ready) {
      _readyTap(pos);
      return;
    }
    if (phase == Phase.over) {
      if (deadTimer > 0.8) {
        setState(() {
          _resetRun();
          phase = Phase.ready;
          newBest = false;
        });
      }
      return;
    }
    if (control == Control.tap) {
      if (pos.dx < w / 2) {
        targetX = (targetX - laneStep).clamp(-maxX, maxX);
      } else {
        targetX = (targetX + laneStep).clamp(-maxX, maxX);
      }
    }
  }

  void _drag(double dx) {
    if (phase == Phase.playing && control == Control.swipe) {
      targetX = (targetX + dx / (w * 0.42)).clamp(-maxX, maxX);
    }
  }

  Rect get _playRect =>
      Rect.fromCenter(center: Offset(w / 2, h * 0.6), width: w * 0.64, height: h * 0.08);

  void _readyTap(Offset pos) {
    // control selector
    for (int i = 0; i < 3; i++) {
      if (_controlRect(i).contains(pos)) {
        setState(() => control = Control.values[i]);
        _save();
        return;
      }
    }
    if (_leftArrow.contains(pos)) {
      setState(() => skin = (skin - 1 + skins.length) % skins.length);
      return;
    }
    if (_rightArrow.contains(pos)) {
      setState(() => skin = (skin + 1) % skins.length);
      return;
    }
    if (_playRect.contains(pos)) {
      if (skinOwned) {
        setState(() {
          _resetRun();
          phase = Phase.playing;
        });
        _save();
      } else if (wallet >= mySkin.price) {
        setState(() {
          wallet -= mySkin.price;
          owned.add(skin);
        });
        HapticFeedback.mediumImpact();
        _save();
      }
    }
  }

  Rect _controlRect(int i) {
    final bw = w * 0.26;
    final gap = w * 0.03;
    final total = bw * 3 + gap * 2;
    final left = w / 2 - total / 2 + i * (bw + gap);
    return Rect.fromLTWH(left, h * 0.75, bw, h * 0.06);
  }

  Rect get _leftArrow =>
      Rect.fromCenter(center: Offset(w * 0.13, h * 0.44), width: w * 0.2, height: h * 0.12);
  Rect get _rightArrow =>
      Rect.fromCenter(center: Offset(w * 0.87, h * 0.44), width: w * 0.2, height: h * 0.12);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          size = constraints.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _tapAt(d.localPosition),
            onHorizontalDragUpdate: (d) => _drag(d.delta.dx),
            child: CustomPaint(size: size, painter: RacePainter(this)),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- painter

class RacePainter extends CustomPainter {
  RacePainter(this.g);
  final _GamePageState g;

  static const camK = 30.0;

  double _scale(double d) => 1 / (1 + max(d, -4) / camK);

  @override
  void paint(Canvas canvas, Size size) {
    final w = g.w, h = g.h;
    if (w == 0) return;
    final horizonY = h * 0.42;
    final bottomY = h;
    final roadHalf = w * 0.47;
    final cx = w / 2;

    if (g.shake > 0) {
      canvas.save();
      canvas.translate(
          (g._rng.nextDouble() - 0.5) * g.shake * 14,
          (g._rng.nextDouble() - 0.5) * g.shake * 10);
    }

    // Sky
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, horizonY),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A237E), Color(0xFF42A5F5), Color(0xFFFFCCBC)],
        ).createShader(Rect.fromLTWH(0, 0, w, horizonY)),
    );
    // Sun
    canvas.drawCircle(Offset(cx, horizonY - h * 0.02), h * 0.06,
        Paint()..color = const Color(0xFFFFF59D).withOpacity(0.9));
    // Distant skyline
    final sky = Paint()..color = const Color(0xFF283593).withOpacity(0.55);
    for (int i = 0; i < 16; i++) {
      final bx = (i * w * 0.07);
      final bh = h * (0.03 + (i % 4) * 0.012);
      canvas.drawRect(Rect.fromLTWH(bx, horizonY - bh, w * 0.05, bh), sky);
    }

    // Ground base
    canvas.drawRect(Rect.fromLTWH(0, horizonY, w, h - horizonY),
        Paint()..color = const Color(0xFF2E7D32));

    // Perspective road, drawn as horizontal bands from bottom up.
    final grass = Paint();
    final road = Paint();
    final rumble = Paint();
    final lane = Paint()..color = Colors.white;
    for (double y = bottomY; y > horizonY; y -= 4) {
      final sc = (y - horizonY) / (bottomY - horizonY);
      if (sc <= 0) continue;
      final d = camK * (1 / sc - 1);
      final even = (((d + g.worldZ) / 7).floor()).isEven;
      final half = roadHalf * sc;
      grass.color = even ? const Color(0xFF43A047) : const Color(0xFF388E3C);
      canvas.drawRect(Rect.fromLTRB(0, y - 4, w, y), grass);
      road.color = even ? const Color(0xFF4A4F55) : const Color(0xFF42464C);
      canvas.drawRect(Rect.fromLTRB(cx - half, y - 4, cx + half, y), road);
      final rw = half * 0.12;
      rumble.color = even ? const Color(0xFFE53935) : Colors.white;
      canvas.drawRect(Rect.fromLTRB(cx - half, y - 4, cx - half + rw, y), rumble);
      canvas.drawRect(Rect.fromLTRB(cx + half - rw, y - 4, cx + half, y), rumble);
      if (even) {
        final lw = half * 0.02 + 0.6;
        for (final lx in [-0.2, 0.2]) {
          final x = cx + lx * half;
          canvas.drawRect(Rect.fromLTRB(x - lw, y - 4, x + lw, y), lane);
        }
      }
    }

    // Roadside poles for a sense of speed
    final pole = Paint()..color = const Color(0xFF9E9E9E);
    final sign = Paint()..color = const Color(0xFFEF5350);
    const poleSpace = 14.0;
    for (int k = 1; k < 10; k++) {
      final d = k * poleSpace - (g.worldZ % poleSpace);
      if (d < 1) continue;
      final sc = _scale(d);
      final y = horizonY + (bottomY - horizonY) * sc;
      final half = roadHalf * sc;
      final ph = h * 0.1 * sc;
      for (final sdir in [-1.0, 1.0]) {
        final x = cx + sdir * (half + half * 0.18);
        canvas.drawRect(
            Rect.fromLTWH(x - 2 * sc, y - ph, 4 * sc, ph), pole);
        canvas.drawRect(
            Rect.fromLTWH(x - 7 * sc, y - ph, 14 * sc, 9 * sc), sign);
      }
    }

    // Draw cars and pickups far-to-near.
    final items = <_Proj>[];
    for (final c in g.cars) {
      if (c.smashed) continue;
      items.add(_Proj(c.d, () => _drawCar(canvas, _carX(c.d, laneX(c.lane), cx, roadHalf, horizonY, bottomY),
          _carY(c.d, horizonY, bottomY), _carW(c.d, roadHalf), c.color, false, 0)));
    }
    for (final p in g.pickups) {
      if (p.taken) continue;
      items.add(_Proj(p.d, () {
        final sc = _scale(p.d);
        final x = _carX(p.d, laneX(p.lane), cx, roadHalf, horizonY, bottomY);
        final y = _carY(p.d, horizonY, bottomY) - roadHalf * sc * 0.5;
        if (p.nitro) {
          _drawNitro(canvas, x, y, roadHalf * sc * 0.32);
        } else {
          _drawCoin(canvas, x, y, roadHalf * sc * 0.24);
        }
      }));
    }
    items.sort((a, b) => b.d.compareTo(a.d));
    for (final it in items) {
      it.draw();
    }

    // Speed lines during nitro
    if (g.nitroTime > 0) {
      final line = Paint()
        ..color = Colors.white.withOpacity(0.4)
        ..strokeWidth = 2;
      for (int i = 0; i < 14; i++) {
        final a = (i / 14) * 2 * pi;
        final r1 = w * 0.12;
        final r2 = w * (0.3 + (g.t * 2 + i) % 1 * 0.3);
        final o = Offset(cx, horizonY + h * 0.05);
        canvas.drawLine(o + Offset(cos(a) * r1, sin(a) * r1),
            o + Offset(cos(a) * r2, sin(a) * r2), line);
      }
    }

    // Player car at the bottom
    if (g.phase != Phase.ready) {
      final px = cx + g.playerX * roadHalf * 0.92;
      _drawCar(canvas, px, h * 0.93, w * 0.17, g.mySkin.color, true, g.tilt,
          stripe: g.mySkin.stripe, nitro: g.nitroTime > 0);
    }

    // Smash/crash bursts
    for (final b in g.bursts) {
      final a = max(0.0, 1 - b.age / 0.6);
      final r = w * (0.06 + b.age * 0.32);
      canvas.drawCircle(Offset(b.x, b.y), r,
          Paint()..color = const Color(0xFFFF6F00).withOpacity(a * 0.75));
      canvas.drawCircle(Offset(b.x, b.y), r * 0.55,
          Paint()..color = const Color(0xFFFFEB3B).withOpacity(a));
    }

    if (g.shake > 0) canvas.restore();

    if (g.phase != Phase.ready) _hud(canvas);
    if (g.phase == Phase.ready) _garage(canvas);
    if (g.phase == Phase.over) _gameOver(canvas);

    if (g.flash > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h),
          Paint()..color = Colors.white.withOpacity(g.flash * 0.6));
    }
  }

  double _carX(double d, double lane, double cx, double roadHalf,
      double hor, double bot) {
    final sc = _scale(d);
    return cx + lane * roadHalf * sc * 0.92;
  }

  double _carY(double d, double hor, double bot) {
    final sc = _scale(d);
    return hor + (bot - hor) * sc;
  }

  double _carW(double d, double roadHalf) => roadHalf * _scale(d) * 0.52;

  void _drawCar(Canvas c, double cxs, double baseY, double wpx, Color color,
      bool player, double tiltv,
      {Color stripe = Colors.white, bool nitro = false}) {
    if (wpx < 2) return;
    final hpx = wpx * 1.5;
    c.save();
    c.translate(cxs, baseY - hpx / 2);
    if (player) c.rotate(tiltv * 0.12);

    RRect rr(double x, double y, double ww, double hh, double r) =>
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, y), width: ww, height: hh),
            Radius.circular(r));

    // shadow
    c.drawOval(
        Rect.fromCenter(
            center: Offset(0, hpx * 0.52), width: wpx * 1.15, height: hpx * 0.16),
        Paint()..color = Colors.black.withOpacity(0.3));

    if (nitro) {
      for (final sx in [-0.26, 0.26]) {
        final fx = sx * wpx;
        final len = hpx * (0.4 + 0.2 * sin(g.t * 40 + sx * 10).abs());
        final path = Path()
          ..moveTo(fx - wpx * 0.12, hpx * 0.48)
          ..lineTo(fx, hpx * 0.48 + len)
          ..lineTo(fx + wpx * 0.12, hpx * 0.48)
          ..close();
        c.drawPath(path, Paint()..color = const Color(0xFF00B0FF));
        final path2 = Path()
          ..moveTo(fx - wpx * 0.06, hpx * 0.48)
          ..lineTo(fx, hpx * 0.48 + len * 0.6)
          ..lineTo(fx + wpx * 0.06, hpx * 0.48)
          ..close();
        c.drawPath(path2, Paint()..color = const Color(0xFFE1F5FE));
      }
    }

    // wheels
    final wheel = Paint()..color = const Color(0xFF212121);
    for (final sx in [-1.0, 1.0]) {
      for (final sy in [-1.0, 1.0]) {
        c.drawRRect(
            rr(sx * wpx * 0.48, sy * hpx * 0.3, wpx * 0.2, hpx * 0.22, 2), wheel);
      }
    }
    // body with vertical gradient
    final bodyRect =
        Rect.fromCenter(center: Offset.zero, width: wpx, height: hpx);
    c.drawRRect(
      RRect.fromRectAndRadius(bodyRect, Radius.circular(wpx * 0.22)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(color, Colors.white, 0.25)!,
            color,
            Color.lerp(color, Colors.black, 0.25)!,
          ],
        ).createShader(bodyRect),
    );
    if (player) {
      final sp = Paint()..color = stripe;
      c.drawRect(Rect.fromLTWH(-wpx * 0.13, -hpx * 0.5, wpx * 0.07, hpx), sp);
      c.drawRect(Rect.fromLTWH(wpx * 0.06, -hpx * 0.5, wpx * 0.07, hpx), sp);
    }
    // rear window
    c.drawRRect(rr(0, -hpx * 0.14, wpx * 0.72, hpx * 0.22, wpx * 0.1),
        Paint()..color = const Color(0xFF263238));
    c.drawRRect(rr(0, hpx * 0.08, wpx * 0.64, hpx * 0.2, wpx * 0.08),
        Paint()..color = Color.lerp(color, Colors.black, 0.35)!);
    // tail lights
    final tail = Paint()..color = const Color(0xFFFF1744);
    c.drawRRect(rr(-wpx * 0.28, hpx * 0.42, wpx * 0.22, hpx * 0.08, 3), tail);
    c.drawRRect(rr(wpx * 0.28, hpx * 0.42, wpx * 0.22, hpx * 0.08, 3), tail);
    c.restore();
  }

  void _drawCoin(Canvas canvas, double x, double y, double r) {
    if (r < 1) return;
    canvas.drawCircle(Offset(x, y), r, Paint()..color = const Color(0xFFFFA000));
    canvas.drawCircle(Offset(x, y), r * 0.78, Paint()..color = const Color(0xFFFFD54F));
    canvas.drawCircle(Offset(x - r * 0.25, y - r * 0.25), r * 0.18,
        Paint()..color = Colors.white70);
  }

  void _drawNitro(Canvas canvas, double x, double y, double r) {
    if (r < 1) return;
    final glow = 0.5 + 0.5 * sin(g.t * 8).abs();
    canvas.drawCircle(Offset(x, y), r * 1.4,
        Paint()..color = const Color(0xFF00B0FF).withOpacity(0.25 * glow));
    canvas.drawCircle(Offset(x, y), r, Paint()..color = const Color(0xFF0091EA));
    canvas.drawCircle(Offset(x, y), r * 0.82, Paint()..color = const Color(0xFF40C4FF));
    final bolt = Path()
      ..moveTo(x + r * 0.15, y - r * 0.6)
      ..lineTo(x - r * 0.35, y + r * 0.08)
      ..lineTo(x - r * 0.02, y + r * 0.08)
      ..lineTo(x - r * 0.15, y + r * 0.6)
      ..lineTo(x + r * 0.35, y - r * 0.08)
      ..lineTo(x + r * 0.02, y - r * 0.08)
      ..close();
    canvas.drawPath(bolt, Paint()..color = Colors.white);
  }

  // -------------------------------------------------------- overlays

  void _hud(Canvas canvas) {
    final w = g.w, h = g.h;
    _text(canvas, '${g.score}', h * 0.055, Offset(w / 2, h * 0.06));
    final cy = h * 0.065;
    _drawCoin(canvas, w * 0.08, cy, h * 0.014);
    _text(canvas, '${g.coins}', h * 0.026, Offset(w * 0.08 + h * 0.025, cy),
        left: true);
    _text(canvas, '${g.kmh} km/h', h * 0.024, Offset(w * 0.95, cy),
        right: true, color: g.nitroTime > 0 ? const Color(0xFF80D8FF) : Colors.white);
    if (g.nitroTime > 0) {
      final bw = w * 0.44;
      final bar = Rect.fromCenter(
          center: Offset(w / 2, h * 0.11), width: bw, height: h * 0.015);
      canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(8)),
          Paint()..color = Colors.black38);
      final fill = Rect.fromLTWH(bar.left, bar.top,
          bw * (g.nitroTime / _GamePageState.nitroLength), bar.height);
      canvas.drawRRect(RRect.fromRectAndRadius(fill, const Radius.circular(8)),
          Paint()..color = const Color(0xFF00B0FF));
    }
  }

  void _garage(Canvas canvas) {
    final w = g.w, h = g.h;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black54);
    _drawCoin(canvas, w * 0.08, h * 0.06, h * 0.015);
    _text(canvas, '${g.wallet}', h * 0.028, Offset(w * 0.08 + h * 0.026, h * 0.06),
        left: true);
    _text(canvas, 'ROAD RUSH', h * 0.058, Offset(w / 2, h * 0.14));
    _text(canvas, 'GARAGE', h * 0.02, Offset(w / 2, h * 0.21),
        color: const Color(0xFFFFD54F));
    _text(canvas, g.mySkin.name, h * 0.032, Offset(w / 2, h * 0.25));

    // big car preview
    canvas.save();
    canvas.translate(w / 2, h * 0.42);
    _drawCar(canvas, 0, h * 0.06, w * 0.3, g.mySkin.color, true, 0,
        stripe: g.mySkin.stripe);
    canvas.restore();
    if (!g.skinOwned) {
      _text(canvas, 'LOCKED', h * 0.022, Offset(w / 2, h * 0.4));
    }
    _arrow(canvas, g._leftArrow.center, true);
    _arrow(canvas, g._rightArrow.center, false);
    _text(canvas, '${g.skin + 1} / ${skins.length}', h * 0.018,
        Offset(w / 2, h * 0.52), color: Colors.white70, shadow: false);

    // play / buy button
    final b = g._playRect;
    String label;
    Color col;
    if (g.skinOwned) {
      final pulse = 0.85 + 0.15 * sin(g.t * 4).abs();
      label = 'START';
      col = Color.lerp(const Color(0xFF2E7D32), const Color(0xFF43A047), pulse)!;
    } else if (g.wallet >= g.mySkin.price) {
      label = 'BUY  •  ${g.mySkin.price} coins';
      col = const Color(0xFFFF8F00);
    } else {
      label = 'Need ${g.mySkin.price} coins';
      col = const Color(0xFF616161);
    }
    canvas.drawRRect(
        RRect.fromRectAndRadius(b, Radius.circular(b.height / 2)),
        Paint()..color = col);
    _text(canvas, label, h * (g.skinOwned ? 0.03 : 0.023), b.center);

    // control selector
    _text(canvas, 'CONTROLS', h * 0.016, Offset(w / 2, h * 0.725),
        color: Colors.white54, shadow: false);
    const labels = ['Tap', 'Swipe', 'Tilt'];
    for (int i = 0; i < 3; i++) {
      final r = g._controlRect(i);
      final on = g.control.index == i;
      canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(10)),
          Paint()..color = on ? const Color(0xFF1565C0) : const Color(0xFF455A64));
      _text(canvas, labels[i], h * 0.02, r.center,
          color: on ? Colors.white : Colors.white70, shadow: false);
    }
    _text(canvas, g.best > 0 ? 'Best: ${g.best}' : 'Tap left/right • swipe • or tilt to steer',
        h * 0.02, Offset(w / 2, h * 0.86), color: Colors.white70);
  }

  void _gameOver(Canvas canvas) {
    final w = g.w, h = g.h;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black45);
    final panel = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(w / 2, h * 0.44), width: w * 0.78, height: h * 0.34),
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
    _text(canvas, 'Crash!', h * 0.05, c + Offset(0, -h * 0.11),
        color: const Color(0xFFD32F2F));
    _text(canvas, 'Score: ${g.score}', h * 0.032, c + Offset(0, -h * 0.045),
        color: const Color(0xFF5D4037), shadow: false);
    _text(canvas, '+${g.coins} coins  (total ${g.wallet})', h * 0.022,
        c + Offset(0, h * 0.0),
        color: const Color(0xFFFF8F00), shadow: false);
    _text(canvas, g.newBest ? 'New best!' : 'Best: ${g.best}', h * 0.028,
        c + Offset(0, h * 0.05),
        color: g.newBest ? const Color(0xFF2E7D32) : const Color(0xFF5D4037),
        shadow: false);
    if (g.deadTimer > 0.8) {
      _text(canvas, 'Tap to go to the garage', h * 0.022, c + Offset(0, h * 0.11),
          color: const Color(0xFF1565C0), shadow: false);
    }
  }

  void _arrow(Canvas canvas, Offset c, bool left) {
    final r = g.h * 0.03;
    canvas.drawCircle(c, r, Paint()..color = Colors.black45);
    final s = left ? -1.0 : 1.0;
    final path = Path()
      ..moveTo(c.dx - s * r * 0.25, c.dy - r * 0.45)
      ..lineTo(c.dx + s * r * 0.3, c.dy)
      ..lineTo(c.dx - s * r * 0.25, c.dy + r * 0.45);
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.22
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
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

class _Proj {
  _Proj(this.d, this.draw);
  final double d;
  final VoidCallback draw;
}
