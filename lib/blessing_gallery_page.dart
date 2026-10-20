import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'app_palette.dart';

const Color _galleryGreen = Color(0xFF70867A);

class BlessingGalleryPage extends StatefulWidget {
  const BlessingGalleryPage({super.key, required this.maxCount});

  final int maxCount;

  @override
  State<BlessingGalleryPage> createState() => _BlessingGalleryPageState();
}

class _BlessingGalleryPageState extends State<BlessingGalleryPage> {
  static const int _pageSize = 80;

  final ScrollController _scroll = ScrollController();
  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _selected = [];

  AssetPathEntity? _album;
  int _page = 0;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _denied = false;
  String? _error;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _init();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _denied = false;
      _error = null;
      _assets.clear();
      _selected.clear();
      _page = 0;
      _total = 0;
      _hasMore = true;
    });
    try {
      final state = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
      if (!mounted) return;
      if (!state.hasAccess) {
        setState(() {
          _denied = true;
          _loading = false;
        });
        return;
      }
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: const [OrderOption(asc: false)],
        ),
      );
      if (!mounted) return;
      if (paths.isEmpty) {
        setState(() {
          _loading = false;
          _hasMore = false;
        });
        return;
      }
      _album = paths.first;
      _total = await _album!.assetCountAsync;
      await _loadMore();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _album == null) return;
    setState(() => _loadingMore = true);
    try {
      final list = await _album!.getAssetListPaged(
        page: _page,
        size: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _assets.addAll(list);
        _page++;
        _hasMore = list.isNotEmpty && _assets.length < _total;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _hasMore = false);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _toggle(AssetEntity asset) {
    final index = _selected.indexWhere((e) => e.id == asset.id);
    if (index >= 0) {
      setState(() => _selected.removeAt(index));
      return;
    }
    if (_selected.length >= widget.maxCount) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('最多选择 ${widget.maxCount} 张'),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ));
      return;
    }
    setState(() => _selected.add(asset));
  }

  Future<void> _finish() async {
    if (_selected.isEmpty || _finishing) return;
    setState(() => _finishing = true);
    final files = <File>[];
    for (final asset in _selected) {
      try {
        final file = await asset.file;
        if (file != null) files.add(file);
      } catch (_) {}
    }
    if (!mounted) return;
    if (files.isEmpty) {
      setState(() => _finishing = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('读取图片失败，请重试'),
          behavior: SnackBarBehavior.floating,
        ));
      return;
    }
    Navigator.pop(context, files);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(Icons.close, color: p.text),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '选择图片',
          style: TextStyle(
            color: p.text,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed:
                  _selected.isEmpty || _finishing ? null : _finish,
              style: TextButton.styleFrom(
                foregroundColor: _galleryGreen,
                disabledForegroundColor: p.textHint,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: _finishing
                  ? SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _galleryGreen,
                      ),
                    )
                  : Text(
                      _selected.isEmpty
                          ? '完成'
                          : '完成(${_selected.length})',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
      body: _body(p),
    );
  }

  Widget _body(PaletteData p) {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            color: _galleryGreen,
          ),
        ),
      );
    }
    if (_denied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_library_outlined,
                  size: 44, color: p.textHint),
              const SizedBox(height: 14),
              Text(
                '需要访问相册才能选择图片',
                style: TextStyle(fontSize: 14, color: p.textSec),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _init,
                    child: const Text('重新授权'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => PhotoManager.openSetting(),
                    style: FilledButton.styleFrom(
                      backgroundColor: _galleryGreen,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('去设置'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('读取相册失败', style: TextStyle(color: p.textSec)),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: _init, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_assets.isEmpty) {
      return Center(
        child: Text('相册里还没有图片',
            style: TextStyle(fontSize: 14, color: p.textHint)),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Row(
            children: [
              Text('全部图片',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.text)),
              const Spacer(),
              Text('最多选择 ${widget.maxCount} 张',
                  style: TextStyle(fontSize: 11.5, color: p.textHint)),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: _assets.length + (_loadingMore ? 1 : 0),
            itemBuilder: (_, index) {
              if (index >= _assets.length) {
                return Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _galleryGreen,
                    ),
                  ),
                );
              }
              final asset = _assets[index];
              return _AssetTile(
                key: ValueKey(asset.id),
                asset: asset,
                index: _selected.indexWhere((e) => e.id == asset.id),
                onTap: () => _toggle(asset),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    super.key,
    required this.asset,
    required this.index,
    required this.onTap,
  });

  final AssetEntity asset;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = index >= 0;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AssetThumb(asset: asset),
          if (selected)
            Container(color: Colors.black.withValues(alpha: 0.18)),
          Positioned(
            top: 5,
            right: 5,
            child: Container(
              width: 21,
              height: 21,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? _galleryGreen : Colors.black26,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.4),
              ),
              child: selected
                  ? Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _AssetThumb extends StatefulWidget {
  const _AssetThumb({required this.asset});

  final AssetEntity asset;

  @override
  State<_AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends State<_AssetThumb> {
  late final Future<Uint8List?> _thumb = widget.asset.thumbnailDataWithSize(
    const ThumbnailSize(320, 320),
    quality: 82,
  );

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return FutureBuilder<Uint8List?>(
      future: _thumb,
      builder: (_, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return Container(
            color: p.tintBg,
            child: Icon(Icons.image_outlined,
                size: 18, color: p.textHint),
          );
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      },
    );
  }
}
