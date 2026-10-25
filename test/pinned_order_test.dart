import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/pinned_order.dart';

class _Item {
  final String id;
  final int time;
  const _Item(this.id, this.time);
}

void main() {
  test('置顶项排最前，其余保持原有相对顺序（稳定排序）', () {
    final items = <_Item>[
      _Item('a', 30),
      _Item('b', 20),
      _Item('c', 10),
      _Item('d', 25),
    ];

    sortPinnedFirst<_Item>(
      items,
      isPinned: (i) => i.id == 'c',
    );

    expect(items.map((e) => e.id).toList(), ['c', 'a', 'b', 'd']);
  });

  test('无置顶时完全保持原顺序（不会因不稳定排序乱跳）', () {
    final items = <_Item>[
      for (var i = 0; i < 64; i++) _Item('n$i', i),
    ];
    final before = items.map((e) => e.id).toList();

    sortPinnedFirst<_Item>(items, isPinned: (_) => false);

    expect(items.map((e) => e.id).toList(), before);
  });

  test('compareRest 只作用于非置顶内容的排序', () {
    final items = <_Item>[
      _Item('a', 30),
      _Item('pinned', 1),
      _Item('b', 20),
      _Item('c', 40),
    ];

    sortPinnedFirst<_Item>(
      items,
      isPinned: (i) => i.id == 'pinned',
      compareRest: (x, y) => y.time.compareTo(x.time),
    );

    expect(items.map((e) => e.id).toList(), ['pinned', 'c', 'a', 'b']);
  });

  test('空列表与单元素列表安全', () {
    final empty = <_Item>[];
    sortPinnedFirst<_Item>(empty, isPinned: (_) => true);
    expect(empty, isEmpty);

    final one = <_Item>[_Item('only', 1)];
    sortPinnedFirst<_Item>(one, isPinned: (_) => true);
    expect(one.single.id, 'only');
  });
}
