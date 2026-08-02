import 'package:cloudbase_flutter/cloudbase_flutter.dart';

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
  final String visibility;
  final String status;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final int repostCount;
  final String repostOf;
  final String repostSourceAuthor;
  final int createdAt;
  final int updatedAt;

  const PlazaNote({
    required this.id,
    required this.ownerUserId,
    required this.title,
    required this.content,
    required this.authorName,
    required this.visibility,
    required this.status,
    required this.likeCount,
    required this.commentCount,
    this.viewCount = 0,
    this.repostCount = 0,
    this.repostOf = '',
    this.repostSourceAuthor = '',
    required this.createdAt,
    required this.updatedAt,
  });

  factory PlazaNote.fromJson(Map<String, dynamic> json) => PlazaNote(
        id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
        ownerUserId: json['ownerUserId']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        authorName: json['authorName']?.toString() ?? '同修',
        visibility: json['visibility']?.toString() ?? 'public',
        status: json['status']?.toString() ?? 'normal',
        likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
        commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
        viewCount: (json['viewCount'] as num?)?.toInt() ?? 0,
        repostCount: (json['repostCount'] as num?)?.toInt() ?? 0,
        repostOf: json['repostOf']?.toString() ?? '',
        repostSourceAuthor: json['repostSourceAuthor']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 广场评论。
class PlazaComment {
  final String id;
  final String noteId;
  final String authorId;
  final String authorName;
  final String content;
  final int createdAt;

  const PlazaComment({
    required this.id,
    required this.noteId,
    required this.authorId,
    required this.authorName,
    required this.content,
    required this.createdAt,
  });

  factory PlazaComment.fromJson(Map<String, dynamic> json) => PlazaComment(
        id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
        noteId: json['noteId']?.toString() ?? '',
        authorId: json['authorId']?.toString() ?? '',
        authorName: json['authorName']?.toString() ?? '同修',
        content: json['content']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
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
    return (res['viewCount'] as num?)?.toInt() ?? 0;
  }

  /// 转发笔记（以当前用户身份复制生成新笔记）。返回新笔记 id。
  Future<String> repostNote(String noteId) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const CloudApiException('请先登录');
    }
    final res = await _call('repostNote', params: {
      'id': noteId,
      'authorName': _authorName,
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
    final res = await _call('toggleLike', params: {'noteId': noteId});
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
}
