import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'settings_widgets.dart';
import 'sutra_downloader.dart';

/// 一条已排版经文的展示/下载状态。
class LayoutItem {
  LayoutItem({
    required this.id,
    required this.title,
    required this.vol,
    this.localExists = false,
  });

  final String id;
  final String title;
  final String vol;
  bool localExists;
  bool downloading = false;
  double progress = 0.0;
}

/// 管理员「排版经文」页：列出所有已标记完成排版的经文，
/// 并支持单个/一键批量把排版版下载到本地。
class SutraLayoutAdminPage extends StatefulWidget {
  const SutraLayoutAdminPage({super.key});

  @override
  State<SutraLayoutAdminPage> createState() => _SutraLayoutAdminPageState();
}

class _SutraLayoutAdminPageState extends State<SutraLayoutAdminPage> {
  bool _loading = true;
  String? _error;
  final List<LayoutItem> _items = [];
  bool _downloadingAll = false;
  double _allProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
    });
    try {
      await NoteSutraCatalog.load();
      final prefs = await SharedPreferences.getInstance();

      // 1) 本机标记：管理员在阅读页点过「完成排版」的经文。
      final donePaths = <String>[];
      for (final k in prefs.getKeys()) {
        if (k.startsWith('sutra_layout_done_') && prefs.getBool(k) == true) {
          donePaths.add(k.substring('sutra_layout_done_'.length));
        }
      }

      // 2) 云端：有排版记录的经文（含重装后本机标记被清空的情形）。
      //    单次批量拉取标题表；与本机标记合并（同一部经只留一条）。
      final cloudIds = <String, String>{};
      try {
        final titles =
            await CloudNotesService.instance.getSutraEditTitles();
        for (final e in titles.entries) {
          final id = e.key;
          if (id.isEmpty) continue;
          cloudIds[id] = e.value;
        }
      } catch (_) {
        // 云端不可用：只用本机标记，不报错。
      }

      final rawById = NoteSutraCatalog.cachedRawTitleById ?? const {};
      final merged = <String, LayoutItem>{};

      // 本机标记优先（这些是「标记完成排版」的来源之一）。
      for (final fp in donePaths) {
        final id = SutraDownloader.extractId(null, fp) ??
            SutraDownloader.extractId(fp);
        if (id == null || id.isEmpty) continue;
        merged.putIfAbsent(
          id,
          () => LayoutItem(
            id: id,
            title: rawById[id] ?? id,
            vol: id.substring(0, id.length >= 3 ? 3 : id.length),
          ),
        );
      }
      // 云端补充（排版版实际存在）。
      for (final e in cloudIds.entries) {
        final id = e.key;
        if (merged.containsKey(id)) continue;
        merged.putIfAbsent(
          id,
          () => LayoutItem(
            id: id,
            title: e.value.isNotEmpty ? e.value : (rawById[id] ?? id),
            vol: id.substring(0, id.length >= 3 ? 3 : id.length),
          ),
        );
      }

      final list = merged.values.toList()
        ..sort((a, b) => a.title.compareTo(b.title));

      for (final item in list) {
        await _refreshLocalState(item);
      }

      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 本地是否已有该经的正文文件（打包资产或已下载副本）。
  Future<void> _refreshLocalState(LayoutItem item) async {
    var exists = false;
    try {
      final rel = '${item.vol}/${item.id}.txt';
      // 打包的排版版 / 原始版资产。
      try {
        await rootBundle.load('assets/sutras_edited/$rel');
        exists = true;
      } catch (_) {
        try {
          await rootBundle.load('assets/sutras_ascii/$rel');
          exists = true;
        } catch (_) {}
      }
      // 已下载副本。
      final f = await SutraDownloader.localFile(item.id);
      if (!exists) {
        exists = await f.exists() && (await f.length()) > 0;
      }
    } catch (_) {
      exists = false;
    }
    if (!mounted) return;
    item.localExists = exists;
  }

  String _progressText(double p) => '${(p * 100).toStringAsFixed(0)}%';

  Future<void> _downloadOne(LayoutItem item) async {
    if (item.downloading || _downloadingAll) return;
    final ok = await _confirm(
      title: '下载排版版',
      message: '把《${item.title}》的排版版下载到本地？',
      confirmLabel: '下载',
    );
    if (ok != true || !mounted) return;
    setState(() {
      item.downloading = true;
      item.progress = 0.0;
    });
    try {
      await SutraDownloader.download(
        item.id,
        preferEdited: true,
        force: true,
        onProgress: (r, t) {
          if (t <= 0 || !mounted) return;
          setState(() => item.progress = r / t);
        },
      );
      await _refreshLocalState(item);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('《${item.title}》排版版已下载')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败：$e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          item.downloading = false;
          item.progress = 0.0;
        });
      }
    }
  }

  Future<void> _downloadAll() async {
    if (_items.isEmpty || _downloadingAll) return;
    final ok = await _confirm(
      title: '一键全部下载',
      message: '将把全部 ${_items.length} 部已排版经文的排版版下载到本地，'
          '下载过程可能较久。确定继续？',
      confirmLabel: '全部下载',
    );
    if (ok != true || !mounted) return;
    setState(() {
      _downloadingAll = true;
      _allProgress = 0.0;
    });
    var done = 0;
    for (final item in _items) {
      if (!mounted) return;
      try {
        await SutraDownloader.download(item.id, preferEdited: true, force: true);
      } catch (_) {
        // 单部失败不中断整体。
      }
      await _refreshLocalState(item);
      done++;
      if (mounted) {
        setState(() => _allProgress = done / _items.length);
      }
    }
    if (!mounted) return;
    setState(() => _downloadingAll = false);
    _toast('一键下载完成');
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '排版经文',
      child: _loading
          ? Center(child: CircularProgressIndicator(color: sGold))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('加载失败：$_error',
                            textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _loadItems,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    _buildHeader(),
                    if (_downloadingAll)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: LinearProgressIndicator(value: _allProgress),
                      ),
                    Expanded(child: _buildList()),
                  ],
                ),
    );
  }

  Widget _buildHeader() {
    final downloaded = _items.where((e) => e.localExists).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '已排版 ${_items.length} 部 · 本地已有 $downloaded 部',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          ElevatedButton.icon(
            onPressed:
                _items.isEmpty || _downloadingAll ? null : _downloadAll,
            icon: _downloadingAll
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: sGold,
                    ),
                  )
                : const Icon(Icons.download, size: 18),
            label: Text(
              _downloadingAll
                  ? '下载中 ${_progressText(_allProgress)}'
                  : '一键全部下载',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('还没有已标记「完成排版」的经文', textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (ctx, i) {
        final item = _items[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: ListTile(
            title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              item.id,
              style: const TextStyle(fontSize: 11),
            ),
            leading: CircleAvatar(
              backgroundColor: sCard,
              child: Text(
                item.id.length >= 3 ? item.id.substring(0, 3) : item.id,
                style: const TextStyle(fontSize: 11),
              ),
            ),
            trailing: item.downloading
                ? SizedBox(
                    width: 96,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        LinearProgressIndicator(
                          value: item.progress > 0 ? item.progress : null,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _progressText(item.progress),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  )
                : TextButton.icon(
                    onPressed: _downloadingAll
                        ? null
                        : () => _downloadOne(item),
                    icon: Icon(
                      item.localExists
                          ? Icons.download_done
                          : Icons.download,
                      size: 18,
                    ),
                    label: Text(
                      item.localExists ? '重新下载' : '下载排版版',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
          ),
        );
      },
    );
  }
}
