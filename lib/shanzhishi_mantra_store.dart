import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置密咒名单（展示用起步名单；用户在「添加」里录的另存）。
const List<String> kBuiltInMantras = [
  '六字大明咒',
  '准提神咒',
  '大悲咒',
  '往生咒',
  '药师心咒',
  '文殊心咒',
  '金刚萨埵百字明咒',
  '绿度母心咒',
  '尊胜佛母心咒',
  '楞严咒',
  '黄财神心咒',
  '莲花生大士心咒',
  '白度母心咒',
  '不空绢索毗卢遮那佛大灌顶光真言',
  '金刚手菩萨心咒',
  '虚空藏菩萨真言',
  '地藏菩萨灭定业真言',
  '大白伞盖佛母心咒',
  '作明佛母心咒（咕噜咕列佛母心咒）',
  '秽迹金刚咒',
];

/// 密咒名号数据：内置名单 + 用户自建（本地持久化），与佛号名号同模式。
class ShanZhiShiMantraStore extends ChangeNotifier {
  ShanZhiShiMantraStore._();

  static final ShanZhiShiMantraStore instance = ShanZhiShiMantraStore._();

  static const _prefKey = 'shanzhishi_mantra_added';

  /// 用户自建的密咒（新添加的排最前，像佛号页那样新的先看到）。
  List<String> _added = [];

  bool loaded = false;

  /// 当前完整名单：用户自建在前、内置名单在后；重复名只保留一处。
  List<String> get mantras {
    final out = <String>[];
    final seen = <String>{};
    for (final m in [..._added, ...kBuiltInMantras]) {
      final key = m.trim();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      out.add(m);
    }
    return out;
  }

  /// 从本地恢复用户自建的密咒。
  Future<void> load() async {
    if (loaded) return;
    loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _added = prefs.getStringList(_prefKey) ?? const <String>[];
    } catch (_) {
      _added = const <String>[];
    }
    notifyListeners();
  }

  /// 新增一条用户密咒；重名返回 false，成功持久化后通知刷新。
  Future<bool> add(String name) async {
    final key = name.trim();
    if (key.isEmpty || kBuiltInMantras.contains(key) || _added.contains(key)) {
      return false;
    }
    _added = [key, ..._added];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKey, _added);
    } catch (_) {}
    notifyListeners();
    return true;
  }

  /// 测试用：清空用户自建记录（只动内存，供单测隔离）。
  void resetForTest() {
    _added = const <String>[];
    loaded = false;
    notifyListeners();
  }
}
