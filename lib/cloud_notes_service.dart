import 'package:cloudbase_flutter/cloudbase_flutter.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// 云端接口错误，message 可直接展示给用户。
class CloudApiException implements Exception {
  final String message;

  const CloudApiException(this.message);

  @override
  String toString() => message;
}

/// 云调用返回 401 unauthorized / 登录态无法恢复时的统一提示文案。
/// 云函数对需要真实身份的 action（我的帖子/回复/书签/喜欢/关注列表等）
/// 在 uid 为空时返回 fail("unauthorized")，SDK 会把它包装成
/// AuthError: [null] unauthorized 抛给业务层——一律展示为这句可操作的文案。
const String kLoginExpiredMessage = '登录已失效，请退出后重新登录';

/// 广场笔记（云端返回的一条记录）。
class PlazaNote {
  final String id;
  final String ownerUserId;
  final String title;
  final String content;
  final String authorName;
  final String authorAccount;
  final bool authorVerified;

  /// 作者「阅藏进度」原始数据：完成册数/总册数（帖子行百分比展示用）。
  final int canonRead;
  final int canonTotal;
  final String visibility;
  final String status;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final int repostCount;
  final String repostOf;
  final String repostSourceAuthor;

  /// 被转发原帖的作者用户 ID（用于屏蔽过滤：转发源作者被屏蔽也不展示）。
  final String repostSourceUserId;

  /// 转发类型：forward / quote / reply（reply 不展示转发角标）。
  final String repostKind;

  /// 已删除祖先链（紧邻父帖在前，nearest-first）。
  /// 参考 X 的 tombstone_ancestor_ids：删除回复链中间节点时服务端会把
  /// 子回复重挂到祖父帖，同时把被删 id 记录在此；详情页据此在链路中
  /// 渲染「已删除帖子」占位并保持连线。普通帖子恒为空。
  final List<String> tombstoneAncestorIds;

  /// 帖子类型：普通帖为空；announcement = 管理员公告（详情页展示「公告」标签）。
  final String kind;

  /// 引用转发时的用户引言（空表示直接转发）。
  final String quoteContent;
  final String quoteOfTitle;
  final String quoteOfContent;
  final int createdAt;
  final int updatedAt;

  const PlazaNote({
    required this.id,
    required this.ownerUserId,
    required this.title,
    required this.content,
    required this.authorName,
    this.authorAccount = '',
    this.authorVerified = false,
    this.canonRead = 0,
    this.canonTotal = 0,
    required this.visibility,
    required this.status,
    required this.likeCount,
    required this.commentCount,
    this.viewCount = 0,
    this.repostCount = 0,
    this.repostOf = '',
    this.repostSourceAuthor = '',
    this.repostSourceUserId = '',
    this.repostKind = '',
    this.tombstoneAncestorIds = const [],
    this.kind = '',
    this.quoteContent = '',
    this.quoteOfTitle = '',
    this.quoteOfContent = '',
    required this.createdAt,
    required this.updatedAt,
  });

