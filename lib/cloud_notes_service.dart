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

/// 广场笔记（云端返回的一条记录）。
class PlazaNote {
  final String id;
  final String ownerUserId;
  final String title;
  final String content;
  final String authorName;
  final String authorAccount;
  final bool authorVerified;
  final String visibility;
  final String status;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final int repostCount;
  final String repostOf;
  final String repostSourceAuthor;

  /// 转发类型：forward / quote / reply（reply 不展示转发角标）。
  final String repostKind;

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
    required this.visibility,
    required this.status,
    required this.likeCount,
    required this.commentCount,
    this.viewCount = 0,
    this.repostCount = 0,
    this.repostOf = '',
    this.repostSourceAuthor = '',
    this.repostKind = '',
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
        visibility: json['visibility']?.toString() ?? 'public',
        status: json['status']?.toString() ?? 'normal',
        likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
        commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
        viewCount: _parseViewCount(json['viewCount']),
        repostCount: (json['repostCount'] as num?)?.toInt() ?? 0,
        repostOf: json['repostOf']?.toString() ?? '',
        repostSourceAuthor: json['repostSourceAuthor']?.toString() ?? '',
        repostKind: json['repostKind']?.toString() ?? '',
        quoteContent: json['quoteContent']?.toString() ?? '',
        quoteOfTitle: json['quoteOfTitle']?.toString() ?? '',
        quoteOfContent: json['quoteOfContent']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  /// 把云端返回的 viewCount 安全转成数字（容忍字符串脏数据）。
  static int _parseViewCount(dynamic v) =>
      v is num ? v.toInt() : int.tryParse('$v') ?? 0;
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
  final int createdAt;

