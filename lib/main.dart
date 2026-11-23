import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.init();
  runApp(const SafetyApp());
}

// ------------------------------------------------------------- storage

class Store {
  static late SharedPreferences p;
  static Future<void> init() async => p = await SharedPreferences.getInstance();

  static String? get role => p.getString('role');
  static set role(String? v) =>
      v == null ? p.remove('role') : p.setString('role', v);

  static String get childName => p.getString('childName') ?? '';
  static set childName(String v) => p.setString('childName', v);

  static String get bloodType => p.getString('bloodType') ?? '';
  static set bloodType(String v) => p.setString('bloodType', v);
  static String get allergies => p.getString('allergies') ?? '';
  static set allergies(String v) => p.setString('allergies', v);
  static String get notes => p.getString('notes') ?? '';
  static set notes(String v) => p.setString('notes', v);

  static List<Map<String, String>> get guardians {
    final s = p.getString('guardians');
    if (s == null) return [];
    return (json.decode(s) as List)
        .map((e) => Map<String, String>.from(e as Map))
        .toList();
  }

  static set guardians(List<Map<String, String>> v) =>
      p.setString('guardians', json.encode(v));

  // Parent-side: details of the child this phone watches
  static String get parentChildName => p.getString('pChildName') ?? '';
  static set parentChildName(String v) => p.setString('pChildName', v);
  static String get parentChildPhone => p.getString('pChildPhone') ?? '';
  static set parentChildPhone(String v) => p.setString('pChildPhone', v);
}

// ------------------------------------------------------------- helpers

Future<String?> locationLink() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high));
    return 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
  } catch (_) {
    return null;
  }
}

Future<bool> sendSms(List<String> numbers, String body) async {
  final nums = numbers.where((n) => n.trim().isNotEmpty).toList();
  if (nums.isEmpty) return false;
  final uri = Uri.parse('sms:${nums.join(',')}?body=${Uri.encodeComponent(body)}');
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<void> dialNumber(String number) async {
  final uri = Uri.parse('tel:$number');
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

const teal = Color(0xFF00897B);
const tealDark = Color(0xFF00695C);

// ------------------------------------------------------------- app

class SafetyApp extends StatelessWidget {
  const SafetyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Safety',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: teal, primary: teal, brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF2F6F5),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      home: const RootPage(),
    );
  }
}

class RootPage extends StatefulWidget {
  const RootPage({super.key});
  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final role = Store.role;
    if (role == null) return RolePage(onDone: _refresh);
    if (role == 'parent') return ParentHome(onReset: _refresh);
    if (Store.guardians.isEmpty) {
      return ChildSetup(onDone: _refresh, first: true);
    }
    return ChildHome(onReset: _refresh);
  }
}

// ------------------------------------------------------------- role pick

