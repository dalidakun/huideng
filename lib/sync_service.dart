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
import 'reading_badges.dart';
import 'reading_time_service.dart';
import 'sutra_asset_path.dart';

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

  /// 推送执行中标记：同步中发起的推送会排队，避免开关等即时操作被丢弃。
  bool _pushBusy = false;
  bool _pendingPush = false;

  /// 最近一次全量拉取是否失败。失败时周期任务会持续重试拉取，直到成功，
  /// 避免新设备登录时拉取失败后本地打卡数据覆盖云端导致历史丢失。
  bool _fullSyncPending = true;

  /// 打卡类数据：本地与云端做并集合并（绝不丢记录），而不是"云端只补缺失键"。
  static const Set<String> _mergeableCheckInKeys = {
    'checkin_records',
    'custom_checkin_types',
    'checkin_goals',
  };

  /// 云端权威字段：这些字段以云端返回值为准，只要云端有非空值就覆盖本地。
  /// 用于修复「第二天后加入时间变昨天、认证状态丢失」等问题——
  /// 冷启动时若本地缓存异常被清，my_page.dart 会错误写入当前时间；
  /// 同步时默认规则是"本地已有值就跳过云端"，导致错误值永久固化。
  static const Set<String> _cloudAuthorityKeys = {
    'user_created_at',
    'user_verified',
    'user_verified_name',
    'user_account_name',
    'user_nickname',
  };

  static const Set<String> _excludeKeys = {
    'switch_to_sutra',
    'switch_to_assistant',
    'apk_last_update_time',
    'downloaded_sutra_ids',
    'user_avatar_path',
    'user_banner_path',
    // 下载镜像轮换索引：纯本机下载源缓存，跨设备无意义。
    'sutra_downloader_mirror_index',
    // 读经会话开始时间戳：本机「阅读进行中」临时标记。同步到新设备会被
    // start() 当作未结束会话，凭空补记最长 6 小时假时长，故不上传。
    'reading_time_session_start_ms',
    // 本地登录身份缓存（设备本地兜底用），不随数据同步上传。
    'user_login_uid',
    'user_login_phone',
    'user_login_nickname',
  };

  static const int _maxFileChars = 400000;

  /// 头像压缩后最长边像素。
  static const int _avatarMaxSize = 512;

  /// 横幅压缩后最长边像素。
  static const int _bannerMaxSize = 800;

  /// 压缩文件到能放进上传包的字节数内：反复缩小尺寸直到 base64 长度
  /// 不超过 [_maxFileChars]（否则 _collect 会静默跳过，头像/横幅永远上传不上去）。
  Uint8List? _fitForUpload(Uint8List bytes, int maxSide) {
    var side = maxSide;
    for (var i = 0; i < 5; i++) {
      final out = _downscale(bytes, side);
      if (base64Encode(out).length <= _maxFileChars) return out;
      side = (side * 0.7).round();
      if (side < 128) return null;
    }
    return null;
  }

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
      // 登录后立即重读本地读经统计（云端数据恢复完成后再读一次），
      // 避免早先读到的 0 一直显示到重启应用。
      unawaited(ReadingTimeService.instance.reload());
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
    // 上报「阅藏进度」（标记完成册数），供主页头部展示百分比。
    await _reportCanonProgress();
    // 上报读经时长增量，供他人主页展示点亮的修学徽章。
    await ReadingTimeService.instance.reportToCloud();
  }

  /// 上报经藏页「阅藏进度」的原始数据：已完成册数 + 全藏总册数。
  /// 服务端保存原始数值（canonRead/canonTotal），百分比由客户端计算；
  /// 只有数据变化时才上报。
  Future<void> _reportCanonProgress() async {
    if (!AuthService.instance.isLoggedIn) return;
    await LocalCanonProgress.refresh();
    final read = LocalCanonProgress.read;
    final total = LocalCanonProgress.total;
    if (total <= 0 || read == _lastReportedCanonRead) return;
    _lastReportedCanonRead = read;
    try {
      await CloudNotesService.instance
          .reportCanonProgress(readCount: read, totalCount: total);
    } catch (_) {
      // 失败静默，下次周期重试。
    }
  }

  int _lastReportedCanonRead = -1;

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
    // ★ 权威字段修正：绝不信任「云端备份的 prefs 中的 user_created_at / user_verified」
    // 因为旧版本 bug 会把 DateTime.now() 兜底写入本地，然后 push 污染云端备份。
    // 真实注册时间 & 认证状态只来自服务端注册/认证记录表，
    // 通过 getUserProfiles.joinTime 与 getMyVerification() 直接拿到，然后无条件覆盖本地。
    unawaited(_enforceAuthorityFields());
    // 云端恢复的昵称/签名立即刷新到登录态展示（重装/清数据后启动时读到的是默认值）。
    await AuthService.instance.reloadLocalProfile();
    await push();
    // 云端恢复的读经时长可能晚于进程内首次读取：重新读取本地统计并广播，
    // 首页「今日读经/累积读经」立即显示正确值，无需重启应用。
    await ReadingTimeService.instance.reload();
    // 登录/恢复会话后立即上报阅藏进度与读经时长，主页尽快有数据。
    await _reportCanonProgress();
    await ReadingTimeService.instance.reportToCloud();
  }

  /// 用最权威的数据源（getUserProfiles.joinTime / getMyVerification）
  /// 无条件覆盖本地 prefs 中的事实性字段，修复旧版本兜底写入污染问题。
  /// 执行顺序：先写本地 → 再 push 回云端备份 → 彻底把错误的备份值也纠正。
  Future<void> _enforceAuthorityFields() async {
    if (!AuthService.instance.isLoggedIn) return;
    final me = AuthService.instance.currentUser.value;
    if (me == null) return;
    final prefs = await SharedPreferences.getInstance();
    bool anyChanged = false;
    try {
      final profiles =
          await CloudNotesService.instance.getUserProfiles([me.id]);
      if (profiles.isNotEmpty) {
        final p = profiles.first;
        if (p.joinTime > 0) {
          final local = prefs.getInt('user_created_at');
          if (local == null || local != p.joinTime) {
            await prefs.setInt('user_created_at', p.joinTime);
            anyChanged = true;
          }
        }
        if (p.account.isNotEmpty) {
          final local = prefs.getString('user_account_name') ?? '';
          if (local != p.account) {
            await prefs.setString('user_account_name', p.account);
            anyChanged = true;
          }
        }
        if (p.name.isNotEmpty) {
          final local = prefs.getString('user_nickname') ?? '';
          if (local != p.name) {
            await prefs.setString('user_nickname', p.name);
            anyChanged = true;
          }
        }
        // verified 兜底：若 getUserProfiles 说已认证，先覆盖，getMyVerification 会再细查
        final localVer = prefs.getBool('user_verified') ?? false;
        if (p.verified && !localVer) {
          await prefs.setBool('user_verified', true);
          anyChanged = true;
        }
      }
    } catch (_) {}
    try {
      final info = await CloudNotesService.instance.getMyVerification();
      final localVer = prefs.getBool('user_verified') ?? false;
      // 认证状态永久单向：只在云端确认为「已认证」时覆盖为 true，
      // 绝不因云端误报 false（匿名/降级会话解析到共享匿名 uid）把已认证清掉。
      if (info.verified && !localVer) {
        await prefs.setBool('user_verified', true);
        anyChanged = true;
      }
      // 认证后的脱敏真名（如「张*三」），显示在昵称下方；一旦写入不再清空。
      if (info.realNameMasked.isNotEmpty) {
        final local = prefs.getString('user_verified_name') ?? '';
        if (local != info.realNameMasked) {
          await prefs.setString('user_verified_name', info.realNameMasked);
          anyChanged = true;
        }
      }
    } catch (_) {}
    if (anyChanged) {
      dataVersion.value++;
      // 权威字段修正后立即 push 回云端备份，
      // 把"云端备份里错误的昨天日期/未认证状态"也一起纠正。
      unawaited(push());
    }
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
        if (_cloudAuthorityKeys.contains(key) && cv != null) {
          // 云端权威字段：只要云端有非空值就覆盖本地，修复错误的兜底写入。
          final normalizedCv = _normalizeSutraPaths(
              key, cv, prefs, cPrefs['current_sutra_title']?.toString());
          if (lv == null || lv.toString() != normalizedCv.toString()) {
            _writePref(prefs, key, normalizedCv);
            changed = true;
          }
        } else if (lv == null && cv != null) {
          // 普通字段：本地缺失才从云端补齐，避免覆盖本地用户的最新设置。
          _writePref(
              prefs,
              key,
              _normalizeSutraPaths(
                  key, cv, prefs, cPrefs['current_sutra_title']?.toString()));
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
          // 键名先按规范路径归一：旧版本曾用本机绝对路径命名进度键，
          // 不归一的话换机/重装后按规范路径查不到，进度会显示成 0。
          final canonKey = _canonicalProgressKey(key, prefs, cPrefs);
          final ld = _toDouble(_readPref(prefs, canonKey));
          final cd = _toDouble(cv);
          if (cd != null && (ld == null || cd > ld)) {
            prefs.setDouble(canonKey, cd);
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
        // 规范化云端 sutras_list.json 中每条经书的 filePath：
        // 其他设备上传的可能含本机绝对路径（换机后在本机不存在），
        // 原样写入会导致"已下载却显示未下载"。统一映射回 assets/sutras_ascii/...
        String normalized = sutraList;
        try {
          final list = jsonDecode(sutraList) as List<dynamic>;
          var modified = false;
          for (var i = 0; i < list.length; i++) {
            final entry = list[i];
            if (entry is! Map<String, dynamic>) continue;
            final fp = entry['filePath']?.toString();
            if (fp == null || fp.isEmpty) continue;
            if (!fp.startsWith('assets/')) {
              final resolved = SutraAssetPath.resolve(
                title: entry['title']?.toString() ?? '',
                filePath: fp,
              );
              if (resolved.startsWith('assets/') && resolved != fp) {
                entry['filePath'] = resolved;
                modified = true;
              }
            }
          }
          if (modified) normalized = jsonEncode(list);
        } catch (_) {}

        final docs = await getApplicationDocumentsDirectory();
        final f = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
        String? localText;
        if (await f.exists()) {
          try {
            localText = await f.readAsString();
          } catch (_) {}
        }
        if (localText != normalized) {
          try {
            await f.writeAsString(normalized, flush: true);
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
      if (v != null) {
        if (key.startsWith('progress_')) {
          // 进度键按规范路径归一后再上传：旧版本曾用本机绝对路径命名，
          // 随账号流转到其他设备后按规范路径查不到，进度会显示成 0。
          final canonKey = _canonicalProgressKey(key, prefs, null);
          final existing = _toDouble(prefsData[canonKey]);
          final nv = _toDouble(v);
          if (nv != null && (existing == null || nv > existing)) {
            prefsData[canonKey] = v;
          }
        } else {
          // 经书路径类键规范化后再上传：本机绝对路径随账号流转到其他设备
          // 会让已下载的经书被误判为「未下载」。
          prefsData[key] = _normalizeSutraPaths(key, v, prefs);
        }
      }
    }

    final files = <String, dynamic>{};

    final avatarPath = prefs.getString('user_avatar_path');
    if (avatarPath != null && avatarPath.isNotEmpty) {
      final f = File(avatarPath);
      if (await f.exists()) {
        try {
          final bytes = await f.readAsBytes();
          final fitted = _fitForUpload(bytes, _avatarMaxSize);
          if (fitted != null) {
            final name =
                avatarPath.split(Platform.pathSeparator).last;
            files['avatar'] = {'name': name, 'data': base64Encode(fitted)};
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
          final fitted = _fitForUpload(bytes, _bannerMaxSize);
          if (fitted != null) {
            final name =
                bannerPath.split(Platform.pathSeparator).last;
            files['banner'] = {'name': name, 'data': base64Encode(fitted)};
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
        if (text.length <= _maxFileChars) {
          // 上传前同样规范化 filePath，避免本机绝对路径进了云端
          // 被其他设备拿到后误判为「未下载」。
          String uploadText = text;
          try {
            final list = jsonDecode(text) as List<dynamic>;
            var modified = false;
            for (var i = 0; i < list.length; i++) {
              final entry = list[i];
              if (entry is! Map<String, dynamic>) continue;
              final fp = entry['filePath']?.toString();
              if (fp == null || fp.isEmpty) continue;
              if (!fp.startsWith('assets/')) {
                final resolved = SutraAssetPath.resolve(
                  title: entry['title']?.toString() ?? '',
                  filePath: fp,
                );
                if (resolved.startsWith('assets/') && resolved != fp) {
                  entry['filePath'] = resolved;
                  modified = true;
                }
              }
            }
            if (modified) {
              uploadText = jsonEncode(list);
              // 同步把规范化后的版本写回本地
              await listFile.writeAsString(uploadText, flush: true);
            }
          } catch (_) {}
          files['sutras_list'] = uploadText;
        }
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
        final rl = e['isReadLater'] == true;
        final rt = e['readTime']?.toString();
        final ft = e['favoriteTime']?.toString();
        final rlt = e['readLaterTime']?.toString();
        final hasRt = rt != null && rt.isNotEmpty;
        final hasFt = ft != null && ft.isNotEmpty;
        final hasRlt = rlt != null && rlt.isNotEmpty;
        if (!r && !fv && !p && !rl && !hasRt && !hasFt && !hasRlt) continue;
        states[title] = {
          if (r) 'r': true,
          if (fv) 'f': true,
          if (p) 'p': true,
          if (rl) 'rl': true,
          if (hasRt) 'rt': rt,
          if (hasFt) 'ft': ft,
          if (hasRlt) 'rlt': rlt,
        };
      }
      return states.isEmpty ? null : jsonEncode(states);
    } catch (_) {
      return null;
    }
  }

  /// 推送到云端（内容未变化则跳过）。全量拉取或推送进行中时排队，避免丢弃。
  Future<void> push() async {
    if (!AuthService.instance.isLoggedIn) return;
    if (_busy || _pushBusy) {
      _pendingPush = true;
      return;
    }
    _pushBusy = true;
    try {
      final payload = await _collect();
      final jsonStr = jsonEncode(payload);
      if (jsonStr == _lastPushedJson) return;
      try {
        await CloudNotesService.instance.setUserData(payload);
        _lastPushedJson = jsonStr;
      } catch (_) {
        // 失败静默，等待下次周期推送。
      }
    } finally {
      _pushBusy = false;
      if (_pendingPush) {
        _pendingPush = false;
        unawaited(push());
      }
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

  void _writePref(SharedPreferences prefs, String key, Object? v) {
    if (v == null) return;
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

  /// prefs 中记录经书文件路径的键。旧版本可能把本机绝对路径存进这些键并
  /// 上传云端，换机/重新登录恢复后会把已下载的经书误判为「未下载」。
  static const Set<String> _sutraPathKeys = {
    'current_sutra_file_path',
    'locked_sutra_file_path',
    'last_read_filePath',
    'recent_sutras',
    'daily_sutra_history',
  };

  /// 把单条经书路径规范化为打包资产路径（assets/sutras_ascii/...）。
  /// 无法识别（如用户自选本地文件）时原样返回。
  String? _canonicalSutraPath(String? path, String? title) {
    if (path == null || path.isEmpty) return path;
    final resolved =
        SutraAssetPath.resolve(title: title ?? '', filePath: path);
    return resolved.startsWith('assets/') ? resolved : path;
  }

  /// 最近阅读条目格式 `经名|||路径`，只规范化路径部分。
  String _canonicalRecentEntry(String entry) {
    final sep = entry.indexOf('|||');
    if (sep <= 0) return entry;
    final title = entry.substring(0, sep);
    final path = entry.substring(sep + 3);
    final canon = _canonicalSutraPath(path, title);
    return canon == path ? entry : '$title|||$canon';
  }

  /// 每日阅读历史 JSON（`{日期: [{title, filePath, progress}]}`），
  /// 规范化其中的 filePath；解析失败或无需修改时原样返回。
  String _canonicalDailyHistory(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return raw;
      var changed = false;
      for (final list in decoded.values) {
        if (list is! List) continue;
        for (final item in list) {
          if (item is! Map) continue;
          final title = item['title']?.toString() ?? '';
          final fp = item['filePath']?.toString();
          final canon = fp == null ? null : _canonicalSutraPath(fp, title);
          if (canon != null && canon != fp) {
            item['filePath'] = canon;
            changed = true;
          }
        }
      }
      return changed ? jsonEncode(decoded) : raw;
    } catch (_) {
      return raw;
    }
  }

  /// 把 `progress_<路径>` 键的路径部分归一为规范资产路径。
  /// 旧版本曾用本机绝对路径命名进度键（如 `progress_/data/user/0/...`），
  /// 换机/重装后按规范资产路径查不到，阅读进度会显示成 0。
  /// [cloudPrefs] 为云端 prefs 映射（可能含 current_sutra_title），供解析路径。
  String _canonicalProgressKey(
      String key, SharedPreferences prefs, Object? cloudPrefs) {
    final p = key.substring('progress_'.length);
    final title = (cloudPrefs is Map)
        ? cloudPrefs['current_sutra_title']?.toString()
        : null;
    final t = title ?? prefs.getString('current_sutra_title') ?? '';
    final canon = _canonicalSutraPath(p, t);
    return canon == p ? key : 'progress_$canon';
  }

  /// 同步前（收集）与同步后（拉取写入）对含经书路径的 prefs 值做规范化，
  /// 其他键原样返回。[title] 用于解析无 ID 的路径，优先取云端标题。
  Object? _normalizeSutraPaths(
      String key, Object? v, SharedPreferences prefs, [String? title]) {
    if (!_sutraPathKeys.contains(key)) return v;
    final t = title ?? prefs.getString('current_sutra_title') ?? '';
    switch (key) {
      case 'current_sutra_file_path':
      case 'locked_sutra_file_path':
      case 'last_read_filePath':
        return _canonicalSutraPath(v?.toString(), t);
      case 'recent_sutras':
        if (v is List) {
          return v.map((e) => _canonicalRecentEntry(e.toString())).toList();
        }
        return v;
      case 'daily_sutra_history':
        return v is String ? _canonicalDailyHistory(v) : v;
      default:
        return v;
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

  /// 压缩图片到最长边 ≤ [maxSize]，输出 JPEG。无法解码时原样返回。
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
      unawaited(_reportCanonProgress());
      unawaited(ReadingTimeService.instance.reportToCloud());
    }
  }
}
