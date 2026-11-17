import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 「善知识 · 影音」的云端资源根地址（Cloudflare R2 的公开 r2.dev 域名）。
///
/// 后续所有讲经视频都上传到这个桶，视频文件放 `videos/`，封面放 `posters/`，
/// 清单 `catalog.json` 放在根目录；App 只认清单，加片后不用发版。
const String kVideoBaseUrl =
    'https://pub-5b5f4d4b26d4455796c20a6f89388785.r2.dev';

/// 视频清单地址。拉取失败时回退到 [VideoCatalogStore] 内置的默认清单，
/// 页面不会空白。
const String kVideoCatalogUrl = '$kVideoBaseUrl/catalog.json';

/// 相对路径补全成绝对地址；已经是 http(s) 的原样返回。
String resolveVideoUrl(String pathOrUrl) {
  final raw = pathOrUrl.trim();
  if (raw.isEmpty) return '';
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return raw;
  final path = raw.startsWith('/') ? raw.substring(1) : raw;
  return '$kVideoBaseUrl/$path';
}

/// 一部视频的单个清晰度源。
class VideoSource {
  /// 展示用的短标签：720P / 480P。
  final String label;

  /// 完整播放地址（已补全为绝对地址）。
  final String url;

  /// 画面高度（像素），用于挑默认清晰度；未知为 0。
  final int height;

  /// 码率（bps），未知为 0。
  final int bitrate;

  /// 是否为「自动」档：指向多码率 master.m3u8，由播放器按网速自动切清晰度。
  final bool auto;

  const VideoSource({
    required this.label,
    required this.url,
    this.height = 0,
    this.bitrate = 0,
    this.auto = false,
  });

