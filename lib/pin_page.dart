import 'package:flutter/material.dart';

import 'common.dart';

/// Opens the PIN screen. Creates a PIN first time, otherwise asks for it.
Future<bool> unlockHidden(BuildContext context) async {
  final hasPin = await Pin.isSet();
  if (!context.mounted) return false;
  final ok = await Navigator.push<bool>(
    context,
    MaterialPageRoute(builder: (_) => PinPage(create: !hasPin)),
  );
  return ok == true;
}

/// Makes sure a PIN exists (asks to create one if not).
Future<bool> ensurePinCreated(BuildContext context) async {
  if (await Pin.isSet()) return true;
  if (!context.mounted) return false;
  final ok = await Navigator.push<bool>(
    context,
    MaterialPageRoute(builder: (_) => const PinPage(create: true)),
  );
  return ok == true;
}

class PinPage extends StatefulWidget {
  const PinPage({super.key, required this.create});
  final bool create;

  @override
  State<PinPage> createState() => _PinPageState();
}

class _PinPageState extends State<PinPage> {
  String _entered = '';
  String? _first;
  late String _msg;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _msg = widget.create ? 'Create a 4-digit PIN' : 'Enter your PIN';
  }

  Future<void> _tap(String digit) async {
    if (_entered.length >= 4) return;
    setState(() {
      _entered += digit;
      _error = false;
    });
    if (_entered.length < 4) return;

    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;

    if (widget.create) {
      if (_first == null) {
        setState(() {
          _first = _entered;
          _entered = '';
          _msg = 'Confirm your PIN';
        });
      } else if (_first == _entered) {
        await Pin.set(_entered);
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() {
          _first = null;
          _entered = '';
          _msg = "PINs didn't match. Try again";
          _error = true;
        });
      }
    } else {
      if (await Pin.check(_entered)) {
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() {
          _entered = '';
          _msg = 'Wrong PIN';
          _error = true;
        });
      }
    }
  }

  void _back() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Widget _key(String label) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        width: 72,
        height: 72,
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(shape: const CircleBorder()),
          onPressed: () => _tap(label),
          child: Text(label, style: const TextStyle(fontSize: 26)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Hidden folder')),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Icon(Icons.lock_outline, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              _msg,
              style: TextStyle(
                fontSize: 18,
                color: _error ? Colors.red : null,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) {
                final filled = i < _entered.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? scheme.primary : Colors.transparent,
                    border: Border.all(color: scheme.primary, width: 2),
                  ),
                );
              }),
            ),
            const Spacer(),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [for (final d in row) _key(d)],
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 88),
                _key('0'),
                SizedBox(
                  width: 88,
                  child: IconButton(
                    icon: const Icon(Icons.backspace_outlined),
                    onPressed: _back,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
