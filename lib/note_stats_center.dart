import 'package:flutter/foundation.dart';

import 'cloud_notes_service.dart';

/// 帖子指标实时同步中心：详情页的点赞/评论/转发/阅读等操作后，
/// 把最新指标广播出去，Feed 列表上的对应帖子数字立即刷新（无需切页重拉）。
class NoteStatsCenter extends ChangeNotifier {
  NoteStatsCenter._();

  static final NoteStatsCenter instance = NoteStatsCenter._();

  final Map<String, PlazaNote> _latest = {};

  /// 最近一次新发布的回复帖：发现/关注流监听它，把新回复立即挂到当前列表里的
  /// 根帖下方，头像连线即时出现，不等列表刷新返回（云端写入到可查询、
  /// 再加网络往返会有数秒延迟）。
  final ValueNotifier<PlazaNote?> lastReplyPosted = ValueNotifier<PlazaNote?>(null);

  /// 该帖子最近一次广播的指标（无则 null）。
  PlazaNote? latest(String noteId) => _latest[noteId];

  /// 上报某帖子的最新指标。
  void report(PlazaNote note) {
    _latest[note.id] = note;
    notifyListeners();
  }
}