class RolePage extends StatelessWidget {
  const RolePage({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.shield, size: 72, color: teal),
              const SizedBox(height: 12),
              const Text('Family Safety',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Whose phone is this?',
                  style: TextStyle(fontSize: 16, color: Colors.black54)),
              const SizedBox(height: 32),
              _card(
                context,
                Icons.child_care,
                "My child's phone",
                'Shows the SOS, check-in and safe-walk buttons. Taps send a text with their location to you.',
                () {
                  Store.role = 'child';
                  onDone();
                },
              ),
              const SizedBox(height: 16),
              _card(
                context,
                Icons.family_restroom,
                'My phone (parent)',
                'Receive your child\'s alerts and reach them fast.',
                () {
                  Store.role = 'parent';
                  onDone();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, IconData icon, String title, String body,
      VoidCallback onTap) {
    return Card(
      elevation: 1,
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
                  backgroundColor: teal.withOpacity(0.12),
                  child: Icon(icon, color: teal, size: 30)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(body,
                        style: const TextStyle(
                            fontSize: 13.5, color: Colors.black54, height: 1.3)),
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

// ------------------------------------------------------------- child setup

class ChildSetup extends StatefulWidget {
  const ChildSetup({super.key, required this.onDone, this.first = false});
  final VoidCallback onDone;
  final bool first;
  @override
  State<ChildSetup> createState() => _ChildSetupState();
}

class _ChildSetupState extends State<ChildSetup> {
  late final TextEditingController _name =
      TextEditingController(text: Store.childName);
  late final TextEditingController _blood =
      TextEditingController(text: Store.bloodType);
  late final TextEditingController _allergy =
      TextEditingController(text: Store.allergies);
  late final TextEditingController _notes =
      TextEditingController(text: Store.notes);
  late List<Map<String, String>> _guardians =
      Store.guardians.map((e) => {...e}).toList();

  @override
  void initState() {
    super.initState();
    if (_guardians.isEmpty) _guardians.add({'name': '', 'phone': ''});
  }

  void _save() {
    final clean = _guardians
        .where((g) => (g['phone'] ?? '').trim().isNotEmpty)
        .toList();
    if (clean.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add at least one guardian with a phone number.')));
      return;
    }
    Store.childName = _name.text.trim();
    Store.bloodType = _blood.text.trim();
    Store.allergies = _allergy.text.trim();
    Store.notes = _notes.text.trim();
    Store.guardians = clean;
    widget.onDone();
    if (!widget.first && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.first ? 'Set up' : 'Edit details'),
        backgroundColor: teal,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _label('Child\'s name'),
          TextField(
              controller: _name,
              decoration: _dec('e.g. Aarav')),
          const SizedBox(height: 20),
          _label('Guardians to alert'),
          const Text('They receive the SOS, check-in and safe-walk texts.',
              style: TextStyle(fontSize: 13, color: Colors.black54)),
          const SizedBox(height: 10),
          ..._guardians.asMap().entries.map((e) => _guardianRow(e.key)),
          TextButton.icon(
            onPressed: () =>
                setState(() => _guardians.add({'name': '', 'phone': ''})),
            icon: const Icon(Icons.add),
            label: const Text('Add another guardian'),
          ),
          const SizedBox(height: 12),
          _label('Emergency info (optional)'),
          TextField(
              controller: _blood, decoration: _dec('Blood type, e.g. O+')),
          const SizedBox(height: 10),
          TextField(
              controller: _allergy, decoration: _dec('Allergies')),
          const SizedBox(height: 10),
          TextField(
              controller: _notes,
              maxLines: 2,
              decoration: _dec('Other notes (doctor, conditions)')),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _guardianRow(int i) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: TextField(
              controller: TextEditingController(text: _guardians[i]['name']),
              onChanged: (v) => _guardians[i]['name'] = v,
              decoration: _dec('Name'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: TextField(
              controller: TextEditingController(text: _guardians[i]['phone']),
              keyboardType: TextInputType.phone,
              onChanged: (v) => _guardians[i]['phone'] = v,
              decoration: _dec('Phone'),
            ),
          ),
          if (_guardians.length > 1)
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
              onPressed: () => setState(() => _guardians.removeAt(i)),
            ),
        ],
      ),
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300)),
      );
}

// ------------------------------------------------------------- child home

class ChildHome extends StatefulWidget {
  const ChildHome({super.key, required this.onReset});
  final VoidCallback onReset;
  @override
  State<ChildHome> createState() => _ChildHomeState();
}

class _ChildHomeState extends State<ChildHome> {
  bool _busy = false;

  List<String> get _numbers =>
      Store.guardians.map((g) => g['phone'] ?? '').toList();

  String get _who => Store.childName.trim().isEmpty ? 'I' : Store.childName.trim();

  Future<void> _send(String label, String Function(String?) build) async {
    setState(() => _busy = true);
    final link = await locationLink();
    final ok = await sendSms(_numbers, build(link));
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '$label ready — tap send in your messages app.'
          : 'Could not open messages. Check your guardians\' numbers.'),
    ));
  }

  void _sos() => _send('SOS', (link) =>
      '🚨 EMERGENCY — $_who needs help now. '
      '${link != null ? 'Location: $link' : '(location unavailable)'}');

  void _safe() => _send('Check-in', (link) =>
      '✅ $_who arrived safely. '
      '${link != null ? 'Location: $link' : ''}');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Safety'),
        backgroundColor: teal,
        foregroundColor: Colors.white,
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            ChildSetup(onDone: () => setState(() {}))));
              } else if (v == 'role') {
                _confirmSwitch();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit details')),
              PopupMenuItem(value: 'role', child: Text('Switch phone role')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              // SOS
              Expanded(
                flex: 5,
                child: _SosButton(busy: _busy, onTap: _busy ? null : _sos),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _tile(Icons.check_circle, 'I\'m safe',
                        const Color(0xFF2E7D32), _busy ? null : _safe),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _tile(Icons.timer, 'Safe walk', const Color(0xFF1565C0),
                        () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => SafeWalkPage(
                                    numbers: _numbers, who: _who)))),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: _tile(Icons.medical_information, 'Emergency info',
                    const Color(0xFF00897B), () {
                  Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const EmergencyCard()));
                }, wide: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(IconData icon, String label, Color color, VoidCallback? onTap,
      {bool wide = false}) {
    return Material(
      color: color.withOpacity(onTap == null ? 0.4 : 1),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: wide ? 16 : 22),
          child: wide
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: Colors.white, size: 26),
                    const SizedBox(width: 10),
                    Text(label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600)),
                  ],
                )
              : Column(
                  children: [
                    Icon(icon, color: Colors.white, size: 30),
                    const SizedBox(height: 8),
                    Text(label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
        ),
      ),
    );
  }

  void _confirmSwitch() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Switch phone role?'),
        content: const Text(
            'This returns to the first screen where you pick child or parent. Your saved details stay.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                Store.role = null;
                Navigator.pop(context);
                widget.onReset();
              },
              child: const Text('Switch')),
        ],
      ),
    );
  }
}

