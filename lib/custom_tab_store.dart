import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 菩提空间「自定义栏目」的单个条目：经文（$）、话题（#）或社区（◈）。
/// 社区条目的 [name] 就是社区 key（`{栏目名}社区`）。
class CustomTabItem {
  /// 取值：`sutra` / `topic` / `community`。
  final String type;
  final String name;
  final String path;

  const CustomTabItem({required this.type, required this.name, this.path = ''});

  bool get isSutra => type == 'sutra';
  bool get isTopic => type == 'topic';
  bool get isCommunity => type == 'community';

  /// 面板讨论数的键：经文 `s:`、话题 `t:`、社区 `c:`。
  String get countKey => '${type.isEmpty ? 't' : type[0]}:$name';

  Map<String, dynamic> toJson() => {
        'type': type,
        'name': name,
        'path': path,
      };

  static CustomTabItem? fromJson(Map<String, dynamic> e) {
    final name = (e['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final raw = (e['type'] ?? '').toString();
    // 老配置没有 type 字段时按话题处理，与旧版 `type == 'sutra'` 的判定一致。
    final type = raw == 'sutra' || raw == 'community' ? raw : 'topic';
    return CustomTabItem(
      type: type,
      name: name,
      path: (e['path'] ?? '').toString(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomTabItem &&
      other.type == type &&
      other.name == name &&
      other.path == path;

  @override
  int get hashCode => Object.hash(type, name, path);
}

/// 自定义栏目的持久化。
///
/// 只有一份数据：SharedPreferences 的 [`key`]（`{name, items}`）。
/// 社区页的星标、菩提空间的列表读写的都是它，谁改了另一边都是最新的；
/// 写入会拨动 [revision]，菩提空间挂了监听，切回去立刻是新列表。
class CustomTabStore {
  CustomTabStore._();

  static const String key = 'plaza_custom_tab';
  static const String defaultName = '列表';

  /// 列表有改动时自增，供别的页面监听后重读。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 读整份配置；没存过 / 存坏了一律退回默认骨架，绝不抛。
  static Future<Map<String, dynamic>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return _empty();
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final name = (m['name'] ?? '').toString().trim();
      final items = (m['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      return {
        'name': name.isEmpty ? defaultName : name,
        'items': items,
      };
    } catch (_) {
      return _empty();
    }
  }

  static Map<String, dynamic> _empty() =>
      {'name': defaultName, 'items': const <dynamic>[]};

  /// 解析好的条目列表（经文 / 话题 / 社区混排，顺序即存储顺序）。
  static Future<List<CustomTabItem>> loadItems() async {
    final m = await read();
    return (m['items'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(CustomTabItem.fromJson)
        .whereType<CustomTabItem>()
        .toList(growable: false);
  }

  /// 回写整份配置（条目原样存，name 为空时回落默认栏目名）。
  static Future<void> write(String name, List<CustomTabItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode({
        'name': name.trim().isEmpty ? defaultName : name.trim(),
        'items': items.map((e) => e.toJson()).toList(),
      }),
    );
    revision.value++;
  }

  static bool containsCommunity(List<CustomTabItem> items, String community) =>
      items.any((e) => e.isCommunity && e.name == community);

  /// 当前是否已收藏该社区。
  static Future<bool> isStarred(String community) async =>
      containsCommunity(await loadItems(), community);

  /// 加入/移出列表；返回变更后的真实状态（[star] 恒等于返回值）。
  static Future<bool> setStarred(String community, bool star) async {
    if (community.trim().isEmpty) return false;
    final m = await read();
    final name = (m['name'] ?? '').toString();
    final items = (m['items'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(CustomTabItem.fromJson)
        .whereType<CustomTabItem>()
        .toList(growable: true);
    final on = containsCommunity(items, community);
    if (star == on) return on;
    if (star) {
      items.add(CustomTabItem(type: 'community', name: community));
    } else {
      items.removeWhere((e) => e.isCommunity && e.name == community);
    }
    await write(name, items);
    return star;
  }
}
