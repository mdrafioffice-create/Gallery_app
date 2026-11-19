import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'common.dart';
import 'hidden.dart';
import 'pin_page.dart';

String albumName(AssetPathEntity a) => a.isAll ? 'All photos' : a.name;

// ───────────────────────── Albums screen ─────────────────────────

class AlbumsPage extends StatefulWidget {
  const AlbumsPage({super.key});

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  List<AssetPathEntity> _albums = [];
  final Map<String, int> _counts = {};
  final Map<String, AssetEntity?> _covers = {};
  bool _loading = true;
  bool _denied = false;
  bool _searching = false;
  String _query = '';
  String _sort = 'default'; // default | name | count

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

    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _denied = true;
      });
      return;
    }

    final albums =
        await PhotoManager.getAssetPathList(type: RequestType.common);
    for (final album in albums) {
      _counts[album.id] = await album.assetCountAsync;
      final first = await album.getAssetListRange(start: 0, end: 1);
      _covers[album.id] = first.isEmpty ? null : first.first;
    }
    albums.removeWhere((a) => (_counts[a.id] ?? 0) == 0);

    if (!mounted) return;
    setState(() {
      _albums = albums;
      _loading = false;
    });
  }

  List<AssetPathEntity> get _visible {
    final q = _query.toLowerCase();
    final list =
        _albums.where((a) => albumName(a).toLowerCase().contains(q)).toList();
    if (_sort == 'name') {
      list.sort((a, b) =>
          albumName(a).toLowerCase().compareTo(albumName(b).toLowerCase()));
    } else if (_sort == 'count') {
      list.sort((a, b) => (_counts[b.id] ?? 0).compareTo(_counts[a.id] ?? 0));
    }
    return list;
  }

  Future<void> _openHidden() async {
    final ok = await unlockHidden(context);
    if (!ok || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const HiddenPage()),
    );
    _load(); // unhidden items come back into albums
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search albums',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : const Text('Gallery'),
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
              PopupMenuItem(value: 'default', child: Text('Default order')),
              PopupMenuItem(value: 'name', child: Text('Name (A–Z)')),
              PopupMenuItem(value: 'count', child: Text('Most items')),
            ],
          ),
          IconButton(
            tooltip: 'Hidden folder',
            icon: const Icon(Icons.lock_outline),
            onPressed: _openHidden,
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_denied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.photo_library_outlined, size: 64),
              const SizedBox(height: 16),
              const Text(
                'Allow access to photos and videos to see your gallery.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Try again')),
              TextButton(
                onPressed: PhotoManager.openSetting,
                child: const Text('Open settings'),
              ),
            ],
          ),
        ),
      );
    }

    return ValueListenableBuilder<Set<String>>(
      valueListenable: Favs.ids,
      builder: (context, favIds, _) {
        final albums = _visible;
        final showFav = favIds.isNotEmpty &&
            'favourites'.contains(_query.toLowerCase());
        final total = albums.length + (showFav ? 1 : 0);
        if (total == 0) {
          return ListView(children: const [
            SizedBox(height: 200),
            Center(child: Text('No albums found')),
          ]);
        }
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: total,
          itemBuilder: (context, i) {
            if (showFav && i == 0) {
              return _AlbumTile(
                name: 'Favourites',
                count: favIds.length,
                cover: Container(
                  color: Colors.red.withOpacity(0.12),
                  child: const Icon(Icons.favorite,
                      color: Colors.red, size: 56),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const FavouritesPage()),
                ),
              );
            }
            final album = albums[i - (showFav ? 1 : 0)];
            final cover = _covers[album.id];
            return _AlbumTile(
              name: albumName(album),
              count: _counts[album.id] ?? 0,
              cover: cover == null
                  ? Container(color: Colors.black12)
                  : Thumb(asset: cover, size: 400),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AlbumPage(album: album)),
                );
                _load();
              },
            );
          },
        );
      },
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.name,
    required this.count,
    required this.cover,
    required this.onTap,
  });
  final String name;
  final int count;
  final Widget cover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox.expand(child: cover),
            ),
          ),
          const SizedBox(height: 6),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Text('$count items', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

// ───────────────────────── Shared photo grid ─────────────────────────

class AssetGrid extends StatelessWidget {
  const AssetGrid({
    super.key,
    required this.assets,
    required this.onReturn,
    this.onNearEnd,
  });
  final List<AssetEntity> assets;
  final VoidCallback onReturn;
  final VoidCallback? onNearEnd;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: assets.length,
      itemBuilder: (context, i) {
        if (onNearEnd != null && i >= assets.length - 20) onNearEnd!();
        final asset = assets[i];
        return GestureDetector(
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ViewerPage(assets: assets, initialIndex: i),
              ),
            );
            onReturn();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Thumb(key: ValueKey(asset.id), asset: asset),
              ValueListenableBuilder<Set<String>>(
                valueListenable: Favs.ids,
                builder: (_, ids, __) => ids.contains(asset.id)
                    ? const Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.favorite,
                              color: Colors.red, size: 18),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── Single album ─────────────────────────

class AlbumPage extends StatefulWidget {
  const AlbumPage({super.key, required this.album});
  final AssetPathEntity album;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  static const _pageSize = 80;
  late AssetPathEntity _album;
  final List<AssetEntity> _assets = [];
  int _page = 0;
  int _gen = 0;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _oldestFirst = false;

  @override
  void initState() {
    super.initState();
    _album = widget.album;
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final gen = _gen;
    final items = await _album.getAssetListPaged(page: _page, size: _pageSize);
    if (!mounted || gen != _gen) return;
    setState(() {
      _assets.addAll(items);
      _page++;
      _hasMore = items.length == _pageSize;
      _loadingMore = false;
    });
  }

  Future<void> _changeSort(bool oldestFirst) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      filterOption: FilterOptionGroup(
        orders: [
          OrderOption(type: OrderOptionType.createDate, asc: oldestFirst),
        ],
      ),
    );
    final match = paths.where((p) => p.id == widget.album.id);
    if (!mounted) return;
    setState(() {
      _gen++;
      _oldestFirst = oldestFirst;
      if (match.isNotEmpty) _album = match.first;
      _assets.clear();
      _page = 0;
      _hasMore = true;
      _loadingMore = false;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(albumName(widget.album)),
        actions: [
          PopupMenuButton<bool>(
            icon: const Icon(Icons.sort),
            initialValue: _oldestFirst,
            onSelected: _changeSort,
            itemBuilder: (_) => const [
              PopupMenuItem(value: false, child: Text('Newest first')),
              PopupMenuItem(value: true, child: Text('Oldest first')),
            ],
          ),
        ],
      ),
      body: _assets.isEmpty && _loadingMore
          ? const Center(child: CircularProgressIndicator())
          : AssetGrid(
              assets: _assets,
              onNearEnd: _loadMore,
              onReturn: () => setState(() {}),
            ),
    );
  }
}