  factory VideoSource.fromJson(Map<String, dynamic> json) {
    final rawUrl = (json['url'] ?? json['path'] ?? '').toString();
    final height = _asInt(json['height']);
    var label = (json['label'] ?? '').toString().trim();
    if (label.isEmpty) label = height > 0 ? '${height}P' : '默认';
    return VideoSource(
      label: label,
      url: resolveVideoUrl(rawUrl),
      height: height,
      bitrate: _asInt(json['bitrate']),
      auto: json['auto'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'url': url,
        if (height > 0) 'height': height,
        if (bitrate > 0) 'bitrate': bitrate,
        if (auto) 'auto': true,
      };
}

/// 一个分片：网盘里放一个 <100MB 的文件，App 下载后按顺序拼回完整 MP4。
class VideoPart {
  final String url;

  /// 分片字节数，用于校验与进度；0 = 未知。
  final int size;

  const VideoPart({required this.url, this.size = 0});

  factory VideoPart.fromJson(Map<String, dynamic> json) => VideoPart(
        url: resolveVideoUrl(
            (json['url'] ?? json['path'] ?? '').toString()),
        size: _asInt(json['size'] ?? json['sizeBytes']),
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        if (size > 0) 'size': size,
      };
}

/// 一部视频（一条讲经 / 一段开示）的完整信息。
class VideoItem {
  final String id;
  final String title;

  /// 副标题：出品方 / 版本说明，一行小字。
  final String subtitle;

  /// 简介，展示在首页卡片下方。
  final String description;

  final String coverUrl;
  final Duration duration;
  final List<VideoSource> sources;

  /// 光鸭等网盘的直链：App 先下载到本地，再用本地文件播放。
  /// 为空时退回在线播放 [sources]。
  final String downloadUrl;

  /// 分片直链（每片 <100MB，避开网盘“免登录仅限小文件”的限制）。
  /// 有值时优先按分片下载，全部下完后按顺序拼成一个完整 MP4。
  final List<VideoPart> parts;

  /// 文件大小（字节），用于下载进度与空间提示；0 = 未知。
  final int fileSize;

  /// 网盘分享页（蓝奏云等）：走「用户手动浏览器下载 → App 导入合并」模式。
  /// 与 [downloadUrl] / [parts] 互斥，优先直链。
  final String shareUrl;

  /// 手动模式下的分片大小（字节），用于导入后校验；可空。
  final List<int> partSizes;

  const VideoItem({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.description = '',
    this.coverUrl = '',
    this.duration = Duration.zero,
    this.sources = const [],
    this.downloadUrl = '',
    this.parts = const [],
    this.fileSize = 0,
    this.shareUrl = '',
    this.partSizes = const [],
  });

  bool get playable =>
      sources.isNotEmpty ||
      downloadUrl.isNotEmpty ||
      parts.isNotEmpty ||
      shareUrl.isNotEmpty;

  /// 是否走「先下载再播」模式（自动或手动）。
  bool get downloadFirst =>
      downloadUrl.isNotEmpty || parts.isNotEmpty || shareUrl.isNotEmpty;

  /// 是否「用户手动下载 → App 导入合并」模式。
  bool get manualDownload =>
      shareUrl.isNotEmpty && downloadUrl.isEmpty && parts.isEmpty;

  /// 全部下载任务的总字节数：分片按片求和，单片用 fileSize。
  int get expectedBytes {
    if (parts.isNotEmpty) {
      return parts.fold(0, (sum, p) => sum + p.size);
    }
    if (partSizes.isNotEmpty) {
      return partSizes.fold(0, (sum, s) => sum + s);
    }
    return fileSize;
  }

  /// 默认清晰度：有「自动」档就优先用它（多码率自适应，弱网会自己降档，
  /// 这是播放中不卡的关键）；没有就优先 720P，再其次按高度取最高。
  VideoSource? get defaultSource {
    if (sources.isEmpty) return null;
    for (final s in sources) {
      if (s.auto) return s;
    }
    final sorted = [...sources]..sort((a, b) => b.height.compareTo(a.height));
    for (final s in sorted) {
      if (s.height == 720) return s;
    }
    return sorted.first;
  }

  /// 最高清晰度的短标签（卡片右下角展示，不把「自动」当成清晰度）。
  String get qualityLabel {
    final real = sources.where((s) => !s.auto && s.height > 0).toList()
      ..sort((a, b) => b.height.compareTo(a.height));
    if (real.isNotEmpty) return real.first.label;
    return sources.isEmpty ? '' : sources.first.label;
  }

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'];
    final sources = <VideoSource>[];
    if (rawSources is List) {
      for (final s in rawSources) {
        if (s is Map) {
          final src = VideoSource.fromJson(Map<String, dynamic>.from(s));
          if (src.url.isNotEmpty) sources.add(src);
        }
      }
    }
    // 兼容只写一个 url 的简写清单。
    final singleUrl = (json['url'] ?? json['path'] ?? '').toString();
    if (sources.isEmpty && singleUrl.isNotEmpty) {
      sources.add(VideoSource(
        label: (json['quality'] ?? '默认').toString(),
        url: resolveVideoUrl(singleUrl),
        height: _asInt(json['height']),
      ));
    }
    final cover = (json['cover'] ?? json['poster'] ?? '').toString();
    // 网盘直链：既支持写绝对地址，也支持写相对路径（走 kVideoBaseUrl）。
    final rawDownload =
        (json['downloadUrl'] ?? json['download'] ?? '').toString();
    // 分片直链：每片 <100MB，按顺序拼回完整文件。
    final rawParts = json['parts'];
    final parts = <VideoPart>[];
    if (rawParts is List) {
      for (final p in rawParts) {
        if (p is Map) {
          final part = VideoPart.fromJson(Map<String, dynamic>.from(p));
          if (part.url.isNotEmpty) parts.add(part);
        }
      }
    }
    // 手动模式：网盘分享页 + 每片大小。
    final share = (json['shareUrl'] ?? json['manualUrl'] ?? '').toString();
    final rawSizes = json['partSizes'];
    final partSizes = <int>[];
    if (rawSizes is List) {
      for (final s in rawSizes) {
        final n = _asInt(s);
        if (n > 0) partSizes.add(n);
      }
    }
    return VideoItem(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString().trim(),
      subtitle: (json['subtitle'] ?? json['series'] ?? '').toString().trim(),
      description: (json['description'] ?? json['intro'] ?? '').toString().trim(),
      coverUrl: resolveVideoUrl(cover),
      duration: Duration(seconds: _asInt(json['durationSec'] ?? json['duration'])),
      sources: sources,
      downloadUrl: rawDownload.isEmpty
          ? ''
          : resolveVideoUrl(rawDownload),
      parts: parts,
      fileSize: _asInt(json['fileSize'] ?? json['sizeBytes'] ?? json['size']),
      shareUrl: share.isEmpty ? '' : resolveVideoUrl(share),
      partSizes: partSizes,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (subtitle.isNotEmpty) 'subtitle': subtitle,
        if (description.isNotEmpty) 'description': description,
        if (coverUrl.isNotEmpty) 'cover': coverUrl,
        'durationSec': duration.inSeconds,
        'sources': [for (final s in sources) s.toJson()],
        if (downloadUrl.isNotEmpty) 'downloadUrl': downloadUrl,
        if (parts.isNotEmpty) 'parts': [for (final p in parts) p.toJson()],
        if (shareUrl.isNotEmpty) 'shareUrl': shareUrl,
        if (partSizes.isNotEmpty) 'partSizes': partSizes,
        if (fileSize > 0) 'fileSize': fileSize,
      };
}

/// 视频清单：一组按展示顺序排好的视频。
class VideoCatalog {
  final List<VideoItem> videos;

  /// 清单更新时间（清单里没写就是 null）。
  final String updatedAt;

  const VideoCatalog({required this.videos, this.updatedAt = ''});

  factory VideoCatalog.fromJson(Map<String, dynamic> json) {
    final raw = json['videos'];
    final videos = <VideoItem>[];
    if (raw is List) {
      for (final v in raw) {
        if (v is Map) {
          final item = VideoItem.fromJson(Map<String, dynamic>.from(v));
          if (item.title.isNotEmpty && item.playable) videos.add(item);
        }
      }
    }
    return VideoCatalog(
      videos: videos,
      updatedAt: (json['updatedAt'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'updatedAt': updatedAt,
        'videos': [for (final v in videos) v.toJson()],
      };

  /// 内置兜底清单：即使云端清单没拉到，v001 也能直接播。
  factory VideoCatalog.fallback() => const VideoCatalog(
        updatedAt: '2026-10-28',
        videos: [
          VideoItem(
            id: 'v001',
            title: '佛说无量寿经',
            subtitle: 'Aputi 动画 · 4K 修复版',
            description:
                '《佛说无量寿经》动画版。依经文脉络，讲述阿弥陀佛因地为法藏比丘，'
                '于世自在王佛前发四十八大愿，累劫修行、成就极乐国土的因缘。'
                '全片约四十一分钟，中英双语字幕。',
            coverUrl: '$kVideoBaseUrl/posters/v001.jpg',
            duration: Duration(minutes: 41, seconds: 30),
            sources: [
              VideoSource(
                label: '720P',
                // R2 上的 HLS 720P 单档：点开直接在线播放。
                url: '$kVideoBaseUrl/videos/v001/index.m3u8',
                height: 720,
                bitrate: 1250000,
              ),
            ],
          ),
        ],
      );
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  return int.tryParse('${value ?? ''}') ?? 0;
}

/// 视频清单的全局仓库：先读本地缓存秒开，再后台拉云端清单覆盖。
class VideoCatalogStore extends ChangeNotifier {
  VideoCatalogStore._();

  static final VideoCatalogStore instance = VideoCatalogStore._();

  static const String _cacheKey = 'video_catalog_json_v3';

  VideoCatalog _catalog = VideoCatalog.fallback();
  bool _loaded = false;
  bool _refreshing = false;
  String? _error;
  DateTime? _fetchedAt;
  Future<void>? _pending;

  /// 连续失败次数：页面只在连续失败 3 次后才提示「用的是内置片单」，
  /// 避免启动瞬间网络还没就绪就弹一条吓人的提示。
  int _failStreak = 0;
  Timer? _retryTimer;

  /// 云端片单是否可达：true=能访问（有加速），false=访问不了（无加速）。
  /// 页面据此决定显示视频还是只显示国内内容。null=还没测过。
  bool? _cloudReachable;
  bool? get cloudReachable => _cloudReachable;

  VideoCatalog get catalog => _catalog;

  /// 是否已经完成过一次「缓存 / 网络」读取。
  bool get loaded => _loaded;

  bool get refreshing => _refreshing;

  /// 最近一次网络拉取的错误（用于页面顶部一行轻提示，不阻塞浏览）。
  String? get error => _error;

  /// 是否已经连续多次拉不到云端清单（此时页面显示的是内置片单）。
  bool get usingFallback => _failStreak >= 3 && _fetchedAt == null;

  /// 距离上次成功拉取是否已超过 [maxAge]。
  bool isStale(Duration maxAge) {
    final at = _fetchedAt;
    return at == null || DateTime.now().difference(at) > maxAge;
  }

  /// 读取清单：先回填缓存（如果有），再按需拉云端。
  /// [force] 为 true 时忽略「刚拉过」的判断，强制走一次网络（下拉刷新用）。
  Future<void> load({bool force = false}) {
    final pending = _pending;
    if (pending != null) return pending;
    final future = _load(force).whenComplete(() => _pending = null);
    _pending = future;
    return future;
  }

  Future<void> _load(bool force) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    if (cached != null && cached.trim().isNotEmpty) {
      _applyJson(cached, notify: true);
    }
    if (!force && _fetchedAt != null && !isStale(const Duration(minutes: 20))) {
      _loaded = true;
      notifyListeners();
      return;
    }
    _refreshing = true;
    _error = null;
    notifyListeners();
    try {
      final resp = await http
          .get(Uri.parse(kVideoCatalogUrl))
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final body = utf8.decode(resp.bodyBytes);
      final ok = _applyJson(body, notify: true);
      if (!ok) throw Exception('清单格式不正确');
      _fetchedAt = DateTime.now();
      _failStreak = 0;
      _retryTimer?.cancel();
      _error = null;
      _cloudReachable = true;
      await prefs.setString(_cacheKey, body);
    } catch (e) {
      _error = '$e';
      _failStreak++;
      // 拉不到云端清单就判定「当前网络访问不了云端」，页面先隐藏视频；
      // 后台自动重试成功后 _cloudReachable 会恢复成 true。
      _cloudReachable = false;
      // 拉取失败保留缓存 / 默认清单，页面照常可看；最多再自动重试 3 次。
      if (_catalog.videos.isEmpty) _catalog = VideoCatalog.fallback();
      _scheduleRetry();
    } finally {
      _refreshing = false;
      _loaded = true;
      notifyListeners();
    }
  }

  /// 失败后按 3s / 6s / 12s 退避自动重试，用户不用手点。
  void _scheduleRetry() {
    if (_failStreak > 3) return;
    _retryTimer?.cancel();
    final seconds = _failStreak == 1 ? 3 : (_failStreak == 2 ? 6 : 12);
    _retryTimer = Timer(Duration(seconds: seconds), () {
      unawaited(load(force: true));
    });
  }

  /// 预热一条视频：先拉 HLS 播放列表，再把前两片拉一遍。
  /// 目的是让 CDN 边缘提前缓存住，点播放时首字节快很多；失败静默。
  ///
  /// 源是「自动」档时，列表是 master.m3u8（里面只有各档的子列表），
  /// 会再往下钻一层，预热最低码率那档的头两片——ExoPlayer 起播通常从低档起步。
  Future<void> prewarm(VideoItem video) async {
    final source = video.defaultSource;
    if (source == null || source.url.isEmpty) return;
    if (!source.url.toLowerCase().contains('.m3u8')) return;
    await _prewarmPlaylist(Uri.parse(source.url), depth: 0);
  }

  Future<void> _prewarmPlaylist(Uri uri, {required int depth}) async {
    try {
      final resp =
          await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return;
      final lines = const LineSplitter().convert(resp.body);
      final isMaster = lines.any((l) => l.startsWith('#EXT-X-STREAM-INF'));
      final entries = <Uri>[];
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        entries.add(uri.resolve(line));
      }
      if (isMaster && depth == 0) {
        // 最低码率通常排在最后；钻进去预热它的头两片。
        if (entries.isNotEmpty) {
          await _prewarmPlaylist(entries.last, depth: 1);
        }
        return;
      }
      await Future.wait([
        for (final u in entries.take(2)) _prefetch(u),
      ]);
    } catch (_) {
      // 预热失败不影响正常播放。
    }
  }

  Future<void> _prefetch(Uri uri) async {
    try {
      await http.get(uri).timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// 解析并应用清单；返回是否解析出至少一部可播放视频。
  bool _applyJson(String text, {required bool notify}) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return false;
      final next = VideoCatalog.fromJson(Map<String, dynamic>.from(decoded));
      if (next.videos.isEmpty) return false;
      _catalog = next;
      if (notify) notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }
}
