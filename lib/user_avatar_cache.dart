import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_notes_service.dart';

/// 批量拉取头像的函数签名（测试可注入桩实现）。
typedef AvatarFetcher = Future<List<UserProfile>> Function(List<String> ids);

/// 广场/帖子/评论等场景的「他人头像 base64」缓存。
///
/// 帖子列表接口不内嵌作者头像（避免响应过大），由本服务按需批量调用
/// `getUserProfiles` 拉取当前页作者的头像并缓存；[UserAvatar] 对非本人
/// 用户先查缓存，未命中则触发拉取，头像到达后通知重建。
///
/// 缓存分两级：
/// 1. 内存缓存（_cache）：同一次运行内即时命中。
/// 2. 磁盘缓存（SharedPreferences）：app 重启后从磁盘恢复，避免冷启动
///    时所有头像都走云函数拉取（冷启动会话恢复 + 网络往返很慢）。
class UserAvatarCache extends ChangeNotifier {
  UserAvatarCache._();

  static final UserAvatarCache instance = UserAvatarCache._();

  /// 拉取函数（默认走云端，测试可替换）。
  @visibleForTesting
  AvatarFetcher fetcher = CloudNotesService.instance.getUserProfiles;

  /// 头像缓存：uid -> base64。
  final Map<String, String> _cache = {};

  /// 拉取中的 uid（去重）。
  final Set<String> _pending = {};

  /// 头像时效：24 小时内不重复拉取（用户换头像后最多 24 小时生效）。
  /// 头像不常变，5 分钟 TTL 导致每次冷启动都要重新拉取所有头像，太慢。
  static const Duration _ttl = Duration(hours: 24);
  final Map<String, DateTime> _fetchedAt = {};

  /// 当前帧内待拉取的 uid，统一合并成一次批量请求。
  final Set<String> _queue = {};
  Timer? _flushTimer;

  /// 磁盘缓存 key 前缀。
  static const String _diskKeyPrefix = 'avatar_cache_';
  static const String _diskTimePrefix = 'avatar_time_';

  /// 是否已从磁盘加载过（只执行一次）。
  bool _diskLoaded = false;

  /// 从磁盘加载所有缓存的头像到内存（app 启动时调用一次）。
  Future<void> loadFromDisk() async {
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final now = DateTime.now();
      for (final key in keys) {
        if (!key.startsWith(_diskKeyPrefix)) continue;
        final uid = key.substring(_diskKeyPrefix.length);
        final b64 = prefs.getString(key);
        if (b64 == null || b64.isEmpty) continue;
        // 检查 TTL：过期的磁盘缓存不恢复，下次按需重新拉取。
        final timeKey = '$_diskTimePrefix$uid';
        final timeMs = prefs.getInt(timeKey) ?? 0;
        final fetched = DateTime.fromMillisecondsSinceEpoch(timeMs);
        if (now.difference(fetched) > _ttl) continue;
        _cache[uid] = b64;
        _fetchedAt[uid] = fetched;
      }
      debugPrint('[AvatarCache] loaded ${_cache.length} avatars from disk');
    } catch (e) {
      debugPrint('[AvatarCache] loadFromDisk error: $e');
    }
  }

  /// 将单个头像写入磁盘缓存。
  Future<void> _saveToDisk(String uid, String b64) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_diskKeyPrefix$uid', b64);
      await prefs.setInt(
          '$_diskTimePrefix$uid', DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[AvatarCache] _saveToDisk error: $e');
    }
  }

  /// 请求某用户头像；已缓存立即返回，否则排队批量拉取（结果到达时通知监听者）。
  /// 首次调用会自动触发磁盘缓存加载（异步，不阻塞当前返回）。
  String? request(String uid) {
    if (uid.isEmpty) return null;
    // 确保磁盘缓存已加载（只执行一次，后续调用无开销）。
    if (!_diskLoaded) loadFromDisk();
    final cached = _cache[uid];
    if (cached != null) return cached;
    if (_pending.contains(uid)) return null;
    _pending.add(uid);
    _queue.add(uid);
    _scheduleFlush();
    return null;
  }

  /// 直接返回缓存（不触发拉取）。
  String? peek(String uid) => _cache[uid];

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 100), _flush);
  }

  Future<void> _flush() async {
    _flushTimer = null;
    final ids = _queue.toList();
    _queue.clear();
    if (ids.isEmpty) return;
    // 只拉取 TTL 内没拉取过的（无论是否真的设置了头像，避免反复请求）。
    final now = DateTime.now();
    final need = ids.where((id) {
      final fetched = _fetchedAt[id];
      return fetched == null || fetched.isBefore(now.subtract(_ttl));
    }).toList();
    if (need.isEmpty) {
      for (final id in ids) {
        _pending.remove(id);
      }
      return;
    }
    try {
      final profiles = await fetcher(need);
      for (final p in profiles) {
        if (p.avatar.isNotEmpty) {
          _cache[p.id] = p.avatar;
          // 异步写入磁盘，不阻塞 UI。
          unawaited(_saveToDisk(p.id, p.avatar));
        }
        _fetchedAt[p.id] = now;
      }
      for (final id in need) {
        _pending.remove(id);
        // 用户确实没有头像时也记录拉取时间，避免每次重建都重复请求。
        if (!_fetchedAt.containsKey(id)) _fetchedAt[id] = now;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[AvatarCache] _flush error: $e');
      for (final uid in need) {
        _pending.remove(uid);
        _fetchedAt[uid] = now;
      }
    }
  }

  /// 清空缓存（头像修改后由编辑页调用，让本机立即展示新头像）。
  void invalidate(String uid) {
    _cache.remove(uid);
    _fetchedAt.remove(uid);
    _pending.remove(uid);
    // 同步清除磁盘缓存。
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove('$_diskKeyPrefix$uid');
      prefs.remove('$_diskTimePrefix$uid');
    });
    notifyListeners();
  }

  /// 清空全部缓存与待拉取队列（仅测试用）。
  @visibleForTesting
  void resetForTest() {
    _cache.clear();
    _pending.clear();
    _fetchedAt.clear();
    _queue.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    _diskLoaded = true; // 测试时不从磁盘加载
  }
}
