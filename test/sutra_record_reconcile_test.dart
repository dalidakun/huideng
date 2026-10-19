import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/note_sutra_links.dart';
import 'package:my_flutter_app/sutra_downloader.dart';
import 'package:my_flutter_app/sutra_list_page.dart';

String idOf(String? path) =>
    SutraDownloader.extractId(null, path ?? '') ?? '';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await NoteSutraCatalog.load();
  });

  group('reconcileSutraTitleAndPath', () {
    test('经名带编号、路径指向另一部经：按经名重算路径（显示A点开B的根治）', () {
      final r = reconcileSutraTitleAndPath(
          '地藏菩萨本愿经T13n0412_001', 'assets/sutras_ascii/T08/T08n0251_001.txt');
      expect(r.title, '地藏菩萨本愿经T13n0412_001');
      expect(idOf(r.filePath), 'T13n0412_001');
    });

    test('经名只有基础经名、路径指向另一部经：换成该经正文路径', () {
      final r = reconcileSutraTitleAndPath(
          '地藏菩萨本愿经', 'assets/sutras_ascii/T08/T08n0251_001.txt');
      expect(r.title, '地藏菩萨本愿经');
      expect(idOf(r.filePath).startsWith('T13n0412_'), isTrue);
    });

    test('经名带中文卷标、路径错配：按卷标定位到具体卷', () {
      final r = reconcileSutraTitleAndPath(
          '地藏菩萨本愿经卷二', 'assets/sutras_ascii/T08/T08n0251_001.txt');
      expect(r.title, '地藏菩萨本愿经卷二');
      expect(idOf(r.filePath), 'T13n0412_002');
    });

    test('基础经名 + 同名不同卷的路径：路径更具体，保持原路径不误伤', () {
      const path = 'assets/sutras_ascii/T13/T13n0412_002.txt';
      final r = reconcileSutraTitleAndPath('地藏菩萨本愿经', path);
      expect(r.title, '地藏菩萨本愿经');
      expect(r.filePath, path);
    });

    test('路径为空：补上经名对应的正文路径', () {
      final r = reconcileSutraTitleAndPath('地藏菩萨本愿经T13n0412_001', null);
      expect(idOf(r.filePath), 'T13n0412_001');
      final r2 = reconcileSutraTitleAndPath('地藏菩萨本愿经卷二', '');
      expect(idOf(r2.filePath), 'T13n0412_002');
    });

    test('两侧指向同一部经：原样返回', () {
      const path = 'assets/sutras_ascii/T13/T13n0412_001.txt';
      final r = reconcileSutraTitleAndPath('地藏菩萨本愿经T13n0412_001', path);
      expect(r.title, '地藏菩萨本愿经T13n0412_001');
      expect(r.filePath, path);
      // 同一编号的本机绝对路径也保持原样。
      const local = '/data/user/0/app/sutras/T13/T13n0412_001.txt';
      final r2 = reconcileSutraTitleAndPath('地藏菩萨本愿经T13n0412_001', local);
      expect(r2.filePath, local);
    });

    test('自选本地文件（路径无编号）：不被覆盖', () {
      const local = '/storage/emulated/0/my sutra.txt';
      final r = reconcileSutraTitleAndPath('地藏菩萨本愿经T13n0412_001', local);
      expect(r.filePath, local);
    });

    test('经名不在目录里、路径带编号：按路径订正经名', () {
      final r = reconcileSutraTitleAndPath(
          '某某无从校验的经名', 'assets/sutras_ascii/T08/T08n0251_001.txt');
      expect(r.title, contains('般若波罗蜜多心经'));
      expect(r.filePath, 'assets/sutras_ascii/T08/T08n0251_001.txt');
    });
  });
}
