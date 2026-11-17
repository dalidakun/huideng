import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'video_catalog.dart';

/// 一部视频在本机的下载状态。
enum VideoDownloadStatus { idle, downloading, done, failed }

class VideoDownloadTask {
  final String videoId;
  VideoDownloadStatus status;
  int receivedBytes;
  int totalBytes;
  String? error;
  DateTime? startedAt;

  VideoDownloadTask({
    required this.videoId,
    this.status = VideoDownloadStatus.idle,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
    this.startedAt,
  });

  bool get done => status == VideoDownloadStatus.done;

  bool get downloading => status == VideoDownloadStatus.downloading;

  double get progress {
    if (totalBytes <= 0) return 0;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// 当前速度（字节/秒），用于「1.2 MB/s · 还剩 3 分钟」。
  double get bytesPerSecond {
    final at = startedAt;
    if (at == null || receivedBytes <= 0) return 0;
    final seconds = DateTime.now().difference(at).inMilliseconds / 1000.0;
    if (seconds <= 0) return 0;
    // 断点续传时 receivedBytes 含旧进度，速度会偏高；只作展示，够用。
    return receivedBytes / seconds;
  }
}

/// 视频下载仓库：把光鸭等网盘的直链（或分片直链）下载到 App 私有目录，
/// 下载完用本地文件播放。
///
/// - 文件放在应用文档目录 `videos/<id>.mp4`，不需要存储权限；
/// - 单片先写 `<id>.part`，分片写 `<id>.p0 …`，都支持 HTTP Range 断点续传；
/// - 分片全部下完后按顺序拼成 `<id>.mp4`，校验总大小后删除分片。
class VideoDownloadStore extends ChangeNotifier {
  VideoDownloadStore._();

  static final VideoDownloadStore instance = VideoDownloadStore._();

  final Map<String, VideoDownloadTask> _tasks = {};
  final Map<String, http.Client> _clients = {};
  Directory? _dir;
  bool _cancelRequested = false;

  VideoDownloadTask taskOf(String videoId) =>
      _tasks.putIfAbsent(videoId, () => VideoDownloadTask(videoId: videoId));

  bool isDownloading(String videoId) =>
      _tasks[videoId]?.status == VideoDownloadStatus.downloading;

  /// 已下载到本地的文件（没有就是 null）。
  Future<File?> localFile(String videoId) async {
    final dir = await _videoDir();
    final f = File('${dir.path}${Platform.pathSeparator}$videoId.mp4');
    if (await f.exists() && await f.length() > 0) return f;
    return null;
  }

