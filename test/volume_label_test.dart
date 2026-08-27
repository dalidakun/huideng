import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/cloud_notes_service.dart';
import 'package:my_flutter_app/sutra_list_page.dart';

void main() {
  group('卷标显示', () {
    String disp(String t) => sutraDisplayNameWithVolume(t);

    test('地藏菩萨本愿经 卷一/卷二', () {
      expect(disp('地藏菩萨本愿经T13n0412_001'), '地藏菩萨本愿经卷一');
      expect(disp('地藏菩萨本愿经T13n0412_002'), '地藏菩萨本愿经卷二');
    });

    test('基本卷数转换', () {
      expect(disp('中阿含经T01n0026_001'), '中阿含经卷一');
      expect(disp('中阿含经T01n0026_010'), '中阿含经卷十');
      expect(disp('中阿含经T01n0026_011'), '中阿含经卷十一');
      expect(disp('中阿含经T01n0026_020'), '中阿含经卷二十');
      expect(disp('中阿含经T01n0026_021'), '中阿含经卷二十一');
      expect(disp('高僧传T50n2059_005'), '高僧传卷五');
    });

    test('百位卷数转换（大般若经 600 卷、大毗婆沙论 200 卷、大宝积经 120 卷）', () {
      expect(disp('大般若波罗蜜多经T05n0220_100'), '大般若波罗蜜多经卷一百');
      expect(disp('大般若波罗蜜多经T05n0220_101'), '大般若波罗蜜多经卷一百零一');
      expect(disp('大般若波罗蜜多经T05n0220_105'), '大般若波罗蜜多经卷一百零五');
      expect(disp('大般若波罗蜜多经T05n0220_110'), '大般若波罗蜜多经卷一百一十');
      expect(disp('大般若波罗蜜多经T05n0220_115'), '大般若波罗蜜多经卷一百一十五');
      expect(disp('大般若波罗蜜多经T05n0220_120'), '大般若波罗蜜多经卷一百二十');
      expect(disp('大般若波罗蜜多经T05n0220_205'), '大般若波罗蜜多经卷二百零五');
      expect(disp('大般若波罗蜜多经T05n0220_210'), '大般若波罗蜜多经卷二百一十');
      expect(disp('大般若波罗蜜多经T05n0220_600'), '大般若波罗蜜多经卷六百');
      expect(disp('阿毘达磨大毘婆沙论T27n1545_105'), '阿毘达磨大毘婆沙论卷一百零五');
      expect(disp('大宝积经T11n0310_105'), '大宝积经卷一百零五');
    });

    test('多卷判定：单卷经书不加卷标', () {
      final bases = collectMultiVolumeBases([
        Sutra('金刚般若波罗蜜经T08n0236_001', '1k'),
        Sutra('高僧传T50n2059_001', '1k'),
        Sutra('高僧传T50n2059_002', '1k'),
      ]);
      expect(bases, {'高僧传'});
      expect(
        sutraDisplayTitle('金刚般若波罗蜜经T08n0236_001', multiVolumeBases: bases),
        '金刚般若波罗蜜经',
      );
      expect(
        sutraDisplayTitle('高僧传T50n2059_002', multiVolumeBases: bases),
        '高僧传卷二',
      );
    });

    test('标题无卷号时从路径补齐卷号', () {
      final bases = {'地藏菩萨本愿经'};
      expect(
        sutraDisplayTitleWithPath('地藏菩萨本愿经',
            filePath: 'assets/sutras_ascii/T13/T13n0412_002.txt',
            multiVolumeBases: bases),
        '地藏菩萨本愿经卷二',
      );
      expect(
        sutraDisplayTitleWithPath('地藏菩萨本愿经T13n0412_001',
            multiVolumeBases: bases),
        '地藏菩萨本愿经卷一',
      );
    });

    test('聚合场景展示名：基础经名补卷一、带卷号显示具体卷', () {
      final bases = {'高僧传'};
      expect(
        sutraAggregatedDisplayName('高僧传', multiVolumeBases: bases),
        '高僧传卷一',
      );
      expect(
        sutraAggregatedDisplayName('高僧传T50n2059_005', multiVolumeBases: bases),
        '高僧传卷五',
      );
      expect(
        sutraAggregatedDisplayName('金刚般若波罗蜜经', multiVolumeBases: bases),
        '金刚般若波罗蜜经',
      );
    });
  });

  group('热门经文归一化', () {
    test('中文卷标与 CBETA 编号归一到基础经名', () {
      expect(normalizeHotSutraName('地藏菩萨本愿经卷一'), '地藏菩萨本愿经');
      expect(normalizeHotSutraName('地藏菩萨本愿经'), '地藏菩萨本愿经');
      expect(
        normalizeHotSutraName('地藏菩萨本愿经T13n0412_001'),
        '地藏菩萨本愿经',
      );
      expect(normalizeHotSutraName('大般若波罗蜜多经卷一百零五'), '大般若波罗蜜多经');
    });

    test('同名条目合并：posts/score 累加', () {
      final merged = mergeHotSutraItems(const [
        HotDiscussionItem(name: '高僧传', posts: 3, score: 10),
        HotDiscussionItem(name: '高僧传卷一', posts: 2, score: 5),
        HotDiscussionItem(name: '金刚经', posts: 1, score: 2),
      ]);
      final byName = {for (final e in merged) e.name: e};
      expect(byName.keys, {'高僧传', '金刚经'});
      expect(byName['高僧传']!.posts, 5);
      expect(byName['高僧传']!.score, 15);
      expect(byName['金刚经']!.posts, 1);
    });
  });

  group('历史脏标题修复（「第卷」占位）', () {
    String disp(String t) => sutraDisplayNameWithVolume(t);

    test('repairLegacySutraTitle 移除「第卷」占位', () {
      expect(
        repairLegacySutraTitle('大般若波罗蜜多经第卷第卷T05n0220_001'),
        '大般若波罗蜜多经T05n0220_001',
      );
      expect(
        repairLegacySutraTitle('大乘中观释论第卷第卷T30n1567_001'),
        '大乘中观释论T30n1567_001',
      );
      expect(
        repairLegacySutraTitle('地藏菩萨本愿经T13n0412_001'),
        '地藏菩萨本愿经T13n0412_001',
      );
    });

    test('repairLegacySutraList 修复后与干净条目合并状态、保持顺序', () {
      final list = repairLegacySutraList([
        Sutra('大般若波罗蜜多经第卷第卷T05n0220_001', '10k', isRead: true),
        Sutra('大般若波罗蜜多经T05n0220_001', '10k', isFavorite: true),
        Sutra('金刚般若波罗蜜经T08n0236_001', '5k'),
      ]);
      expect(list.length, 2);
      expect(list[0].title, '大般若波罗蜜多经T05n0220_001');
      expect(list[0].isRead, true);
      expect(list[0].isFavorite, true);
      expect(list[1].title, '金刚般若波罗蜜经T08n0236_001');
    });

    test('无脏数据时原样返回', () {
      final src = [Sutra('金刚般若波罗蜜经T08n0236_001', '5k')];
      expect(identical(repairLegacySutraList(src), src), true);
    });

    test('大般若经 T05/T06/T07 后缀即全局卷号（第201卷～第600卷）', () {
      expect(disp('大般若波罗蜜多经T05n0220_001'), '大般若波罗蜜多经卷一');
      expect(disp('大般若波罗蜜多经T06n0220_201'), '大般若波罗蜜多经卷二百零一');
      expect(disp('大般若波罗蜜多经T07n0220_403'), '大般若波罗蜜多经卷四百零三');
      expect(disp('大般若波罗蜜多经T07n0220_600'), '大般若波罗蜜多经卷六百');
    });

    test('修复后的脏标题可正常显示卷标', () {
      final fixed =
          repairLegacySutraTitle('大般若波罗蜜多经第卷第卷T07n0220_403');
      expect(disp(fixed), '大般若波罗蜜多经卷四百零三');
    });
  });
}