  factory PlazaNote.fromJson(Map<String, dynamic> json) => PlazaNote(
        id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
        ownerUserId: json['ownerUserId']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        authorName: json['authorName']?.toString() ?? '同修',
        authorAccount: json['authorAccount']?.toString() ?? '',
        authorVerified: json['authorVerified'] == true,
        canonRead: (json['canonRead'] as num?)?.toInt() ?? 0,
        canonTotal: (json['canonTotal'] as num?)?.toInt() ?? 0,
        visibility: json['visibility']?.toString() ?? 'public',
        status: json['status']?.toString() ?? 'normal',
        likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
        commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
        viewCount: _parseViewCount(json['viewCount']),
        repostCount: (json['repostCount'] as num?)?.toInt() ?? 0,
        repostOf: json['repostOf']?.toString() ?? '',
        repostSourceAuthor: json['repostSourceAuthor']?.toString() ?? '',
        repostSourceUserId: json['repostSourceUserId']?.toString() ?? '',
        repostKind: json['repostKind']?.toString() ?? '',
        tombstoneAncestorIds: (json['tombstoneAncestorIds'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList(growable: false) ??
            const [],
        kind: json['kind']?.toString() ?? '',
        quoteContent: json['quoteContent']?.toString() ?? '',
        quoteOfTitle: json['quoteOfTitle']?.toString() ?? '',
        quoteOfContent: json['quoteOfContent']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  /// 把云端返回的 viewCount 安全转成数字（容忍字符串脏数据）。
  static int _parseViewCount(dynamic v) =>
      v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  /// 复制一份并覆盖作者展示字段（@账号/认证/阅藏进度）。
  /// 用于列表作者信息缺失时用 getUserProfiles 兜底补齐，
  /// 保证「发现/讨论」等栏目与「关注」栏目展示口径一致。
  PlazaNote copyWith({
    String? authorAccount,
    bool? authorVerified,
    int? canonRead,
    int? canonTotal,
    int? commentCount,
    int? likeCount,
    int? repostCount,
  }) =>
      PlazaNote(
        id: id,
        ownerUserId: ownerUserId,
        title: title,
        content: content,
        authorName: authorName,
        authorAccount: authorAccount ?? this.authorAccount,
        authorVerified: authorVerified ?? this.authorVerified,
        canonRead: canonRead ?? this.canonRead,
        canonTotal: canonTotal ?? this.canonTotal,
        visibility: visibility,
        status: status,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        viewCount: viewCount,
        repostCount: repostCount ?? this.repostCount,
        repostOf: repostOf,
        repostSourceAuthor: repostSourceAuthor,
        repostSourceUserId: repostSourceUserId,
        repostKind: repostKind,
        tombstoneAncestorIds: tombstoneAncestorIds,
        kind: kind,
        quoteContent: quoteContent,
        quoteOfTitle: quoteOfTitle,
        quoteOfContent: quoteOfContent,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

/// 热门讨论中的单个话题 / 经文条目（由云端聚合热度后返回）。
class HotDiscussionItem {
  final String name;
  final int posts;
  final double score;

  const HotDiscussionItem({
    required this.name,
    required this.posts,
    this.score = 0,
  });

  factory HotDiscussionItem.fromJson(Map<String, dynamic> e) =>
      HotDiscussionItem(
        name: e['name']?.toString() ?? '',
        posts: (e['posts'] as num?)?.toInt() ?? 0,
        score: (e['score'] as num?)?.toDouble() ?? 0,
      );
}

/// 大家都在读：某部经书被多少用户锁定精读。
class PopularSutraItem {
  final String title;
  final int count;
  final String filePath;

  const PopularSutraItem({
    required this.title,
    this.count = 0,
    this.filePath = '',
  });

  factory PopularSutraItem.fromJson(Map<String, dynamic> e) =>
      PopularSutraItem(
        title: e['title']?.toString() ?? '',
        count: (e['count'] as num?)?.toInt() ?? 0,
        filePath: e['filePath']?.toString() ?? '',
      );
}

/// 广场评论。
class PlazaComment {
  final String id;
  final String noteId;
  final String authorId;
  final String authorName;
  final String authorAccount;
  final bool authorVerified;
  final String content;
  final int likeCount;

  /// 当前登录用户是否已赞这条评论（服务端返回，用于恢复点亮状态）。
  final bool likedByMe;
  final int createdAt;

  const PlazaComment({
    required this.id,
    required this.noteId,
    required this.authorId,
    required this.authorName,
    this.authorAccount = '',
    this.authorVerified = false,
    required this.content,
    this.likeCount = 0,
    this.likedByMe = false,
    required this.createdAt,
  });

  factory PlazaComment.fromJson(Map<String, dynamic> json) => PlazaComment(
        id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
        noteId: json['noteId']?.toString() ?? '',
        authorId: json['authorId']?.toString() ?? '',
        authorName: json['authorName']?.toString() ?? '同修',
        authorAccount: json['authorAccount']?.toString() ?? '',
        authorVerified: json['authorVerified'] == true,
        content: json['content']?.toString() ?? '',
        likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
        likedByMe: json['liked'] == true,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );

  PlazaComment copyWith({int? likeCount, bool? likedByMe}) => PlazaComment(
        id: id,
        noteId: noteId,
        authorId: authorId,
        authorName: authorName,
        authorAccount: authorAccount,
        authorVerified: authorVerified,
        content: content,
        likeCount: likeCount ?? this.likeCount,
        likedByMe: likedByMe ?? this.likedByMe,
        createdAt: createdAt,
      );
}

/// 反馈条目（管理页展示）。
class FeedbackItem {
  final String id;
  final String userId;
  final String username;
  final String content;
  final String contact;
  final String status; // new | handled
  final int createdAt;

  const FeedbackItem({
    required this.id,
    this.userId = '',
    this.username = '',
    required this.content,
    this.contact = '',
    this.status = 'new',
    required this.createdAt,
  });

  bool get isHandled => status == 'handled';

  factory FeedbackItem.fromJson(Map<String, dynamic> json) => FeedbackItem(
        id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
        userId: json['userId']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        contact: json['contact']?.toString() ?? '',
        status: json['status']?.toString() ?? 'new',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// 反馈分页列表结果。
class FeedbackListResult {
  final List<FeedbackItem> items;
  final bool hasMore;
  final int unread;

  const FeedbackListResult({
    required this.items,
    required this.hasMore,
    required this.unread,
  });
}

/// 管理员条目（管理员管理页展示）。
class AdminItem {
  final String uid;
  final String username;
  final int createdAt;

  const AdminItem({
    required this.uid,
    this.username = '',
    this.createdAt = 0,
  });

  factory AdminItem.fromJson(Map<String, dynamic> json) => AdminItem(
        uid: json['uid']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// 公告条目（主页公告栏与管理页展示）。
class AnnouncementItem {
  final String id;
  final String title;
  final String content;
  final int createdAt;

  const AnnouncementItem({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  factory AnnouncementItem.fromJson(Map<String, dynamic> json) =>
      AnnouncementItem(
        id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// 菩提空间：单条互动动态（转发/我的评论/别人对我的回复）。
class PlazaActivity {
  final String id;
  final String type; // repost | comment | reply
  final String noteId;
  final String noteTitle;
  final String sourceTitle;
  final String content;
  final String actorId;
  final String actorName;
  final int createdAt;

  const PlazaActivity({
    required this.id,
    required this.type,
    required this.noteId,
    required this.noteTitle,
    this.sourceTitle = '',
    this.content = '',
    this.actorId = '',
    this.actorName = '',
    required this.createdAt,
  });

  factory PlazaActivity.fromJson(Map<String, dynamic> json) => PlazaActivity(
        id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
        noteId: json['noteId']?.toString() ?? '',
        noteTitle: json['noteTitle']?.toString() ?? '',
        sourceTitle: json['sourceTitle']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        actorId: json['actorId']?.toString() ?? '',
        actorName: json['actorName']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// 消息中心：单条「收到的互动」（点赞/评论/回复评论/转发/收藏/关注/@提及）。
class NotificationItem {
  final String id;
  final String type; // like_me | reply | comment_reply | repost_me | favorite_me | follow_me | mention
  final String noteId;
  final String noteTitle;
  final String content;
  final String contentPreview;
  final String commentId;

  /// 被点赞/互动帖子的转发类型（reply=回复帖，forward/quote=转发帖，空=原创帖）。
  final String noteRepostKind;
  final String actorId;
  final String actorName;

  /// 互动用户头像（base64，可能为空）。
  final String actorAvatar;

  /// 互动用户账号名（@账号，可能为空）。
  final String actorAccount;

  /// 互动用户是否实名认证。
  final bool actorVerified;
  final bool viewed;
  final int createdAt;

  const NotificationItem({
    required this.id,
    required this.type,
    this.noteId = '',
    this.noteTitle = '',
    this.content = '',
    this.contentPreview = '',
    this.commentId = '',
    this.noteRepostKind = '',
    this.actorId = '',
    this.actorName = '',
    this.actorAvatar = '',
    this.actorAccount = '',
    this.actorVerified = false,
    this.viewed = false,
    required this.createdAt,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> json) =>
      NotificationItem(
        id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
        noteId: json['noteId']?.toString() ?? '',
        noteTitle: json['noteTitle']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        contentPreview: json['contentPreview']?.toString() ?? '',
        commentId: json['commentId']?.toString() ?? '',
        noteRepostKind: json['repostKind']?.toString() ?? '',
        actorId: json['actorId']?.toString() ?? '',
        actorName: json['actorName']?.toString() ?? '同修',
        actorAvatar: json['actorAvatar']?.toString() ?? '',
        actorAccount: json['actorAccount']?.toString() ?? '',
        actorVerified: json['actorVerified'] == true,
        viewed: json['viewed'] == true,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// 消息中心分页结果。
class NotificationPageResult {
  final List<NotificationItem> items;
  final bool hasMore;

  const NotificationPageResult({required this.items, required this.hasMore});
}

/// 广场用户（关注/粉丝列表展示用，可含签名/加入时间/账号）。
class UserProfile {
  final String id;
  final String name;
  final bool verified;
  final String tagline;
  final int joinTime;
  final String account;

  /// 头像 base64（存于云端 userData.payload.files.avatar，未设置时为空）。
  final String avatar;

  /// 横幅 base64（存于云端 userData.payload.files.banner，未设置时为空）。
  final String banner;

  /// 「阅藏进度」原始数据：完成册数/总册数（主页头部展示用）。
  final int canonRead;
  final int canonTotal;

  /// 累计读经时长（秒）：他人主页展示其点亮的修学徽章用。
  final int readingSeconds;

  const UserProfile({
    required this.id,
    required this.name,
    this.verified = false,
    this.tagline = '',
    this.joinTime = 0,
    this.account = '',
    this.avatar = '',
    this.banner = '',
    this.canonRead = 0,
    this.canonTotal = 0,
    this.readingSeconds = 0,
  });

  factory UserProfile.fromJson(Map<String, dynamic> e) => UserProfile(
        id: e['id']?.toString() ?? '',
        name: e['name']?.toString() ?? '同修',
        verified: e['verified'] == true,
        tagline: e['tagline']?.toString() ?? '',
        joinTime: (e['joinTime'] as num?)?.toInt() ??
            (e['createdAt'] as num?)?.toInt() ??
            0,
        account: e['account']?.toString() ?? e['username']?.toString() ?? '',
        avatar: e['avatar']?.toString() ?? '',
        banner: e['banner']?.toString() ?? '',
        canonRead: (e['canonRead'] as num?)?.toInt() ?? 0,
        canonTotal: (e['canonTotal'] as num?)?.toInt() ?? 0,
        readingSeconds: (e['readingSeconds'] as num?)?.toInt() ?? 0,
      );
}

/// 他人主页的「精读 / 功课」数据（由 getUserHomeData 返回，受对方隐私开关控制）。
class UserHomeData {
  final bool readingAllowed;
  final bool checkinAllowed;

  /// 精读：该用户锁定过的经书列表。
  final List<UserReadingSutra> reading;

  /// 当前锁定的经书标题（用于在列表中标记「当前锁定」）。
  final String currentLockedTitle;

  /// 功课：对方打卡相关 prefs 键（未开启时为 null）。
  final Map<String, dynamic>? checkin;

  const UserHomeData({
    this.readingAllowed = false,
    this.checkinAllowed = false,
    this.reading = const [],
    this.currentLockedTitle = '',
    this.checkin,
  });

  factory UserHomeData.fromJson(Map<String, dynamic> e) => UserHomeData(
        readingAllowed: e['readingAllowed'] == true,
        checkinAllowed: e['checkinAllowed'] == true,
        reading: (e['reading'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(UserReadingSutra.fromJson)
            .toList(),
        currentLockedTitle: e['currentLockedTitle']?.toString() ?? '',
        checkin: e['checkin'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(e['checkin'] as Map)
            : null,
      );
}

/// 用户正在读（最近阅读）的一部经书。
class UserReadingSutra {
  final String title;
  final String filePath;

  const UserReadingSutra({required this.title, this.filePath = ''});

  factory UserReadingSutra.fromJson(Map<String, dynamic> e) => UserReadingSutra(
        title: e['title']?.toString() ?? '',
        filePath: e['filePath']?.toString() ?? '',
      );
}

/// 我的主页角标：互动未读数 / 关注数 / 粉丝数。
class MyCounts {
  final int following;
  final int followers;
  final int unread;

  const MyCounts({this.following = 0, this.followers = 0, this.unread = 0});
}

/// 实名认证状态：是否已认证 + 脱敏姓名 + 认证时间。
class VerificationInfo {
  final bool verified;
  final String realNameMasked;
  final int verifiedAt;

  const VerificationInfo({
    this.verified = false,
    this.realNameMasked = '',
    this.verifiedAt = 0,
  });
}

/// 广场云端数据服务：所有操作统一走「api」云函数。
class CloudNotesService {
  CloudNotesService._();

  static final CloudNotesService instance = CloudNotesService._();

  static const String _fnName = 'api';

  /// 已登录用户是否点过赞的 noteId 集合（下拉时预取，用于列表展示已赞态）。
  final Set<String> likedNoteIds = {};

  /// 已登录用户收藏过的 noteId 集合（预取，用于展示收藏态）。
  final Set<String> favoriteNoteIds = {};

  /// 已登录用户关注的 userId 集合（预取）。
  final Set<String> followingUserIds = {};

  /// 已登录用户屏蔽的 userId 集合（预取）。
  final Set<String> blockedUserIds = {};

  /// 管理员删除的话题名集合（预取）：全端隐藏含这些话题的帖子，
  /// `#` 输入联想也不展示。删除时间戳仅回收站展示用。
  final Set<String> bannedTopicNames = {};
  final Map<String, int> bannedTopicAt = {};

  /// 本机已删除的云端笔记 id（墓碑）。
  ///
  /// 背景：删除成功后的短时间内（在途请求返回旧数据 / 云端列表查询
  /// 读到删除前的快照），任何一次列表刷新都可能把刚删的帖子重新带回
  /// 界面——表现为「删除后立即消失，随即又跳出来，再刷新一次才真正消失」。
  /// 记录墓碑后所有列表拉取统一过滤，保证本会话内绝不复活；
  /// 仅存内存，重启后服务端早已一致，无需持久化。
  final Set<String> locallyDeletedNoteIds = {};

  /// 笔记详情缓存：noteId → PlazaNote。避免通知页/回复卡等场景
  /// 重复调用 getNoteById（每次都是独立云函数调用，弱网下极慢）。
  /// 仅存内存，不持久化；写操作（编辑/删除）后主动清除对应条目。
  final Map<String, PlazaNote> _noteCache = {};

  /// 本次会话内「我刚发布」的内容 id → 发布时间（广场笔记/回复与经书讨论通用）。
  ///
  /// 用途：各列表页（发现/话题页/经书讨论页）把我刚发布的帖子短暂置顶，
  /// 让用户发完立刻能看到；仅对刚发的这一条生效——历史帖子一律不置顶，
  /// 否则发帖多的用户一进列表满屏都是自己的旧帖。
  /// 超过 [_recentlyPublishedTtl] 自动失效，回到正常排序；
  /// 仅存内存，重启即清空。其他用户的客户端没有这些 id，不受影响。
  static final Map<String, int> _recentlyPublished = {};
  static const Duration _recentlyPublishedTtl = Duration(minutes: 30);

  /// 记录一条我刚发布的内容（发布成功后调用）。
  static void markRecentlyPublished(String id) {
    if (id.isEmpty) return;
    _recentlyPublished[id] = DateTime.now().millisecondsSinceEpoch;
  }

  /// 该内容是否是本次会话里刚发布的（未过期，可短暂置顶展示）。
  static bool isRecentlyPublished(String id) {
    if (id.isEmpty) return false;
    final t = _recentlyPublished[id];
    if (t == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - t >
        _recentlyPublishedTtl.inMilliseconds) {
      _recentlyPublished.remove(id);
      return false;
    }
    return true;
  }

  /// 过滤掉已删除（墓碑）笔记；所有返回笔记列表的接口统一调用。
  List<PlazaNote> _withoutDeleted(Iterable<PlazaNote> notes) => notes
      .where((n) => !locallyDeletedNoteIds.contains(n.id))
      .toList(growable: true);

  /// 拉取被管理员删除的话题（未登录也返回，用于内容隐藏）。
  Future<void> refreshBannedTopics() async {
    try {
      final res = await _call('getBannedTopics');
      final list = res['topics'];
      if (list is List) {
        bannedTopicNames.clear();
        bannedTopicAt.clear();
        for (final e in list) {
          if (e is Map) {
            final name = e['name']?.toString() ?? '';
            if (name.isNotEmpty) {
              bannedTopicNames.add(name);
              bannedTopicAt[name] = (e['createdAt'] as num?)?.toInt() ?? 0;
            }
          }
        }
      }
    } catch (_) {
      // 静默失败：保留旧缓存，下一轮刷新。
    }
  }

  /// 管理员删除话题：加入封禁表，含该话题的帖子全端隐藏。
  Future<void> deleteTopic(String name) async {
    await _call('deleteTopic', params: {'name': name});
    bannedTopicNames.add(name);
    bannedTopicAt[name] = DateTime.now().millisecondsSinceEpoch;
  }

  /// 管理员恢复话题：从封禁表移除，相关帖子自动重新可见。
  Future<void> restoreTopic(String name) async {
    await _call('restoreTopic', params: {'name': name});
    bannedTopicNames.remove(name);
    bannedTopicAt.remove(name);
  }

  String get _authorName =>
      AuthService.instance.currentUser.value?.displayName ?? '同修';

  /// AI 经文翻译/讨论（云端调用 DeepSeek，密钥在服务端，客户端不接触）。
  /// - action: 'translate' 把整段古文翻译成白话；'discuss' 围绕该段继续追问。
  /// - history: 追问时带上 {role, content}（与 OpenAI 消息格式一致）。
  /// 返回已生成的译文/回复文本。
  Future<String> aiTranslate({
    required String paragraph,
    String action = 'translate',
    List<Map<String, String>> history = const [],
  }) async {
    final res = await _call(
      'aiTranslate',
      params: {
        'paragraph': paragraph,
        'mode': action,
        if (history.isNotEmpty) 'history': history,
      },
      // 大模型生成耗时较长，放宽云调用超时（内部另设服务端 60s 上限）。
      timeout: const Duration(seconds: 70),
    );
    final text = res['text']?.toString() ?? '';
    if (text.isEmpty) {
      throw const CloudApiException('AI 未返回内容，请稍后重试');
    }
    return text;
  }

  /// 读取某段经文已缓存的白话翻译（其他同修/自己之前翻译过的结果）。
  /// 只查共享缓存，不调用 DeepSeek 生成。未命中返回 null。
  Future<String?> getCachedParagraphTranslation(String paragraph) async {
    final res = await _call(
      'getParagraphTranslation',
      params: {'paragraph': paragraph},
    );
    if (res['found'] == true) {
      final text = res['text']?.toString() ?? '';
      return text.isEmpty ? null : text;
    }
    return null;
  }

  /// 读取某本经的全部段落笔记/完成态（跨设备云端同步）。
  /// 返回 [{index, note, done, updatedAt}]。
  Future<List<Map<String, dynamic>>> getParagraphNotes(String sutraKey) async {
    final res = await _call('getParagraphNotes', params: {'sutraKey': sutraKey});
    final items = res['items'];
    if (items is List) {
      return items.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  /// 保存某段的备注文本（note 为空表示清除该段备注）。
  /// [shared] 表示该段读经笔记是否分享到菩提空间，[cloudId] 为分享后的云端帖子 ID。
  Future<void> saveParagraphNote({
    required String sutraKey,
    required int index,
    required String text,
    required String note,
    bool shared = false,
    String cloudId = '',
  }) async {
    await _call('saveParagraphNote', params: {
      'sutraKey': sutraKey,
      'index': index,
      'text': text,
      'note': note,
      'shared': shared,
      'cloudId': cloudId,
    });
  }

  /// 切换某段「已读完/学完」标记。
  Future<void> toggleParagraphDone({
    required String sutraKey,
    required int index,
    required String text,
    required bool done,
  }) async {
    await _call('toggleParagraphDone', params: {
      'sutraKey': sutraKey,
      'index': index,
      'text': text,
      'done': done,
    });
  }

  /// 删除某段全部段落数据（备注 + 完成态）。
  Future<void> deleteParagraphNote({
    required String sutraKey,
    required int index,
  }) async {
    await _call('deleteParagraphNote', params: {'sutraKey': sutraKey, 'index': index});
  }

  Future<Map<String, dynamic>> _call(
    String action, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) {
    return _doCall(action, params: params, timeout: timeout);
  }

    /// 写操作名单：已登录但 token 拿不到时，这些动作绝不能静默以匿名身份执行
  /// （否则评论/回复/转发/关注会被写成共享 uid "anon"，@账号 全部丢失）。
  static bool _isWriteAction(String action) {
    const writes = <String>{
      'createNote',
      'updateNote',
      'deleteNote',
      'repostNote',
      'toggleNoteFavorite',
      'toggleFollow',
      'toggleBlockUser',
      'toggleLike',
      'toggleCommentLike',
      'createComment',
      'createSutraDiscussion',
      'deleteSutraDiscussion',
      'deleteComment',
      'reportNote',
      'markNotificationsRead',
      'deleteNotifications',
      'setUserData',
      'submitFeedback',
      'markFeedbackHandled',
      'addAdmin',
      'removeAdmin',
      'addAnnouncement',
      'deleteAnnouncement',
      'reportReadingTime',
      'reportCanonProgress',
      'deleteTopic',
      'saveParagraphNote',
      'toggleParagraphDone',
      'deleteParagraphNote',
    };
    return writes.contains(action);
  }

  Future<Map<String, dynamic>> _doCall(
    String action, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    // 等待启动会话恢复完成（含 token 刷新）：避免热重启/冷启动后会话未就绪，
    // 请求被云函数判定为未授权，导致通知等页面首次打开直接「加载失败」。
    // 注意：此处等待不占用下面的云调用超时预算——冷启动时会话恢复/修复
    // （原始 HTTP 刷新等）可能耗时数秒到十几秒，若把整条链路套进 8s 超时，
    // 首次加载会在会话就绪前就被判「请求超时」而显示「加载失败」，
    // 要等会话恢复完成后的下一次拉取才刷新出来。
    await AuthService.instance.restoreDone;
    final app = await AuthService.instance.ensureApp();
    if (app == null) {
      throw const CloudApiException('尚未配置云环境');
    }
    // 未登录时先确保有一个匿名会话，否则网关会拒绝调用（如浏览广场）。
    await AuthService.instance.ensureAnonymousForBrowse();
    var token = await AuthService.instance.getAccessToken();
    // 已登录但拿不到 access token（token 过期且刷新失败）时，禁止静默降级：
    // 直接以匿名级发起写操作会把评论/回复/转发/关注全部写成共享 uid "anon"，
    // 导致对方页面上「@账号、认证、百分比全都不显示」。先尝试恢复会话，
    // 恢复不了且是写操作则明确报错要求重新登录（读操作可匿名级取公开数据）。
    if (token == null && AuthService.instance.isLoggedIn) {
      debugPrint('[cloud] 已登录但 access token 为空，尝试恢复会话');
      final recovered = await AuthService.instance.tryRestoreOrRefreshSession();
      if (recovered != null) token = recovered;
      if (token == null) {
        // 清掉过期会话：让 SDK 后续请求回落 publishable key（匿名级），
        // 云函数仍会执行并返回公开数据（广场帖子 + 完整作者信息），
        // 而不是带着过期 token 被网关 401 INVALID_CREDENTIALS 挡在门外
        // 导致首页/发现/关注帖子全部加载失败。
        await AuthService.instance.clearSessionIfExpired();
        if (_isWriteAction(action)) {
          throw const CloudApiException(kLoginExpiredMessage);
        }
      }
    }
    final FunctionResponse res;
    try {
      // 超时只覆盖真正的云函数调用（避免网络异常时页面永久卡在加载状态）；
      // 会话准备在前置步骤已完成，不占用此超时预算。
      res = await app.callFunction(
        name: _fnName,
        data: {
          'action': action,
          if (token != null) '__accessToken': token,
          if (params != null) ...params,
        },
      ).timeout(
        timeout ?? const Duration(seconds: 8),
        onTimeout: () => throw const CloudApiException('请求超时'),
      );
    } catch (e) {
      if (e is CloudApiException) rethrow;
      final msg = e.toString();
      // 云函数对需真实身份的动作在 uid 为空时返回 fail("unauthorized")，
      // SDK 包装成 AuthError: [null] unauthorized —— 别把技术错误直接甩给用户，
      // 统一提示登录已失效（可操作）。
      if (msg.contains('unauthorized')) {
        throw const CloudApiException(kLoginExpiredMessage);
      }
      throw CloudApiException('网络异常：$msg');
    }
    final result = res.result is Map<String, dynamic>
        ? res.result as Map<String, dynamic>
        : null;
    if (result == null) {
      throw CloudApiException(res.message ?? '请求失败，请稍后重试');
    }
    if (result['ok'] != true) {
      final err = result['error']?.toString() ?? '请求失败';
      if (err.contains('unauthorized')) {
        throw const CloudApiException(kLoginExpiredMessage);
      }
      throw CloudApiException(err);
    }
    return result;
  }

  /// 预取当前登录用户的点赞记录（用于广场列表/详情展示已赞态）。未登录时清空。
  Future<void> refreshLikedNoteIds() async {
    if (!AuthService.instance.isLoggedIn) {
      likedNoteIds.clear();
      return;
    }
    try {
      final app = await AuthService.instance.ensureApp();
      if (app == null) return;
      final res = await _call('getLikedNoteIds');
      final ids = res['ids'];
      final newLiked = <String>{};
      if (ids is List) newLiked.addAll(ids.map((e) => e.toString()));
      likedNoteIds
        ..clear()
        ..addAll(newLiked);
    } catch (_) {}
  }

  /// 发布笔记到广场（分享）。返回云端笔记 id。
  Future<String> publishNote({
    required String title,
    required String content,
  }) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('createNote', params: {
      'title': title,
      'content': content,
      'visibility': 'public',
      'authorName': _authorName,
    });
    final id = res['id']?.toString() ?? '';
    markRecentlyPublished(id);
    return id;
  }

  /// 更新已分享笔记的云端副本（标题/内容/可见性）。
  Future<void> updateSharedNote({
    required String cloudId,
    String? title,
    String? content,
    bool? isPublic,
  }) async {
    await _call('updateNote', params: {
      'id': cloudId,
      if (title != null) 'title': title,
      if (content != null) 'content': content,
      if (isPublic != null) 'visibility': isPublic ? 'public' : 'private',
    });
  }

  /// 取消分享（云端置为私密）。
  Future<void> unpublishNote(String cloudId) async {
    await _call('updateNote', params: {
      'id': cloudId,
      'visibility': 'private',
    });
  }

  /// 删除云端笔记及其点赞/评论/举报。
  /// 成功后记录墓碑：删除后短时间内的列表刷新可能仍返回该笔记
  /// （在途请求/查询快照），统一过滤避免「删了又跳回来」。
  Future<void> deleteCloudNote(String cloudId) async {
    await _call('deleteNote', params: {'id': cloudId});
    locallyDeletedNoteIds.add(cloudId);
    _noteCache.remove(cloudId);
  }

  /// 软删除/隐藏云端笔记（从广场移除，仍可恢复）。
  Future<void> hideCloudNote(String cloudId) async {
    await _call('updateNote', params: {'id': cloudId, 'status': 'hidden'});
    locallyDeletedNoteIds.add(cloudId);
    _noteCache.remove(cloudId);
  }

  /// 恢复被软删除的云端笔记（重新在广场展示）。
  Future<void> unhideCloudNote(String cloudId) async {
    await _call('updateNote', params: {'id': cloudId, 'status': 'normal'});
    locallyDeletedNoteIds.remove(cloudId);
    _noteCache.remove(cloudId);
  }

  /// 拉取广场笔记流。sort: latest / hot。
  Future<(List<PlazaNote>, bool hasMore)> getPlazaNotes({
    int page = 1,
    int pageSize = 20,
    String sort = 'latest',
  }) async {
    final res = await _call('getPlazaNotes', params: {
      'page': page,
      'pageSize': pageSize,
      'sort': sort,
    });
    final list = (res['notes'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaNote.fromJson)
        .toList();
    final hasMore = res['hasMore'] == true;
    return (_withoutDeleted(list), hasMore);
  }

  /// 拉取某话题下的帖子（服务端按 #话题 边界精确过滤，不再客户端截断前100条）。
  /// 排序与「发现」同款：热度衰减分倒序（热帖靠前、随时间下沉给新帖让位）。
  /// 同时返回话题发起人帖 id——服务端权威查出的最早一条，
  /// 客户端置顶展示时不受分页截断影响。未登录也可浏览。
  /// 第四个返回值为该话题下的帖子总数（服务端 count）。
  Future<(List<PlazaNote>, bool hasMore, String firstNoteId, int total)>
      getTopicNotes(
    String topic, {
    int page = 1,
    int pageSize = 100,
  }) async {
    final res = await _call('getPlazaNotes', params: {
      'page': page,
      'pageSize': pageSize,
      'sort': 'hot',
      'topic': topic,
    });
    final list = (res['notes'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaNote.fromJson)
        .toList();
    return (
      _withoutDeleted(list),
      res['hasMore'] == true,
      res['firstNoteId']?.toString() ?? '',
      (res['total'] as num?)?.toInt() ?? list.length,
    );
  }

  /// 拉取关注用户的帖子（服务端按关注列表 + 屏蔽列表过滤）。
  /// 需登录，未登录返回空。
  Future<(List<PlazaNote>, bool hasMore)> getFollowingNotes({
    int page = 1,
    int pageSize = 20,
  }) async {
    if (!AuthService.instance.isLoggedIn) return (<PlazaNote>[], false);
    final res = await _call('getFollowingNotes', params: {
      'page': page,
      'pageSize': pageSize,
    });
    final list = (res['notes'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaNote.fromJson)
        .toList();
    final hasMore = res['hasMore'] == true;
    return (_withoutDeleted(list), hasMore);
  }

  /// 兜底补齐笔记列表的作者展示信息（@账号/认证/阅藏进度）。
  ///
  /// 服务端 attachAuthorAccounts/attachAuthorCanonProgress 正常时返回原列表
  /// （零开销）；仅当笔记里作者信息缺失（历史脏数据、云端记录顺序漂移、
  /// 旧版云函数未附加等）时，才批量拉取 getUserProfiles 按 uid 补齐——
  /// 与「关注」栏目数据来源一致，保证发现/讨论等栏目同一用户显示口径相同：
  /// 头像旁有 @账号、阅藏百分比，点击头像进入个人主页信息完整。
  Future<List<PlazaNote>> enrichFeedAuthors(List<PlazaNote> notes) async {
    if (notes.isEmpty) return notes;
    final missing = <String>{};
    for (final n in notes) {
      if (n.ownerUserId.isEmpty) continue;
      if (n.authorAccount.isEmpty || n.canonTotal <= 0) {
        missing.add(n.ownerUserId);
      }
    }
    if (missing.isEmpty) return notes;
    try {
      final profiles = await getUserProfiles(missing.toList());
      if (profiles.isEmpty) return notes;
      final byUid = {for (final p in profiles) p.id: p};
      return [
        for (final n in notes) _patchFeedAuthor(n, byUid[n.ownerUserId]),
      ];
    } catch (_) {
      return notes;
    }
  }

  /// 单条笔记按用户资料补齐缺失的作者展示字段；资料未命中或无需补齐时原样返回。
  static PlazaNote _patchFeedAuthor(PlazaNote n, UserProfile? p) {
    if (p == null) return n;
    final needsAccount = n.authorAccount.isEmpty && p.account.isNotEmpty;
    final needsCanon = n.canonTotal <= 0 && p.canonTotal > 0;
    final needsVerified = !n.authorVerified && p.verified;
    if (!needsAccount && !needsCanon && !needsVerified) return n;
    return n.copyWith(
      authorAccount: needsAccount ? p.account : n.authorAccount,
      authorVerified: n.authorVerified || p.verified,
      canonRead: n.canonRead > 0 ? n.canonRead : p.canonRead,
      canonTotal: n.canonTotal > 0 ? n.canonTotal : p.canonTotal,
    );
  }

  /// 拉取热门讨论：返回（top 话题, top 经文），每类最多 10 条。
  /// 热度由云端按互动量 + 时间衰减聚合；客户端负责取前 3 并做当日轮换。
  Future<(List<HotDiscussionItem>, List<HotDiscussionItem>)>
      getHotDiscussions() async {
    final res = await _call('getHotDiscussions');
    List<HotDiscussionItem> parse(String key) => (res[key] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(HotDiscussionItem.fromJson)
        .toList();
    return (parse('topics'), parse('sutras'));
  }

  /// 菩提空间热门经文榜：最近 30 天内被提及的经文（广场帖正文的 $经名 引用 +
  /// 经书讨论页发布的讨论），同一帖子多次提及只算一次；提及次数即热度分，
  /// 次数越多越靠前，有 1 次提及即入榜。
  Future<List<HotDiscussionItem>> getHotSutraMentions() async {
    final res = await _call('getHotSutraMentions');
    return (res['sutras'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(HotDiscussionItem.fromJson)
        .toList();
  }

  /// 获取全平台热门经书（按锁定精读用户数排序，最多 50 条）。
  Future<List<PopularSutraItem>> getPopularSutras() async {
    final res = await _call('getPopularSutras');
    return (res['sutras'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PopularSutraItem.fromJson)
        .toList();
  }

  /// 拉取某帖子的回复帖列表（repostOf == noteId，最早在前），供详情页折叠展示。
  Future<(List<PlazaNote>, int total)> getNoteReplies(
    String noteId, {
    int page = 1,
    int pageSize = 50,
  }) async {
    final res = await _call('getNoteReplies', params: {
      'noteId': noteId,
      'page': page,
      'pageSize': pageSize,
    });
    final list = (res['notes'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaNote.fromJson)
        .toList();
    final total = (res['total'] as num?)?.toInt() ?? list.length;
    return (_withoutDeleted(list), total);
  }

  /// 广场笔记详情（公开或本人可见）。
  Future<PlazaNote> getNoteById(String id) async {
    // 通知页/回复卡等场景会重复调用此方法，用缓存避免多次云函数调用。
    final cached = _noteCache[id];
    if (cached != null) return cached;
    final res = await _call('getNoteById', params: {'id': id});
    final note = res['note'];
    if (note is! Map<String, dynamic>) {
      throw const CloudApiException('笔记不存在');
    }
    final plazaNote = PlazaNote.fromJson(note);
    _noteCache[id] = plazaNote;
    return plazaNote;
  }

  /// 阅读量 +1（打开详情页时调用）。返回最新阅读量。
  Future<int> incView(String noteId) async {
    final res = await _call('incView', params: {'id': noteId});
    final v = res['viewCount'];
    // 云端可能返回字符串（历史脏数据），统一转数字；并打印原始值便于排查。
    final count = v is num ? v.toInt() : int.tryParse('$v');
    debugPrint('[incView] noteId=$noteId viewCount=$v -> $count');
    return count ?? 0;
  }

  /// 转发笔记。quote 为空 → 直接转发；quote 非空 → 引用转发（引言 + 原笔记）。
  /// kind：forward（直接转发）/ quote（引用转发）/ reply（回复，不展示转发角标）。
  Future<String> repostNote(String noteId,
      {String quote = '', String kind = 'forward'}) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('repostNote', params: {
      'id': noteId,
      'authorName': _authorName,
      'kind': kind,
      if (quote.trim().isNotEmpty) 'quote': quote.trim(),
    });
    final id = res['id']?.toString() ?? '';
    markRecentlyPublished(id);
    return id;
  }

  /// 预取当前登录用户的笔记收藏记录（用于广场/详情展示收藏态）。未登录时清空。
  Future<void> refreshFavoriteNoteIds() async {
    favoriteNoteIds.clear();
    if (!AuthService.instance.isLoggedIn) return;
    try {
      final app = await AuthService.instance.ensureApp();
      if (app == null) return;
      final res = await _call('getFavoriteNoteIds');
      final ids = res['ids'];
      if (ids is List) {
        favoriteNoteIds.addAll(ids.map((e) => e.toString()));
      }
    } catch (_) {}
  }

  /// 收藏/取消收藏笔记。返回是否已收藏。
  Future<bool> toggleNoteFavorite(String noteId) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('toggleNoteFavorite',
        params: {'noteId': noteId, 'authorName': _authorName});
    final favorited = res['favorited'] == true;
    if (favorited) {
      favoriteNoteIds.add(noteId);
    } else {
      favoriteNoteIds.remove(noteId);
    }
    return favorited;
  }

  /// 拉取当前用户收藏的笔记列表（公开且正常的）。
  Future<List<PlazaNote>> getFavoriteNotes() async {
    if (!AuthService.instance.isLoggedIn) return [];
    final res = await _call('getFavoriteNotes');
    return _withoutDeleted((res['notes'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaNote.fromJson)
        .toList());
  }

  /// 拉取当前用户点赞过的笔记列表（最新点赞在前）。
  Future<List<PlazaNote>> getLikedNotes() async {
    if (!AuthService.instance.isLoggedIn) return [];
    // 优先新版云函数的 getLikedNotes（带 createdAt 倒序）。
    try {
      final res = await _call('getLikedNotes');
      return _withoutDeleted((res['notes'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(PlazaNote.fromJson)
          .toList());
    } catch (_) {
      // 旧版云函数兜底：getLikedNoteIds 拿 ID 顺序（最新在前），再逐个取详情。
    }
    final idRes = await _call('getLikedNoteIds');
    final ids = (idRes['ids'] as List<dynamic>? ?? []).map((e) => e.toString());
    final list = <PlazaNote>[];
    // 旧接口无排序，默认按插入顺序返回（旧在前），反转后最新点赞在前。
    for (final id in ids.toList().reversed) {
      try {
        if (locallyDeletedNoteIds.contains(id)) continue;
        final res = await _call('getNoteById', params: {'id': id});
        final note = res['note'];
        if (note is Map<String, dynamic>) {
          list.add(PlazaNote.fromJson(note));
        }
      } catch (_) {
        // 单个笔记获取失败（已删除/隐藏）跳过
      }
    }
    return list;
  }

  /// 拉取当前用户自己发布的笔记列表（含私密笔记）。
  /// [repostKind] 非空时服务端按转发类型过滤（如 'reply' 只返回回复帖）。
  Future<(List<PlazaNote>, bool hasMore)> getMyNotes({
    int page = 1,
    int pageSize = 20,
    String? repostKind,
  }) async {
    if (!AuthService.instance.isLoggedIn) return (<PlazaNote>[], false);
    final res = await _call('getMyNotes', params: {
      'page': page,
      'pageSize': pageSize,
      if (repostKind != null) 'repostKind': repostKind,
    });
    final notes = (res['notes'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaNote.fromJson)
        .toList();
    final hasMore = res['hasMore'] == true;
    return (_withoutDeleted(notes), hasMore);
  }

  /// 最近一次关注/屏蔽列表刷新是否失败（登录失效/网络异常）。
  /// 失败时关注/屏蔽集合是旧的（或空的），UI 不能据此展示「未关注」等状态，
  /// 应提示登录已失效，而不是给用户错误的按钮/空列表。
  bool followStateFailed = false;

  /// 预取当前登录用户的关注/屏蔽记录。未登录时清空。
  /// 先拉取成功再整体替换，避免网络抖动时清空本地集合导致屏蔽失效。
  /// 并发调用去重：主页多个栏目同时预取时共享同一次请求。
  /// 返回是否刷新成功（失败时集合保持原值，UI 应提示登录失效而非误用旧值）。
  Future<bool>? _followStatesInFlight;
  Future<bool> refreshFollowStates() {
    final existing = _followStatesInFlight;
    if (existing != null) return existing;
    final f = _refreshFollowStates();
    _followStatesInFlight = f;
    f.whenComplete(() => _followStatesInFlight = null);
    return f;
  }

  Future<bool> _refreshFollowStates() async {
    if (!AuthService.instance.isLoggedIn) {
      followingUserIds.clear();
      blockedUserIds.clear();
      followStateFailed = false;
      return true;
    }
    followStateFailed = false;
    try {
      final app = await AuthService.instance.ensureApp();
      if (app == null) {
        followStateFailed = true;
        return false;
      }
      // 关注/屏蔽列表互相独立，串行 await 会累积两倍网络延迟；
      // 并行拉取让预热更快，列表就绪后首页/关注刷新都等更短。
      final results = await Future.wait([
        _call('getFollowingUserIds'),
        _call('getBlockedUserIds'),
      ]);
      final fs = results[0]['ids'];
      final bs = results[1]['ids'];
      // 先构建新集合，成功后再替换——避免云调用失败时清空本地集合
      // 导致关注/屏蔽状态丢失（token 过期时的竞态问题）。
      final newFollowing = <String>{};
      final newBlocked = <String>{};
      if (fs is List) newFollowing.addAll(fs.map((e) => e.toString()));
      if (bs is List) newBlocked.addAll(bs.map((e) => e.toString()));
      followingUserIds
        ..clear()
        ..addAll(newFollowing);
      blockedUserIds
        ..clear()
        ..addAll(newBlocked);
      return true;
    } catch (_) {
      followStateFailed = true;
      return false;
    }
  }

  /// 拉取当前用户关注的用户 id 列表（未登录返回空）。
  Future<List<String>> getFollowingUserIds() async {
    if (!AuthService.instance.isLoggedIn) return [];
    final res = await _call('getFollowingUserIds');
    return (res['ids'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
  }

  /// 拉取关注当前用户的所有用户 id 列表（粉丝，未登录返回空）。
  Future<List<String>> getFollowerUserIds() async {
    if (!AuthService.instance.isLoggedIn) return [];
    final res = await _call('getFollowerUserIds');
    return (res['ids'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
  }

  /// 批量获取用户展示信息（昵称）。用于关注/粉丝列表。
  /// 拉取一批用户的资料（昵称/账号/认证/阅藏进度/头像等）。
  /// [timeout] 可放宽：详情页评论作者资料是后台预取，不影响首屏，
  /// 但服务端要按人扫 notes 表算加入时间，数据多时可能超过默认 8 秒。
  Future<List<UserProfile>> getUserProfiles(
    List<String> ids, {
    Duration? timeout,
  }) async {
    if (ids.isEmpty) return [];
    final res = await _call('getUserProfiles',
        params: {'ids': ids}, timeout: timeout);
    return (res['users'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(UserProfile.fromJson)
        .toList();
  }

  /// 拉取某位用户主页的「精读 / 功课」数据（对方开启相应隐私开关才返回内容）。
  Future<UserHomeData> getUserHomeData(String userId) async {
    final res = await _call('getUserHomeData', params: {'userId': userId});
    return UserHomeData.fromJson(res);
  }

  /// 按账号前缀/包含搜索用户（@提及面板）。返回匹配账号与 uid，名称待 getUserProfiles 补齐。
  Future<List<UserProfile>> searchUsers(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final res = await _call('searchUsers', params: {'query': q});
    final list = (res['users'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(UserProfile.fromJson)
        .toList();
    final ids = list.map((u) => u.id).where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return list;
    try {
      final enriched = await getUserProfiles(ids);
      final byId = {for (final u in enriched) u.id: u};
      return [
        for (final u in list)
          byId[u.id] == null
              ? u
              : UserProfile(
                  id: u.id,
                  name: byId[u.id]!.name,
                  account: u.account,
                  verified: byId[u.id]!.verified,
                  tagline: byId[u.id]!.tagline,
                  joinTime: byId[u.id]!.joinTime,
                ),
      ];
    } catch (_) {
      return list;
    }
  }

  /// 我的主页角标：互动未读数 / 关注数 / 粉丝数（未登录返回全 0）。
  Future<MyCounts> getMyCounts() async {
    if (!AuthService.instance.isLoggedIn) return const MyCounts();
    final res = await _call('getMyCounts');
    return MyCounts(
      following: (res['following'] as num?)?.toInt() ?? 0,
      followers: (res['followers'] as num?)?.toInt() ?? 0,
      unread: (res['unread'] as num?)?.toInt() ?? 0,
    );
  }

  /// 关注/取消关注某个用户。返回是否已关注。
  Future<bool> toggleFollow(String targetUserId) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('toggleFollow', params: {
      'targetUserId': targetUserId,
      'authorName': _authorName,
    });
    final following = res['following'] == true;
    if (following) {
      followingUserIds.add(targetUserId);
    } else {
      followingUserIds.remove(targetUserId);
    }
    return following;
  }

  /// 屏蔽/取消屏蔽某个用户。返回是否已屏蔽。
  Future<bool> toggleBlockUser(String targetUserId) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('toggleBlockUser', params: {
      'targetUserId': targetUserId,
    });
    final blocked = res['blocked'] == true;
    if (blocked) {
      blockedUserIds.add(targetUserId);
    } else {
      blockedUserIds.remove(targetUserId);
    }
    return blocked;
  }

  /// 点赞/取消点赞。返回 (是否已赞, 最新点赞数)。
  Future<(bool, int)> toggleLike(String noteId) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('toggleLike',
        params: {'noteId': noteId, 'authorName': _authorName});
    final liked = res['liked'] == true;
    final count = (res['likeCount'] as num?)?.toInt() ?? 0;
    if (liked) {
      likedNoteIds.add(noteId);
    } else {
      likedNoteIds.remove(noteId);
    }
    return (liked, count);
  }

  /// 点赞/取消点赞评论。返回 (是否已赞, 最新点赞数)。
  Future<(bool, int)> toggleCommentLike(String commentId) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('toggleCommentLike',
        params: {'commentId': commentId});
    final liked = res['liked'] == true;
    final count = (res['likeCount'] as num?)?.toInt() ?? 0;
    return (liked, count);
  }

  /// 发表评论。
  Future<PlazaComment> createComment(String noteId, String content) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('createComment', params: {
      'noteId': noteId,
      'content': content,
      'authorName': _authorName,
    });
    final comment = res['comment'];
    if (comment is! Map<String, dynamic>) {
      throw const CloudApiException('评论失败');
    }
    return PlazaComment.fromJson(comment);
  }

  /// 拉取评论（时间正序）。
  Future<List<PlazaComment>> getComments(String noteId) async {
    final res = await _call('getComments', params: {'noteId': noteId});
    return (res['comments'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaComment.fromJson)
        .toList();
  }

  /// 拉取某本经书的讨论（公开共享，最新在前）。
  /// 返回（讨论列表, 是否还有更多, 讨论总数）；每条为 {id, content, name,
  /// userId, account, verified, likeCount, at} 结构，供经书讨论页直接渲染。
  Future<(List<Map<String, dynamic>>, bool hasMore, int total)>
      getSutraDiscussions({
    required String sutraTitle,
    int page = 1,
    int pageSize = 50,
  }) async {
    final res = await _call('getSutraDiscussions', params: {
      'sutraTitle': sutraTitle,
      'page': page,
      'pageSize': pageSize,
    });
    final list = (res['discussions'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_sutraDiscussionFromJson)
        .toList();
    final hasMore = res['hasMore'] == true;
    return (list, hasMore, (res['total'] as num?)?.toInt() ?? list.length);
  }

  /// 发表经书讨论（需登录）。返回云端讨论 id。
  Future<String> createSutraDiscussion({
    required String sutraTitle,
    required String content,
  }) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('createSutraDiscussion', params: {
      'sutraTitle': sutraTitle,
      'content': content,
      'authorName': _authorName,
    });
    final id = res['id']?.toString() ?? '';
    markRecentlyPublished(id);
    return id;
  }

  /// 云端经书讨论记录 → 页面渲染用的字典结构。
  static Map<String, dynamic> _sutraDiscussionFromJson(
      Map<String, dynamic> json) {
    return {
      'id': json['_id']?.toString() ?? json['id']?.toString() ?? '',
      'content': json['content']?.toString() ?? '',
      'name': json['authorName']?.toString() ?? '同修',
      'userId': json['ownerUserId']?.toString() ?? '',
      'account': json['authorAccount']?.toString() ?? '',
      'verified': json['authorVerified'] == true,
      'likeCount': (json['likeCount'] as num?)?.toInt() ?? 0,
      'at': (json['createdAt'] as num?)?.toInt() ?? 0,
      'canonRead': (json['canonRead'] as num?)?.toInt() ?? 0,
      'canonTotal': (json['canonTotal'] as num?)?.toInt() ?? 0,
    };
  }

  /// 删除自己发表的经书讨论。
  Future<void> deleteSutraDiscussion(String discussionId) async {
    await _call('deleteSutraDiscussion', params: {'discussionId': discussionId});
  }

  /// 删除评论（仅评论作者或笔记作者）。
  Future<void> deleteComment(String commentId) async {
    await _call('deleteComment', params: {'commentId': commentId});
  }

  /// 举报笔记。
  Future<void> reportNote(String noteId, String reason) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    await _call('reportNote', params: {'noteId': noteId, 'reason': reason});
  }

  /// 拉取我的互动动态（转发/我的评论/别人对我的回复）。
  Future<(List<PlazaActivity>, bool hasMore)> getMyActivities({
    int page = 1,
    int pageSize = 20,
  }) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('getMyActivities', params: {
      'page': page,
      'pageSize': pageSize,
    });
    final list = res['activities'];
    final items = list is List
        ? list
            .map((e) => PlazaActivity.fromJson(e as Map<String, dynamic>))
            .toList()
        : <PlazaActivity>[];
    return (items, res['hasMore'] == true);
  }

  /// 拉取某位用户公开发布的所有笔记（用于查看对方的菩提空间）。
  Future<(List<PlazaNote>, bool hasMore)> getUserNotes(
    String userId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final res = await _call('getUserNotes', params: {
      'userId': userId,
      'page': page,
      'pageSize': pageSize,
    });
    final list = res['notes'];
    final items = list is List
        ? list
            .map((e) => PlazaNote.fromJson(e as Map<String, dynamic>))
            .toList()
        : <PlazaNote>[];
    return (_withoutDeleted(items), res['hasMore'] == true);
  }

  // ==================== 消息中心 ====================

  /// 拉取「收到的互动」通知列表（分页，最新在前）。不自动标记已读。
  Future<NotificationPageResult> getNotifications({
    int page = 1,
    int pageSize = 20,
  }) async {
    if (!AuthService.instance.isLoggedIn) {
      return const NotificationPageResult(items: [], hasMore: false);
    }
    final res = await _call('getNotifications', params: {
      'page': page,
      'pageSize': pageSize,
    });
    final list = res['activities'];
    final items = list is List
        ? list
            .map((e) => NotificationItem.fromJson(e as Map<String, dynamic>))
            .toList()
        : <NotificationItem>[];
    debugPrint('[Notif] getNotifications page=$page rawKeys=${res.keys.toList()} count=${items.length} hasMore=${res['hasMore']}');
    if (items.isEmpty) {
      debugPrint('[Notif] empty! total=${res['total']} ok=${res['ok']}');
    }
    return NotificationPageResult(
      items: items,
      hasMore: res['hasMore'] == true,
    );
  }

  /// 消息中心未读数（点赞/评论/回复评论/转发/收藏/关注/@提及）。
  Future<int> getNotificationUnreadCount() async {
    if (!AuthService.instance.isLoggedIn) return 0;
    final res = await _call('getNotificationUnreadCount');
    return (res['unread'] as num?)?.toInt() ?? 0;
  }

  /// 诊断接口：返回当前 uid、笔记数、活动数、活动样本。
  /// 用于排查通知不显示问题。
  Future<Map<String, dynamic>> debugWhoami() async {
    return _call('whoami');
  }

  /// 标记通知已读：传 ids 标记指定通知；[all] 为 true 时全部标记已读。
  Future<void> markNotificationsRead(List<String> ids, {bool all = false}) async {
    if (!AuthService.instance.isLoggedIn) return;
    if (all) {
      await _call('markNotificationsRead', params: {'all': true});
      return;
    }
    if (ids.isEmpty) return;
    await _call('markNotificationsRead', params: {'ids': ids});
  }

  /// 删除指定通知。
  Future<void> deleteNotifications(List<String> ids) async {
    if (!AuthService.instance.isLoggedIn) return;
    if (ids.isEmpty) return;
    await _call('deleteNotifications', params: {'ids': ids});
  }

  /// 拉取当前用户云端整包数据（无记录返回 null）。
  Future<Map<String, dynamic>?> getUserData() async {
    if (!AuthService.instance.isLoggedIn) return null;
    final res = await _call('getUserData');
    if (res['hasData'] != true) return null;
    final payload = res['payload'];
    return payload is Map<String, dynamic> ? payload : null;
  }

  /// 上传当前用户云端整包数据（整包覆盖，见 getUserData）。
  Future<void> setUserData(Map<String, dynamic> payload) async {
    if (!AuthService.instance.isLoggedIn) return;
    await _call('setUserData', params: {'payload': payload});
  }

  /// 提交反馈意见（未登录也可提交，云端记录用户 uid）。
  Future<void> submitFeedback(String content, {String? contact}) async {
    await _call('submitFeedback', params: {
      'content': content,
      if (contact != null && contact.isNotEmpty) 'contact': contact,
    });
  }

  /// 当前登录用户是否为管理员（admins 集合中登记了 uid）。
  Future<bool> isAdmin() async {
    try {
      final res = await _call('isAdmin');
      return res['isAdmin'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 管理员拉取反馈列表。
  /// [status] 可选：'new' / 'handled'，为空返回全部。
  Future<FeedbackListResult> getFeedbacks({
    int page = 1,
    int pageSize = 20,
    String status = '',
  }) async {
    final res = await _call('getFeedbacks', params: {
      'page': page,
      'pageSize': pageSize,
      if (status.isNotEmpty) 'status': status,
    });
    final list = res['feedbacks'];
    final items = list is List
        ? list
            .map((e) => FeedbackItem.fromJson(e as Map<String, dynamic>))
            .toList()
        : <FeedbackItem>[];
    return FeedbackListResult(
      items: items,
      hasMore: res['hasMore'] == true,
      unread: (res['unread'] as num?)?.toInt() ?? 0,
    );
  }

  /// 管理员标记反馈为已处理 / 待处理。
  Future<void> markFeedbackHandled(String id, {bool handled = true}) async {
    await _call('markFeedbackHandled', params: {'id': id, 'handled': handled});
  }

  /// 管理员拉取管理员列表（含账号名称）。
  Future<List<AdminItem>> getAdmins() async {
    final res = await _call('getAdmins');
    return (res['admins'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(AdminItem.fromJson)
        .toList();
  }

  /// 管理员添加管理员：输入账号名称（或用户 uid）。
  Future<void> addAdmin(String input) async {
    await _call('addAdmin', params: {'username': input});
  }

  /// 管理员移除管理员（至少保留一位）。
  Future<void> removeAdmin(String uid) async {
    await _call('removeAdmin', params: {'uid': uid});
  }

  /// 拉取公告列表（所有用户可读，最新在前）。
  Future<List<AnnouncementItem>> getAnnouncements() async {
    final res = await _call('getAnnouncements');
    return (res['announcements'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(AnnouncementItem.fromJson)
        .toList();
  }

  /// 管理员发布公告。
  Future<void> addAnnouncement({
    required String title,
    required String content,
  }) async {
    await _call('addAnnouncement', params: {
      'title': title,
      'content': content,
    });
  }

  /// 管理员删除公告。
  Future<void> deleteAnnouncement(String id) async {
    await _call('deleteAnnouncement', params: {'id': id});
  }

  /// 通用调用「api」云函数（供账号名称/密码等认证相关 action 使用）。
  Future<Map<String, dynamic>> callApi(
    String action, {
    Map<String, dynamic>? params,
  }) {
    return _call(action, params: params);
  }

  /// AI 网络自诊断：检测云函数到大模型服务的连通性，返回根因结论。
  Future<Map<String, dynamic>> aiNetProbe() async {
    return _call('aiNetProbe', timeout: const Duration(seconds: 30));
  }

  /// 上报读经时长增量（秒）到云端：服务端累加到 userAccounts.readingSeconds，
  /// 供他人主页展示该用户点亮的修学徽章。返回 { accepted }（实际接受的增量）。
  Future<Map<String, dynamic>> reportReadingTime(int deltaSeconds) async {
    return _call('reportReadingTime', params: {'delta': deltaSeconds});
  }

  /// 上报「阅藏进度」：标记完成阅读的经书册数与全藏总册数（经藏页同源算法），
  /// 服务端计算百分比存到 userAccounts.canonPercent，供广场帖子头部展示。
  Future<Map<String, dynamic>> reportCanonProgress({
    required int readCount,
    required int totalCount,
  }) async {
    return _call('reportCanonProgress', params: {
      'read': readCount,
      'total': totalCount,
    });
  }

  /// 提交实名认证（真实姓名 + 身份证号）。
  /// 云端会再次校验格式（地区码/出生日期/校验位），返回是否已认证。
  Future<bool> verifyIdentity({
    required String realName,
    required String idCard,
  }) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('verifyIdentity', params: {
      'realName': realName,
      'idCard': idCard,
    });
    return res['verified'] == true;
  }

  /// 查询当前用户实名认证状态（未登录/未认证返回未认证）。
  Future<VerificationInfo> getMyVerification() async {
    if (!AuthService.instance.isLoggedIn) return const VerificationInfo();
    final res = await _call('getMyVerification');
    return VerificationInfo(
      verified: res['verified'] == true,
      realNameMasked: res['realNameMasked']?.toString() ?? '',
      verifiedAt: (res['verifiedAt'] as num?)?.toInt() ?? 0,
    );
  }
}