// ───────────────────────── Favourites ─────────────────────────

class FavouritesPage extends StatefulWidget {
  const FavouritesPage({super.key});

  @override
  State<FavouritesPage> createState() => _FavouritesPageState();
}

class _FavouritesPageState extends State<FavouritesPage> {
  List<AssetEntity> _assets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = <AssetEntity>[];
    for (final id in Favs.ids.value.toList()) {
      final a = await AssetEntity.fromId(id);
      if (a == null) {
        await Favs.remove(id); // was deleted from the phone
      } else {
        out.add(a);
      }
    }
    out.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    if (!mounted) return;
    setState(() {
      _assets = out;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Favourites')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _assets.isEmpty
              ? const Center(child: Text('No favourites yet'))
              : AssetGrid(
                  assets: _assets,
                  onReturn: () => setState(() {
                    _assets.removeWhere((a) => !Favs.isFav(a.id));
                  }),
                ),
    );
  }
}

// ───────────────────────── Thumbnail tile ─────────────────────────

class Thumb extends StatefulWidget {
  const Thumb({super.key, required this.asset, this.size = 250});
  final AssetEntity asset;
  final int size;

  @override
  State<Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<Thumb> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future =
        widget.asset.thumbnailDataWithSize(ThumbnailSize.square(widget.size));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return Container(color: Colors.black12);
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
            if (widget.asset.type == AssetType.video)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.play_arrow,
                          size: 14, color: Colors.white),
                      Text(
                        fmtDuration(widget.asset.videoDuration),
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ───────────────────────── Full-screen viewer ─────────────────────────

class ViewerPage extends StatefulWidget {
  const ViewerPage(
      {super.key, required this.assets, required this.initialIndex});
  final List<AssetEntity> assets; // shared list, removals update the grid
  final int initialIndex;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _controller;
  late int _index;
  bool _showUi = true;

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

  AssetEntity get _current => widget.assets[_index];

  void _removeCurrent() {
    setState(() {
      widget.assets.removeAt(_index);
      if (_index >= widget.assets.length) _index = widget.assets.length - 1;
    });
    if (widget.assets.isEmpty) Navigator.pop(context);
  }

  Future<void> _share() async {
    final file = await _current.file;
    if (file != null) await Share.shareXFiles([XFile(file.path)]);
  }

  Future<void> _hide() async {
    final ok = await ensurePinCreated(context);
    if (!ok || !mounted) return;
    final done = await Hidden.hide(_current);
    if (!done || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Moved to Hidden folder 🔒')),
    );
    _removeCurrent();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this item?'),
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

    final id = _current.id;
    final deleted = await PhotoManager.editor.deleteWithIds([id]);
    if (deleted.isEmpty || !mounted) return;
    await Favs.remove(id);
    _removeCurrent();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.assets.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final date = _current.createDateTime;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showUi
          ? AppBar(
              backgroundColor: Colors.black45,
              foregroundColor: Colors.white,
              title: Text(
                '${date.day}/${date.month}/${date.year}',
                style: const TextStyle(fontSize: 16),
              ),
              actions: [
                ValueListenableBuilder<Set<String>>(
                  valueListenable: Favs.ids,
                  builder: (_, ids, __) {
                    final fav = ids.contains(_current.id);
                    return IconButton(
                      tooltip: 'Favourite',
                      icon: Icon(
                        fav ? Icons.favorite : Icons.favorite_border,
                        color: fav ? Colors.red : null,
                      ),
                      onPressed: () => Favs.toggle(_current.id),
                    );
                  },
                ),
                IconButton(
                    tooltip: 'Share',
                    icon: const Icon(Icons.share),
                    onPressed: _share),
                IconButton(
                    tooltip: 'Hide',
                    icon: const Icon(Icons.visibility_off_outlined),
                    onPressed: _hide),
                IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _delete),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: () => setState(() => _showUi = !_showUi),
        child: PageView.builder(
          controller: _controller,
          itemCount: widget.assets.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (context, i) {
            final asset = widget.assets[i];
            return asset.type == AssetType.video
                ? VideoFileView(key: ValueKey(asset.id), file: asset.file)
                : FullImage(key: ValueKey(asset.id), asset: asset);
          },
        ),
      ),
    );
  }
}