class _SosButton extends StatefulWidget {
  const _SosButton({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback? onTap;
  @override
  State<_SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<_SosButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final s = 1 + _c.value * 0.04;
          return Center(
            child: Transform.scale(
              scale: widget.busy ? 1 : s,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                      colors: [Color(0xFFFF5252), Color(0xFFD32F2F)]),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.red.withOpacity(0.4),
                        blurRadius: 30,
                        spreadRadius: 4)
                  ],
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Center(
                    child: widget.busy
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.warning_amber_rounded,
                                  color: Colors.white, size: 56),
                              SizedBox(height: 8),
                              Text('SOS',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 44,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2)),
                              Text('Tap to alert guardians',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 13)),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------- safe walk

class SafeWalkPage extends StatefulWidget {
  const SafeWalkPage({super.key, required this.numbers, required this.who});
  final List<String> numbers;
  final String who;
  @override
  State<SafeWalkPage> createState() => _SafeWalkPageState();
}

class _SafeWalkPageState extends State<SafeWalkPage> {
  int _minutes = 15;
  Timer? _timer;
  int _remaining = 0;
  bool _running = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() {
      _running = true;
      _remaining = _minutes * 60;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        _expire();
      } else {
        setState(() => _remaining--);
      }
    });
  }

  Future<void> _expire() async {
    setState(() => _running = false);
    final link = await locationLink();
    await sendSms(
        widget.numbers,
        '⚠️ ${widget.who} started a safe-walk timer and did not check in on time. '
        '${link != null ? 'Last location: $link' : ''}');
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Timer ended'),
        content: const Text(
            'An alert was prepared for your guardians — tap send in your messages app.'),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK')),
        ],
      ),
    );
  }

  void _arrived() {
    _timer?.cancel();
    setState(() => _running = false);
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Safe-walk timer cancelled. Glad you made it!')));
  }

  String get _clock {
    final m = (_remaining ~/ 60).toString().padLeft(2, '0');
    final s = (_remaining % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safe walk'),
        backgroundColor: teal,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _running
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Checking in by',
                      style: TextStyle(fontSize: 18, color: Colors.black54)),
                  const SizedBox(height: 12),
                  Text(_clock,
                      style: const TextStyle(
                          fontSize: 72,
                          fontWeight: FontWeight.bold,
                          color: tealDark)),
                  const SizedBox(height: 12),
                  const Text(
                      'If you don\'t tap "I made it" before this reaches zero, your guardians get an alert with your location.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32)),
                    onPressed: _arrived,
                    icon: const Icon(Icons.check_circle),
                    label: const Text('I made it safely'),
                  ),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.directions_walk, size: 64, color: teal),
                  const SizedBox(height: 16),
                  const Text('How long is your walk?',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        iconSize: 32,
                        onPressed: _minutes > 5
                            ? () => setState(() => _minutes -= 5)
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      SizedBox(
                        width: 120,
                        child: Text('$_minutes min',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 28, fontWeight: FontWeight.bold)),
                      ),
                      IconButton.filledTonal(
                        iconSize: 32,
                        onPressed: _minutes < 120
                            ? () => setState(() => _minutes += 5)
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  FilledButton(
                      onPressed: widget.numbers
                              .any((n) => n.trim().isNotEmpty)
                          ? _start
                          : null,
                      child: const Text('Start timer')),
                  if (!widget.numbers.any((n) => n.trim().isNotEmpty))
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('Add a guardian first in Edit details.',
                          style: TextStyle(color: Colors.red)),
                    ),
                ],
              ),
      ),
    );
  }
}

