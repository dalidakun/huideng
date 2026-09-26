import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/record_page.dart';

void main() {
  // 记录里的 sutraKey 有三种来源形态，都必须显示成同一个「经名 + 卷X」。
  const bases = {'地藏菩萨本愿经', '高僧传'};

  group('recordSutraDisplayName', () {
    test('带 CBETA 编号的经名补上卷标，不显示编号', () {
      expect(
        recordSutraDisplayName('地藏菩萨本愿经T13n0412_002',
            multiVolumeBases: bases),
        '地藏菩萨本愿经卷二',
      );
      expect(
        recordSutraDisplayName('高僧传T50n2061_005', multiVolumeBases: bases),
        '高僧传卷五',
      );
    });

    test('单卷经不加卷标', () {
      expect(
        recordSutraDisplayName('金刚般若波罗蜜经T08n0235_001',
            multiVolumeBases: bases),
        '金刚般若波罗蜜经',
      );
    });

    test('已经是「经名 + 中文卷标」的保持原样', () {
      expect(
        recordSutraDisplayName('地藏菩萨本愿经卷二', multiVolumeBases: bases),
        '地藏菩萨本愿经卷二',
      );
    });

    test('只有编号时按目录反查经名', () {
      const rawTitles = [
        '地藏菩萨本愿经T13n0412_001',
        '地藏菩萨本愿经T13n0412_002',
        '金刚般若波罗蜜经T08n0235_001',
      ];
      expect(
        recordSutraDisplayName('T13n0412_002',
            multiVolumeBases: bases, rawTitles: rawTitles),
        '地藏菩萨本愿经卷二',
      );
      // 目录里查不到时原样返回，不吞掉编号。
      expect(
        recordSutraDisplayName('T99n9999_001',
            multiVolumeBases: bases, rawTitles: rawTitles),
        'T99n9999_001',
      );
    });

    test('三种形态归一到同一个显示名', () {
      const rawTitles = ['地藏菩萨本愿经T13n0412_002'];
      final a = recordSutraDisplayName('地藏菩萨本愿经T13n0412_002',
          multiVolumeBases: bases);
      final b = recordSutraDisplayName('地藏菩萨本愿经卷二',
          multiVolumeBases: bases);
      final c = recordSutraDisplayName('T13n0412_002',
          multiVolumeBases: bases, rawTitles: rawTitles);
      expect({a, b, c}, {'地藏菩萨本愿经卷二'});
    });

    test('空 key 返回空串', () {
      expect(recordSutraDisplayName('  ', multiVolumeBases: bases), '');
    });
  });
}
