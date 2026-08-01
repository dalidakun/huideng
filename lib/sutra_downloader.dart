import 'dart:io';

import 'package:path_provider/path_provider.dart';

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

  /// 下载单本经书并保存到本地。成功后返回本地文件，失败抛出异常。
  static Future<File> download(
    String id, {
    void Function(int received, int total)? onProgress,
  }) async {
    final url = Uri.parse(remoteUrl(id));
    final file = await localFile(id);
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);

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

      if (await part.exists()) {
        if (await file.exists()) await file.delete();
        await part.rename(file.path);
      }
      return file;
    } finally {
      client.close(force: true);
    }
  }
}
