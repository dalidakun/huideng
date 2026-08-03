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

  /// 最近一次全量拉取是否失败。失败时周期任务会持续重试拉取，直到成功，
  /// 避免新设备登录时拉取失败后本地打卡数据覆盖云端导致历史丢失。
  bool _fullSyncPending = true;

  /// 打卡类数据：本地与云端做并集合并（绝不丢记录），而不是"云端只补缺失键"。
  static const Set<String> _mergeableCheckInKeys = {
    'checkin_records',
    'custom_checkin_types',
    'checkin_goals',
  };

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
      (_) => unawaited(_periodic()),
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
      _fullSyncPending = true;
    }
  }

  /// 周期任务：上次全量拉取失败则重试拉取合并，否则只做增量推送。
  Future<void> _periodic() async {
    if (_fullSyncPending) {
      await _fullSync();
    } else {
      await push();
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
      _fullSyncPending = false;
    } catch (_) {
      // 网络失败：保留 pending 标记，周期任务会持续重试拉取，避免本地数据覆盖云端。
      _fullSyncPending = true;
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
        // scroll_*/read_* 只在本机使用，不同步，避免挤占同步包体积。
        if (_isLocalOnlyRedundantKey(key)) continue;
        final cv = e.value;
        final lv = _readPref(prefs, key);
        if (lv == null && cv != null) {
          _writePref(prefs, key, cv);
          changed = true;
        } else if (cv is String &&
            lv is String &&
            _mergeableCheckInKeys.contains(key)) {
          // 打卡类数据：本地与云端并集合并，保证换机/换号后历史与连续天数不丢。
          final merged = _mergeCheckInValue(key, cv, lv);
          if (merged != null && merged != lv) {
            prefs.setString(key, merged);
            changed = true;
          }
        } else if (key.startsWith('progress_')) {
          // 阅读进度取较大值（读得更远的一边为准），
          // 避免换机后同步完成前先读了书导致云端进度被覆盖回退。
          final ld = _toDouble(lv);
          final cd = _toDouble(cv);
          if (ld != null && cd != null && cd > ld) {
            prefs.setDouble(key, cd);
            changed = true;
          }
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

      final banner = cFiles['banner'];
      if (banner is Map) {
        final name = banner['name']?.toString();
        final data = banner['data']?.toString();
        if (name != null && data != null && data.isNotEmpty) {
          final existing = prefs.getString('user_banner_path');
          final valid = existing != null &&
              existing.isNotEmpty &&
              File(existing).existsSync();
          if (!valid) {
            final docs = await getApplicationDocumentsDirectory();
            final dest = File('${docs.path}${Platform.pathSeparator}$name');
            try {
              await dest.writeAsBytes(base64Decode(data));
              await prefs.setString('user_banner_path', dest.path);
              changed = true;
            } catch (_) {}
          }
        }
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
      // scroll_*/read_* 只在本机使用，不上传云端。
      if (_isLocalOnlyRedundantKey(key)) continue;
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

    final bannerPath = prefs.getString('user_banner_path');
    if (bannerPath != null && bannerPath.isNotEmpty) {
      final f = File(bannerPath);
      if (await f.exists()) {
        try {
          final bytes = await f.readAsBytes();
          final b64 = base64Encode(_downscaleBanner(bytes));
          if (b64.length <= _maxFileChars) {
            final name =
                bannerPath.split(Platform.pathSeparator).last;
            files['banner'] = {'name': name, 'data': b64};
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

    // 经书状态（已读/收藏/置顶/时间）压缩后随 prefs 一起同步。
    // sutras_list.json 本身太大无法整体上传，这里只汇总有状态变化的经书。
    final sutraStates = await _collectSutraStates();
    if (sutraStates != null) prefsData['sutra_states'] = sutraStates;

    return {'prefs': prefsData, 'files': files};
  }

  /// 从本地 sutras_list.json 汇总经书状态为紧凑 JSON：
  /// `{标题: {r:已读, f:收藏, p:置顶, rt:已读时间, ft:收藏时间}}`，只含非默认状态的经书。
  /// 文件缺失或全部为默认状态时返回 null（不上传，避免覆盖云端已有数据）。
  Future<String?> _collectSutraStates() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await f.exists()) return null;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! List) return null;
      final states = <String, dynamic>{};
      for (final e in decoded) {
        if (e is! Map) continue;
        final title = e['title']?.toString() ?? '';
        if (title.isEmpty) continue;
        final r = e['isRead'] == true;
        final fv = e['isFavorite'] == true;
        final p = e['isPinned'] == true;
        final rt = e['readTime']?.toString();
        final ft = e['favoriteTime']?.toString();
        final hasRt = rt != null && rt.isNotEmpty;
        final hasFt = ft != null && ft.isNotEmpty;
        if (!r && !fv && !p && !hasRt && !hasFt) continue;
        states[title] = {
          if (r) 'r': true,
          if (fv) 'f': true,
          if (p) 'p': true,
          if (hasRt) 'rt': rt,
          if (hasFt) 'ft': ft,
        };
      }
      return states.isEmpty ? null : jsonEncode(states);
    } catch (_) {
      return null;
    }
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
  Object? _readPref(SharedPreferences prefs, String key) {    try {
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

  /// 合并打卡类本地/云端 JSON 字符串，返回合并结果。
  /// 无新增差异时返回 null，避免无意义回写。损坏的 JSON 一律忽略。
  String? _mergeCheckInValue(String key, String cloudJson, String localJson) {
    try {
      switch (key) {
        case 'checkin_records':
          // 以 (date + type) 为唯一键合并，本地优先，云端缺失的补入。
          final byKey = <String, Map<String, dynamic>>{};
          for (final r in _decodeList(localJson)) {
            byKey['${r['date']}|${r['type']}'] = r;
          }
          for (final r in _decodeList(cloudJson)) {
            byKey.putIfAbsent('${r['date']}|${r['type']}', () => r);
          }
          final out = jsonEncode(byKey.values.toList());
          return out == localJson ? null : out;
        case 'custom_checkin_types':
          final byKey = <String, Map<String, dynamic>>{};
          for (final r in _decodeList(localJson)) {
            final k = r['key']?.toString() ?? '';
            if (k.isNotEmpty) byKey[k] = r;
          }
          for (final r in _decodeList(cloudJson)) {
            final k = r['key']?.toString() ?? '';
            if (k.isNotEmpty) byKey.putIfAbsent(k, () => r);
          }
          final out = jsonEncode(byKey.values.toList());
          return out == localJson ? null : out;
        case 'checkin_goals':
          final cloud = _decodeMap(cloudJson);
          final local = _decodeMap(localJson);
          final merged = <String, dynamic>{};
          merged.addAll(local);
          cloud.forEach((k, v) => merged.putIfAbsent(k, () => v));
          final out = jsonEncode(merged);
          return out == localJson ? null : out;
      }
    } catch (_) {}
    return null;
  }

  List<Map<String, dynamic>> _decodeList(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded.map((e) {
      if (e is Map) return Map<String, dynamic>.from(e);
      return <String, dynamic>{};
    }).toList();
  }

  Map<String, dynamic> _decodeMap(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return Map<String, dynamic>.from(decoded);
  }

  /// scroll_*/read_*（阅读滚动位置 / 已读标记）只在本机使用，不同步到云端：
  /// 换设备后阅读位置用 progress_*（进度比例）恢复即可，避免挤占同步包体积。
  bool _isLocalOnlyRedundantKey(String key) {
    return key.startsWith('scroll_') || key.startsWith('read_');
  }

  /// 尝试把 prefs/云端值解析为 double，解析不了返回 null。
  double? _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// 头像压缩到最长边 ≤ [_avatarMaxSize]，输出 JPEG。无法解码时原样返回。
  Uint8List _downscaleAvatar(Uint8List bytes) {
    return _downscale(bytes, _avatarMaxSize);
  }

  /// 横幅压缩到最长边 ≤ [_bannerMaxSize]，输出 JPEG。无法解码时原样返回。
  Uint8List _downscaleBanner(Uint8List bytes) {
    return _downscale(bytes, _bannerMaxSize);
  }

  /// 横幅压缩后最长边像素。
  static const int _bannerMaxSize = 800;

  Uint8List _downscale(Uint8List bytes, int maxSize) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      final w = decoded.width;
      final h = decoded.height;
      final m = w > h ? w : h;
      if (m <= maxSize) {
        return Uint8List.fromList(img.encodeJpg(decoded, quality: 85));
      }
      final scale = maxSize / m;
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
