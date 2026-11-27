import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const PixelDashApp());
}

class PixelDashApp extends StatelessWidget {
  const PixelDashApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Pixel Dash',
      debugShowCheckedModeBanner: false,
      home: GamePage(),
    );
  }
}

// ---------------------------------------------------------------- levels

// Legend:  X ground   = platform   o coin   E enemy   P player start   F flag
const levels = <List<String>>[
  [
    '                                                                      ',
    '                                                                      ',
    '              ooo                             ooo                     ',
    '             =====            ===             ===            o o o    ',
    '                        ooo              E                  =======   ',
    '        o              =====      o                 o                F',
    '   P        E                           o      E          o          ',
    'XXXXXXXXXXXXXXX   XXXXXXXXXXXXXXXXXX   XXXXXXXXXXXXXXXX   XXXXXXXXXXXXX',
  ],
  [
    '                                                                              ',
    '          ooo                   E           ooo                               ',
    '         =====       ===       ===         =====        ===        o o o      ',
    '                    ooo                              E             =======     ',
    '      o            =====     o        o        =====        o                 ',
    '  P      E    o                  E                     o        E            F',
    '      XXXX        XXXXX      XXXXXXXXX      XXXX     XXXXXXXX       XXXXXXXXXXXX',
    'XXXXXXXXXXXX   XXXXXXXXXXX  XXXXXXXXXX   XXXXXXXXX XXXXXXXXXXX   XXXXXXXXXXXXXXX',
  ],
];

// ---------------------------------------------------------------- model

enum Phase { ready, playing, dead, levelDone, won }

class Enemy {
  Enemy(this.x, this.y);
  double x, y;
  double vx = -70;
  bool dead = false;
  double deadT = 0;
}

class Coin {
  Coin(this.x, this.y);
  final double x, y;
  bool taken = false;
  double spin = 0;
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
  Size size = Size.zero;

  Phase phase = Phase.ready;
  int level = 0;
  int lives = 3;
  int coins = 0;
  int best = 0;

  // world
  double tile = 48;
  int rows = 8;
  int cols = 0;
  late List<String> grid;
  final List<Enemy> enemies = [];
  final List<Coin> coinList = [];
  double flagX = 0;
  double cameraX = 0;

  // player
  double px = 0, py = 0, vx = 0, vy = 0;
  bool onGround = false;
  bool facingRight = true;
  double animT = 0;
  double hurtFlash = 0;
  double winT = 0;

  // input
  final Map<int, String> _pointers = {};
  bool get leftHeld => _pointers.containsValue('left');
  bool get rightHeld => _pointers.containsValue('right');
  bool _jumpHeld = false;

  double get pw => tile * 0.62;
  double get ph => tile * 0.78;
  double get w => size.width;
  double get h => size.height;
  double get levelW => cols * tile;

  static const gravity = 2600.0;
  static const moveSpeed = 250.0;
  static const jumpVel = -900.0;

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

