import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';

/// 单个互动用户。
class NotificationActor {
  final String userId;
  final String name;

  /// 头像 base64（可能为空，空时用默认 App 图标）。
  final String avatar;

  /// 账号名（@账号，可能为空）。
  final String account;

  /// 是否实名认证。
  final bool verified;

  const NotificationActor(this.userId, this.name,
      [this.avatar = '', this.account = '', this.verified = false]);
}

/// 聚合后的通知组：相同帖子 + 相同互动类型合并为一条通知。
class NotificationGroup {
  /// 聚合键：帖子类为 "type:noteId"，关注为 "follow_me"。
  final String key;
  final String type;

  /// 对应帖子 id（关注通知为空）。
  final String noteId;
  final String noteTitle;

  /// 互动对象帖子的转发类型：reply=回复帖，空/forward/quote=普通帖。
  /// 点赞通知用它区分「喜欢了你的回复」与「点赞了你的帖子」。
  String noteRepostKind;

  /// 评论类通知定位到该评论。
  String commentId;

  /// 帖子/评论摘要（帖子内容两行以内展示）。
  String noteContent;

  /// 互动用户（最新在前，已去重）。
  final List<NotificationActor> actors;

  /// 组内所有底层通知记录的 _id（用于标记已读/删除）。
  final List<String> activityIds;

  /// 组内最新一条通知时间。
  int latestAt;

  /// 组内是否存在未读通知。
  bool hasUnread;

  int get count => actors.length;

  NotificationGroup({
    required this.key,
    required this.type,
    this.noteId = '',
    this.noteTitle = '',
    this.noteRepostKind = '',
    this.commentId = '',
    this.noteContent = '',
    required this.actors,
    required this.activityIds,
    required this.latestAt,
    required this.hasUnread,
  });
}

/// 消息中心全局服务：未读数（底部角标）+ 通知聚合 + 定时同步。
class NotificationCenter {
  NotificationCenter._();

  static final NotificationCenter instance = NotificationCenter._();

  /// 底部导航「通知」角标实时读取的未读数。
  final ValueNotifier<int> unread = ValueNotifier<int>(0);

  Timer? _pollTimer;
  bool _listening = false;

