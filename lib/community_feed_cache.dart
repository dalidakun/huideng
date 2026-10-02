import 'cloud_notes_service.dart';

/// 一个排序档（社区页的「热门」/「最新」）的帖子流状态。
///
/// 两个档各拉各的（云端排序不同），互不牵连：切到「最新」不必把已经在屏上的
/// 「热门」清空重转一圈，切回「热门」也不用等「最新」。
///
/// [notes] 为 null = **还没拉过**；空列表 = 拉过、本档确实一个帖子都没有。
/// 这两者的区分正是来回切核心经典/社区不再反复首屏刷新的关键：原先拿
/// 「帖子是否为空」当「有没有拉过」，空社区和拉失败的社区每次切回来都被当成
/// 没拉过，于是又转一轮加载圈。
class CommunityFeedSlot {
  /// null = 还没拉过；空列表 = 拉过、本档确实没有帖子。
  List<PlazaNote>? notes;

  /// 这一档发起过请求没有（失败也算）。
  ///
  /// 来回切核心经典/社区只看它，不再看「帖子是否为空」：
  /// 空社区与拉失败的社区同样要记住自己已经试过，否则每次切回来都被当成
  /// 没拉过，在已经看过的内容上又盖一轮加载圈。
  bool attempted = false;

  /// 正在拉。只影响当前这一档：另一档照常显示，不会跟着转圈。
  bool loading = false;

  /// 拉失败了，只在正看着这一档时才报错误态。
  bool failed = false;
}

/// 社区帖子流的进程内缓存 + 同请求合并。
///
/// 进出社区页不再每次都干等一次云端往返：拉过一次的内容先秒出屏，
/// [ttl] 内再打开同一个社区直接不碰网络。
/// 键是 `{社区}#{排序}`，所以「热门」与「最新」各存各的，互不覆盖；
/// 20 个栏目也互不串数据。
class CommunityFeedCache {
  /// 缓存保质期：超龄的不再直接端上屏，退回「转圈等网络」那套老路。
  static const Duration ttl = Duration(minutes: 3);

  static final Map<String, _CacheEntry> _entries = {};

  /// 在途请求登记：同一键的并发调用合成一份。
  static final Map<String, Future<List<PlazaNote>>> _inflight = {};

  static String _key(String community, String sort) => '$community#$sort';

  /// 取一份没超龄的缓存；没有或已超龄返回 null。
  static List<PlazaNote>? peek(String community, String sort) {
    final e = _entries[_key(community, sort)];
    if (e == null) return null;
    if (DateTime.now().difference(e.at) > ttl) return null;
    return e.notes;
  }

  /// 落一份缓存。任何一次成功拉取都顺手写进来，
  /// 于是下一次打开这个社区直接是热的。
  static void put(String community, String sort, List<PlazaNote> notes) {
    _entries[_key(community, sort)] = _CacheEntry(notes, DateTime.now());
  }

  /// 丢掉某个键（下拉刷新、写操作之后用）：下次读不到旧数据。
  static void drop(String community, String sort) {
    _entries.remove(_key(community, sort));
  }

  /// 跑一次 [fetch]：已在途就直接等那一份，否则登记为在途并在结束后销掉。
  /// 这样来回切 tab、连开两个社区页都不会重复打云端。
  /// [fetch] 抛错时销掉登记并把错误原样抛出，缓存里也不会留下半截数据。
  static Future<List<PlazaNote>> coalesce(
    String community,
    String sort,
    Future<List<PlazaNote>> Function() fetch,
  ) {
    final key = _key(community, sort);
    final running = _inflight[key];
    if (running != null) return running;
    final fut = _runOnce(key, fetch);
    _inflight[key] = fut;
    return fut;
  }

  /// 登记为在途的那一份：无论成功还是抛错，都在结束时把登记销掉。
  static Future<List<PlazaNote>> _runOnce(
    String key,
    Future<List<PlazaNote>> Function() fetch,
  ) async {
    try {
      return await fetch();
    } finally {
      _inflight.remove(key);
    }
  }

  /// 清空全部缓存与在途登记（测试与登出时用）。
  static void clear() {
    _entries.clear();
    _inflight.clear();
  }
}

class _CacheEntry {
  final List<PlazaNote> notes;
  final DateTime at;

  _CacheEntry(this.notes, this.at);
}