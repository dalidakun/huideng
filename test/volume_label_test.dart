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

  group('中文卷标解析', () {
    test('parseChineseVolumeNumber 各种卷数', () {
      expect(parseChineseVolumeNumber('卷一'), 1);
      expect(parseChineseVolumeNumber('卷十'), 10);
      expect(parseChineseVolumeNumber('卷十一'), 11);
      expect(parseChineseVolumeNumber('卷二十一'), 21);
      expect(parseChineseVolumeNumber('卷一百'), 100);
      expect(parseChineseVolumeNumber('卷一百零五'), 105);
      expect(parseChineseVolumeNumber('卷一百一十'), 110);
      expect(parseChineseVolumeNumber('卷四百零三'), 403);
      expect(parseChineseVolumeNumber('卷六百'), 600);
      expect(parseChineseVolumeNumber('11'), 11);
      expect(parseChineseVolumeNumber(''), 0);
      expect(parseChineseVolumeNumber('卷'), 0);
    });

    test('讨论页展示名：filePath 能定位具体卷时优先显示具体卷标', () {
      final bases = {'高僧传'};
      expect(
        sutraDiscussionDisplayName('高僧传',
            filePath: 'assets/sutras_ascii/T50/T50n2059_011.txt',
            multiVolumeBases: bases),
        '高僧传卷十一',
      );
      expect(
        sutraDiscussionDisplayName('高僧传', filePath: '', multiVolumeBases: bases),
        '高僧传卷一',
      );
      expect(
        sutraDiscussionDisplayName('高僧传T50n2059_005',
            filePath: '', multiVolumeBases: bases),
        '高僧传卷五',
      );
      expect(
        sutraDiscussionDisplayName('金刚般若波罗蜜经',
            filePath: 'assets/sutras_ascii/T08/T08n0236_001.txt',
            multiVolumeBases: bases),
        '金刚般若波罗蜜经',
      );
    });
  });

  group('讨论页按卷拆分：相关帖子筛选', () {
    test('带卷标引用只匹配对应卷', () {
      const text = '今天读，\$高僧传卷十一有感';
      expect(referencesSutraVolume(text, '高僧传', 11), true);
      expect(referencesSutraVolume(text, '高僧传', 1), false);
      expect(referencesSutraVolume(text, '高僧传', 5), false);
    });

    test('只写基础经名的引用视为卷一', () {
      const text = '\$高僧传，今天读了一点';
      expect(referencesSutraVolume(text, '高僧传', 1), true);
      expect(referencesSutraVolume(text, '高僧传', 11), false);
    });

    test('百位卷标解析', () {
      const text = '\$大般若波罗蜜多经卷四百零三';
      expect(referencesSutraVolume(text, '大般若波罗蜜多经', 403), true);
      expect(referencesSutraVolume(text, '大般若波罗蜜多经', 43), false);
    });

    test('旧式 [@经名](路径) 视为卷一引用', () {
      const text = '[@高僧传](assets/sutras_ascii/T50/T50n2059_001.txt)';
      expect(referencesSutraVolume(text, '高僧传', 1), true);
      expect(referencesSutraVolume(text, '高僧传', 2), false);
    });

    test('长经名前缀不误匹配', () {
      const text = '\$续高僧传卷一';
      expect(referencesSutraVolume(text, '高僧传', 1), false);
    });
  });

  group('热门经文目录归一（榜单计数与讨论页口径一致）', () {
    const catalog = {'金刚经', '心经', '大般若波罗蜜多经', '高僧传'};

    test('直接命中目录原样返回（含卷标/编号归一）', () {
      expect(resolveHotSutraName('金刚经', catalog), '金刚经');
      expect(resolveHotSutraName('金刚经卷一', catalog), '金刚经');
      expect(resolveHotSutraName('金刚经T08n0236_001', catalog), '金刚经');
    });

    test('尾部粘连文字按最长前缀归一到真实经名', () {
      expect(resolveHotSutraName('金刚经真好', catalog), '金刚经');
      expect(resolveHotSutraName('金刚经》很好', catalog), '金刚经');
      expect(resolveHotSutraName('大般若波罗蜜多经真言', catalog), '大般若波罗蜜多经');
    });

    test('最长前缀优先更长的经名', () {
      const c2 = {'金刚经', '金刚般若波罗蜜经'};
      expect(resolveHotSutraName('金刚般若波罗蜜经注', c2), '金刚般若波罗蜜经');
      expect(resolveHotSutraName('金刚经注疏', c2), '金刚经');
    });

    test('无法归一返回 null（丢弃）', () {
      expect(resolveHotSutraName('随便聊聊', catalog), isNull);
      expect(resolveHotSutraName('某经真好', catalog), isNull);
    });

    test('mergeHotSutraItems 传目录：粘连名并入真实经名、无效名丢弃', () {
      final merged = mergeHotSutraItems(const [
        HotDiscussionItem(name: '金刚经', posts: 2, score: 4),
        HotDiscussionItem(name: '金刚经真好', posts: 1, score: 2),
        HotDiscussionItem(name: '心经卷一', posts: 3, score: 6),
        HotDiscussionItem(name: '随便聊聊', posts: 9, score: 99),
      ], catalogNames: catalog);
      final byName = {for (final e in merged) e.name: e};
      expect(byName.keys, {'金刚经', '心经'});
      expect(byName['金刚经']!.posts, 3);
      expect(byName['金刚经']!.score, 6);
      expect(byName['心经']!.posts, 3);
    });

    test('mergeHotSutraItems 不传目录保持旧行为', () {
      final merged = mergeHotSutraItems(const [
        HotDiscussionItem(name: '金刚经真好', posts: 1, score: 2),
      ]);
      expect(merged.length, 1);
      expect(merged[0].name, '金刚经真好');
    });
  });

  group('热门经文按卷拆分（榜单计数与分卷讨论页一致）', () {
    const catalog = {'地藏菩萨本愿经', '金刚经', '高僧传'};
    const mvBases = {'地藏菩萨本愿经', '高僧传'};

    test('多卷经书按卷分开：基础名/裸引用并入卷一，各卷独立', () {
      final merged = mergeHotSutraItems(const [
        HotDiscussionItem(name: '地藏菩萨本愿经', posts: 2, score: 4),
        HotDiscussionItem(name: '地藏菩萨本愿经卷一', posts: 3, score: 6),
        HotDiscussionItem(name: '地藏菩萨本愿经卷二', posts: 5, score: 10),
      ], catalogNames: catalog, multiVolumeBases: mvBases);
      final byName = {for (final e in merged) e.name: e};
      expect(byName.keys, {'地藏菩萨本愿经卷一', '地藏菩萨本愿经卷二'});
      expect(byName['地藏菩萨本愿经卷一']!.posts, 5);
      expect(byName['地藏菩萨本愿经卷二']!.posts, 5);
    });

    test('单卷经书仍按基础经名归并', () {
      final merged = mergeHotSutraItems(const [
        HotDiscussionItem(name: '金刚经', posts: 2, score: 4),
        HotDiscussionItem(name: '金刚经卷一', posts: 1, score: 2),
      ], catalogNames: catalog, multiVolumeBases: mvBases);
      final byName = {for (final e in merged) e.name: e};
      expect(byName.keys, {'金刚经'});
      expect(byName['金刚经']!.posts, 3);
    });

    test('粘连名按卷归一：卷二粘连文字计入卷二，裸引用计入卷一', () {
      final merged = mergeHotSutraItems(const [
        HotDiscussionItem(name: '高僧传卷二真好', posts: 1, score: 2),
        HotDiscussionItem(name: '高僧传', posts: 2, score: 4),
      ], catalogNames: catalog, multiVolumeBases: mvBases);
      final byName = {for (final e in merged) e.name: e};
      expect(byName.keys, {'高僧传卷一', '高僧传卷二'});
      expect(byName['高僧传卷一']!.posts, 2);
      expect(byName['高僧传卷二']!.posts, 1);
    });

    test('不传 multiVolumeBases 保持整部归并（经文总榜旧行为）', () {
      final merged = mergeHotSutraItems(const [
        HotDiscussionItem(name: '地藏菩萨本愿经', posts: 2, score: 4),
        HotDiscussionItem(name: '地藏菩萨本愿经卷一', posts: 3, score: 6),
        HotDiscussionItem(name: '地藏菩萨本愿经卷二', posts: 5, score: 10),
      ], catalogNames: catalog);
      final byName = {for (final e in merged) e.name: e};
      expect(byName.keys, {'地藏菩萨本愿经'});
      expect(byName['地藏菩萨本愿经']!.posts, 10);
    });

    test('splitHotSutraName 拆分基础名与卷号', () {
      expect(splitHotSutraName('地藏菩萨本愿经卷二'), ('地藏菩萨本愿经', 2));
      expect(splitHotSutraName('地藏菩萨本愿经'), ('地藏菩萨本愿经', 0));
      expect(splitHotSutraName('高僧传卷十一'), ('高僧传', 11));
      expect(splitHotSutraName('金刚经'), ('金刚经', 0));
    });

    test('resolveHotSutraBaseAndVolume 解析经名与卷号', () {
      expect(resolveHotSutraBaseAndVolume('地藏菩萨本愿经卷二', catalog),
          ('地藏菩萨本愿经', 2));
      expect(resolveHotSutraBaseAndVolume('地藏菩萨本愿经', catalog),
          ('地藏菩萨本愿经', 0));
      expect(resolveHotSutraBaseAndVolume('高僧传卷十一真好', catalog),
          ('高僧传', 11));
      expect(resolveHotSutraBaseAndVolume('随便聊聊', catalog), isNull);
    });
  });
}
