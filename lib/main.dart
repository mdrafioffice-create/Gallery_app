import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
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

// ---------------------------------------------------------------- data

enum Phase { ready, playing, over }

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
  Car(this.lane, this.y, this.color);
  final int lane;
  double y;
  final Color color;
  bool smashed = false;
}

class Pickup {
  Pickup(this.lane, this.y, this.nitro);
  final int lane;
  double y;
  final bool nitro;
  bool taken = false;
}

class Burst {
  Burst(this.x, this.y);
  final double x, y;
  double age = 0;
}

// ---------------------------------------------------------------- sound

class Sfx {
  bool on = true;
  final Map<String, AudioPlayer> _players = {};
  AudioPlayer? _engine;
  double _pitch = 1;
  bool _engineRunning = false;

  AudioPlayer _make() => AudioPlayer(
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );

  Future<void> init() async {
    for (final n in ['coin', 'crash', 'nitro', 'smash', 'click']) {
      try {
        final p = _make();
        await p.setAsset('assets/sounds/$n.wav');
        _players[n] = p;
      } catch (_) {}
    }
    try {
      final e = _make();
      await e.setAsset('assets/sounds/engine.wav');
      await e.setLoopMode(LoopMode.one);
      await e.setVolume(0.45);
      _engine = e;
      if (_engineRunning && on) e.play();
    } catch (_) {}
  }

  void play(String name) {
    if (!on) return;
    final p = _players[name];
    if (p == null) return;
    p.seek(Duration.zero).catchError((_) {});
    p.play().catchError((_) {});
  }

  void engineStart() {
    _engineRunning = true;
    if (on) _engine?.play().catchError((_) {});
  }

  void engineStop() {
    _engineRunning = false;
    _engine?.pause().catchError((_) {});
  }

  void enginePause() => _engine?.pause().catchError((_) {});
  void engineResume() {
    if (_engineRunning && on) _engine?.play().catchError((_) {});
  }

  void enginePitch(double v) {
    if ((v - _pitch).abs() < 0.04) return;
    _pitch = v;
    _engine?.setPitch(v).catchError((_) {});
  }

  void setOn(bool v) {
    on = v;
    if (!v) {
      _engine?.pause().catchError((_) {});
    } else {
      engineResume();
    }
  }

  void dispose() {
    for (final p in _players.values) {
      p.dispose();
    }
    _engine?.dispose();
  }
}

