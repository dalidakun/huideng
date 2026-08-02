import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';

/// 全量本地数据云同步：
///  - 收集所有 SharedPreferences 键 + 头像文件 + sutras_list.json，
///  - 登录/启动时从云端拉取并合并到本地（缺失键补齐、冲突保留本地），再推回云端，
///  - 每 5 分钟及 App 退后台时增量推送。
///
/// 规则：
///  - prefs 键：云端缺失的键补到本地；本地已有且不同的键以本地为准。
///  - 文件（头像、经书列表）：云端存在且本地缺失时才恢复。
class SyncService with WidgetsBindingObserver {
  SyncService._();

  static final SyncService instance = SyncService._();

  /// 拉取应用后 +1，供主页面监听并刷新（修学/我的）。
  final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  Timer? _timer;
  String? _lastPushedJson;
  bool _busy = false;

  static const Set<String> _excludeKeys = {
    'switch_to_sutra',
    'switch_to_assistant',
    'apk_last_update_time',
    'downloaded_sutra_ids',
    'user_avatar_path',
  };

  static const int _maxFileChars = 400000;

  /// 头像压缩后最长边像素。
  static const int _avatarMaxSize = 512;

  /// 应用启动时调用：注册监听 + 启动定时推送 + 处理已恢复的会话。
  void init() {
    WidgetsBinding.instance.addObserver(this);
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(push()),
    );
    _onAuthChanged();
  }

  /// 停止定时器并注销监听（正常不会调用，仅用于测试/彻底清理）。
  void dispose() {
    _timer?.cancel();
    _timer = null;
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
  }

  void _onAuthChanged() {
    if (AuthService.instance.isLoggedIn) {
      unawaited(_fullSync());
    } else {
      _lastPushedJson = null;
    }
  }

  /// 登录/恢复会话后：拉取云端 → 合并到本地 → 推回（含本地新增）。
  Future<void> _fullSync() async {
    if (_busy || !AuthService.instance.isLoggedIn) return;
    _busy = true;
    try {
      final cloud = await CloudNotesService.instance.getUserData();
      if (cloud != null) {
        final changed = await _applyCloud(cloud);
        if (changed) dataVersion.value++;
      }
    } catch (_) {
      // 网络失败静默，下次周期同步或登录重试。
    } finally {
      _busy = false;
    }
    await push();
  }

  /// 拉取云端并合并到本地。
  Future<bool> _applyCloud(Map<String, dynamic> cloud) async {
    var changed = false;
    final prefs = await SharedPreferences.getInstance();

    final cPrefs = cloud['prefs'];
    if (cPrefs is Map) {
      for (final e in cPrefs.entries) {
        final key = e.key.toString();
        if (_excludeKeys.contains(key)) continue;
        final cv = e.value;
        final lv = _readPref(prefs, key);
        if (lv == null && cv != null) {
          _writePref(prefs, key, cv);
          changed = true;
        }
      }
    }

    final cFiles = cloud['files'];
    if (cFiles is Map) {
      final avatar = cFiles['avatar'];
      if (avatar is Map) {
        final name = avatar['name']?.toString();
        final data = avatar['data']?.toString();
        if (name != null && data != null && data.isNotEmpty) {
          final existing = prefs.getString('user_avatar_path');
          final valid = existing != null &&
              existing.isNotEmpty &&
              File(existing).existsSync();
          if (!valid) {
            final docs = await getApplicationDocumentsDirectory();
            final dest = File('${docs.path}${Platform.pathSeparator}$name');
            try {
              await dest.writeAsBytes(base64Decode(data));
              await prefs.setString('user_avatar_path', dest.path);
              changed = true;
            } catch (_) {}
          }        }
      }

      final sutraList = cFiles['sutras_list']?.toString();
      if (sutraList != null && sutraList.isNotEmpty) {
        final docs = await getApplicationDocumentsDirectory();
        final f = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
        String? localText;
        if (await f.exists()) {
          try {
            localText = await f.readAsString();
          } catch (_) {}
        }
        if (localText != sutraList) {
          try {
            await f.writeAsString(sutraList, flush: true);
            changed = true;
          } catch (_) {}
        }
      }
    }

    return changed;
  }

  /// 收集本地全部可同步数据。
  Future<Map<String, dynamic>> _collect() async {
    final prefs = await SharedPreferences.getInstance();
    final prefsData = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (_excludeKeys.contains(key)) continue;
      final v = _readPref(prefs, key);
      if (v != null) prefsData[key] = v;
    }

    final files = <String, dynamic>{};

    final avatarPath = prefs.getString('user_avatar_path');
    if (avatarPath != null && avatarPath.isNotEmpty) {
      final f = File(avatarPath);
      if (await f.exists()) {
        try {
          final bytes = await f.readAsBytes();
          final b64 = base64Encode(_downscaleAvatar(bytes));
          if (b64.length <= _maxFileChars) {
            final name =
                avatarPath.split(Platform.pathSeparator).last;
            files['avatar'] = {'name': name, 'data': b64};
          }
        } catch (_) {}
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    final listFile =
        File('${docs.path}${Platform.pathSeparator}sutras_list.json');
    if (await listFile.exists()) {
      try {
        final text = await listFile.readAsString();
        if (text.length <= _maxFileChars) files['sutras_list'] = text;
      } catch (_) {}
    }

    return {'prefs': prefsData, 'files': files};
  }

  /// 推送到云端（内容未变化则跳过）。
  Future<void> push() async {
    if (_busy || !AuthService.instance.isLoggedIn) return;
    final payload = await _collect();
    final jsonStr = jsonEncode(payload);
    if (jsonStr == _lastPushedJson) return;
    try {
      await CloudNotesService.instance.setUserData(payload);
      _lastPushedJson = jsonStr;
    } catch (_) {
      // 失败静默，等待下次周期推送。
    }
  }

  /// 安全读取任意类型的 prefs 键（避免类型断言抛错）。
  Object? _readPref(SharedPreferences prefs, String key) {
    try {
      final v = prefs.getString(key);
      if (v != null) return v;
    } catch (_) {}
    try {
      final v = prefs.getBool(key);
      if (v != null) return v;
    } catch (_) {}
    try {
      final v = prefs.getInt(key);
      if (v != null) return v;
    } catch (_) {}
    try {
      final v = prefs.getDouble(key);
      if (v != null) return v;
    } catch (_) {}
    try {
      final v = prefs.getStringList(key);
      if (v != null) return v;
    } catch (_) {}
    return null;
  }

  void _writePref(SharedPreferences prefs, String key, Object v) {
    if (v is String) {
      prefs.setString(key, v);
    } else if (v is bool) {
      prefs.setBool(key, v);
    } else if (v is int) {
      prefs.setInt(key, v);
    } else if (v is double) {
      prefs.setDouble(key, v);
    } else if (v is List) {
      prefs.setStringList(key, v.map((e) => e.toString()).toList());
    }
  }

  /// 头像压缩到最长边 ≤ [_avatarMaxSize]，输出 JPEG。无法解码时原样返回。
  Uint8List _downscaleAvatar(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      final w = decoded.width;
      final h = decoded.height;
      final m = w > h ? w : h;
      if (m <= _avatarMaxSize) {
        return Uint8List.fromList(img.encodeJpg(decoded, quality: 85));
      }
      final scale = _avatarMaxSize / m;
      final resized = img.copyResize(
        decoded,
        width: (w * scale).round(),
        height: (h * scale).round(),
      );
      return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    } catch (_) {
      return bytes;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && AuthService.instance.isLoggedIn) {
      unawaited(push());
    }
  }
}
