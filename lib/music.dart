import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:photo_manager/photo_manager.dart';

import 'common.dart';

String songTitle(AssetEntity a) {
  final t = a.title ?? 'Unknown';
  final i = t.lastIndexOf('.');
  return i > 0 ? t.substring(0, i) : t;
}

/// One music player for the whole app, so songs keep playing
/// while you look at photos.
class MusicController extends ChangeNotifier {
  MusicController._() {
    player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        next();
      }
      notifyListeners();
    });
  }

  static final MusicController instance = MusicController._();

  final AudioPlayer player = AudioPlayer();
  List<AssetEntity> queue = [];
  int index = -1;

  AssetEntity? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  Future<void> playList(List<AssetEntity> list, int start) async {
    queue = List.of(list);
    await _playAt(start);
  }

  Future<void> _playAt(int i) async {
    if (queue.isEmpty) return;
    index = ((i % queue.length) + queue.length) % queue.length;
    notifyListeners();
    final file = await queue[index].file;
    if (file == null) return;
    try {
      await player.setFilePath(file.path);
      player.play(); // not awaited: completes only when playback stops
    } catch (_) {
      // Skip songs that can't be played.
    }
  }

  void toggle() => player.playing ? player.pause() : player.play();

  Future<void> next() => _playAt(index + 1);

  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
    } else {
      await _playAt(index - 1);
    }
  }
}

class MusicPage extends StatefulWidget {
  const MusicPage({super.key});

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  List<AssetEntity> _songs = [];
  bool _loading = true;
  bool _denied = false;
  bool _searching = false;
  String _query = '';
  String _sort = 'name'; // name | newest

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _denied = false;
    });
    final ps = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.audio,
          mediaLocation: false,
        ),
      ),
    );
    if (!ps.hasAccess) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _denied = true;
      });
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.audio,
      onlyAll: true,
    );
    final songs = <AssetEntity>[];
    if (paths.isNotEmpty) {
      final n = await paths.first.assetCountAsync;
      songs.addAll(await paths.first.getAssetListRange(start: 0, end: n));
    }
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  List<AssetEntity> get _visible {
    final q = _query.toLowerCase();
    final list =
        _songs.where((s) => songTitle(s).toLowerCase().contains(q)).toList();
    if (_sort == 'name') {
      list.sort((a, b) =>
          songTitle(a).toLowerCase().compareTo(songTitle(b).toLowerCase()));
    } else {
      list.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search songs',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : const Text('Music'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              _query = '';
            }),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'name', child: Text('Name (A–Z)')),
              PopupMenuItem(value: 'newest', child: Text('Newest first')),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_denied) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_off, size: 64),
            const SizedBox(height: 12),
            const Text('Allow access to music and audio to see your songs.'),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Try again')),
            TextButton(
              onPressed: PhotoManager.openSetting,
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    final songs = _visible;
    if (songs.isEmpty) {
      return Center(
        child: Text(_songs.isEmpty ? 'No songs found on this phone' : 'No match'),
      );
    }
    final m = MusicController.instance;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => ListView.builder(
        itemCount: songs.length,
        itemBuilder: (context, i) {
          final s = songs[i];
          final playing = m.current?.id == s.id;
          return ListTile(
            leading: CircleAvatar(
              child: Icon(playing ? Icons.graphic_eq : Icons.music_note),
            ),
            title: Text(
              songTitle(s),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: playing
                  ? TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    )
                  : null,
            ),
            trailing: Text(fmtDuration(s.videoDuration)),
            onTap: () => m.playList(songs, i),
          );
        },
      ),
    );
  }
}

/// Small player bar shown above the bottom tabs while a song is loaded.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final m = MusicController.instance;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final song = m.current;
        if (song == null) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<Duration>(
                stream: m.player.positionStream,
                builder: (context, snap) {
                  final pos = snap.data ?? Duration.zero;
                  final dur = m.player.duration ?? Duration.zero;
                  final max = dur.inMilliseconds.toDouble();
                  final value = max <= 0
                      ? 0.0
                      : pos.inMilliseconds.toDouble().clamp(0.0, max);
                  return SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: value,
                      max: max <= 0 ? 1 : max,
                      onChanged: max <= 0
                          ? null
                          : (v) => m.player
                              .seek(Duration(milliseconds: v.toInt())),
                    ),
                  );
                },
              ),
              Row(
                children: [
                  const SizedBox(width: 16),
                  const Icon(Icons.music_note),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      songTitle(song),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    onPressed: m.previous,
                  ),
                  IconButton(
                    icon: Icon(
                        m.player.playing ? Icons.pause : Icons.play_arrow),
                    onPressed: m.toggle,
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: m.next,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
