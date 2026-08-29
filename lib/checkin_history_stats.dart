import 'package:flutter/material.dart';

import 'app_palette.dart';
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;
Color get _gold => AppPalette.p.accent;
class CheckInStatEntry {
  final String label;
  final String unit;
  final double total;
  final List<String> detail;

  /// 类型标识，用于长按拖动排序时定位条目与持久化顺序。
  final String? key;
  const CheckInStatEntry({
    required this.label,
    required this.unit,
    required this.total,
    this.detail = const [],
    this.key,
  });
}

/// 历史统计区块：直接列出各类功课自使用以来累计的总量（与打卡目标无关，持续累积）。
/// 提供 [onOrderChanged] 回调时，可长按某一条目直接拖动调整顺序，
/// 并把最新顺序（类型 key 列表）回调给调用方持久化。
class CheckInHistoryStats extends StatefulWidget {
  final List<CheckInStatEntry> entries;

  /// 背景色；为 null 时使用当前配色卡片色。
  final Color? bg;

  /// 圆角；为 null 时默认 14。
  final double? radius;

  /// 是否带细边框（独立页面用带边卡片，主页内嵌时去掉边框更协调）。
  final bool bordered;

  /// 提供后启用「长按拖动排序」；回调参数为调整后的类型 key 顺序列表。
  final ValueChanged<List<String>>? onOrderChanged;

  const CheckInHistoryStats({
    super.key,
    required this.entries,
    this.bg,
    this.radius,
    this.bordered = true,
    this.onOrderChanged,
  });

  @override
  State<CheckInHistoryStats> createState() => _CheckInHistoryStatsState();
}

class _CheckInHistoryStatsState extends State<CheckInHistoryStats> {
  late List<CheckInStatEntry> _entries;

  bool get _reorderable =>
      widget.onOrderChanged != null &&
      _entries.isNotEmpty &&
      _entries.every((e) => e.key != null && e.key!.isNotEmpty);

  @override
  void initState() {
    super.initState();
    _entries = _filter(widget.entries);
  }

  @override
  void didUpdateWidget(covariant CheckInHistoryStats oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entries = _filter(widget.entries);
  }

  List<CheckInStatEntry> _filter(List<CheckInStatEntry> entries) =>
      entries.where((e) => e.total > 0).toList();

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _entries.removeAt(oldIndex);
      _entries.insert(newIndex, item);
    });
    widget.onOrderChanged
        ?.call([for (final e in _entries) e.key ?? '']);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: widget.bg ?? _card,
        borderRadius: BorderRadius.circular(widget.radius ?? 14),
        border: widget.bordered ? Border.all(color: _border) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.timeline,
                    size: 15, color: _gold),
              ),
              const SizedBox(width: 8),
              Text('历史统计',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _text)),
              const Spacer(),
              Text(_reorderable ? '长按拖动排序' : '自使用以来累计',
                  style: TextStyle(fontSize: 11, color: _textHint)),
            ],
          ),
          if (_entries.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('还没有打卡记录',
                    style: TextStyle(fontSize: 12, color: _textHint)),
              ),
            )
          else if (_reorderable)
            _buildReorderList()
          else
            for (final e in _entries) _buildEntry(e),
        ],
      ),
    );
  }

  Widget _buildReorderList() {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      padding: EdgeInsets.zero,
      onReorder: _onReorder,
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: widget.bg ?? _card,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 8,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: child,
        ),
      ),
      children: [
        for (int i = 0; i < _entries.length; i++)
          ReorderableDelayedDragStartListener(
            key: ValueKey(_entries[i].key),
            index: i,
            child: _buildEntry(_entries[i]),
          ),
      ],
    );
  }

  Widget _buildEntry(CheckInStatEntry e) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              e.detail.isEmpty
                  ? e.label
                  : '${e.label} · ${e.detail.join('·')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: _textSec),
            ),
          ),
          const SizedBox(width: 10),
          Text(_fmtNum(e.total),
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: _text,
                  height: 1.2)),
          const SizedBox(width: 5),
          Text(e.unit,
              style: TextStyle(fontSize: 12, color: _textHint)),
        ],
      ),
    );
  }

  /// 千分位格式化数字（保留最多 1 位小数）。
  static String _fmtNum(double v) {
    final raw = v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(1);
    final neg = raw.startsWith('-');
    final body = neg ? raw.substring(1) : raw;
    final dot = body.indexOf('.');
    final intPart = dot < 0 ? body : body.substring(0, dot);
    final decPart = dot < 0 ? '' : body.substring(dot);
    final buf = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '${neg ? '-' : ''}${buf.toString()}$decPart';
  }
}