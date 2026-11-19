import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Favourite photo/video IDs, saved on the phone.
class Favs {
  static final ValueNotifier<Set<String>> ids = ValueNotifier(<String>{});

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    ids.value = (p.getStringList('favs') ?? <String>[]).toSet();
  }

  static bool isFav(String id) => ids.value.contains(id);

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('favs', ids.value.toList());
  }

  static Future<void> toggle(String id) async {
    final s = Set<String>.of(ids.value);
    if (!s.remove(id)) s.add(id);
    ids.value = s;
    await _save();
  }

  static Future<void> remove(String id) async {
    if (!ids.value.contains(id)) return;
    ids.value = Set<String>.of(ids.value)..remove(id);
    await _save();
  }
}

/// PIN for the hidden folder (only a hash is stored).
class Pin {
  static String _hash(String pin) =>
      sha256.convert(utf8.encode('mygallery:$pin')).toString();

  static Future<bool> isSet() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('pin_hash') != null;
  }

  static Future<void> set(String pin) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('pin_hash', _hash(pin));
  }

  static Future<bool> check(String pin) async {
    final p = await SharedPreferences.getInstance();
    return p.getString('pin_hash') == _hash(pin);
  }
}

String fmtDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

bool isVideoPath(String path) {
  final l = path.toLowerCase();
  const exts = ['.mp4', '.mkv', '.webm', '.3gp', '.mov', '.avi', '.m4v'];
  return exts.any((e) => l.endsWith(e));
}