  /// 启动监听：登录态变化 + 周期轮询未读数（角标实时同步服务器）。
  void start() {
    if (_listening) return;
    _listening = true;
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    refreshUnread();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => refreshUnread(),
    );
  }

  void stop() {
    if (!_listening) return;
    _listening = false;
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _onAuthChanged() {
    if (!AuthService.instance.isLoggedIn) {
      unread.value = 0;
      return;
    }
    refreshUnread();
  }

  /// 同步服务器未读数。失败静默保留旧值，下次轮询再试。
  Future<void> refreshUnread() async {
    try {
      final n = await CloudNotesService.instance.getNotificationUnreadCount();
      if (n != unread.value) unread.value = n;
    } catch (_) {}
  }

  /// 拉取一页通知并聚合（含帖子摘要补齐）。返回 (通知组, 是否还有更多)。
  /// 并发调用去重：消息页首次加载、未读数变化、切回 Tab 的静默刷新
  /// 可能同时打 page:1，去重后共享同一次请求，避免重复云调用拖慢/超时。
  final Map<String, Future<(List<NotificationGroup>, bool)>> _fetchInFlight = {};

  Future<(List<NotificationGroup>, bool)> fetchGroups({
    int page = 1,
    int pageSize = 20,
  }) {
    final key = '$page:$pageSize';
    final existing = _fetchInFlight[key];
    if (existing != null) return existing;
    final f = _fetchGroups(page: page, pageSize: pageSize, key: key);
    _fetchInFlight[key] = f;
    return f;
  }

  Future<(List<NotificationGroup>, bool)> _fetchGroups({
    int page = 1,
    int pageSize = 20,
    String key = '',
  }) async {
    try {
      final res =
          await CloudNotesService.instance.getNotifications(page: page, pageSize: pageSize);
      final groups = aggregate(res.items);
      await _attachNotePreviews(groups);
      return (groups, res.hasMore);
    } finally {
      // 用 try/finally 清理在途标记：既不会像 whenComplete 那样派生一个
      // 未被监听的失败 Future（会触发全局错误弹窗），也能保证无论成败都释放。
      _fetchInFlight.remove(key);
    }
  }

  /// 按「相同帖子 + 相同互动类型」聚合成通知组。
  static List<NotificationGroup> aggregate(List<NotificationItem> items) {
    final order = <String>[];
    final groups = <String, NotificationGroup>{};

    NotificationGroup ensureGroup(NotificationItem it) {
      // 聚合键：关注类全局一组；点赞类显式带「被赞对象类型」拆组——
      // 「点赞了你的帖子」与「喜欢了你的回复」是两类通知（X 内部事件同样
      // 按 favorited_tweet / favorited_reply 区分），即使 id 异常也不合并；
      // 其余按 类型:帖子id 聚合。
      final key = it.type == 'follow_me'
          ? 'follow_me'
          : it.type == 'like_me'
              ? 'like_me:${it.noteRepostKind}:${it.noteId}'
              : '${it.type}:${it.noteId}';
      var g = groups[key];
      if (g == null) {
        g = NotificationGroup(
          key: key,
          type: it.type,
          noteId: it.noteId,
          noteTitle: it.noteTitle,
          noteRepostKind: it.noteRepostKind,
          commentId: it.type == 'follow_me' ? '' : it.commentId,
          noteContent: it.type == 'follow_me'
              ? ''
              : (it.content.isNotEmpty ? it.content : it.contentPreview),
          actors: [],
          activityIds: [],
          latestAt: it.createdAt,
          hasUnread: !it.viewed,
        );
        groups[key] = g;
        order.add(key);
      }
      return g;
    }

    // 接口已按时间倒序，首个用户即最新互动者。
    for (final it in items) {
      final g = ensureGroup(it);
      if (it.createdAt > g.latestAt) g.latestAt = it.createdAt;
      if (!it.viewed) g.hasUnread = true;
      if (it.commentId.isNotEmpty && g.commentId.isEmpty) g.commentId = it.commentId;
      g.activityIds.add(it.id);
      final exists = g.actors.any((a) => a.userId == it.actorId && it.actorId.isNotEmpty);
      if (!exists) {
        g.actors.add(NotificationActor(
          it.actorId,
          it.actorName,
          it.actorAvatar,
          it.actorAccount,
          it.actorVerified,
        ));
      }
    }
    return [for (final k in order) groups[k]!];
  }

  /// 补齐帖子内容摘要：帖子摘要为空且帖子还在时拉取正文；失败保留原样。
  /// 一页最多 20 个通知组，老实现一次性并发 20 个 getNoteById 云调用，
  /// 冷启动/弱网下互相拖慢甚至超时。这里按小批量（≤4）串行补齐，
  /// 既不阻塞首屏渲染、也不会把云函数并发打满。
  Future<void> _attachNotePreviews(List<NotificationGroup> groups) async {
    final pending = groups.where((g) {
      if (g.type == 'follow_me') return false;
      if (g.noteContent.isEmpty) return true;
      // 点赞通知缺少转发类型时回源补齐（区分「喜欢了你的回复」/「点赞了你的帖子」）。
      if (g.type == 'like_me' && g.noteRepostKind.isEmpty) return true;
      return false;
    }).where((g) => g.noteId.isNotEmpty).toList();
    const batchSize = 4;
    for (var i = 0; i < pending.length; i += batchSize) {
      final batch = pending.sublist(
          i, math.min(i + batchSize, pending.length));
      await Future.wait(batch.map((g) async {
        try {
          final note = await CloudNotesService.instance.getNoteById(g.noteId);
          if (g.noteContent.isEmpty) g.noteContent = note.content;
          if (g.noteRepostKind.isEmpty) g.noteRepostKind = note.repostKind;
        } catch (_) {}
      }));
    }
  }

  /// 把指定通知组标记为已读，并同步本地未读数。
  Future<void> markGroupRead(NotificationGroup g) async {
    await CloudNotesService.instance.markNotificationsRead(g.activityIds);
    g.hasUnread = false;
    await refreshUnread();
  }

  /// 全部标记已读。
  Future<void> markAllRead() async {
    await CloudNotesService.instance.markNotificationsRead(const [], all: true);
    unread.value = 0;
  }

  /// 删除指定通知组。
  Future<void> deleteGroups(List<NotificationGroup> groups) async {
    final ids = <String>[
      for (final g in groups) ...g.activityIds,
    ];
    await CloudNotesService.instance.deleteNotifications(ids);
    await refreshUnread();
  }
}