// ---------------------------------------------------------------- game

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final Random _rng = Random();
  final Sfx sfx = Sfx();
  SharedPreferences? _prefs;
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
  double nitroTimer = 0;
  double nitroTime = 0;
  double deadTimer = 0;
  double flash = 0;
  double crashX = 0;
  double crashY = 0;
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

  double get w => size.width;
  double get h => size.height;
  double get roadL => w * 0.12;
  double get roadR => w * 0.88;
  double get laneW => (roadR - roadL) / 3;
  double laneX(int i) => roadL + laneW * (i + 0.5);
  double get carW => laneW * 0.56;
  double get carH => carW * 1.85;
  double get playerY => h * 0.8;
  double get baseSpeed =>
      phase == Phase.playing ? h * (0.62 + min(runTime, 70) * 0.011) : h * 0.35;
  double get speed => baseSpeed * (nitroTime > 0 ? 1.6 : 1.0);
  int get score => (dist / h * 10).floor() + coins * 25 + bonus;
  int get kmh => (speed / h * 160).round();
  CarSkin get mySkin => skins[skin];
  bool get skinOwned => owned.contains(skin);

  // Tap areas on the garage (start) screen
  Rect get soundRect => Rect.fromLTWH(w * 0.62, h * 0.04, w * 0.34, h * 0.055);
  Rect get leftArrowRect => Rect.fromCenter(center: Offset(w * 0.15, h * 0.4), width: w * 0.24, height: h * 0.14);
  Rect get rightArrowRect => Rect.fromCenter(center: Offset(w * 0.85, h * 0.4), width: w * 0.24, height: h * 0.14);
  Rect get mainButtonRect => Rect.fromCenter(center: Offset(w / 2, h * 0.6), width: w * 0.62, height: h * 0.075);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick)..start();
    sfx.init();
    SharedPreferences.getInstance().then((p) {
      _prefs = p;
      if (!mounted) return;
      setState(() {
        best = p.getInt('best') ?? 0;
        wallet = p.getInt('wallet') ?? 0;
        owned = {0, ...(p.getStringList('owned') ?? []).map(int.parse)};
        final s = p.getInt('skin') ?? 0;
        skin = (s >= 0 && s < skins.length && owned.contains(s)) ? s : 0;
        sfx.setOn(p.getBool('sound') ?? true);
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      sfx.engineResume();
    } else {
      sfx.enginePause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    sfx.dispose();
    super.dispose();
  }

  void _save() {
    final p = _prefs;
    if (p == null) return;
    p.setInt('best', best);
    p.setInt('wallet', wallet);
    p.setInt('skin', skin);
    p.setStringList('owned', owned.map((e) => '$e').toList());
    p.setBool('sound', sfx.on);
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
    for (final b in bursts) {
      b.age += dt;
    }
    bursts.removeWhere((b) => b.age > 0.6);

    if (phase == Phase.over) {
      deadTimer += dt;
      return;
    }

    final sp = speed;
    scroll += sp * dt;

    final dx = laneX(lane) - playerX;
    playerX += dx * min(1.0, dt * 14);
    tilt = (dx / laneW).clamp(-1.0, 1.0).toDouble() * 0.25;

    if (phase == Phase.ready) return;

    runTime += dt;
    dist += sp * dt;
    if (nitroTime > 0) nitroTime = max(0, nitroTime - dt);
    sfx.enginePitch((0.85 + (sp / h - 0.62) * 0.6).clamp(0.8, 2.0).toDouble());

    for (final c in cars) {
      c.y += sp * 0.55 * dt;
    }
    cars.removeWhere((c) => c.smashed || c.y > h + carH);
    for (final p in pickups) {
      p.y += sp * dt;
    }
    pickups.removeWhere((p) => p.taken || p.y > h + carW);

    spawnTimer -= dt;
    if (spawnTimer <= 0) {
      _spawnCar();
      spawnTimer = max(0.42, 1.05 - runTime * 0.009);
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

    final me = Rect.fromCenter(
        center: Offset(playerX, playerY), width: carW * 0.85, height: carH * 0.88);
    for (final c in cars) {
      final r = Rect.fromCenter(
          center: Offset(laneX(c.lane), c.y), width: carW * 0.85, height: carH * 0.88);
      if (!me.overlaps(r)) continue;
      if (nitroTime > 0) {
        // Nitro makes you unstoppable: smash the car out of the way.
        c.smashed = true;
        bonus += 10;
        bursts.add(Burst(laneX(c.lane), c.y));
        sfx.play('smash');
        HapticFeedback.mediumImpact();
      } else {
        _crash();
        return;
      }
    }
    for (final p in pickups) {
      final d = (Offset(laneX(p.lane), p.y) - Offset(playerX, playerY)).distance;
      if (p.taken || d >= carW * 0.8) continue;
      p.taken = true;
      if (p.nitro) {
        nitroTime = nitroLength;
        sfx.play('nitro');
        HapticFeedback.mediumImpact();
      } else {
        coins++;
        sfx.play('coin');
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

  void _spawnPickup(bool nitro) {
    final free = [0, 1, 2]
        .where((l) =>
            !cars.any((c) => c.lane == l && c.y < carH * 2) &&
            !pickups.any((p) => p.lane == l && p.y < carW * 2))
        .toList();
    if (free.isEmpty) return;
    pickups.add(Pickup(free[_rng.nextInt(free.length)], -carW, nitro));
  }

  void _crash() {
    phase = Phase.over;
    deadTimer = 0;
    flash = 1;
    nitroTime = 0;
    crashX = playerX;
    crashY = playerY - carH * 0.4;
    sfx.engineStop();
    sfx.play('crash');
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
    spawnTimer = 0.8;
    coinTimer = 1.5;
    nitroTimer = 6;
  }

  void _tap(Offset pos) {
    if (phase == Phase.ready) {
      _garageTap(pos);
    } else if (phase == Phase.playing) {
      if (pos.dx < w / 2) {
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

  void _garageTap(Offset pos) {
    if (soundRect.contains(pos)) {
      sfx.setOn(!sfx.on);
      sfx.play('click');
      _save();
    } else if (leftArrowRect.contains(pos)) {
      skin = (skin - 1 + skins.length) % skins.length;
      sfx.play('click');
    } else if (rightArrowRect.contains(pos)) {
      skin = (skin + 1) % skins.length;
      sfx.play('click');
    } else if (mainButtonRect.contains(pos)) {
      if (skinOwned) {
        _resetRun();
        phase = Phase.playing;
        sfx.engineStart();
        _save();
      } else if (wallet >= mySkin.price) {
        wallet -= mySkin.price;
        owned.add(skin);
        sfx.play('coin');
        HapticFeedback.mediumImpact();
        _save();
      }
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
            onPointerDown: (e) => _tap(e.localPosition),
            child: CustomPaint(size: size, painter: GamePainter(this)),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- drawing

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

    // Trees
    for (int i = 0; i < 6; i++) {
      final y = (i * h * 0.22 + g.scroll) % (h * 1.32) - h * 0.16;
      final x = i.isEven ? w * 0.055 : w - w * 0.055;
      canvas.drawCircle(Offset(x + 3, y + 4), w * 0.05, Paint()..color = Colors.black26);
      canvas.drawCircle(Offset(x, y), w * 0.05, Paint()..color = const Color(0xFF2E7D32));
      canvas.drawCircle(Offset(x - w * 0.012, y - w * 0.012), w * 0.03,
          Paint()..color = const Color(0xFF43A047));
    }

    // Road, curbs and lane dashes
    canvas.drawRect(Rect.fromLTRB(g.roadL, 0, g.roadR, h),
        Paint()..color = const Color(0xFF455A64));
    final cl = h * 0.04;
    final cw = w * 0.025;
    int idx = 0;
    for (double y = -cl * 2 + g.scroll % (cl * 2); y < h; y += cl, idx++) {
      final p = Paint()..color = idx.isEven ? const Color(0xFFE53935) : Colors.white;
      canvas.drawRect(Rect.fromLTWH(g.roadL - cw, y, cw, cl), p);
      canvas.drawRect(Rect.fromLTWH(g.roadR, y, cw, cl), p);
    }
    final period = h * 0.12;
    final dash = Paint()..color = Colors.white70;
    for (int i = 1; i < 3; i++) {
      final x = g.roadL + g.laneW * i;
      for (double y = -period + g.scroll % period; y < h; y += period) {
        canvas.drawRect(Rect.fromLTWH(x - w * 0.008, y, w * 0.016, h * 0.06), dash);
      }
    }

    // Speed lines during nitro
    if (g.nitroTime > 0) {
      final line = Paint()
        ..color = Colors.white.withOpacity(0.45)
        ..strokeWidth = 2;
      for (int i = 0; i < 10; i++) {
        final x = g.roadL + ((i * 0.37) % 1.0) * (g.roadR - g.roadL);
        final y = (i * h * 0.17 + g.scroll * 1.5) % (h * 1.1) - h * 0.05;
        canvas.drawLine(Offset(x, y), Offset(x, y + h * 0.08), line);
      }
    }

    // Pickups
    for (final p in g.pickups) {
      final o = Offset(g.laneX(p.lane), p.y);
      if (p.nitro) {
        _nitroIcon(canvas, o, g.carW * 0.34);
      } else {
        _coin(canvas, o, g.carW * 0.28);
      }
    }

    // Cars
    for (final c in g.cars) {
      _car(canvas, Offset(g.laneX(c.lane), c.y), c.color, false);
    }
    if (g.nitroTime > 0) _flames(canvas);
    if (g.phase != Phase.ready) {
      _car(canvas, Offset(g.playerX, g.playerY), g.mySkin.color, true,
          stripe: g.mySkin.stripe);
    }

    // Smash bursts
    for (final b in g.bursts) {
      final a = max(0.0, 1 - b.age / 0.6);
      final r = g.carW * (0.5 + b.age * 2.5);
      canvas.drawCircle(Offset(b.x, b.y), r, Paint()..color = const Color(0xFFFF6F00).withOpacity(a * 0.7));
      canvas.drawCircle(Offset(b.x, b.y), r * 0.55, Paint()..color = const Color(0xFFFFEB3B).withOpacity(a));
    }

    // Crash explosion
    if (g.phase == Phase.over && g.deadTimer < 0.9) {
      final k = g.deadTimer;
      final a = max(0.0, 1 - k * 1.1);
      final r = g.carW * (0.6 + min(k, 0.5) * 2.4);
      final o = Offset(g.crashX, g.crashY);
      canvas.drawCircle(o, r, Paint()..color = const Color(0xFFFF6F00).withOpacity(a * 0.8));
      canvas.drawCircle(o, r * 0.6, Paint()..color = const Color(0xFFFFEB3B).withOpacity(a));
    }

    if (g.phase != Phase.ready) _hud(canvas);
    if (g.phase == Phase.ready) _garage(canvas);
    if (g.phase == Phase.over) _gameOver(canvas);

    if (g.flash > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h),
          Paint()..color = Colors.white.withOpacity(g.flash * 0.6));
    }
  }

  void _hud(Canvas canvas) {
    final w = g.w, h = g.h;
    _text(canvas, '${g.score}', h * 0.06, Offset(w / 2, h * 0.07));
    final cy = h * 0.075;
    _coin(canvas, Offset(w * 0.07, cy), h * 0.014);
    _text(canvas, '${g.coins}', h * 0.026, Offset(w * 0.07 + h * 0.025, cy), left: true);
    _text(canvas, '${g.kmh} km/h', h * 0.022, Offset(w * 0.96, cy), right: true,
        color: g.nitroTime > 0 ? const Color(0xFF80D8FF) : Colors.white);
    if (g.nitroTime > 0) {
      final bw = w * 0.44;
      final bar = Rect.fromCenter(center: Offset(w / 2, h * 0.125), width: bw, height: h * 0.016);
      canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(8)),
          Paint()..color = Colors.black38);
      final fill = Rect.fromLTWH(bar.left, bar.top,
          bw * (g.nitroTime / _GamePageState.nitroLength), bar.height);
      canvas.drawRRect(RRect.fromRectAndRadius(fill, const Radius.circular(8)),
          Paint()..color = const Color(0xFF00B0FF));
      _text(canvas, 'NITRO!', h * 0.024, Offset(w / 2, h * 0.155),
          color: const Color(0xFF80D8FF));
    }
  }

  void _garage(Canvas canvas) {
    final w = g.w, h = g.h;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black45);

    // Wallet and sound switch
    _coin(canvas, Offset(w * 0.07, h * 0.067), h * 0.015);
    _text(canvas, '${g.wallet}', h * 0.028, Offset(w * 0.07 + h * 0.026, h * 0.067), left: true);
    final sr = g.soundRect;
    canvas.drawRRect(RRect.fromRectAndRadius(sr, Radius.circular(sr.height / 2)),
        Paint()..color = Colors.black45);
    _text(canvas, g.sfx.on ? 'Sound: ON' : 'Sound: OFF', h * 0.02, sr.center,
        color: g.sfx.on ? Colors.white : Colors.white54, shadow: false);

    _text(canvas, 'Road Rush', h * 0.06, Offset(w / 2, h * 0.15));
    _text(canvas, 'GARAGE', h * 0.02, Offset(w / 2, h * 0.225), color: const Color(0xFFFFD54F));
    _text(canvas, g.mySkin.name, h * 0.032, Offset(w / 2, h * 0.26));

    // Big preview of the selected car, with arrows to switch
    canvas.save();
    canvas.translate(w / 2, h * 0.4);
    canvas.scale(1.7);
    _car(canvas, Offset.zero, g.mySkin.color, true, stripe: g.mySkin.stripe, tiltOn: false);
    canvas.restore();
    if (!g.skinOwned) {
      _text(canvas, 'LOCKED', h * 0.022, Offset(w / 2, h * 0.4), color: Colors.white);
    }
    _arrow(canvas, g.leftArrowRect.center, true);
    _arrow(canvas, g.rightArrowRect.center, false);
    _text(canvas, '${g.skin + 1} / ${skins.length}', h * 0.018, Offset(w / 2, h * 0.52),
        color: Colors.white70, shadow: false);

    // Main button: start, buy, or not enough coins
    final b = g.mainButtonRect;
    String label;
    Color color;
    if (g.skinOwned) {
      final pulse = 0.85 + 0.15 * sin(g.t * 4).abs();
      label = 'START';
      color = Color.lerp(const Color(0xFF2E7D32), const Color(0xFF43A047), pulse)!;
    } else if (g.wallet >= g.mySkin.price) {
      label = 'BUY  •  ${g.mySkin.price} coins';
      color = const Color(0xFFFF8F00);
    } else {
      label = 'Need ${g.mySkin.price} coins';
      color = const Color(0xFF616161);
    }
    canvas.drawRRect(RRect.fromRectAndRadius(b.shift(const Offset(0, 4)), Radius.circular(b.height / 2)),
        Paint()..color = Colors.black38);
    canvas.drawRRect(RRect.fromRectAndRadius(b, Radius.circular(b.height / 2)),
        Paint()..color = color);
    _text(canvas, label, h * (g.skinOwned ? 0.032 : 0.024), b.center);

    _text(canvas, 'Tap left or right to steer', h * 0.021, Offset(w / 2, h * 0.68));
    _text(canvas, 'Coins buy new cars  •  Blue bolt = NITRO', h * 0.019, Offset(w / 2, h * 0.71));
    if (g.best > 0) {
      _text(canvas, 'Best: ${g.best}', h * 0.024, Offset(w / 2, h * 0.75));
    }
  }

  void _gameOver(Canvas canvas) {
    final w = g.w, h = g.h;
    final panel = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(w / 2, h * 0.42), width: w * 0.78, height: h * 0.36),
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
    _text(canvas, 'Crash!', h * 0.055, c + Offset(0, -h * 0.12), color: const Color(0xFFD32F2F));
    _text(canvas, 'Score: ${g.score}', h * 0.032, c + Offset(0, -h * 0.05),
        color: const Color(0xFF5D4037), shadow: false);
    _text(canvas, '+${g.coins} coins  (total ${g.wallet})', h * 0.022, c + Offset(0, -h * 0.005),
        color: const Color(0xFFFF8F00), shadow: false);
    _text(canvas, g.newBest ? 'New best!' : 'Best: ${g.best}', h * 0.028,
        c + Offset(0, h * 0.045),
        color: g.newBest ? const Color(0xFF2E7D32) : const Color(0xFF5D4037),
        shadow: false);
    if (g.deadTimer > 0.8) {
      _text(canvas, 'Tap to go to the garage', h * 0.022, c + Offset(0, h * 0.115),
          color: const Color(0xFF1565C0), shadow: false);
    }
  }

  void _arrow(Canvas canvas, Offset c, bool left) {
    final r = g.h * 0.032;
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

  void _coin(Canvas canvas, Offset o, double r) {
    canvas.drawCircle(o, r, Paint()..color = const Color(0xFFFFA000));
    canvas.drawCircle(o, r * 0.78, Paint()..color = const Color(0xFFFFD54F));
    canvas.drawCircle(o + Offset(-r * 0.25, -r * 0.25), r * 0.18, Paint()..color = Colors.white70);
  }

  void _nitroIcon(Canvas canvas, Offset o, double r) {
    final glow = 0.5 + 0.5 * sin(g.t * 8).abs();
    canvas.drawCircle(o, r * 1.35, Paint()..color = const Color(0xFF00B0FF).withOpacity(0.25 * glow));
    canvas.drawCircle(o, r, Paint()..color = const Color(0xFF0091EA));
    canvas.drawCircle(o, r * 0.82, Paint()..color = const Color(0xFF40C4FF));
    final bolt = Path()
      ..moveTo(o.dx + r * 0.15, o.dy - r * 0.6)
      ..lineTo(o.dx - r * 0.35, o.dy + r * 0.08)
      ..lineTo(o.dx - r * 0.02, o.dy + r * 0.08)
      ..lineTo(o.dx - r * 0.15, o.dy + r * 0.6)
      ..lineTo(o.dx + r * 0.35, o.dy - r * 0.08)
      ..lineTo(o.dx + r * 0.02, o.dy - r * 0.08)
      ..close();
    canvas.drawPath(bolt, Paint()..color = Colors.white);
  }

  void _flames(Canvas canvas) {
    final cw = g.carW, ch = g.carH;
    final baseY = g.playerY + ch * 0.48;
    for (final sx in [-0.25, 0.25]) {
      final x = g.playerX + sx * cw;
      final len = ch * (0.35 + 0.15 * sin(g.t * 40 + sx * 10).abs());
      final outer = Path()
        ..moveTo(x - cw * 0.13, baseY)
        ..lineTo(x, baseY + len)
        ..lineTo(x + cw * 0.13, baseY)
        ..close();
      final inner = Path()
        ..moveTo(x - cw * 0.07, baseY)
        ..lineTo(x, baseY + len * 0.6)
        ..lineTo(x + cw * 0.07, baseY)
        ..close();
      canvas.drawPath(outer, Paint()..color = const Color(0xFF00B0FF));
      canvas.drawPath(inner, Paint()..color = const Color(0xFFE1F5FE));
    }
  }

  void _car(Canvas c, Offset center, Color color, bool player,
      {Color stripe = Colors.white, bool tiltOn = true}) {
    final cw = g.carW, ch = g.carH;
    c.save();
    c.translate(center.dx, center.dy);
    if (player && tiltOn) c.rotate(g.tilt);

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
      final sp = Paint()..color = stripe;
      c.drawRect(Rect.fromLTWH(-cw * 0.14, -ch * 0.5, cw * 0.08, ch), sp);
      c.drawRect(Rect.fromLTWH(cw * 0.06, -ch * 0.5, cw * 0.08, ch), sp);
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
