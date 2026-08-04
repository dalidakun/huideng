import 'package:flutter/foundation.dart';

import 'cloud_notes_service.dart';

/// 帖子指标实时同步中心：详情页的点赞/评论/转发/阅读等操作后，
/// 把最新指标广播出去，Feed 列表上的对应帖子数字立即刷新（无需切页重拉）。
class NoteStatsCenter extends ChangeNotifier {
  NoteStatsCenter._();

  static final NoteStatsCenter instance = NoteStatsCenter._();

  final Map<String, PlazaNote> _latest = {};

  /// 该帖子最近一次广播的指标（无则 null）。
  PlazaNote? latest(String noteId) => _latest[noteId];

  /// 上报某帖子的最新指标。
  void report(PlazaNote note) {
    _latest[note.id] = note;
    notifyListeners();
  }
}
