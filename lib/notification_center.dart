import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';

/// 单个互动用户。
class NotificationActor {
  final String userId;
  final String name;
  const NotificationActor(this.userId, this.name);
}

/// 聚合后的通知组：相同帖子 + 相同互动类型合并为一条通知。
class NotificationGroup {
  /// 聚合键：帖子类为 "type:noteId"，关注为 "follow_me"。
  final String key;
  final String type;

  /// 对应帖子 id（关注通知为空）。
  final String noteId;
  final String noteTitle;

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
  Future<(List<NotificationGroup>, bool)> fetchGroups({
    int page = 1,
    int pageSize = 20,
  }) async {
    final res =
        await CloudNotesService.instance.getNotifications(page: page, pageSize: pageSize);
    final groups = aggregate(res.items);
    await _attachNotePreviews(groups);
    return (groups, res.hasMore);
  }

  /// 按「相同帖子 + 相同互动类型」聚合成通知组。
  static List<NotificationGroup> aggregate(List<NotificationItem> items) {
    final order = <String>[];
    final groups = <String, NotificationGroup>{};

    NotificationGroup ensureGroup(NotificationItem it) {
      final key = it.type == 'follow_me' ? 'follow_me' : '${it.type}:${it.noteId}';
      var g = groups[key];
      if (g == null) {
        g = NotificationGroup(
          key: key,
          type: it.type,
          noteId: it.noteId,
          noteTitle: it.noteTitle,
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
        g.actors.add(NotificationActor(it.actorId, it.actorName));
      }
    }
    return [for (final k in order) groups[k]!];
  }

  /// 补齐帖子内容摘要：帖子摘要为空且帖子还在时拉取正文；失败保留原样。
  Future<void> _attachNotePreviews(List<NotificationGroup> groups) async {
    final pending = groups.where((g) => g.type != 'follow_me' && g.noteContent.isEmpty);
    await Future.wait(pending.map((g) async {
      if (g.noteId.isEmpty) return;
      try {
        final note = await CloudNotesService.instance.getNoteById(g.noteId);
        g.noteContent = note.content;
      } catch (_) {}
    }));
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
