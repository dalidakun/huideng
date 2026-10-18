import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/shanzhishi_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShanZhiShiStore.instance.resetForTest();
  });

  group('ShanyishiEntry 序列化', () {
    test('正常数据往返不丢字段', () {
      const e = ShanyishiEntry(
        name: '地藏王菩萨',
        sutras: ['地藏菩萨本愿经'],
        createdAt: 1770000000000,
      );
      final back = ShanyishiEntry.fromJson(e.toJson());
      expect(back, isNotNull);
      expect(back!.name, '地藏王菩萨');
      expect(back.sutras, ['地藏菩萨本愿经']);
      expect(back.createdAt, 1770000000000);
    });

    test('空名号 / 坏数据返回 null 不抛异常', () {
      expect(ShanyishiEntry.fromJson(const {'name': '  ', 'sutras': []}),
          isNull);
      expect(ShanyishiEntry.fromJson(const {}), isNull);
    });

    test('经文去空白去重', () {
      final e = ShanyishiEntry.fromJson(const {
        'name': '阿弥陀佛',
        'sutras': [' 佛说阿弥陀经 ', '', '佛说阿弥陀经', '观无量寿佛经'],
      });
      expect(e!.sutras, ['佛说阿弥陀经', '观无量寿佛经']);
    });
  });

  group('ShanZhiShiStore', () {
    test('首次加载写入预置名号并落盘', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      expect(store.loaded, isTrue);
      expect(store.length, 35);
      expect(store[0]!.name, '地藏菩萨');

      // 重新加载（模拟重启）：仍是预置名单，不重复添加。
      store.resetForTest();
      await store.load();
      expect(store.length, 35);
    });

    test('add 追加并持久化，返回新位次', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final idx = await store.add('大势至菩萨', ['佛说观无量寿佛经']);
      expect(idx, 35);
      expect(store[idx]!.name, '大势至菩萨');

      store.resetForTest();
      await store.load();
      expect(store.length, 36);
      expect(store[35]!.name, '大势至菩萨');
      expect(store[35]!.sutras, ['佛说观无量寿佛经']);
    });

    test('同名重复录入定位到已有位次并合并经文', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final first = await store.add('药王菩萨', []);
      final again = await store.add('药王菩萨', ['妙法莲华经药王菩萨本事品']);
      expect(again, first);
      expect(store.length, 36);
      expect(store[first]!.sutras, ['妙法莲华经药王菩萨本事品']);
    });

    test('update 改名与经文；空名号被拒绝', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      await store.update(0, name: '本师释迦牟尼佛', sutras: ['妙法莲华经']);
      expect(store[0]!.name, '本师释迦牟尼佛');
      expect(store[0]!.sutras, ['妙法莲华经']);

      await store.update(0, name: '   ');
      expect(store[0]!.name, '本师释迦牟尼佛');
    });

    test('removeAt 删除后位次前移并落盘', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final second = store[1]!.name;
      await store.removeAt(0);
      expect(store[0]!.name, second);
      expect(store.length, 34);

      store.resetForTest();
      await store.load();
      expect(store.length, 34);
      expect(store[0]!.name, second);
    });

    test('randomIndex 不重复抽到被排除的位次', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final hit = <int>{};
      for (var i = 0; i < 40; i++) {
        final idx = store.randomIndex(exclude: 0);
        expect(idx, isNot(0));
        expect(idx, inInclusiveRange(0, store.length - 1));
        hit.add(idx);
      }
      expect(hit.length, greaterThan(1));
    });

    test('空名单 randomIndex 返回 -1', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      await store.removeAt(0);
      while (store.length > 0) {
        await store.removeAt(0);
      }
      expect(store.randomIndex(), -1);
    });

    test('旧版预置升级：原样旧预置被替换，用户自建条目保留', () async {
      // 模拟旧版落盘：旧预置 + 一条用户自建。
      SharedPreferences.setMockInitialValues({
        'shanzhishi_names': jsonEncode([
          {'name': '释迦牟尼佛', 'sutras': ['佛说四十二章经'], 'createdAt': 1},
          {'name': '地藏王菩萨', 'sutras': ['地藏菩萨本愿经'], 'createdAt': 2},
          {'name': '我的上师', 'sutras': ['自定义'], 'createdAt': 3},
        ]),
      });
      final store = ShanZhiShiStore.instance;
      await store.load();
      final names = store.entries.map((e) => e.name).toList();
      // 原样旧预置已清掉，新名单补进来。
      expect(names, isNot(contains('地藏王菩萨')));
      expect(names, contains('地藏菩萨'));
      expect(names, contains('无边身如来'));
      // 用户自建的没被动。
      expect(names, contains('我的上师'));
      // 重新加载不再重复添加。
      store.resetForTest();
      await store.load();
      expect(store.entries.map((e) => e.name).toList(), names);
    });
  });

  group('resolveSutra', () {
    test('目录未加载时返回 null 不抛异常', () {
      expect(ShanZhiShiStore.resolveSutra('地藏菩萨本愿经'), isNull);
    });
  });
}