// ───────────────────────── Full image with pinch-zoom ─────────────────────────

class FullImage extends StatefulWidget {
  const FullImage({super.key, required this.asset});
  final AssetEntity asset;

  @override
  State<FullImage> createState() => _FullImageState();
}

class _FullImageState extends State<FullImage> {
  late Future<File?> _file;

  @override
  void initState() {
    super.initState();
    _file = widget.asset.file;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _file,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final file = snap.data;
        if (file == null) {
          return const Center(
            child: Text('Could not open this image',
                style: TextStyle(color: Colors.white70)),
          );
        }
        return InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(child: Image.file(file, fit: BoxFit.contain)),
        );
      },
    );
  }
}

// ───────────────────────── Video player ─────────────────────────

class VideoFileView extends StatefulWidget {
  const VideoFileView({super.key, required this.file});
  final Future<File?> file;

  @override
  State<VideoFileView> createState() => _VideoFileViewState();
}

class _VideoFileViewState extends State<VideoFileView> {
  VideoPlayerController? _c;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final file = await widget.file;
    if (!mounted) return;
    if (file == null) {
      setState(() => _error = true);
      return;
    }
    final c = VideoPlayerController.file(file);
    _c = c;
    c.addListener(() {
      if (mounted) setState(() {});
    });
    try {
      await c.initialize();
      if (mounted) c.play();
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return const Center(
        child: Text('Could not play this video',
            style: TextStyle(color: Colors.white70)),
      );
    }
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
        IconButton(
          iconSize: 64,
          color: Colors.white.withOpacity(c.value.isPlaying ? 0.0 : 0.9),
          icon: const Icon(Icons.play_circle_fill),
          onPressed: () => c.value.isPlaying ? c.pause() : c.play(),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 32,
          child: Column(
            children: [
              VideoProgressIndicator(c, allowScrubbing: true),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fmtDuration(c.value.position),
                      style: const TextStyle(color: Colors.white)),
                  GestureDetector(
                    onTap: () => c.value.isPlaying ? c.pause() : c.play(),
                    child: Icon(
                      c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                  ),
                  Text(fmtDuration(c.value.duration),
                      style: const TextStyle(color: Colors.white)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