// ------------------------------------------------------------- emergency card

class EmergencyCard extends StatelessWidget {
  const EmergencyCard({super.key});

  @override
  Widget build(BuildContext context) {
    final rows = <List<String>>[
      ['Name', Store.childName],
      ['Blood type', Store.bloodType],
      ['Allergies', Store.allergies],
      ['Notes', Store.notes],
    ].where((r) => r[1].trim().isNotEmpty).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergency info'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEBEE),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFD32F2F), width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.medical_information, color: Color(0xFFD32F2F)),
                  SizedBox(width: 8),
                  Text('IN CASE OF EMERGENCY',
                      style: TextStyle(
                          color: Color(0xFFD32F2F),
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                ]),
                const Divider(height: 24),
                if (rows.isEmpty)
                  const Text('No info added yet — add it in Edit details.',
                      style: TextStyle(color: Colors.black54))
                else
                  ...rows.map((r) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r[0].toUpperCase(),
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black45,
                                    fontWeight: FontWeight.w600)),
                            Text(r[1],
                                style: const TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      )),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('Guardians',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...Store.guardians.map((g) => Card(
                child: ListTile(
                  leading: const CircleAvatar(
                      backgroundColor: teal,
                      child: Icon(Icons.person, color: Colors.white)),
                  title: Text(
                      (g['name'] ?? '').trim().isEmpty ? 'Guardian' : g['name']!),
                  subtitle: Text(g['phone'] ?? ''),
                  trailing: IconButton(
                    icon: const Icon(Icons.call, color: teal),
                    onPressed: () => dialNumber(g['phone'] ?? ''),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- parent home

class ParentHome extends StatefulWidget {
  const ParentHome({super.key, required this.onReset});
  final VoidCallback onReset;
  @override
  State<ParentHome> createState() => _ParentHomeState();
}

class _ParentHomeState extends State<ParentHome> {
  @override
  Widget build(BuildContext context) {
    final name = Store.parentChildName.trim();
    final phone = Store.parentChildPhone.trim();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Safety'),
        backgroundColor: teal,
        foregroundColor: Colors.white,
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'role') {
                Store.role = null;
                widget.onReset();
              }
            },
            itemBuilder: (_) =>
                const [PopupMenuItem(value: 'role', child: Text('Switch phone role'))],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your child',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.black54,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(name.isEmpty ? 'Not set yet' : name,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  Text(phone.isEmpty ? '' : phone,
                      style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: phone.isEmpty
                              ? null
                              : () => dialNumber(phone),
                          icon: const Icon(Icons.call),
                          label: const Text('Call'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF1565C0)),
                          onPressed: phone.isEmpty
                              ? null
                              : () => sendSms([phone], 'Checking in — are you okay?'),
                          icon: const Icon(Icons.message),
                          label: const Text('Text'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _editChild,
                    icon: const Icon(Icons.edit),
                    label: Text(name.isEmpty
                        ? 'Add your child\'s details'
                        : 'Edit child details'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _info(
            Icons.notifications_active,
            'What you\'ll receive',
            'When your child taps SOS, checks in, or a safe-walk timer runs out, you get a text from their phone with a Google Maps link to their location. No internet needed on either side.',
          ),
          _info(
            Icons.map,
            'Live map (optional, later)',
            'Watching your child\'s location continuously on a map needs a free online server (like Firebase) connected to both phones. The app is ready for it — ask to have it set up when you want it.',
          ),
          _info(
            Icons.verified_user,
            'Honest and open',
            'This app only sends what your child chooses to send. Keeping monitoring open and talking about it is the safest approach for everyone.',
          ),
        ],
      ),
    );
  }

  Widget _info(IconData icon, String title, String body) => Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: teal),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(body,
                        style: const TextStyle(
                            fontSize: 14, color: Colors.black54, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  void _editChild() {
    final nameC = TextEditingController(text: Store.parentChildName);
    final phoneC = TextEditingController(text: Store.parentChildPhone);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Your child'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameC,
                decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 10),
            TextField(
                controller: phoneC,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                Store.parentChildName = nameC.text.trim();
                Store.parentChildPhone = phoneC.text.trim();
                Navigator.pop(context);
                setState(() {});
              },
              child: const Text('Save')),
        ],
      ),
    );
  }
}
