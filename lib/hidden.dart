import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'common.dart';
import 'gallery.dart' show VideoFileView;

/// Hidden files live in the app's private storage, so other apps
/// (and the normal gallery) can't see them.
class Hidden {
  static Future<Directory> dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/hidden');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<List<File>> list() async {
    final d = await dir();
    final files = d.listSync().whereType<File>().toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  static String originalName(File f) {
    final n = f.uri.pathSegments.last;
    final i = n.indexOf('_');
    return i >= 0 ? n.substring(i + 1) : n;
  }

  /// Copies the photo/video into the hidden folder, then removes it
  /// from the phone gallery.
  static Future<bool> hide(AssetEntity asset) async {
    final src = await asset.originFile ?? await asset.file;
    if (src == null) return false;
    final d = await dir();
    final title = asset.title;
    final name = (title != null && title.isNotEmpty)
        ? title
        : src.uri.pathSegments.last;
    final target =
        File('${d.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
    await src.copy(target.path);

    final deleted = await PhotoManager.editor.deleteWithIds([asset.id]);
    if (deleted.isEmpty) {
      await target.delete(); // user cancelled – undo
      return false;
    }
    await Favs.remove(asset.id);
    return true;
  }

  /// Puts the file back into the phone gallery.
  static Future<bool> unhide(File f) async {
    try {
      final name = originalName(f);
      if (isVideoPath(f.path)) {
        await PhotoManager.editor.saveVideo(f, title: name);
      } else {
        await PhotoManager.editor.saveImageWithPath(f.path, title: name);
      }
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}

class HiddenPage extends StatefulWidget {
  const HiddenPage({super.key});

  @override
  State<HiddenPage> createState() => _HiddenPageState();
}

class _HiddenPageState extends State<HiddenPage> {
  List<File> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final files = await Hidden.list();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hidden')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No hidden items yet.\n\nOpen any photo or video and tap the '
                      'eye button to hide it here.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: _files.length,
                  itemBuilder: (context, i) {
                    final f = _files[i];
                    return GestureDetector(
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                HiddenViewer(files: _files, initialIndex: i),
                          ),
                        );
                        setState(() {});
                      },
                      child: isVideoPath(f.path)
                          ? Container(
                              color: Colors.black87,
                              child: const Icon(Icons.play_circle_outline,
                                  color: Colors.white, size: 40),
                            )
                          : Image.file(f,
                              key: ValueKey(f.path),
                              fit: BoxFit.cover,
                              cacheWidth: 300),
                    );
                  },
                ),
    );
  }
}

class HiddenViewer extends StatefulWidget {
  const HiddenViewer(
      {super.key, required this.files, required this.initialIndex});
  final List<File> files;
  final int initialIndex;

  @override
  State<HiddenViewer> createState() => _HiddenViewerState();
}

class _HiddenViewerState extends State<HiddenViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _removeCurrent() {
    setState(() {
      widget.files.removeAt(_index);
      if (_index >= widget.files.length) _index = widget.files.length - 1;
    });
    if (widget.files.isEmpty) Navigator.pop(context);
  }

  Future<void> _unhide() async {
    final ok = await Hidden.unhide(widget.files[_index]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Moved back to gallery' : 'Could not unhide'),
    ));
    if (ok) _removeCurrent();
  }

  Future<void> _deleteForever() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete forever?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.files[_index].delete();
    if (mounted) _removeCurrent();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black45,
        foregroundColor: Colors.white,
        title: Text(
          Hidden.originalName(widget.files[_index]),
          style: const TextStyle(fontSize: 15),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Unhide',
            icon: const Icon(Icons.visibility),
            onPressed: _unhide,
          ),
          IconButton(
            tooltip: 'Delete forever',
            icon: const Icon(Icons.delete_forever),
            onPressed: _deleteForever,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.files.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          final f = widget.files[i];
          if (isVideoPath(f.path)) {
            return VideoFileView(key: ValueKey(f.path), file: Future.value(f));
          }
          return InteractiveViewer(
            key: ValueKey(f.path),
            minScale: 1,
            maxScale: 5,
            child: Center(child: Image.file(f, fit: BoxFit.contain)),
          );
        },
      ),
    );
  }
}