  const PlazaComment({
    required this.id,
    required this.noteId,
    required this.authorId,
    required this.authorName,
    this.authorAccount = '',
    this.authorVerified = false,
    required this.content,
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
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
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

/// 广场用户（关注/粉丝列表展示用，可含签名/加入时间/账号）。
class UserProfile {
  final String id;
  final String name;
  final bool verified;
  final String tagline;
  final int joinTime;
  final String account;

  const UserProfile({
    required this.id,
    required this.name,
    this.verified = false,
    this.tagline = '',
    this.joinTime = 0,
    this.account = '',
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

  String get _authorName =>
      AuthService.instance.currentUser.value?.displayName ?? '同修';

  Future<Map<String, dynamic>> _call(
    String action, {
    Map<String, dynamic>? params,
  }) {
    // 所有云端调用统一加超时，避免网络异常时页面永久卡在加载状态。
    return _doCall(action, params: params).timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw const CloudApiException('请求超时'),
    );
  }

  Future<Map<String, dynamic>> _doCall(
    String action, {
    Map<String, dynamic>? params,
  }) async {
    final app = await AuthService.instance.ensureApp();
    if (app == null) {
      throw const CloudApiException('尚未配置云环境');
    }
    // 未登录时先确保有一个匿名会话，否则网关会拒绝调用（如浏览广场）。
    await AuthService.instance.ensureAnonymousForBrowse();
    final token = await AuthService.instance.getAccessToken();
    final FunctionResponse res;
    try {
      res = await app.callFunction(
        name: _fnName,
        data: {
          'action': action,
          if (token != null) '__accessToken': token,
          if (params != null) ...params,
        },
      );
    } catch (e) {
      throw CloudApiException('网络异常：${e.toString()}');
    }
    final result = res.result is Map<String, dynamic>
        ? res.result as Map<String, dynamic>
        : null;
    if (result == null) {
      throw CloudApiException(res.message ?? '请求失败，请稍后重试');
    }
    if (result['ok'] != true) {
      throw CloudApiException(result['error']?.toString() ?? '请求失败');
    }
    return result;
  }

  /// 预取当前登录用户的点赞记录（用于广场列表/详情展示已赞态）。未登录时清空。
  Future<void> refreshLikedNoteIds() async {
    likedNoteIds.clear();
    if (!AuthService.instance.isLoggedIn) return;
    try {
      final app = await AuthService.instance.ensureApp();
      if (app == null) return;
      final res = await _call('getLikedNoteIds');
      final ids = res['ids'];
      if (ids is List) {
        likedNoteIds.addAll(ids.map((e) => e.toString()));
      }
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
    return res['id']?.toString() ?? '';
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
  Future<void> deleteCloudNote(String cloudId) async {
    await _call('deleteNote', params: {'id': cloudId});
  }

  /// 软删除/隐藏云端笔记（从广场移除，仍可恢复）。
  Future<void> hideCloudNote(String cloudId) async {
    await _call('updateNote', params: {'id': cloudId, 'status': 'hidden'});
  }

  /// 恢复被软删除的云端笔记（重新在广场展示）。
  Future<void> unhideCloudNote(String cloudId) async {
    await _call('updateNote', params: {'id': cloudId, 'status': 'normal'});
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
    return (list, hasMore);
  }

  /// 广场笔记详情（公开或本人可见）。
  Future<PlazaNote> getNoteById(String id) async {
    final res = await _call('getNoteById', params: {'id': id});
    final note = res['note'];
    if (note is! Map<String, dynamic>) {
      throw const CloudApiException('笔记不存在');
    }
    return PlazaNote.fromJson(note);
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
    return res['id']?.toString() ?? '';
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
    final res = await _call('toggleNoteFavorite', params: {'noteId': noteId});
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
    return (res['notes'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaNote.fromJson)
        .toList();
  }

  /// 拉取当前用户点赞过的笔记列表（最新点赞在前）。
  Future<List<PlazaNote>> getLikedNotes() async {
    if (!AuthService.instance.isLoggedIn) return [];
    // 优先新版云函数的 getLikedNotes（带 createdAt 倒序）。
    try {
      final res = await _call('getLikedNotes');
      return (res['notes'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(PlazaNote.fromJson)
          .toList();
    } catch (_) {
      // 旧版云函数兜底：getLikedNoteIds 拿 ID 顺序（最新在前），再逐个取详情。
    }
    final idRes = await _call('getLikedNoteIds');
    final ids = (idRes['ids'] as List<dynamic>? ?? []).map((e) => e.toString());
    final list = <PlazaNote>[];
    // 旧接口无排序，默认按插入顺序返回（旧在前），反转后最新点赞在前。
    for (final id in ids.toList().reversed) {
      try {
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
  Future<(List<PlazaNote>, bool hasMore)> getMyNotes({
    int page = 1,
    int pageSize = 20,
  }) async {
    if (!AuthService.instance.isLoggedIn) return (<PlazaNote>[], false);
    final res = await _call('getMyNotes', params: {
      'page': page,
      'pageSize': pageSize,
    });
    final notes = (res['notes'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PlazaNote.fromJson)
        .toList();
    final hasMore = res['hasMore'] == true;
    return (notes, hasMore);
  }

  /// 预取当前登录用户的关注/屏蔽记录。未登录时清空。
  Future<void> refreshFollowStates() async {
    followingUserIds.clear();
    blockedUserIds.clear();
    if (!AuthService.instance.isLoggedIn) return;
    try {
      final app = await AuthService.instance.ensureApp();
      if (app == null) return;
      final f = await _call('getFollowingUserIds');
      final fs = f['ids'];
      if (fs is List) followingUserIds.addAll(fs.map((e) => e.toString()));
      final b = await _call('getBlockedUserIds');
      final bs = b['ids'];
      if (bs is List) blockedUserIds.addAll(bs.map((e) => e.toString()));
    } catch (_) {}
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
  Future<List<UserProfile>> getUserProfiles(List<String> ids) async {
    if (ids.isEmpty) return [];
    final res = await _call('getUserProfiles', params: {'ids': ids});
    return (res['users'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(UserProfile.fromJson)
        .toList();
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
    return (items, res['hasMore'] == true);
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
