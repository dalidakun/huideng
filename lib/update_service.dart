import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'notification_service.dart';
import 'settings_widgets.dart';

/// 远程最新版本信息。
class UpdateInfo {
  final String version;
  final int versionCode;
  final String downloadPage;
  final String downloadUrl;
  final String notes;
  final String sha256;

  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.downloadPage,
    required this.downloadUrl,
    required this.notes,
    this.sha256 = '',
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] as String? ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      downloadPage: json['downloadPage'] as String? ?? '',
      downloadUrl: json['downloadUrl'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
    );
  }
}

/// 检查更新的结果：有新版时 [info] 非空；查不到新版时两者都为空；
/// 网络/数据异常时 [error] 给出可展示的提示（避免把失败说成「已是最新」）。
class UpdateCheckResult {
  const UpdateCheckResult({this.info, this.error = ''});

  final UpdateInfo? info;
  final String error;

  bool get hasUpdate => info != null;
}

/// 更新包下载阶段。
enum UpdateDownloadPhase { idle, downloading, completed, failed }

/// 后台下载安装包的实时状态。
///
/// 下载交给系统 DownloadManager，App 内只负责展示与在合适时机提示安装；
/// 因此这个状态可以被任意页面监听（关于我们页的进度条、下载完成后的安装弹窗）。
@immutable
class UpdateDownloadStatus {
  const UpdateDownloadStatus({
    this.phase = UpdateDownloadPhase.idle,
    this.version = '',
    this.progress = 0,
    this.received = 0,
    this.total = 0,
    this.path = '',
    this.error = '',
  });

  final UpdateDownloadPhase phase;
  final String version;
  final double progress;
  final int received;
  final int total;
  final String path;
  final String error;

  static const UpdateDownloadStatus idle = UpdateDownloadStatus();

  bool get isIdle => phase == UpdateDownloadPhase.idle;
  bool get isDownloading => phase == UpdateDownloadPhase.downloading;
  bool get isCompleted => phase == UpdateDownloadPhase.completed;
  bool get isFailed => phase == UpdateDownloadPhase.failed;

  /// 百分比文案，如 `45%`。
  String get percentText =>
      '${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%';

  /// 已下载/总大小文案，如 `12.3 MB / 62.1 MB`。
  String get sizeText {
    if (total > 0) return '${formatBytes(received)} / ${formatBytes(total)}';
    return formatBytes(received);
  }

  UpdateDownloadStatus copyWith({
    UpdateDownloadPhase? phase,
    String? version,
    double? progress,
    int? received,
    int? total,
    String? path,
    String? error,
  }) {
    return UpdateDownloadStatus(
      phase: phase ?? this.phase,
      version: version ?? this.version,
      progress: progress ?? this.progress,
      received: received ?? this.received,
      total: total ?? this.total,
      path: path ?? this.path,
      error: error ?? this.error,
    );
  }
}

/// 字节数转可读文本。
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// 发起后台下载的结果。
enum UpdateStartResult {
  /// 已开始下载。
  started,

  /// 已有下载任务在跑，直接复用。
  alreadyRunning,

  /// 没有直链（只能去网页下载）。
  noUrl,

  /// 系统下载器启动失败。
  failed,
}

/// 安装已下载安装包的结果。
enum UpdateInstallResult {
  /// 已拉起系统安装界面。
  opened,

  /// 缺少「安装未知应用」权限，需要用户去设置里放行。
  needPermission,

  /// 安装包不存在（可能被清理），需要重新下载。
  missing,

  /// 拉起安装界面失败。
  failed,
}

