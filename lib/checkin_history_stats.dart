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
  const CheckInStatEntry({
    required this.label,
    required this.unit,
    required this.total,
    this.detail = const [],
  });
}

/// 历史统计区块：直接列出各类功课自使用以来累计的总量（与打卡目标无关，持续累积）。
class CheckInHistoryStats extends StatelessWidget {
  final List<CheckInStatEntry> entries;

  const CheckInHistoryStats({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    final list = entries.where((e) => e.total > 0).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
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
              Text('自使用以来累计',
                  style: TextStyle(fontSize: 11, color: _textHint)),
            ],
          ),
          if (list.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('还没有打卡记录',
                    style: TextStyle(fontSize: 12, color: _textHint)),
              ),
            )
          else
            for (final e in list) _buildEntry(e),
        ],
      ),
    );
  }

  Widget _buildEntry(CheckInStatEntry e) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
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
