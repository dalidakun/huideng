import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'shanzhishi_store.dart';

/// 善知识搜索：上千位名号靠滑动不好定位，这里输入关键字过滤。
///
/// 与经藏页检索一致：前缀匹配优先、包含匹配其次；
/// 输入前不展示任何名号（避免刷屏），点选后返回位次，由页面把球转到该名号。
class ShanZhiShiSearchPage extends StatefulWidget {
  final List<ShanyishiEntry> entries;

  const ShanZhiShiSearchPage({super.key, required this.entries});

  @override
  State<ShanZhiShiSearchPage> createState() => _ShanZhiShiSearchPageState();
}

class _ShanZhiShiSearchPageState extends State<ShanZhiShiSearchPage> {
  final TextEditingController _ctrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 前缀匹配优先、包含匹配其次（与 NoteSutraCatalog.search 口径一致）。
  List<int> get _hits {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final prefix = <int>[];
    final contains = <int>[];
    for (var i = 0; i < widget.entries.length; i++) {
      final t = widget.entries[i].name.toLowerCase();
      if (t.startsWith(q)) {
        prefix.add(i);
      } else if (t.contains(q)) {
        contains.add(i);
      }
    }
    return [...prefix, ...contains];
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final hits = _hits;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, size: 18, color: p.text),
          onPressed: () => Navigator.pop(context),
        ),
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          style: TextStyle(fontSize: 15, color: p.text),
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            hintText: '搜索名号',
            hintStyle: TextStyle(fontSize: 14, color: p.textHint),
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              icon: Icon(Icons.clear, size: 18, color: p.textSec),
              onPressed: () {
                _ctrl.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
      body: _query.trim().isEmpty
          ? Center(
              child: Text(
                '输入名号关键字开始搜索',
                style: TextStyle(fontSize: 13, color: p.textHint),
              ),
            )
          : hits.isEmpty
              ? Center(
                  child: Text('没有找到「$_query」',
                      style: TextStyle(fontSize: 14, color: p.textSec)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 32),
                  itemCount: hits.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: p.divider),
                  itemBuilder: (ctx, i) {
                    final idx = hits[i];
                    final e = widget.entries[idx];
                    return InkWell(
                      onTap: () => Navigator.pop(context, idx),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.name,
                                style: TextStyle(
                                  fontSize: 15.5,
                                  color: p.text,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                            Text(
                              e.sutras.isEmpty
                                  ? ''
                                  : '${e.sutras.length} 部经文',
                              style:
                                  TextStyle(fontSize: 11.5, color: p.textHint),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