/// App 更新检查与后台下载服务。
///
/// 发布新版流程（需要一台能放静态文件的服务器/对象存储，本项目推荐
/// 腾讯云开发 CloudBase 静态托管）：
///  1. 构建新 APK，上传到静态托管，例如 `huideng/downloads/huideng.apk`；
///  2. 上传 `huideng/download.html`（下载页，见 site/ 目录）；
///  3. 更新 `huideng/version.json` 中的版本号/链接/说明。
///
/// 下载流程：用户点「立即下载」后立即交给系统 [DownloadManager]（原生侧
/// `startApkDownload`），所以收起弹窗、切到后台、甚至杀掉 App 下载都会继续；
/// 下载完成后由原生广播接收器发通知，App 在前台时则弹窗提示安装。
class UpdateService {
  UpdateService._();

  /// 版本检查接口地址：CloudBase 静态托管上的 version.json。
  /// 注意是 .tcloudbaseapp.com（可用），.tcb.qcloud.la 旧域名已失效（418）。
  static const String _checkUrl =
      'https://randeng-d8gs968w22a3d98e8-1461892767.tcloudbaseapp.com/huideng/version.json';

  /// 请求超时（秒）。
  static const int _timeoutSeconds = 8;

  /// 自动检查间隔：约一周一次（「关于我们」里的手动检查不受此限制）。
  static const Duration autoCheckInterval = Duration(days: 7);

  /// 上次检查时间（毫秒时间戳）的持久化键。
  static const String _kLastCheckAt = 'update_last_check_at';

  /// 自动检查是否正在进行：启动与回到前台可能同时触发，避免重复请求/弹窗。
  static bool _autoChecking = false;

  static const MethodChannel _channel = MethodChannel('app_channel');

  /// DownloadManager 状态码。
  static const int _statusSuccessful = 8;
  static const int _statusFailed = 16;

  /// 下载状态（跨页面共享，供进度条与安装提示监听）。
  static final ValueNotifier<UpdateDownloadStatus> downloadStatus =
      ValueNotifier<UpdateDownloadStatus>(UpdateDownloadStatus.idle);

  /// 更新弹窗是否正在显示：弹窗自己会提示安装，避免再叠一层全局提示。
  static int _dialogCount = 0;
  static bool get updateDialogVisible => _dialogCount > 0;

  static void markDialogVisible(bool visible) {
    if (visible) {
      _dialogCount++;
    } else {
      if (_dialogCount > 0) _dialogCount--;
    }
  }

  // 持久化键：让「正在后台下载 / 已下载待安装」在 App 重启后仍然认得。
  static const String _kId = 'update_dl_id';
  static const String _kVersion = 'update_dl_version';
  static const String _kCode = 'update_dl_code';
  static const String _kSha = 'update_dl_sha';
  static const String _kPath = 'update_dl_path';
  static const String _kDone = 'update_dl_done';

  static int? _downloadId;
  static String _downloadSha = '';
  static String _downloadVersion = '';
  static int _downloadCode = 0;
  static Timer? _pollTimer;
  static bool _restored = false;
  static bool _finishing = false;

  // ---------------------------------------------------------------- 版本检查

  /// 检查更新：有新版返回 [UpdateInfo]，无新版/失败返回 null。
  static Future<UpdateInfo?> check() async => (await checkDetailed()).info;

