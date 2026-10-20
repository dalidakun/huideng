import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 祈福图片本地缓存。
///
/// 云存储临时链接每次都会变化，因此以稳定的 fileID 为键缓存到本地，
/// 第二次打开详情页时可直接读文件，避免重复下载。
class BlessingImageCache {
  BlessingImageCache._();

  static final BlessingImageCache instance = BlessingImageCache._();

  final Map<String, Future<File?>> _inflight = {};
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final tmp = await getTemporaryDirectory();
    await _hideFromGallery(tmp);
    final dir = Directory('${tmp.path}${Platform.pathSeparator}blessing_images');
    if (!await dir.exists()) await dir.create(recursive: true);
    await _hideFromGallery(dir);
    _dir = dir;
    return dir;
  }

  /// 让系统相册忽略缓存目录，避免详情页图片出现在用户本地相册。
  Future<void> _hideFromGallery(Directory dir) async {
    try {
      final marker = File('${dir.path}${Platform.pathSeparator}.nomedia');
      if (!await marker.exists()) await marker.writeAsString('');
    } catch (_) {}
  }

  /// 选图前给系统缓存目录放 .nomedia，避免 image_picker 的临时副本被相册收录。
  static Future<void> hidePickerCache() async {
    try {
      final tmp = await getTemporaryDirectory();
      final marker = File('${tmp.path}${Platform.pathSeparator}.nomedia');
      if (!await marker.exists()) await marker.writeAsString('');
    } catch (_) {}
  }

  String _key(String fileId) {
    final raw = fileId.split('/').last;
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty) return 'empty';
    return safe.length <= 120 ? safe : safe.substring(0, 120);
  }

  /// 返回缓存文件；缓存不存在时下载并保存。
  Future<File?> get(String fileId, String url) {
    if (fileId.isEmpty && url.isEmpty) return Future.value(null);
    final key = _key(fileId.isEmpty ? url : fileId);
    final running = _inflight[key];
    if (running != null) return running;
    final future = _load(key, url);
    _inflight[key] = future;
    future.whenComplete(() => _inflight.remove(key));
    return future;
  }

  Future<File?> _load(String key, String url) async {
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}${Platform.pathSeparator}$key.img');
      if (await file.exists() && await file.length() > 0) return file;
      if (url.isEmpty) return null;

      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        if (res.statusCode != 200) return null;
        final tmp = File('${file.path}.tmp');
        final sink = tmp.openWrite();
        await res.forEach(sink.add);
        await sink.flush();
        await sink.close();
        if (await tmp.length() == 0) {
          await tmp.delete();
          return null;
        }
        if (await file.exists()) await file.delete();
        await tmp.rename(file.path);
        return file;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _dir = null;
  }
}
