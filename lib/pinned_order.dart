/// 置顶优先的稳定排序。
///
/// Dart 的 `List.sort` 不保证稳定：当比较函数对两两元素返回 0 时（例如
/// 「都不是置顶」或「都在置顶组里」），元素顺序可能被打乱，表现为列表
/// 每次重建顺序乱跳。置顶帖必须固定在最前，其余内容必须保持原有顺序
/// （服务端顺序 / 时间序），所以这里用「原始下标」做最终兜底比较，
/// 保证排序结果稳定且可预期。
///
/// - [isPinned] 判定某元素是否置顶；
/// - [compareRest] 非置顶元素之间的排序规则；不传则完全保持原顺序。
void sortPinnedFirst<T>(
  List<T> items, {
  required bool Function(T item) isPinned,
  int Function(T a, T b)? compareRest,
}) {
  if (items.length < 2) return;
  final indexed = <(int, T)>[
    for (var i = 0; i < items.length; i++) (i, items[i]),
  ];
  indexed.sort((a, b) {
    final ap = isPinned(a.$2);
    final bp = isPinned(b.$2);
    if (ap != bp) return ap ? -1 : 1;
    if (compareRest != null) {
      final c = compareRest(a.$2, b.$2);
      if (c != 0) return c;
    }
    return a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < indexed.length; i++) {
    items[i] = indexed[i].$2;
  }
}
