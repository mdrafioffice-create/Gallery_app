import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const SkyHopperApp());
}

class SkyHopperApp extends StatelessWidget {
  const SkyHopperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Sky Hopper',
      debugShowCheckedModeBanner: false,
      home: GamePage(),
    );
  }
}

enum Phase { ready, playing, over }

class Pipe {
  Pipe(this.x, this.gapCenter, this.gapSize);
  double x;
  final double gapCenter;
  final double gapSize;
  bool scored = false;
}

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
  double birdY = 0;
  double vel = 0;
  double t = 0;
  double groundOffset = 0;
  double deadTimer = 0;
  double flash = 0;
  final List<Pipe> pipes = [];
  int score = 0;
  int best = 0;
  bool newBest = false;

  // Everything is scaled to the screen so it plays the same on any phone.
  double get w => size.width;
  double get h => size.height;
  double get groundH => h * 0.12;
  double get playH => h - groundH;
  double get birdX => w * 0.3;
  double get birdR => h * 0.022;
  double get pipeW => w * 0.18;
  double get speed => w * (0.42 + min(score, 30) * 0.006);
  double get gravity => h * 2.6;
  double get flapV => -h * 0.78;
  double get nextGap =>
      playH * (score < 10 ? 0.27 : (score < 25 ? 0.245 : 0.22));

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
    if (phase != Phase.over) {
      groundOffset = (groundOffset + speed * dt) % (w * 0.1);
    }

    if (phase == Phase.ready) {
      birdY = playH * 0.45 + sin(t * 5) * h * 0.012;
      vel = 0;
      return;
    }

    vel += gravity * dt;
    birdY += vel * dt;

    if (phase == Phase.over) {
      deadTimer += dt;
      if (birdY > playH - birdR) {
        birdY = playH - birdR;
        vel = 0;
      }
      return;
    }

    // Playing: move pipes, spawn new ones, score, and check hits.
    for (final p in pipes) {
      p.x -= speed * dt;
    }
    pipes.removeWhere((p) => p.x + pipeW < 0);
    if (pipes.isEmpty || pipes.last.x < w * 0.38) {
      final gap = nextGap;
      final minC = playH * 0.12 + gap / 2;
      final maxC = playH * 0.88 - gap / 2;
      pipes.add(Pipe(w + 10, minC + _rng.nextDouble() * (maxC - minC), gap));
    }

    for (final p in pipes) {
      if (!p.scored && p.x + pipeW < birdX - birdR) {
        p.scored = true;
        score++;
        HapticFeedback.selectionClick();
      }
    }

    if (birdY - birdR < 0) {
      birdY = birdR;
      vel = 0;
    }
    if (birdY + birdR >= playH) {
      birdY = playH - birdR;
      _die();
      return;
    }
    for (final p in pipes) {
      final top = Rect.fromLTRB(p.x, -h, p.x + pipeW, p.gapCenter - p.gapSize / 2);
      final bottom =
          Rect.fromLTRB(p.x, p.gapCenter + p.gapSize / 2, p.x + pipeW, playH);
      if (_hits(top) || _hits(bottom)) {
        _die();
        return;
      }
    }
  }

  bool _hits(Rect r) {
    final nx = birdX.clamp(r.left, r.right).toDouble();
    final ny = birdY.clamp(r.top, r.bottom).toDouble();
    final dx = birdX - nx;
    final dy = birdY - ny;
    final rr = birdR * 0.85; // a little forgiving
    return dx * dx + dy * dy < rr * rr;
  }

  void _die() {
    phase = Phase.over;
    deadTimer = 0;
    flash = 1;
    if (vel < 0) vel = 0;
    HapticFeedback.heavyImpact();
    newBest = score > best;
    if (newBest) {
      best = score;
      SharedPreferences.getInstance().then((p) => p.setInt('best', best));
    }
  }

  void _tap() {
    if (phase == Phase.ready) {
      phase = Phase.playing;
      vel = flapV;
    } else if (phase == Phase.playing) {
      vel = flapV;
    } else if (deadTimer > 0.7) {
      phase = Phase.ready;
      pipes.clear();
      score = 0;
      newBest = false;
      vel = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          size = constraints.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _tap(),
            child: CustomPaint(
              size: size,
              painter: GamePainter(this),
            ),
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
    final w = g.w, h = g.h, playH = g.playH;
    if (w == 0) return;

    // Sky
    final sky = Rect.fromLTWH(0, 0, w, playH);
    canvas.drawRect(
      sky,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4FC3F7), Color(0xFFB3E5FC)],
        ).createShader(sky),
    );

    // Sun
    canvas.drawCircle(Offset(w * 0.82, playH * 0.13), h * 0.045,
        Paint()..color = const Color(0xFFFFF59D));

    // Clouds drift slowly in the background
    final cloud = Paint()..color = Colors.white.withOpacity(0.85);
    for (int i = 0; i < 4; i++) {
      final span = w * 1.5;
      final x = ((i * w * 0.42) - g.t * w * 0.03) % span - w * 0.25;
      final y = playH * (0.18 + 0.12 * (i % 3));
      final s = h * (0.025 + 0.006 * (i % 2));
      canvas.drawCircle(Offset(x, y), s, cloud);
      canvas.drawCircle(Offset(x + s * 1.1, y - s * 0.5), s * 1.2, cloud);
      canvas.drawCircle(Offset(x + s * 2.2, y), s, cloud);
      canvas.drawRect(Rect.fromLTRB(x, y - s * 0.2, x + s * 2.2, y + s), cloud);
    }

    // Pipes
    final body = Paint()..color = const Color(0xFF43A047);
    final shine = Paint()..color = const Color(0xFF66BB6A);
    final edge = Paint()
      ..color = const Color(0xFF2E7D32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final capH = h * 0.03;
    final capOut = g.pipeW * 0.08;
    for (final p in g.pipes) {
      final gapTop = p.gapCenter - p.gapSize / 2;
      final gapBottom = p.gapCenter + p.gapSize / 2;
      for (final r in [
        Rect.fromLTRB(p.x, -4, p.x + g.pipeW, gapTop - capH),
        Rect.fromLTRB(p.x, gapBottom + capH, p.x + g.pipeW, playH),
      ]) {
        canvas.drawRect(r, body);
        canvas.drawRect(
            Rect.fromLTWH(r.left + g.pipeW * 0.15, r.top, g.pipeW * 0.12, r.height),
            shine);
        canvas.drawRect(r, edge);
      }
      for (final r in [
        Rect.fromLTRB(p.x - capOut, gapTop - capH, p.x + g.pipeW + capOut, gapTop),
        Rect.fromLTRB(p.x - capOut, gapBottom, p.x + g.pipeW + capOut, gapBottom + capH),
      ]) {
        canvas.drawRect(r, body);
        canvas.drawRect(r, edge);
      }
    }

    // Ground with scrolling stripes
    canvas.drawRect(Rect.fromLTRB(0, playH, w, h),
        Paint()..color = const Color(0xFFDEB887));
    final stripe = Paint()..color = const Color(0xFFCFA673);
    for (double x = -g.groundOffset; x < w; x += w * 0.1) {
      canvas.drawRect(
          Rect.fromLTWH(x, playH + g.groundH * 0.3, w * 0.05, g.groundH * 0.12),
          stripe);
    }
    canvas.drawRect(Rect.fromLTRB(0, playH, w, playH + g.groundH * 0.15),
        Paint()..color = const Color(0xFF7CB342));

    _drawBird(canvas);

    // Text and screens
    if (g.phase == Phase.ready) {
      _text(canvas, 'Sky Hopper', h * 0.065, Offset(w / 2, playH * 0.22));
      _text(canvas, 'Tap to fly!', h * 0.032, Offset(w / 2, playH * 0.64));
      if (g.best > 0) {
        _text(canvas, 'Best: ${g.best}', h * 0.026, Offset(w / 2, playH * 0.72));
      }
    } else {
      _text(canvas, '${g.score}', h * 0.08, Offset(w / 2, h * 0.11));
    }

    if (g.phase == Phase.over) {
      final panel = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(w / 2, playH * 0.45), width: w * 0.75, height: h * 0.3),
        const Radius.circular(24),
      );
      canvas.drawRRect(panel, Paint()..color = const Color(0xEEFFF8E1));
      canvas.drawRRect(
          panel,
          Paint()
            ..color = const Color(0xFFF57F17)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5);
      final c = panel.center;
      _text(canvas, 'Game Over', h * 0.05, c + Offset(0, -h * 0.095),
          color: const Color(0xFFE65100));
      _text(canvas, 'Score: ${g.score}', h * 0.032, c + Offset(0, -h * 0.025),
          color: const Color(0xFF5D4037), shadow: false);
      _text(canvas, g.newBest ? 'New best!' : 'Best: ${g.best}', h * 0.028,
          c + Offset(0, h * 0.03),
          color: g.newBest ? const Color(0xFF2E7D32) : const Color(0xFF5D4037),
          shadow: false);
      if (g.deadTimer > 0.7) {
        _text(canvas, 'Tap to play again', h * 0.024, c + Offset(0, h * 0.09),
            color: const Color(0xFF1565C0), shadow: false);
      }
    }

    if (g.flash > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h),
          Paint()..color = Colors.white.withOpacity(g.flash * 0.6));
    }
  }

  void _drawBird(Canvas canvas) {
    final r = g.birdR;
    double angle = 0;
    if (g.phase != Phase.ready) {
      angle = (g.vel / (g.h * 1.2)).clamp(-0.45, 1.2).toDouble();
    }
    canvas.save();
    canvas.translate(g.birdX, g.birdY);
    canvas.rotate(angle);

    canvas.drawCircle(Offset.zero, r, Paint()..color = const Color(0xFFFFCA28));
    canvas.drawCircle(
        Offset.zero,
        r,
        Paint()
          ..color = const Color(0xFFF57F17)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.12);

    final flap = g.phase == Phase.over ? 0.0 : sin(g.t * 22) * r * 0.25;
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(-r * 0.35, r * 0.15 + flap), width: r * 1.1, height: r * 0.65),
        Paint()..color = const Color(0xFFFFE082));

    canvas.drawCircle(Offset(r * 0.4, -r * 0.35), r * 0.36, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(r * 0.52, -r * 0.35), r * 0.16, Paint()..color = Colors.black);

    final beak = Path()
      ..moveTo(r * 0.75, -r * 0.05)
      ..lineTo(r * 1.4, r * 0.15)
      ..lineTo(r * 0.75, r * 0.4)
      ..close();
    canvas.drawPath(beak, Paint()..color = const Color(0xFFFB8C00));
    canvas.restore();
  }

  void _text(Canvas canvas, String s, double fontSize, Offset center,
      {Color color = Colors.white, bool shadow = true}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: FontWeight.w900,
          shadows: shadow
              ? const [
                  Shadow(color: Colors.black45, offset: Offset(2, 3), blurRadius: 4)
                ]
              : null,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
