import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 从 GitHub 仓库按需下载经书正文到应用文档目录。
///
/// 远端目录结构（与打包 asset 一致）：
///   `sutras_ascii/<卷>/<ID>.txt`
/// 本地保存结构：
///   `<documents>/sutras/<卷>/<ID>.txt`
class SutraDownloader {
  SutraDownloader._();

  static const String baseUrl =
      'https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_ascii/';

  /// 下载源列表：GitHub 直连在部分地区（尤其是国内）经常超时，
  /// 依次尝试以下镜像源，直到某个源成功为止。
  static const List<String> mirrors = [
    baseUrl,
    'https://cdn.jsdelivr.net/gh/dalidakun/huideng@main/assets/sutras_ascii/',
    'https://ghfast.top/https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_ascii/',
    'https://gh-proxy.com/https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_ascii/',
  ];

  static const String _kMirrorIndexKey = 'sutra_downloader_mirror_index';

  static final RegExp _idRe = RegExp(r'(T\d{2}n\d{4}[A-Za-z]?_\d{3})');

  /// 从标题或路径中提取规范 ID，例如 "T01n0031_001"。
  static String? extractId(String? title, [String? filePath]) {
    final m = _idRe.firstMatch(filePath ?? '') ?? _idRe.firstMatch(title ?? '');
    return m?.group(1);
  }

  static Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}sutras');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String remoteUrl(String id) {
    final vol = id.substring(0, 3);
    return '$baseUrl$vol/$id.txt';
  }

  static Future<File> localFile(String id) async {
    final root = await _root();
    final vol = id.substring(0, 3);
    return File(
        '${root.path}${Platform.pathSeparator}$vol${Platform.pathSeparator}$id.txt');
  }

  static Future<bool> isDownloaded(String id) async {
    if (id.isEmpty) return false;
    final f = await localFile(id);
    return f.exists();
  }

  /// 扫描本地已下载经书（`<documents>/sutras/**/*.txt`）的 ID 列表。
  /// 用于把历史下载（如阅读页内直接下载）同步进状态，保证各处「下载完成」对号正确显示。
  static Future<List<String>> listDownloadedIds() async {
    if (kIsWeb) return const [];
    try {
      final root = await _root();
      final ids = <String>{};
      await for (final entity in root.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.txt')) {
          final m = _idRe.firstMatch(entity.uri.pathSegments.last);
          if (m != null) ids.add(m.group(1)!);
        }
      }
      return ids.toList();
    } catch (_) {
      return const [];
    }
  }

  /// 将打包 asset 路径映射到本地已下载副本（不存在返回 null）。
  /// 例如 `assets/sutras_ascii/T01/T01n0031_001.txt` -> `<documents>/sutras/T01/T01n0031_001.txt`
  static Future<File?> localFileForAssetPath(String assetPath) async {
    if (!assetPath.startsWith('assets/sutras_ascii/')) return null;
    final rel = assetPath.substring('assets/sutras_ascii/'.length);
    final root = await _root();
    final f = File('${root.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}');
    if (await f.exists()) return f;
    return null;
  }

  /// 下载源顺序：优先使用上次成功的镜像，避免每次都从超时的源重新开始。
  static Future<List<String>> _orderedSources() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_kMirrorIndexKey);
    if (last == null || last < 0 || last >= mirrors.length) return mirrors;
    final out = List<String>.of(mirrors)..removeAt(last);
    out.insert(0, mirrors[last]);
    return out;
  }

  static Future<void> _rememberSource(String base) async {
    final idx = mirrors.indexOf(base);
    if (idx < 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kMirrorIndexKey, idx);
    } catch (_) {
      // 记住失败不影响下载。
    }
  }

  /// 下载单本经书并保存到本地。成功后返回本地文件，失败抛出异常。
  /// 会依次尝试 [mirrors] 中的所有下载源，某个源成功即返回。
  static Future<File> download(
    String id, {
    void Function(int received, int total)? onProgress,
  }) async {
    final file = await localFile(id);
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');

    final rel = '${id.substring(0, 3)}/$id.txt';
    final errors = <String>[];
    var bestTotal = 0;
    int lastReported = -1;

    final sources = await _orderedSources();
    for (final base in sources) {
      final url = Uri.parse('$base$rel');
      try {
        final ok = await _downloadFrom(url, part, (received, total) {
          if (total > bestTotal) bestTotal = total;
          // 镜像切换时进度可能回退，只上报单调递增的值。
          if (received <= lastReported) return;
          lastReported = received;
          onProgress?.call(received, total > 0 ? total : bestTotal);
        });
        if (ok) {
          if (await file.exists()) await file.delete();
          await part.rename(file.path);
          await _rememberSource(base);
          return file;
        }
      } catch (e) {
        errors.add('$base $e');
      } finally {
        // 清理可能的残留分片，避免影响下一次尝试或误判。
        if (await part.exists()) {
          try {
            await part.delete();
          } catch (_) {}
        }
      }
    }

    throw HttpException(
      errors.isEmpty
          ? '下载失败，请检查网络后重试'
          : '下载失败，请检查网络后重试：${errors.first}',
      uri: Uri.parse(remoteUrl(id)),
    );
  }

  /// 从单个 URL 下载正文写入 [part]，成功返回 true。
  static Future<bool> _downloadFrom(
    Uri url,
    File part,
    void Function(int received, int total)? onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 25);

    try {
      final req = await client.getUrl(url);
      req.headers.set(HttpHeaders.userAgentHeader, 'huideng-app/1.0');
      final resp = await req.close();
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${resp.statusCode} ${resp.reasonPhrase}',
            uri: url);
      }

      final total = resp.contentLength;
      final sink = part.openWrite();
      int received = 0;
      try {
        await for (final chunk in resp) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) onProgress?.call(received, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (total > 0) onProgress?.call(total, total);
      return true;
    } finally {
      client.close(force: true);
    }
  }
}