  /// 启动下载；已下载 / 下载中的直接返回。
  Future<void> download(VideoItem video) async {
    final id = video.id;
    final task = taskOf(id);
    if (task.status == VideoDownloadStatus.downloading) return;
    final existing = await localFile(id);
    if (existing != null) {
      task.status = VideoDownloadStatus.done;
      task.receivedBytes = task.totalBytes = await existing.length();
      notifyListeners();
      return;
    }
    if (video.parts.isNotEmpty) {
      await _downloadParts(video);
      return;
    }
    if (video.downloadUrl.isEmpty) {
      task.status = VideoDownloadStatus.failed;
      task.error = '这部视频还没有配置下载地址';
      notifyListeners();
      return;
    }

    _cancelRequested = false;
    task.status = VideoDownloadStatus.downloading;
    task.error = null;
    task.startedAt = DateTime.now();
    final dir = await _videoDir();
    final part = File('${dir.path}${Platform.pathSeparator}$id.part');
    final target = File('${dir.path}${Platform.pathSeparator}$id.mp4');
    final client = http.Client();
    _clients[id] = client;
    IOSink? sink;
    try {
      var start = 0;
      if (await part.exists()) start = await part.length();
      final req = http.Request('GET', Uri.parse(video.downloadUrl));
      if (start > 0) req.headers['Range'] = 'bytes=$start-';
      final resp = await client.send(req);
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final isResume = resp.statusCode == 206;
      if (!isResume) start = 0;
      final total = (resp.contentLength ?? 0) + start;
      task.receivedBytes = start;
      task.totalBytes = total;
      notifyListeners();

      sink = part.openWrite(
        mode: start > 0 ? FileMode.append : FileMode.write,
      );
      var lastNotify = 0;
      await for (final chunk in resp.stream) {
        if (_cancelRequested) throw const _Cancelled();
        sink.add(chunk);
        task.receivedBytes += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastNotify > 250) {
          lastNotify = now;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (_cancelRequested) throw const _Cancelled();
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      task.status = VideoDownloadStatus.done;
      task.receivedBytes = task.totalBytes;
    } on _Cancelled {
      task.status = VideoDownloadStatus.idle;
    } catch (e) {
      // 取消时关闭 client 会让流抛 ClientException，这里按「已取消」处理。
      if (_cancelRequested) {
        task.status = VideoDownloadStatus.idle;
      } else {
        task.status = VideoDownloadStatus.failed;
        task.error = _friendly(e);
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      _clients.remove(id)?.close();
      notifyListeners();
    }
  }

  /// 分片下载：每片单独续传，全部下完按顺序拼成一个 MP4。
  Future<void> _downloadParts(VideoItem video) async {
    final id = video.id;
    final task = taskOf(id);
    _cancelRequested = false;
    task.status = VideoDownloadStatus.downloading;
    task.error = null;
    task.startedAt = DateTime.now();
    final dir = await _videoDir();
    final sep = Platform.pathSeparator;
    final client = http.Client();
    _clients[id] = client;
    final total = video.expectedBytes;
    task.totalBytes = total;
    task.receivedBytes = 0;
    final mergeFile = File('${dir.path}$sep$id.merge');
    final target = File('${dir.path}$sep$id.mp4');
    try {
      var base = 0;
      for (var i = 0; i < video.parts.length; i++) {
        if (_cancelRequested) throw const _Cancelled();
        final meta = video.parts[i];
        final f = File('${dir.path}$sep$id.p$i');
        var have = await f.exists() ? await f.length() : 0;
        if (meta.size > 0 && have == meta.size) {
          base += have;
          task.receivedBytes = base;
          notifyListeners();
          continue;
        }
        if (meta.size > 0 && have > meta.size) {
          await f.delete();
          have = 0;
        }
        final req = http.Request('GET', Uri.parse(meta.url));
        if (have > 0) req.headers['Range'] = 'bytes=$have-';
        final resp = await client.send(req);
        if (resp.statusCode != 200 && resp.statusCode != 206) {
          throw Exception('HTTP ${resp.statusCode}');
        }
        if (resp.statusCode != 206) have = 0;
        final sink =
            f.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
        var lastNotify = 0;
        await for (final chunk in resp.stream) {
          if (_cancelRequested) {
            await sink.close();
            throw const _Cancelled();
          }
          sink.add(chunk);
          have += chunk.length;
          task.receivedBytes = base + have;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastNotify > 250) {
            lastNotify = now;
            notifyListeners();
          }
        }
        await sink.flush();
        await sink.close();
        if (meta.size > 0 && have != meta.size) {
          throw Exception('第 ${i + 1} 片大小不一致');
        }
        base += have;
        task.receivedBytes = base;
        notifyListeners();
      }

      if (_cancelRequested) throw const _Cancelled();
      // 按顺序拼到临时文件，校验总大小后再改名。
      final sink = mergeFile.openWrite();
      for (var i = 0; i < video.parts.length; i++) {
        await sink.addStream(File('${dir.path}$sep$id.p$i').openRead());
      }
      await sink.flush();
      await sink.close();
      if (total > 0 && await mergeFile.length() != total) {
        throw Exception('拼接后大小不一致');
      }
      if (await target.exists()) await target.delete();
      await mergeFile.rename(target.path);
      for (var i = 0; i < video.parts.length; i++) {
        final f = File('${dir.path}$sep$id.p$i');
        if (await f.exists()) await f.delete();
      }
      task.status = VideoDownloadStatus.done;
      task.receivedBytes = task.totalBytes = await target.length();
    } on _Cancelled {
      task.status = VideoDownloadStatus.idle;
    } catch (e) {
      if (_cancelRequested) {
        task.status = VideoDownloadStatus.idle;
      } else {
        task.status = VideoDownloadStatus.failed;
        task.error = _friendly(e);
        try {
          if (await mergeFile.exists()) await mergeFile.delete();
        } catch (_) {}
      }
    } finally {
      _clients.remove(id)?.close();
      notifyListeners();
    }
  }

  /// 取消下载（保留已下载的部分，下次续传）。
  void cancel(String videoId) {
    if (!isDownloading(videoId)) return;
    _cancelRequested = true;
    _clients.remove(videoId)?.close();
    final task = _tasks[videoId];
    if (task != null) {
      task.status = VideoDownloadStatus.idle;
      notifyListeners();
    }
  }

  /// 删除已下载文件（含分片、拼接临时文件）。
  Future<void> delete(String videoId) async {
    final dir = await _videoDir();
    final sep = Platform.pathSeparator;
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        final name = entity.path.split(sep).last;
        if (name == '$videoId.mp4' ||
            name == '$videoId.part' ||
            name == '$videoId.merge' ||
            name.startsWith('$videoId.p')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    final task = _tasks[videoId];
    if (task != null) {
      task.status = VideoDownloadStatus.idle;
      task.receivedBytes = 0;
      task.totalBytes = 0;
      notifyListeners();
    }
  }

  /// 手动模式：把用户从网盘下载到手机的分片合并成一个 MP4。
  /// [files] 必须已经按顺序排好；[expectedBytes] > 0 时校验总大小。
  Future<File> mergeLocalFiles(
    String videoId,
    List<String> files, {
    int expectedBytes = 0,
  }) async {
    final dir = await _videoDir();
    final sep = Platform.pathSeparator;
    final target = File('${dir.path}$sep$videoId.mp4');
    final temp = File('${dir.path}$sep$videoId.merge');
    final sink = temp.openWrite();
    for (final p in files) {
      await sink.addStream(File(p).openRead());
    }
    await sink.flush();
    await sink.close();
    if (expectedBytes > 0 && await temp.length() != expectedBytes) {
      await temp.delete();
      throw Exception('合并后大小不一致（应为 $expectedBytes 字节）');
    }
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
    final task = taskOf(videoId);
    task.status = VideoDownloadStatus.done;
    task.receivedBytes = task.totalBytes = await target.length();
    notifyListeners();
    return target;
  }

  Future<Directory> _videoDir() async {
    final cached = _dir;
    if (cached != null && await cached.exists()) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}videos');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  String _friendly(Object e) {
    final text = '$e';
    if (text.contains('SocketException') || text.contains('Connection')) {
      return '网络中断，点重试会接着下载';
    }
    if (text.contains('403')) return '下载地址无权访问（403）';
    if (text.contains('404')) return '下载文件不存在（404）';
    return '下载失败：$text';
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
