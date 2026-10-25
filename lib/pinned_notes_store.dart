import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 置顶帖的本地存储。
///
/// 规则（与产品口径一致）：
///  - **只能置顶自己的帖子**：帖子（原创/转发）才提供「置顶」入口，
///    调用前由各页面用 `isOwnContent()` 判定归属 —— 他人内容不出现「置顶」，
///    **回复帖也不出现「置顶」**（回复的三点菜单只有编辑/删除），判定统一走
///    [showsPinEntry]；
///  - **同时只保留一条置顶**：置顶新内容会自动顶掉之前的置顶（替换语义，
///    旧置顶立即变回普通内容），再次点击同一条则取消置顶；
///  - 置顶只改变「个人主页」的展示顺序（置顶内容排最前 + 「已置顶」标记），
///    不改变菩提空间广场流本身的热度排序；
///  - 内存里同步缓存当前置顶 id：任意页面都能用 [isPinned] / [currentId]
///    同步判断，不必 `await`，避免异步读写竞态导致的「置顶了但个人主页
///    看不到置顶」；
///  - 写盘串行化：连续点两次置顶/取消不会互相覆盖；
///  - 任何写操作都会 bump [revision]，所有已打开的列表/主页监听它即时刷新。
class PinnedNotesStore {
  PinnedNotesStore._();

  static const String storageKey = 'my_pinned_note_ids';

  /// 置顶记录变化通知：所有已打开的帖子列表/个人主页监听它，
  /// 在任意页面置顶后立即同步，不必等下一次整页刷新。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 内存中的当前置顶 id（'' 表示无置顶）。
  static String _currentId = '';

  /// 首次预热（避免每个页面各自读盘、首帧顺序错乱）。
  static Future<void>? _ensureLoadedFuture;

  /// 写盘队列：保证置顶/取消置顶按调用顺序落盘，不会互相覆盖。
  static Future<void> _writeQueue = Future<void>.value();

  /// 当前置顶 id（'' 表示没有置顶）。同步可读。
  static String get currentId => _currentId;

  /// 该内容是否当前置顶。同步可读。
  static bool isPinned(String noteId) =>
      noteId.isNotEmpty && _currentId == noteId;

  /// 三点菜单是否显示「置顶 / 取消置顶」入口。
  ///
  /// 规则：**只有帖子可以置顶**（自己发布的原创帖/转发帖）；回复帖不提供置顶，
  /// 它的三点菜单里只保留「编辑 / 删除」。
  /// 唯一例外：历史遗留的「已置顶回复」——它当前正好是置顶时仍显示「取消置顶」，
  /// 否则用户会遇到「当年置顶过一条回复，现在找不到入口取消」的死角。
  static bool showsPinEntry(String noteId, {required bool isReply}) =>
      !isReply || isPinned(noteId);

  /// 预热：把磁盘里的置顶 id 读进内存缓存。重复调用复用同一个 Future。
  static Future<void> ensureLoaded() => _ensureLoadedFuture ??= _readFromDisk();

  /// 读取当前置顶 id 集合（最多一条），并刷新内存缓存。
  static Future<Set<String>> load() async {
    await _readFromDisk();
    return _currentId.isEmpty ? <String>{} : {_currentId};
  }

  /// 切换某条内容的置顶状态，返回切换后的状态：
  /// true 表示已置顶，false 表示已取消置顶。
  ///
  /// 置顶一条新内容会自动取消之前的置顶（始终只保留一条）。
  static Future<bool> toggle(String noteId) {
    if (noteId.isEmpty) return Future<bool>.value(false);
    return _serial(() async {
      await _readFromDisk();
      final wasPinned = _currentId == noteId;
      await _write(wasPinned ? const <String>[] : <String>[noteId]);
      return !wasPinned;
    });
  }

  /// 直接置顶某条内容（替换掉之前的置顶；已置顶时不做多余写盘）。
  static Future<void> pin(String noteId) {
    if (noteId.isEmpty) return Future<void>.value();
    return _serial(() async {
      await _readFromDisk();
      if (_currentId == noteId) return;
      await _write(<String>[noteId]);
    });
  }

  /// 删除内容时同步清理置顶记录（仅当当前置顶就是它时才写盘）。
  static Future<void> remove(String noteId) {
    if (noteId.isEmpty) return Future<void>.value();
    return _serial(() async {
      await _readFromDisk();
      if (_currentId != noteId) return;
      await _write(const <String>[]);
    });
  }

  /// 清空置顶（清理失效记录时用）。
  static Future<void> clear() {
    return _serial(() async {
      await _readFromDisk();
      if (_currentId.isEmpty) return;
      await _write(const <String>[]);
    });
  }

  /// 旧版本可能残留多条置顶记录：只认最后一条，并把磁盘规整成单条，
  /// 避免下一次读盘又拿到多条导致「取消置顶」判定错乱。
  static Future<void> _readFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(storageKey) ?? const <String>[];
      final last = list.isEmpty ? '' : list.last;
      _currentId = last;
      if (list.length > 1) {
        await prefs.setStringList(storageKey, <String>[last]);
      }
    } catch (_) {
      // 读盘失败时保留内存缓存：本次会话内的置顶状态仍然有效。
    }
  }

  static Future<void> _write(List<String> ids) async {
    _currentId = ids.isEmpty ? '' : ids.last;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(storageKey, ids);
    } catch (_) {
      // 写盘失败也要通知 UI：本次会话内的置顶状态以内存为准。
    }
    revision.value++;
  }

  static Future<T> _serial<T>(Future<T> Function() action) {
    final result = _writeQueue.then((_) => action());
    _writeQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 仅测试用：清空内存缓存与队列（磁盘数据由测试自己准备）。
  @visibleForTesting
  static void debugReset() {
    _currentId = '';
    _ensureLoadedFuture = null;
    _writeQueue = Future<void>.value();
  }
}
