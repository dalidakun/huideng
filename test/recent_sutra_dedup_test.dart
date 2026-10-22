import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/note_sutra_links.dart';
import 'package:my_flutter_app/recent_sutra_store.dart';
import 'package:my_flutter_app/sutra_list_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _path = 'assets/sutras_ascii/T13/T13n0412_001.txt';
const String _path2 = 'assets/sutras_ascii/T13/T13n0412_002.txt';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await NoteSutraCatalog.load();
  });

  group('recentSutraIdentityKey', () {
    test('同一部经的不同经名写法归一到同一个键', () {
      // 目录原名、基础经名、\$引用面板的展示名都指向同一部经。
      final a = recentSutraIdentityKey('地藏菩萨本愿经T13n0412_001',
          filePath: _path);
      final b = recentSutraIdentityKey('地藏菩萨本愿经卷一', filePath: _path);
      final c = recentSutraIdentityKey('地藏菩萨本愿经', filePath: _path);
      expect(a, b);
      expect(b, c);
    });

    test('资产路径与本机绝对路径是同一个键', () {
      final a = recentSutraIdentityKey('地藏菩萨本愿经T13n0412_001',
          filePath: _path);
      final b = recentSutraIdentityKey('地藏菩萨本愿经卷一',
          filePath: '/data/user/0/app/sutras/T13/T13n0412_001.txt');
      expect(a, b);
    });

    test('不同卷、不同译本是不同的键', () {
      final a = recentSutraIdentityKey('地藏菩萨本愿经T13n0412_001',
          filePath: _path);
      final b = recentSutraIdentityKey('地藏菩萨本愿经T13n0412_002',
          filePath: _path2);
      expect(a, isNot(b));
    });
  });

  group('dedupeRecentSutraEntries', () {
    test('同一部经只保留最新的一条（新读在前）', () {
      final raw = [
        '地藏菩萨本愿经卷一|||$_path',
        '地藏菩萨本愿经T13n0412_001|||$_path',
        '般若波罗蜜多心经|||assets/sutras_ascii/T08/T08n0251_001.txt',
      ];
      final out = dedupeRecentSutraEntries(raw);
      expect(out.length, 2);
      expect(out[0], '地藏菩萨本愿经卷一|||$_path');
      expect(out[1].startsWith('般若波罗蜜多心经'), isTrue);
    });

    test('格式非法的条目原样保留', () {
      final raw = ['坏数据', '地藏菩萨本愿经T13n0412_001|||$_path'];
      final out = dedupeRecentSutraEntries(raw);
      expect(out.length, 2);
      expect(out.first, '坏数据');
    });
  });

  group('recordRecentSutra', () {
    test('再次打开同一部经（经名写法不同）不产生重复条目', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      // 几天前从目录打开。
      await recordRecentSutra(prefs, '地藏菩萨本愿经T13n0412_001', _path);
      // 今天从 \$引用面板打开（经名写法不同，同一部经）。
      await recordRecentSutra(prefs, '地藏菩萨本愿经卷一', _path);

      final list = prefs.getStringList('recent_sutras')!;
      expect(list.length, 1);
      expect(list.first, '地藏菩萨本愿经卷一|||$_path');
    });

    test('不同经分别记录，按新读在前排列', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await recordRecentSutra(prefs, '地藏菩萨本愿经T13n0412_001', _path);
      await recordRecentSutra(prefs, '般若波罗蜜多心经T08n0251_001',
          'assets/sutras_ascii/T08/T08n0251_001.txt');

      final list = prefs.getStringList('recent_sutras')!;
      expect(list.length, 2);
      expect(list.first.startsWith('般若波罗蜜多心经'), isTrue);
    });
  });

  group('reconcileAllSutraRecords（启动自愈顺带去重）', () {
    test('同一部经的重复条目只留最新的一条', () async {
      SharedPreferences.setMockInitialValues({
        'recent_sutras': [
          '地藏菩萨本愿经卷一|||$_path',
          '地藏菩萨本愿经T13n0412_001|||$_path',
          '地藏菩萨本愿经卷二|||$_path2',
        ],
      });
      final prefs = await SharedPreferences.getInstance();
      await reconcileAllSutraRecords(prefs);

      final list = prefs.getStringList('recent_sutras')!;
      expect(list.length, 2);
      expect(list[0], '地藏菩萨本愿经卷一|||$_path');
      expect(list[1], '地藏菩萨本愿经卷二|||$_path2');
    });
  });
}
