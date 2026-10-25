import 'auth_service.dart';

/// 内容归属判定：这条帖子 / 回复是不是「我自己」发的。
///
/// 产品规则：`置顶 / 编辑 / 删除` 三个操作**只针对自己的内容**；
/// 他人内容的三点菜单只有 `关注 / 屏蔽`（以及收藏/分享这类无破坏性入口）。
/// 所有渲染三点菜单的地方都必须用本函数判定归属，避免出现
/// 「别人的帖子也能置顶/删除」或者「自己的帖子被当成别人的」。
///
/// 会话恢复存在竞态窗口：真实会话回来前 [AuthService.currentUser] 可能暂时为
/// null，此时用本地缓存的 uid 兜底；两者都拿不到时按「不是自己的」处理。
bool isOwnContent(String? ownerUserId) {
  if (ownerUserId == null || ownerUserId.isEmpty) return false;
  final me = AuthService.instance.currentUser.value;
  if (me != null && ownerUserId == me.id) return true;
  final cached = AuthService.instance.cachedUserId;
  return cached != null && cached.isNotEmpty && ownerUserId == cached;
}
