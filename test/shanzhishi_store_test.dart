import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/note_sutra_links.dart';
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
      expect(store.length, 113);
      expect(store[0]!.name, '地藏菩萨');

      // 重新加载（模拟重启）：仍是预置名单，不重复添加。
      store.resetForTest();
      await store.load();
      expect(store.length, 113);
    });

    test('add 追加并持久化，返回新位次', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final idx = await store.add('大日如来', ['佛说卢遮那成佛经']);
      expect(idx, 113);
      expect(store[idx]!.name, '大日如来');

      store.resetForTest();
      await store.load();
      expect(store.length, 114);
      expect(store[113]!.name, '大日如来');
      expect(store[113]!.sutras, ['佛说卢遮那成佛经']);
    });

    test('同名重复录入定位到已有位次并合并经文', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final first = await store.add('妙吉祥菩萨', []);
      final again = await store.add('妙吉祥菩萨', ['妙法莲华经药王菩萨本事品']);
      expect(again, first);
      expect(store.length, 114);
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
      expect(store.length, 112);

      store.resetForTest();
      await store.load();
      expect(store.length, 112);
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
      // 原样旧预置已清掉：地藏王菩萨经文链接归空，按新种子重补。
      final dzw = store.entries.firstWhere((e) => e.name == '地藏王菩萨');
      expect(dzw.sutras, isEmpty);
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

  group('引用段落', () {
    test('段落随条目序列化往返', () {
      const e = ShanyishiEntry(
        name: '地藏菩萨',
        sutras: ['地藏菩萨本愿经'],
        paragraphs: ['若有善男子善女人闻是菩萨名字', '第二段'],
        createdAt: 1,
      );
      final back = ShanyishiEntry.fromJson(e.toJson());
      expect(back, isNotNull);
      expect(back!.paragraphs, ['若有善男子善女人闻是菩萨名字', '第二段']);
      expect(back.quotes, isEmpty);
    });

    test('旧档里按经书存的段落，读入时拍平进段落池', () {
      final back = ShanyishiEntry.fromJson(const {
        'name': '地藏菩萨',
        'sutras': ['地藏菩萨本愿经', '占察善恶业报经'],
        'quotes': {
          '地藏菩萨本愿经': ['段落A'],
          '占察善恶业报经': ['段落B'],
        },
        'createdAt': 1,
      });
      expect(back!.paragraphs, ['段落A', '段落B']);
      // 迁移后不再按经书存，避免展示时重复。
      expect(back.quotes, isEmpty);
    });

    test('update 保存段落池：去空去重，落盘后可重读', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      await store.update(0, paragraphs: [' 段落一 ', '段落一', '', '段落二']);
      expect(store[0]!.paragraphs, ['段落一', '段落二']);

      store.resetForTest();
      await store.load();
      expect(store[0]!.paragraphs, ['段落一', '段落二']);
    });

    test('add 可带段落池', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final idx = await store.add(
        '测试菩萨',
        ['地藏菩萨本愿经'],
        paragraphs: ['故事段落'],
      );
      expect(idx, greaterThanOrEqualTo(0));
      expect(store[idx]!.paragraphs, ['故事段落']);
    });

    test('mergeInto 合并段落池并去重', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      await store.update(0, paragraphs: ['旧段落']);
      await store.mergeInto(0, paragraphs: ['旧段落', '新段落']);
      expect(store[0]!.paragraphs, ['旧段落', '新段落']);
    });

    test('旧版按经书存的 quotes 仍可写入（兼容旧调用）', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final sutra = store[0]!.sutras.first;
      await store.update(0, quotes: {
        sutra: ['段落一'],
      });
      expect(store[0]!.quotes, {sutra: ['段落一']});
      // 落盘重读时拍平进段落池。
      store.resetForTest();
      await store.load();
      expect(store[0]!.paragraphs, ['段落一']);
      expect(store[0]!.quotes, isEmpty);
    });
  });

  group('相似名号与合并', () {
    test('nameSimilarity 按字符重合比例算', () {
      expect(ShanZhiShiStore.nameSimilarity('地藏菩萨', '地藏菩萨'), 1.0);
      expect(ShanZhiShiStore.nameSimilarity('地藏菩萨', '地藏王菩萨'),
          closeTo(0.8, 1e-9));
      expect(ShanZhiShiStore.nameSimilarity('地藏菩萨', '文殊菩萨'),
          closeTo(0.5, 1e-9));
      expect(ShanZhiShiStore.nameSimilarity('', '地藏菩萨'), 0);
      expect(ShanZhiShiStore.nameSimilarity(' 地藏菩萨 ', '地藏菩萨'), 1.0);
    });

    test('查重摘掉通用尊称：菩萨 / 如来 / 佛 / 咒 不算相同字符', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      expect(ShanZhiShiStore.distinctName('观世音菩萨'), '观世音');
      expect(ShanZhiShiStore.distinctName('宝性如来'), '宝性');
      expect(ShanZhiShiStore.distinctName('药师心咒'), '药师');
      // 「虚空藏菩萨」与既有诸位菩萨只共有通用称「菩萨」，不算重复。
      final hits = [for (final e in store.findSimilarEntries('虚空藏菩萨')) e.$2];
      expect(hits, isNot(contains('观世音菩萨')));
      expect(hits, isNot(contains('地藏菩萨')));
      // 摘掉尊称后仍有 ≥2 个相同字样，仍要提示。
      expect([for (final e in store.findSimilarEntries('文殊菩萨')) e.$2],
          contains('文殊师利菩萨'));
      // 完全同名始终命中，且排在最前。
      expect(store.findSimilarEntries('地藏菩萨').first.$2, '地藏菩萨');
    });

    test('findSimilarIndex 命中同名与 ≥80% 近似的名号', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      expect(store[store.findSimilarIndex('地藏菩萨')]!.name, '地藏菩萨');
      // 4/5 = 80%：算相似。
      expect(store[store.findSimilarIndex('地藏菩萨摩')]!.name, '地藏菩萨');
      // 完全不搭的名字不命中。
      expect(store.findSimilarIndex('绝无此名的菩萨'), -1);
      expect(store.findSimilarIndex('   '), -1);
    });

    test('findSimilarIndex 编辑时可以跳过自己', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      // 第 0 位就是「地藏菩萨」；跳过它以后不会再命中它自己。
      final hit = store.findSimilarIndex('地藏菩萨', skip: 0);
      expect(hit, isNot(0));
    });

    test('mergeAndRemove 并进目标并删掉来源，返回目标新位次', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final target = store.entries.indexWhere((e) => e.name == '地藏王菩萨');
      expect(target, greaterThan(0));
      await store.update(0, paragraphs: ['来自地藏菩萨的段落']);
      final before = store.length;

      final idx = await store.mergeAndRemove(0, target);

      expect(store.length, before - 1);
      expect(idx, target - 1);
      expect(store[idx]!.name, '地藏王菩萨');
      expect(store[idx]!.paragraphs, contains('来自地藏菩萨的段落'));
      // 来源那一位已经没了。
      expect(store.entries.any((e) => e.name == '地藏菩萨'), isFalse);
    });

    test('mergeInto 合并经文与段落，不新增条目、不改名号', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      await store.update(0, sutras: ['地藏菩萨本愿经'], paragraphs: ['旧段落']);
      final before = store.length;

      final idx = await store.mergeInto(
        0,
        sutras: ['占察善恶业报经'],
        paragraphs: ['旧段落', '新段落'],
      );

      expect(idx, 0);
      expect(store.length, before);
      expect(store[0]!.name, '地藏菩萨');
      expect(store[0]!.sutras, ['地藏菩萨本愿经', '占察善恶业报经']);
      expect(store[0]!.paragraphs, ['旧段落', '新段落']);

      // 落盘后重读仍在。
      store.resetForTest();
      await store.load();
      expect(store[0]!.sutras, ['地藏菩萨本愿经', '占察善恶业报经']);
      expect(store[0]!.paragraphs, ['旧段落', '新段落']);
    });

    test('mergeInto 越界位次返回 -1', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      expect(await store.mergeInto(999, sutras: const []), -1);
    });

    test('allowDuplicate 同名也另起一位', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final before = store.length;
      final idx = await store.add('地藏菩萨', ['新经'], allowDuplicate: true);
      expect(idx, before);
      expect(store.length, before + 1);
      expect(store[idx]!.name, '地藏菩萨');
      expect(store[idx]!.sutras, ['新经']);
      // 原有那一位没被并。
      expect(store[0]!.name, '地藏菩萨');
      expect(store[0]!.sutras, ['地藏菩萨本愿经']);
    });
  });

  group('恢复（退回到编辑前）', () {
    test('restoreLast 退回这一位动手之前的版本（连改几次也只退到最早）', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final originalSutras = List<String>.of(store[0]!.sutras);
      final originalParagraphs = List<String>.of(store[0]!.paragraphs);

      await store.update(0, sutras: ['经一'], paragraphs: ['旧段落']);
      // 在同一段后面追加一句（不是新的引用段）。
      await store.update(0, sutras: ['经一'], paragraphs: ['旧段落又加了一句']);
      expect(store.canRestore(store[0]!), isTrue);

      expect(await store.restoreLast(0), isTrue);
      expect(store[0]!.sutras, originalSutras);
      expect(store[0]!.paragraphs, originalParagraphs);
      // 用完即清：再点没有快照。
      expect(store.canRestore(store[0]!), isFalse);
      expect(await store.restoreLast(0), isFalse);
    });

    test('快照跨重启保留', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      final original = List<String>.of(store[0]!.paragraphs);
      await store.update(0, paragraphs: ['旧段落']);
      await store.update(0, paragraphs: ['新段落']);

      store.resetForTest();
      await store.load();
      expect(store[0]!.paragraphs, ['新段落']);
      expect(store.canRestore(store[0]!), isTrue);

      expect(await store.restoreLast(0), isTrue);
      expect(store[0]!.paragraphs, original);
    });

    test('没编辑过时没有快照', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      expect(store.canRestore(store[0]!), isFalse);
      expect(await store.restoreLast(0), isFalse);
    });

    test('删除名号后不会把快照错套到别人身上', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      await store.update(0, paragraphs: ['旧段落']);
      await store.removeAt(0);
      expect(store.canRestore(store[0]!), isFalse);
      expect(await store.restoreLast(0), isFalse);
    });
  });

  group('resolveSutra', () {
    test('目录未加载时返回 null 不抛异常', () {
      expect(ShanZhiShiStore.resolveSutra('地藏菩萨本愿经'), isNull);
    });

    test('目录加载后能解析出正文路径（阅读页不会显示「暂无实际文件」）', () async {
      await NoteSutraCatalog.load();
      final link = ShanZhiShiStore.resolveSutra('地藏菩萨本愿经');
      expect(link, isNotNull);
      expect(link!.filePath, isNotEmpty);
    });

    test('带卷标的经名也能解析（以前精确匹配失败、兜底又会取错译本）', () async {
      await NoteSutraCatalog.load();
      final l1 = ShanZhiShiStore.resolveSutra('地藏菩萨本愿经卷一');
      expect(l1, isNotNull);
      expect(l1!.filePath, contains('T13n0412_001'));
      final l2 = ShanZhiShiStore.resolveSutra('地藏菩萨本愿经卷二');
      expect(l2!.filePath, contains('T13n0412_002'));
    });

    test('同名异本命中多个时返回 null，绝不猜错译本', () async {
      await NoteSutraCatalog.load();
      expect(ShanZhiShiStore.resolveSutra('金刚'), isNull);
    });

    test('完全查不到的经名返回 null', () async {
      await NoteSutraCatalog.load();
      expect(ShanZhiShiStore.resolveSutra('查无此经之名'), isNull);
    });
  });
}
