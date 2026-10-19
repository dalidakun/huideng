import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/note_sutra_links.dart';

/// GitHub 排版版可读文件名规则：`<经名（含卷数）><CBETA 编号>.txt`。
/// 与仓库 assets/sutras_edited/ 下的副本文件、云函数 sutraEditSave 写入的名字一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await NoteSutraCatalog.load();
  });

  group('NoteSutraCatalog.cachedDisplayTitleById', () {
    test('多卷经书带卷数，单卷经书不带卷标', () {
      expect(NoteSutraCatalog.cachedDisplayTitleById('T08n0251_001'),
          '般若波罗蜜多心经');
      expect(NoteSutraCatalog.cachedDisplayTitleById('T13n0412_001'),
          '地藏菩萨本愿经卷一');
      expect(NoteSutraCatalog.cachedDisplayTitleById('T13n0412_002'),
          '地藏菩萨本愿经卷二');
      expect(NoteSutraCatalog.cachedDisplayTitleById('T85n2850_001'),
          '地藏菩萨十斋日');
      expect(NoteSutraCatalog.cachedDisplayTitleById('T99n9999_999'), isNull);
      expect(NoteSutraCatalog.cachedDisplayTitleById(''), isNull);
    });
  });

  group('assets/sutras_edited 仓库文件', () {
    test('每部 <ID>.txt 都有「经名（含卷数）+编号」可读副本', () {
      final dir = Directory('assets/sutras_edited');
      if (!dir.existsSync()) return;
      final idRe = RegExp(r'T\d{2}n\d{4}[A-Za-z]?_\d{3}');
      var legacy = 0;
      for (final e in dir.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.txt')) continue;
        final name = e.uri.pathSegments.last;
        final id = idRe.firstMatch(name)?.group(0);
        if (id == null || name != '$id.txt') continue; // 只以主文件为基准
        legacy++;
        final display = NoteSutraCatalog.cachedDisplayTitleById(id);
        expect(display, isNotNull, reason: '编号不在经书目录里：$id');
        final readable =
            File('${dir.path}${Platform.pathSeparator}${id.substring(0, 3)}'
                '${Platform.pathSeparator}$display$id.txt');
        expect(readable.existsSync(), isTrue, reason: '缺少可读副本：$display$id.txt');
      }
      expect(legacy, greaterThan(0), reason: '未找到任何排版经文主文件');
    });
  });
}