  /// 检查更新并区分「已是最新」与「检查失败」。
  static Future<UpdateCheckResult> checkDetailed() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: _timeoutSeconds)
      ..autoUncompress = true;
    try {
      final request = await client.getUrl(Uri.parse(_checkUrl));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request
          .close()
          .timeout(const Duration(seconds: _timeoutSeconds));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return const UpdateCheckResult(error: '检查更新失败，请稍后重试');
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: _timeoutSeconds));
      final info =
          UpdateInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
      if (info.versionCode <= 0) {
        return const UpdateCheckResult(error: '版本信息异常，请稍后重试');
      }
      final current = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(current.buildNumber) ?? 0;
      if (info.versionCode <= currentCode) return const UpdateCheckResult();
      return UpdateCheckResult(info: info);
    } catch (_) {
      return const UpdateCheckResult(error: '网络异常，未能检查到新版本');
    } finally {
      client.close(force: true);
    }
  }

  /// 启动或回到主页时调用：恢复未完成的下载，并按「约一周一次」的节奏
  /// 静默检查更新；发现新版时弹出与手动检查相同的更新弹窗。
  ///
  /// 是否到期由上次检查时间（持久化）决定，因此关闭 App、重启手机都不会
  /// 让检查过于频繁；网络失败也记录本次尝试，避免每次启动都重复请求。
  static Future<void> checkAndPrompt(BuildContext context) async {
    if (_autoChecking) return;
    _autoChecking = true;
    try {
      await restorePendingDownload();
      // 已有下载好的安装包在等安装：先让用户装掉，避免和更新弹窗叠两层。
      if (downloadStatus.value.isCompleted) return;
      if (!await _isAutoCheckDue()) return;
      final result = await checkDetailed();
      // 无论有没有新版/是否失败，都记下本次检查时间（下次再等一周）。
      await markCheckedNow();
      final info = result.info;
      if (info == null || !context.mounted) return;
      await prompt(context, info);
    } finally {
      _autoChecking = false;
    }
  }

  /// 自动检查是否已到期（纯函数，便于单元测试）。
  static bool isAutoCheckDue({
    required int lastCheckAt,
    required DateTime now,
  }) {
    if (lastCheckAt <= 0) return true;
    return now.millisecondsSinceEpoch - lastCheckAt >=
        autoCheckInterval.inMilliseconds;
  }

  /// 记录本次检查时间；手动检查成功后也调用，避免自动检查紧接着重复请求。
  static Future<void> markCheckedNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kLastCheckAt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // 记录失败只影响下次检查的节流，不影响更新功能本身。
    }
  }

  static Future<bool> _isAutoCheckDue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_kLastCheckAt) ?? 0;
      return isAutoCheckDue(lastCheckAt: last, now: DateTime.now());
    } catch (_) {
      // 读不到记录时按「已到期」处理，保证首次使用能检查到更新。
      return true;
    }
  }

  /// 展示更新弹窗（供「关于我们」页手动检查更新后调用）。
  static Future<void> prompt(BuildContext context, UpdateInfo info) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(info: info),
    );
  }

  // ------------------------------------------------------------ 后台下载流程

  /// 开始系统后台下载。已有任务在跑时直接复用，不会重复下载。
  ///
  /// 下载由系统 DownloadManager 执行，调用后即可收起弹窗/切后台，
  /// 不会阻塞 App。
  static Future<UpdateStartResult> startBackgroundDownload(
    UpdateInfo info,
  ) async {
    if (downloadStatus.value.isDownloading && _downloadId != null) {
      return UpdateStartResult.alreadyRunning;
    }
    final url = info.downloadUrl.trim();
    if (url.isEmpty) return UpdateStartResult.noUrl;

    // 通知权限只影响「下载完成后系统通知」，拿不到也不影响下载本身。
    var granted = true;
    try {
      granted = await NotificationService.instance
          .requestPermission()
          .timeout(const Duration(seconds: 3), onTimeout: () => true);
    } catch (_) {
      granted = false;
    }

    final id = await _startNativeDownload(info, notifyCompleted: !granted);
    if (id == null || id <= 0) return UpdateStartResult.failed;

    _downloadId = id;
    _downloadSha = info.sha256.trim();
    _downloadVersion = info.version;
    _downloadCode = info.versionCode;
    _finishing = false;
    downloadStatus.value = UpdateDownloadStatus(
      phase: UpdateDownloadPhase.downloading,
      version: info.version,
    );
    _startPolling();
    await _persist(done: false);
    return UpdateStartResult.started;
  }

  /// 取消当前下载（系统下载任务一并移除）。
  static Future<void> cancelDownload() async {
    _pollTimer?.cancel();
    final id = _downloadId;
    _downloadId = null;
    _finishing = false;
    if (id != null) await _cancelNativeDownload(id);
    downloadStatus.value = UpdateDownloadStatus.idle;
    await _clearPersisted();
  }

  /// 安装已下载的安装包。失败时返回具体原因，由界面给出对应引导。
  static Future<UpdateInstallResult> installDownloaded() async {
    final status = downloadStatus.value;
    final path = status.path;
    if (!status.isCompleted || path.isEmpty) return UpdateInstallResult.missing;
    if (!await File(path).exists()) {
      downloadStatus.value = UpdateDownloadStatus.idle;
      await _clearPersisted();
      return UpdateInstallResult.missing;
    }
    if (!await _canInstallPackages()) {
      return UpdateInstallResult.needPermission;
    }
    final opened = await _openInstaller(path);
    if (!opened) return UpdateInstallResult.failed;
    downloadStatus.value = UpdateDownloadStatus.idle;
    await _clearPersisted();
    return UpdateInstallResult.opened;
  }

  /// 打开「安装未知应用」权限设置页。
  static Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  /// App 回到前台时刷新一次下载进度（后台期间定时器可能被系统节流）。
  static Future<void> refreshDownload() async {
    if (!downloadStatus.value.isDownloading || _downloadId == null) return;
    await _poll();
  }

  /// 读取上次会话遗留的下载任务：
  ///  - 还在下载 → 接着轮询，完成后照常提示安装；
  ///  - 已下载完 → 直接进入「待安装」状态；
  ///  - 版本已装上/任务已失效 → 清理记录。
  static Future<void> restorePendingDownload() async {
    if (_restored) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getInt(_kId);
      if (id == null || id <= 0) return;
      final version = prefs.getString(_kVersion) ?? '';
      final code = prefs.getInt(_kCode) ?? 0;
      final sha = prefs.getString(_kSha) ?? '';
      final done = prefs.getBool(_kDone) ?? false;
      final savedPath = prefs.getString(_kPath) ?? '';

      final current = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(current.buildNumber) ?? 0;
      if (code > 0 && code <= currentCode) {
        // 新版本已经装上，之前的安装包记录不再需要。
        await _clearPersisted();
        return;
      }

      _downloadId = id;
      _downloadSha = sha;
      _downloadVersion = version;
      _downloadCode = code;

      if (done) {
        if (savedPath.isEmpty || !await File(savedPath).exists()) {
          await _clearPersisted();
          _downloadId = null;
          return;
        }
        downloadStatus.value = UpdateDownloadStatus(
          phase: UpdateDownloadPhase.completed,
          version: version,
          progress: 1,
          path: savedPath,
        );
        return;
      }

      final data = await _queryNativeDownload(id);
      if (data == null) {
        await _clearPersisted();
        _downloadId = null;
        return;
      }
      final status = (data['status'] as num?)?.toInt() ?? 0;
      if (status == _statusSuccessful) {
        await _finishDownload(data);
        return;
      }
      if (status == _statusFailed) {
        await _failDownload('上次的下载未完成，请重新下载');
        return;
      }
      downloadStatus.value = UpdateDownloadStatus(
        phase: UpdateDownloadPhase.downloading,
        version: version,
      );
      _startPolling();
    } catch (_) {
      // 恢复失败不影响正常使用，忽略。
    }
  }

  static void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => unawaited(_poll()),
    );
    unawaited(_poll());
  }

  static Future<void> _poll() async {
    final id = _downloadId;
    if (id == null || _finishing) return;
    if (!downloadStatus.value.isDownloading) return;
    final data = await _queryNativeDownload(id);
    // 轮询期间任务被取消/替换，丢弃这次结果。
    if (id != _downloadId || _finishing) return;
    if (data == null) {
      await _failDownload('下载任务已丢失，请重新下载');
      return;
    }
    final status = (data['status'] as num?)?.toInt() ?? 0;
    final downloaded = (data['downloaded'] as num?)?.toInt() ?? 0;
    final total = (data['total'] as num?)?.toInt() ?? 0;
    final reason = (data['reason'] as num?)?.toInt() ?? 0;
    if (status == _statusSuccessful) {
      await _finishDownload(data);
      return;
    }
    if (status == _statusFailed) {
      await _failDownload(_reasonText(reason));
      return;
    }
    final current = downloadStatus.value;
    downloadStatus.value = current.copyWith(
      phase: UpdateDownloadPhase.downloading,
      progress: total > 0 ? (downloaded / total).clamp(0.0, 1.0) : 0,
      received: downloaded,
      total: total,
    );
  }

  /// 下载完成：校验安装包后进入「待安装」状态，并持久化记录。
  static Future<void> _finishDownload(Map<String, dynamic> data) async {
    if (_finishing) return;
    _finishing = true;
    try {
      _pollTimer?.cancel();
      final path = (data['path'] as String? ?? '').trim();
      final version = (data['version'] as String? ?? '').trim().isNotEmpty
          ? (data['version'] as String).trim()
          : _downloadVersion;
      final expectedSha = (data['sha256'] as String? ?? '').trim().isNotEmpty
          ? (data['sha256'] as String).trim()
          : _downloadSha;
      if (path.isEmpty) {
        await _failDownload('下载完成但找不到安装包，请重新下载');
        return;
      }
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        await _failDownload('安装包不完整，请重新下载');
        return;
      }
      if (!await _verifySha256(path, expectedSha)) {
        try {
          await file.delete();
        } catch (_) {}
        await _failDownload('安装包校验失败，请重新下载');
        return;
      }
      _downloadVersion = version;
      final length = await file.length();
      downloadStatus.value = UpdateDownloadStatus(
        phase: UpdateDownloadPhase.completed,
        version: version,
        progress: 1,
        received: length,
        total: length,
        path: path,
      );
      await _persist(done: true, path: path);
    } finally {
      _finishing = false;
    }
  }

  static Future<void> _failDownload(String error) async {
    _pollTimer?.cancel();
    _downloadId = null;
    _finishing = false;
    downloadStatus.value = UpdateDownloadStatus(
      phase: UpdateDownloadPhase.failed,
      version: _downloadVersion,
      error: error,
    );
    await _clearPersisted();
  }

  static String _reasonText(int reason) {
    // DownloadManager.ERROR_* 常见原因，提示要能指导用户下一步。
    switch (reason) {
      case 404:
      case 400:
        return '下载地址不可用，请前往网页下载';
      case 1006: // ERROR_FILE_ERROR
        return '写入安装包失败，请检查存储空间后重试';
      case 1007: // ERROR_UNHANDLED_HTTP_CODE
        return '下载地址不可用，请前往网页下载';
      case 1008: // ERROR_HTTP_DATA_ERROR
        return '网络中断，下载失败，请重试';
      case 1009: // ERROR_TOO_MANY_REDIRECTS
        return '下载地址异常，请前往网页下载';
      case 1011: // ERROR_INSUFFICIENT_SPACE
        return '存储空间不足，请清理后重试';
      case 1015: // ERROR_CANNOT_RESUME
        return '网络中断，请重试';
      default:
        return '下载失败，请检查网络后重试';
    }
  }

  // ------------------------------------------------------------- 持久化记录

  static Future<void> _persist({required bool done, String path = ''}) async {
    final id = _downloadId;
    if (id == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kId, id);
      await prefs.setString(_kVersion, _downloadVersion);
      await prefs.setInt(_kCode, _downloadCode);
      await prefs.setString(_kSha, _downloadSha);
      await prefs.setBool(_kDone, done);
      await prefs.setString(_kPath, path);
    } catch (_) {
      // 持久化失败只会影响「重启后复原」，不影响本次下载。
    }
  }

  static Future<void> _clearPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kId);
      await prefs.remove(_kVersion);
      await prefs.remove(_kCode);
      await prefs.remove(_kSha);
      await prefs.remove(_kPath);
      await prefs.remove(_kDone);
    } catch (_) {}
  }

  // -------------------------------------------------------------- 原生调用

  /// 交给系统 DownloadManager 下载：离开 App 后仍会在后台继续。
  static Future<int?> _startNativeDownload(
    UpdateInfo info, {
    required bool notifyCompleted,
  }) async {
    try {
      return await _channel.invokeMethod<int>('startApkDownload', {
        'url': info.downloadUrl,
        'version': info.version,
        'sha256': info.sha256,
        'notifyCompleted': notifyCompleted,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _queryNativeDownload(int id) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'queryApkDownload',
        {'downloadId': id},
      );
      if (raw == null) return null;
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> _cancelNativeDownload(int id) async {
    try {
      await _channel.invokeMethod<void>(
        'cancelApkDownload',
        {'downloadId': id},
      );
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  static Future<bool> _openInstaller(String path) async {
    try {
      final opened = await _channel.invokeMethod<bool>(
        'installApk',
        {'filePath': path},
      );
      return opened ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> _canInstallPackages() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallApk') ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  /// 校验安装包（sha256 为空时跳过）。放到后台 isolate，避免大文件卡住界面。
  static Future<bool> _verifySha256(String path, String expected) async {
    final target = expected.trim().toLowerCase();
    if (target.isEmpty) return true;
    try {
      final actual = await compute(_sha256OfFile, path);
      return actual.toLowerCase() == target;
    } catch (_) {
      return false;
    }
  }
}

/// 后台 isolate 里计算文件 sha256（分块读取，避免把整个 APK 读进内存）。
String _sha256OfFile(String path) {
  final sink = _DigestCollector();
  final input = sha256.startChunkedConversion(sink);
  final raf = File(path).openSync();
  try {
    final buffer = Uint8List(128 * 1024);
    while (true) {
      final read = raf.readIntoSync(buffer);
      if (read <= 0) break;
      input.add(read == buffer.length ? buffer : buffer.sublist(0, read));
    }
  } finally {
    raf.closeSync();
  }
  input.close();
  return sink.value?.toString() ?? '';
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 全局监听后台更新下载：下载完成后在 App 内弹窗提示安装。
///
/// 挂在 MaterialApp 的 Navigator 之下（见 main.dart），所以任何页面都能收到提示；
/// 若此时更新弹窗正开着，则交给弹窗自己提示，避免叠两个对话框。
class UpdateInstallPrompt extends StatefulWidget {
  const UpdateInstallPrompt({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateInstallPrompt> createState() => _UpdateInstallPromptState();
}

class _UpdateInstallPromptState extends State<UpdateInstallPrompt>
    with WidgetsBindingObserver {
  /// 已经提示过的安装包路径：同一次下载只提示一次（「稍后安装」不会反复弹）。
  String _promptedPath = '';
  bool _prompting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    UpdateService.downloadStatus.addListener(_onStatusChanged);
    // 启动前可能已有「已下载待安装」的记录，首帧后补一次检查。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onStatusChanged();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UpdateService.downloadStatus.removeListener(_onStatusChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从后台回来时刷新一次：系统可能暂停过轮询定时器。
    if (state == AppLifecycleState.resumed) {
      unawaited(UpdateService.refreshDownload());
      if (mounted) _onStatusChanged();
    }
  }

  void _onStatusChanged() {
    if (!mounted || _prompting) return;
    final status = UpdateService.downloadStatus.value;
    if (!status.isCompleted || status.path.isEmpty) return;
    // 更新弹窗正开着：由弹窗内的「立即安装」处理。
    if (UpdateService.updateDialogVisible) return;
    if (_promptedPath == status.path) return;
    _promptedPath = status.path;
    unawaited(_showInstallPrompt(status));
  }

  Future<void> _showInstallPrompt(UpdateDownloadStatus status) async {
    _prompting = true;
    try {
      final install = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(
            status.version.isEmpty
                ? '新版本下载完成'
                : '新版本 v${status.version} 下载完成',
          ),
          content: const Text(
            '安装包已下载完成，点击「立即安装」即可完成升级。',
            style: TextStyle(fontSize: 14, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('稍后安装'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('立即安装'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (install == true) {
        await installDownloadedWithFeedback(context);
      }
    } finally {
      _prompting = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 执行安装并把各种失败原因翻译成人话（缺权限时直接引导去设置）。
Future<void> installDownloadedWithFeedback(BuildContext context) async {
  final result = await UpdateService.installDownloaded();
  if (!context.mounted) return;
  switch (result) {
    case UpdateInstallResult.opened:
      return;
    case UpdateInstallResult.needPermission:
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要允许安装应用'),
          content: const Text(
            '系统需要你允许「燃灯」安装未知来源的应用，开启后返回即可继续安装。',
            style: TextStyle(fontSize: 14, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (go == true) await UpdateService.openInstallSettings();
      return;
    case UpdateInstallResult.missing:
      _toast(context, '安装包已被清理，请重新下载');
      return;
    case UpdateInstallResult.failed:
      _toast(context, '无法打开系统安装界面，请稍后重试');
      return;
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

/// 更新弹窗：说明更新内容，并把下载交给系统后台下载。
///
/// 还没开始下载时只有「稍后再说 / 立即下载」；点「立即下载」后弹窗展示实时
/// 进度，此时才出现「后台下载」（收起弹窗继续用 App）。无论哪种方式，
/// 下载完成后都会提示安装（前台弹窗 / 后台通知）。
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.info});

  final UpdateInfo info;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  late UpdateDownloadStatus _status;

  @override
  void initState() {
    super.initState();
    UpdateService.markDialogVisible(true);
    _status = UpdateService.downloadStatus.value;
    UpdateService.downloadStatus.addListener(_onStatusChanged);
  }

  @override
  void dispose() {
    UpdateService.downloadStatus.removeListener(_onStatusChanged);
    UpdateService.markDialogVisible(false);
    super.dispose();
  }

  void _onStatusChanged() {
    if (!mounted) return;
    setState(() => _status = UpdateService.downloadStatus.value);
  }

  /// 只认本版本的状态：服务器又发了新版时，旧包的进度/完成态不应算数。
  UpdateDownloadStatus get _current {
    final s = _status;
    if (s.isIdle) return s;
    if (s.version.isEmpty || s.version == widget.info.version) return s;
    // 版本对不上：当成没有任务，避免把别的包说成本次下载。
    if (s.isDownloading) return s;
    return const UpdateDownloadStatus();
  }

  Future<void> _startDownload() async {
    if (_current.isDownloading) return;
    final result = await UpdateService.startBackgroundDownload(widget.info);
    if (!mounted) return;
    switch (result) {
      case UpdateStartResult.started:
      case UpdateStartResult.alreadyRunning:
        return;
      case UpdateStartResult.noUrl:
      case UpdateStartResult.failed:
        await _openDownloadPage();
        return;
    }
  }

  /// 收起弹窗，下载继续在系统里跑；完成后会再弹窗提示安装。
  void _sendToBackground() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('已转到后台下载，完成后会提示你安装'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _install() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await UpdateService.installDownloaded();
    if (!mounted) return;
    switch (result) {
      case UpdateInstallResult.opened:
        Navigator.of(context).pop();
        return;
      case UpdateInstallResult.needPermission:
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('需要允许安装应用'),
            content: const Text(
              '系统需要你允许「燃灯」安装未知来源的应用，开启后返回即可继续安装。',
              style: TextStyle(fontSize: 14, height: 1.6),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('去设置'),
              ),
            ],
          ),
        );
        if (go == true) await UpdateService.openInstallSettings();
        return;
      case UpdateInstallResult.missing:
        messenger?.showSnackBar(
          const SnackBar(content: Text('安装包已被清理，请重新下载')),
        );
        return;
      case UpdateInstallResult.failed:
        messenger?.showSnackBar(
          const SnackBar(content: Text('无法打开系统安装界面，请稍后重试')),
        );
        return;
    }
  }

  Future<void> _openDownloadPage() async {
    final target = widget.info.downloadPage.isNotEmpty
        ? widget.info.downloadPage
        : widget.info.downloadUrl;
    if (target.isEmpty) return;
    await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final status = _current;
    return AlertDialog(
      title: Text('发现新版本 v${info.version}'),
      scrollable: true,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (info.notes.isNotEmpty)
            Text(info.notes, style: const TextStyle(fontSize: 13, height: 1.6))
          else
            const Text('建议升级到最新版本，体验更佳。'),
          if (status.isDownloading) ...[
            const SizedBox(height: 18),
            _buildProgress(status),
          ] else if (status.isCompleted) ...[
            const SizedBox(height: 18),
            Text(
              '安装包已下载完成，点击「立即安装」即可升级。',
              style: TextStyle(fontSize: 13, color: sTextSec),
            ),
          ] else if (status.isFailed) ...[
            const SizedBox(height: 18),
            Text(
              status.error.isEmpty ? '下载失败，请重试' : status.error,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ] else ...[
            const SizedBox(height: 14),
            Text(
              '点「立即下载」开始下载；下载中可选择「后台下载」继续用 App，完成后会提示你安装。',
              style: TextStyle(fontSize: 12, color: sTextHint),
            ),
          ],
        ],
      ),
      actions: _buildActions(status),
    );
  }

  Widget _buildProgress(UpdateDownloadStatus status) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: status.total > 0 ? status.progress : null,
            minHeight: 6,
            backgroundColor: sGold.withValues(alpha: 0.15),
            color: sGold,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '正在下载 ${status.percentText}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(status.sizeText, style: const TextStyle(fontSize: 12)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '点「后台下载」可收起窗口继续用 App，下载在系统后台进行，完成后会提示你安装。',
          style: TextStyle(fontSize: 12, color: sTextHint),
        ),
      ],
    );
  }

  List<Widget> _buildActions(UpdateDownloadStatus status) {
    switch (status.phase) {
      case UpdateDownloadPhase.downloading:
        // 只有下载过程中才提供「后台下载」：收起弹窗后下载在系统里继续，
        // 完成时再弹窗提示安装。
        return [
          TextButton(
            onPressed: () => UpdateService.cancelDownload(),
            child: const Text('取消下载'),
          ),
          FilledButton(
            onPressed: _sendToBackground,
            style: FilledButton.styleFrom(
              backgroundColor: sGold,
              foregroundColor: Colors.white,
            ),
            child: const Text('后台下载'),
          ),
        ];
      case UpdateDownloadPhase.completed:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后安装'),
          ),
          FilledButton(
            onPressed: _install,
            style: FilledButton.styleFrom(
              backgroundColor: sGold,
              foregroundColor: Colors.white,
            ),
            child: const Text('立即安装'),
          ),
        ];
      case UpdateDownloadPhase.failed:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          if (widget.info.downloadPage.isNotEmpty ||
              widget.info.downloadUrl.isNotEmpty)
            TextButton(
              onPressed: _openDownloadPage,
              child: const Text('网页下载'),
            ),
          FilledButton(
            onPressed: _startDownload,
            style: FilledButton.styleFrom(
              backgroundColor: sGold,
              foregroundColor: Colors.white,
            ),
            child: const Text('重试'),
          ),
        ];
      case UpdateDownloadPhase.idle:
        // 还没开始下载：不出现「后台下载」，避免用户误以为下载已经在跑。
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: widget.info.downloadUrl.trim().isEmpty
                ? _openDownloadPage
                : _startDownload,
            style: FilledButton.styleFrom(
              backgroundColor: sGold,
              foregroundColor: Colors.white,
            ),
            child: const Text('立即下载'),
          ),
        ];
    }
  }
}