  void _loadLevel(int i) {
    final raw = levels[i];
    final maxLen = raw.map((r) => r.length).reduce(max);
    grid = raw.map((r) => r.padRight(maxLen, ' ')).toList();
    rows = grid.length;
    cols = maxLen;
    enemies.clear();
    coinList.clear();
    flagX = (maxLen - 1) * tile;
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final ch = grid[r][c];
        final x = c * tile, y = r * tile;
        if (ch == 'P') {
          px = x;
          py = y;
          vx = 0;
          vy = 0;
        } else if (ch == 'E') {
          enemies.add(Enemy(x, y));
        } else if (ch == 'o') {
          coinList.add(Coin(x + tile * 0.5, y + tile * 0.5));
        } else if (ch == 'F') {
          flagX = x;
        }
      }
    }
    cameraX = 0;
    facingRight = true;
  }

  bool _solidAt(double x, double y) {
    if (x < 0) return true;
    final c = (x / tile).floor();
    final r = (y / tile).floor();
    if (r < 0) return false;
    if (r >= rows || c < 0 || c >= cols) return false;
    final ch = grid[r][c];
    return ch == 'X' || ch == '=';
  }

  bool _rectSolid(double left, double top, double width, double height) {
    for (double x = left; x <= left + width; x += tile * 0.5) {
      for (double y = top; y <= top + height; y += tile * 0.5) {
        if (_solidAt(x, y)) return true;
      }
      if (_solidAt(x, top + height)) return true;
    }
    for (double y = top; y <= top + height; y += tile * 0.5) {
      if (_solidAt(left + width, y)) return true;
    }
    return false;
  }

  void _onTick(Duration elapsed) {
    double dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt > 1 / 30) dt = 1 / 30;
    if (size == Size.zero) return;
    setState(() => _update(dt));
  }

  void _startLevel() {
    tile = h / (rows == 0 ? 8 : 8);
    tile = h / 8;
    _loadLevel(level);
    phase = Phase.playing;
  }

  void _update(double dt) {
    animT += dt;
    if (hurtFlash > 0) hurtFlash = max(0, hurtFlash - dt * 2);
    for (final c in coinList) {
      c.spin += dt * 6;
    }

    if (phase == Phase.levelDone) {
      winT += dt;
      return;
    }
    if (phase != Phase.playing) return;

    // horizontal input
    double target = 0;
    if (leftHeld) target -= moveSpeed;
    if (rightHeld) target += moveSpeed;
    vx += (target - vx) * min(1.0, dt * 14);
    if (target != 0) facingRight = target > 0;

    // gravity
    vy += gravity * dt;
    if (vy > 1400) vy = 1400;

    // move X then resolve
    px += vx * dt;
    if (_rectSolid(px, py, pw, ph)) {
      // step back until clear
      final dir = vx > 0 ? -1 : 1;
      while (_rectSolid(px, py, pw, ph)) {
        px += dir.toDouble();
      }
      vx = 0;
    }
    if (px < 0) px = 0;

    // move Y then resolve
    py += vy * dt;
    onGround = false;
    if (_rectSolid(px, py, pw, ph)) {
      final dir = vy > 0 ? -1 : 1;
      while (_rectSolid(px, py, pw, ph)) {
        py += dir.toDouble();
      }
      if (vy > 0) onGround = true;
      vy = 0;
    }

    // variable jump height: cut upward speed if released
    if (!_jumpHeld && vy < -300) vy = -300;

    // fell in a pit
    if (py > rows * tile + tile * 2) {
      _hurt(fell: true);
      return;
    }

    // camera
    cameraX = (px + pw / 2 - w * 0.4).clamp(0, max(0.0, levelW - w));

    // coins
    for (final c in coinList) {
      if (c.taken) continue;
      if ((c.x - (px + pw / 2)).abs() < tile * 0.6 &&
          (c.y - (py + ph / 2)).abs() < tile * 0.6) {
        c.taken = true;
        coins++;
        HapticFeedback.selectionClick();
      }
    }

    // enemies
    for (final e in enemies) {
      if (e.dead) {
        e.deadT += dt;
        continue;
      }
      _updateEnemy(e, dt);
      // overlap with player?
      final ew = tile * 0.7, eh = tile * 0.7;
      final overlap = px < e.x + ew &&
          px + pw > e.x &&
          py < e.y + eh &&
          py + ph > e.y;
      if (overlap) {
        final stomp = vy > 0 && (py + ph) - e.y < tile * 0.5;
        if (stomp) {
          e.dead = true;
          vy = jumpVel * 0.6;
          coins += 2;
          HapticFeedback.mediumImpact();
        } else {
          _hurt();
          return;
        }
      }
    }
    enemies.removeWhere((e) => e.dead && e.deadT > 0.5);

    // reached flag
    if (px + pw / 2 >= flagX) {
      phase = Phase.levelDone;
      winT = 0;
      HapticFeedback.mediumImpact();
      if (coins > best) {
        best = coins;
        SharedPreferences.getInstance().then((p) => p.setInt('best', best));
      }
    }
  }

  void _hurt({bool fell = false}) {
    lives--;
    hurtFlash = 1;
    HapticFeedback.heavyImpact();
    if (lives <= 0) {
      phase = Phase.dead;
      if (coins > best) {
        best = coins;
        SharedPreferences.getInstance().then((p) => p.setInt('best', best));
      }
    } else {
      _loadLevel(level); // respawn, keep lives & coins
    }
  }

  void _updateEnemy(Enemy e, double dt) {
    final t = tile;
    e.x += e.vx * dt;
    final midY = e.y + t * 0.36;
    // bounce off walls
    final aheadX = e.vx > 0 ? e.x + t * 0.7 : e.x;
    if (_solidAt(aheadX, midY)) {
      e.vx = -e.vx;
      e.x += e.vx * dt * 2;
    }
    // settle on the ground (or fall)
    final footY = e.y + t * 0.72;
    final grounded = _solidAt(e.x + t * 0.35, footY + 2);
    if (grounded) {
      final groundTop = ((footY + 2) / t).floor() * t;
      e.y = groundTop - t * 0.72;
      // turn at a ledge so it doesn't walk off
      final aheadFoot = e.vx > 0 ? e.x + t * 0.62 : e.x + t * 0.08;
      if (!_solidAt(aheadFoot, footY + t * 0.4)) {
        e.vx = -e.vx;
      }
    } else {
      e.y += 420 * dt;
    }
    if (e.y > rows * t + t * 2) e.dead = true;
  }

  void _advance() {
    if (level + 1 < levels.length) {
      level++;
      _loadLevel(level);
      phase = Phase.playing;
    } else {
      phase = Phase.won;
    }
  }

  // ------------------------------------------------- input handling

  void _down(PointerDownEvent e) {
    final zone = _zoneFor(e.localPosition);
    if (phase == Phase.ready) {
      level = 0;
      lives = 3;
      coins = 0;
      _startLevel();
      return;
    }
    if (phase == Phase.dead || phase == Phase.won) {
      phase = Phase.ready;
      return;
    }
    if (phase == Phase.levelDone) {
      if (winT > 0.6) _advance();
      return;
    }
    // playing
    _pointers[e.pointer] = zone;
    if (zone == 'jump') {
      _jumpHeld = true;
      if (onGround) {
        vy = jumpVel;
        onGround = false;
      }
    }
  }

  void _move(PointerMoveEvent e) {
    if (phase != Phase.playing) return;
    if (_pointers.containsKey(e.pointer) && _pointers[e.pointer] != 'jump') {
      _pointers[e.pointer] = _zoneFor(e.localPosition);
    }
  }

  void _up(PointerUpEvent e) {
    if (_pointers[e.pointer] == 'jump') _jumpHeld = false;
    _pointers.remove(e.pointer);
  }

  String _zoneFor(Offset p) {
    if (jumpRect.contains(p)) return 'jump';
    if (leftRect.contains(p)) return 'left';
    if (rightRect.contains(p)) return 'right';
    return 'none';
  }

  double get _btn => h * 0.26;
  Rect get leftRect =>
      Rect.fromLTWH(w * 0.02, h - _btn - 12, _btn, _btn);
  Rect get rightRect =>
      Rect.fromLTWH(w * 0.02 + _btn + 10, h - _btn - 12, _btn, _btn);
  Rect get jumpRect =>
      Rect.fromLTWH(w - _btn - w * 0.02, h - _btn - 12, _btn, _btn);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF4FC3F7),
      body: LayoutBuilder(
        builder: (context, constraints) {
          size = constraints.biggest;
          if (cols == 0) {
            tile = h / 8;
            _loadLevel(0);
          }
          return Listener(
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: (e) {
              if (_pointers[e.pointer] == 'jump') _jumpHeld = false;
              _pointers.remove(e.pointer);
            },
            child: CustomPaint(size: size, painter: GamePainter(this)),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- painter

class GamePainter extends CustomPainter {
  GamePainter(this.g);
  final _GamePageState g;

  @override
  void paint(Canvas canvas, Size size) {
    final w = g.w, h = g.h;
    if (w == 0 || g.cols == 0) return;
    final tile = g.tile;

    // sky
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4FC3F7), Color(0xFFB3E5FC)],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );
    // parallax clouds & hills
    final cloud = Paint()..color = Colors.white.withOpacity(0.85);
    for (int i = 0; i < 6; i++) {
      final cx = (i * w * 0.4 - g.cameraX * 0.3) % (w * 1.6) - w * 0.3;
      final cy = h * (0.12 + 0.07 * (i % 3));
      canvas.drawCircle(Offset(cx, cy), tile * 0.5, cloud);
      canvas.drawCircle(Offset(cx + tile * 0.5, cy - tile * 0.2), tile * 0.6, cloud);
      canvas.drawCircle(Offset(cx + tile, cy), tile * 0.5, cloud);
    }
    final hill = Paint()..color = const Color(0xFF81C784);
    for (int i = 0; i < 8; i++) {
      final cx = (i * w * 0.3 - g.cameraX * 0.5) % (w * 1.8) - w * 0.3;
      canvas.drawCircle(Offset(cx, h), tile * 2.2, hill);
    }

    canvas.save();
    canvas.translate(-g.cameraX, 0);

    // tiles (only visible columns)
    final c0 = (g.cameraX / tile).floor().clamp(0, g.cols - 1);
    final c1 = ((g.cameraX + w) / tile).ceil().clamp(0, g.cols);
    for (int r = 0; r < g.rows; r++) {
      for (int c = c0; c < c1; c++) {
        final ch = g.grid[r][c];
        final x = c * tile, y = r * tile;
        if (ch == 'X') {
          _ground(canvas, x, y, tile, r > 0 ? g.grid[r - 1][c] : ' ');
        } else if (ch == '=') {
          _platform(canvas, x, y, tile);
        }
      }
    }

    // flag
    _flag(canvas, g.flagX, tile);

    // coins
    for (final coin in g.coinList) {
      if (coin.taken) continue;
      final sq = (sin(coin.spin) * 0.5 + 0.5);
      final rw = tile * 0.22 * (0.4 + 0.6 * sq);
      canvas.drawOval(
          Rect.fromCenter(center: Offset(coin.x, coin.y), width: rw * 2, height: tile * 0.44),
          Paint()..color = const Color(0xFFFFA000));
      canvas.drawOval(
          Rect.fromCenter(center: Offset(coin.x, coin.y), width: rw * 1.3, height: tile * 0.3),
          Paint()..color = const Color(0xFFFFD54F));
    }

    // enemies
    for (final e in g.enemies) {
      _enemy(canvas, e, tile);
    }

    // player
    _hero(canvas, tile);

    canvas.restore();

    // HUD
    _hud(canvas);
    // controls
    if (g.phase == Phase.playing) _controls(canvas);

    if (g.hurtFlash > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h),
          Paint()..color = const Color(0xFFD50000).withOpacity(g.hurtFlash * 0.35));
    }

    if (g.phase == Phase.ready) _center(canvas, 'PIXEL DASH', 'Tap to start', true);
    if (g.phase == Phase.levelDone) {
      _center(canvas, 'Level ${g.level + 1} clear!',
          g.winT > 0.6 ? 'Tap to continue' : '', false);
    }
    if (g.phase == Phase.dead) {
      _center(canvas, 'Game Over', 'Coins: ${g.coins}   •   Tap to retry', false);
    }
    if (g.phase == Phase.won) {
      _center(canvas, 'You win! 🎉', 'Coins: ${g.coins}   •   Tap to play again', false);
    }
  }

  void _ground(Canvas c, double x, double y, double t, String above) {
    final top = above != 'X';
    c.drawRect(Rect.fromLTWH(x, y, t, t), Paint()..color = const Color(0xFF6D4C41));
    c.drawRect(Rect.fromLTWH(x, y, t, t),
        Paint()..color = const Color(0xFF4E342E)..style = PaintingStyle.stroke..strokeWidth = 1);
    if (top) {
      c.drawRect(Rect.fromLTWH(x, y, t, t * 0.28),
          Paint()..color = const Color(0xFF7CB342));
      c.drawRect(Rect.fromLTWH(x, y + t * 0.28, t, t * 0.06),
          Paint()..color = const Color(0xFF558B2F));
    }
    // speckles
    c.drawCircle(Offset(x + t * 0.3, y + t * 0.6), 2, Paint()..color = const Color(0x33000000));
    c.drawCircle(Offset(x + t * 0.7, y + t * 0.8), 2, Paint()..color = const Color(0x33000000));
  }

  void _platform(Canvas c, double x, double y, double t) {
    final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, t, t * 0.5), const Radius.circular(6));
    c.drawRRect(r, Paint()..color = const Color(0xFF8D6E63));
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, t, t * 0.16), const Radius.circular(6)),
        Paint()..color = const Color(0xFFA1887F));
  }

  void _flag(Canvas c, double fx, double t) {
    final groundY = (g.rows - 1) * t;
    c.drawRect(Rect.fromLTWH(fx - 3, t * 1.2, 6, groundY - t * 1.2),
        Paint()..color = const Color(0xFFCFD8DC));
    final path = Path()
      ..moveTo(fx + 3, t * 1.2)
      ..lineTo(fx + t * 0.8, t * 1.5)
      ..lineTo(fx + 3, t * 1.8)
      ..close();
    c.drawPath(path, Paint()..color = const Color(0xFFE53935));
    c.drawCircle(Offset(fx, t * 1.2), 7, Paint()..color = const Color(0xFFFFD54F));
  }

  void _coinShine(Canvas c, Offset o, double r) {}

  void _enemy(Canvas c, Enemy e, double t) {
    final cx = e.x + t * 0.35;
    final flat = e.dead ? 0.4 : 1.0;
    final cy = e.y + t * 0.36 + (e.dead ? t * 0.2 : 0);
    final rw = t * 0.33;
    final rh = t * 0.3 * flat;
    // feet
    if (!e.dead) {
      final sw = sin(g.animT * 14) * t * 0.06;
      c.drawOval(Rect.fromCenter(center: Offset(cx - t * 0.14 + sw, cy + rh), width: t * 0.14, height: t * 0.1),
          Paint()..color = const Color(0xFF4E342E));
      c.drawOval(Rect.fromCenter(center: Offset(cx + t * 0.14 - sw, cy + rh), width: t * 0.14, height: t * 0.1),
          Paint()..color = const Color(0xFF4E342E));
    }
    // body
    c.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: rw * 2, height: rh * 2),
        Paint()..color = const Color(0xFF7E57C2));
    c.drawOval(Rect.fromCenter(center: Offset(cx, cy + rh * 0.3), width: rw * 1.3, height: rh),
        Paint()..color = const Color(0xFF9575CD));
    if (!e.dead) {
      // angry eyes
      for (final sx in [-1.0, 1.0]) {
        c.drawCircle(Offset(cx + sx * rw * 0.4, cy - rh * 0.3), rw * 0.22, Paint()..color = Colors.white);
        c.drawCircle(Offset(cx + sx * rw * 0.4 + (e.vx > 0 ? 2 : -2), cy - rh * 0.3), rw * 0.11, Paint()..color = Colors.black);
      }
      c.drawLine(Offset(cx - rw * 0.6, cy - rh * 0.7), Offset(cx - rw * 0.15, cy - rh * 0.45),
          Paint()..color = Colors.black..strokeWidth = 2);
      c.drawLine(Offset(cx + rw * 0.6, cy - rh * 0.7), Offset(cx + rw * 0.15, cy - rh * 0.45),
          Paint()..color = Colors.black..strokeWidth = 2);
    } else {
      c.drawLine(Offset(cx - rw * 0.3, cy - rh * 0.2), Offset(cx - rw * 0.1, cy),
          Paint()..color = Colors.black..strokeWidth = 2);
      c.drawLine(Offset(cx + rw * 0.3, cy - rh * 0.2), Offset(cx + rw * 0.1, cy),
          Paint()..color = Colors.black..strokeWidth = 2);
    }
  }

  void _hero(Canvas c, double t) {
    final cx = g.px + g.pw / 2;
    final bodyCy = g.py + g.ph * 0.5;
    final r = g.pw * 0.5;
    final moving = (g.vx).abs() > 20 && g.onGround;
    final legSwing = moving ? sin(g.animT * 16) * t * 0.08 : 0.0;
    final squash = g.onGround ? 1.0 : 1.08;

    c.save();
    c.translate(cx, bodyCy);
    if (!g.facingRight) c.scale(-1, 1);

    // shadow
    c.drawOval(Rect.fromCenter(center: Offset(0, g.ph * 0.52), width: g.pw * 1.1, height: g.ph * 0.14),
        Paint()..color = Colors.black.withOpacity(0.2));
    // feet
    final feet = Paint()..color = const Color(0xFFEF6C00);
    c.drawOval(Rect.fromCenter(center: Offset(-r * 0.4 + legSwing, g.ph * 0.42), width: r * 0.5, height: r * 0.3), feet);
    c.drawOval(Rect.fromCenter(center: Offset(r * 0.4 - legSwing, g.ph * 0.42), width: r * 0.5, height: r * 0.3), feet);
    // body
    final body = Rect.fromCenter(center: Offset.zero, width: g.pw * (2 - squash), height: g.ph * squash);
    c.drawOval(body, Paint()..color = const Color(0xFFFF8F00));
    c.drawOval(Rect.fromCenter(center: Offset(0, g.ph * 0.12), width: g.pw * 0.7, height: g.ph * 0.55),
        Paint()..color = const Color(0xFFFFE0B2));
    // antenna
    c.drawLine(Offset(0, -g.ph * 0.5), Offset(0, -g.ph * 0.68),
        Paint()..color = const Color(0xFFFF8F00)..strokeWidth = r * 0.14);
    c.drawCircle(Offset(0, -g.ph * 0.72), r * 0.16, Paint()..color = const Color(0xFFFFD54F));
    // eyes
    for (final sx in [-1.0, 1.0]) {
      c.drawCircle(Offset(sx * r * 0.42, -r * 0.25), r * 0.3, Paint()..color = Colors.white);
      c.drawCircle(Offset(sx * r * 0.42 + r * 0.12, -r * 0.25), r * 0.14, Paint()..color = Colors.black);
    }
    // cheeks
    for (final sx in [-1.0, 1.0]) {
      c.drawCircle(Offset(sx * r * 0.7, r * 0.05), r * 0.13, Paint()..color = const Color(0xFFFFAB91));
    }
    c.restore();
  }

  void _hud(Canvas c) {
    final h = g.h, w = g.w;
    _text(c, 'LVL ${g.level + 1}', h * 0.045, Offset(w * 0.03, h * 0.04), left: true);
    // coins
    c.drawCircle(Offset(w * 0.5 - h * 0.03, h * 0.06), h * 0.018, Paint()..color = const Color(0xFFFFD54F));
    _text(c, '${g.coins}', h * 0.05, Offset(w * 0.5, h * 0.06), left: true);
    // lives
    for (int i = 0; i < g.lives; i++) {
      final x = w - w * 0.03 - i * h * 0.06;
      c.drawCircle(Offset(x, h * 0.06), h * 0.02, Paint()..color = const Color(0xFFFF8F00));
      c.drawCircle(Offset(x + h * 0.006, h * 0.055), h * 0.006, Paint()..color = Colors.black);
    }
  }

  void _controls(Canvas c) {
    final o = Paint()..color = Colors.white.withOpacity(0.3);
    final icon = Paint()..color = Colors.white.withOpacity(0.9);
    for (final e in [
      [g.leftRect, 'L'],
      [g.rightRect, 'R'],
      [g.jumpRect, 'J'],
    ]) {
      final r = e[0] as Rect;
      c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.3)), o);
      final cx = r.center.dx, cy = r.center.dy, s = r.width * 0.2;
      if (e[1] == 'L') {
        final p = Path()..moveTo(cx + s * 0.6, cy - s)..lineTo(cx - s * 0.6, cy)..lineTo(cx + s * 0.6, cy + s)..close();
        c.drawPath(p, icon);
      } else if (e[1] == 'R') {
        final p = Path()..moveTo(cx - s * 0.6, cy - s)..lineTo(cx + s * 0.6, cy)..lineTo(cx - s * 0.6, cy + s)..close();
        c.drawPath(p, icon);
      } else {
        final p = Path()..moveTo(cx, cy - s)..lineTo(cx - s, cy + s * 0.5)..lineTo(cx + s, cy + s * 0.5)..close();
        c.drawPath(p, icon);
        _text(c, 'JUMP', r.height * 0.14, Offset(cx, cy + s * 1.2));
      }
    }
  }

  void _center(Canvas c, String title, String sub, bool hero) {
    final w = g.w, h = g.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black38);
    _text(c, title, h * 0.11, Offset(w / 2, h * 0.38));
    if (sub.isNotEmpty) _text(c, sub, h * 0.045, Offset(w / 2, h * 0.55));
    _text(c, g.best > 0 ? 'Best coins: ${g.best}' : '', h * 0.035, Offset(w / 2, h * 0.64),
        color: const Color(0xFFFFE082));
  }

  void _text(Canvas canvas, String s, double fontSize, Offset at,
      {Color color = Colors.white, bool left = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: FontWeight.w900,
          shadows: const [Shadow(color: Colors.black54, offset: Offset(2, 2), blurRadius: 3)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(left ? 0 : tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
