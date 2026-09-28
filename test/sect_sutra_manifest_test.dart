import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/sect_page.dart';
import 'package:my_flutter_app/sect_sutra_manifest.dart';

SectSutraManifest _parse(String raw) {
  final data = jsonDecode(raw) as Map<String, dynamic>;
  List<SectSutraSect> sectsOf(String? field) =>
      ((data[field] as List<dynamic>?) ?? const [])
          .map((e) => SectSutraSect.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
  return SectSutraManifest(
    sects: sectsOf('sects'),
    gates: sectsOf('gates'),
    totalGroups: (data['totalGroups'] as num?)?.toInt() ?? 0,
    totalEditions: (data['totalEditions'] as num?)?.toInt() ?? 0,
    totalVolumes: (data['totalVolumes'] as num?)?.toInt() ?? 0,
    totalWords: (data['totalWords'] as num?)?.toInt() ?? 0,
  );
}

/// 宗门与法门结构完全相同，多数断言要同时跑两边。
List<SectSutraSect> menus(SectSutraManifest m) => [...m.sects, ...m.gates];

Map<String, dynamic> _volume(Map<String, Object?> fields) =>
    <String, dynamic>{
      'title': '中论卷第一T30n1564_001',
      'id': 'T30n1564_001',
      'assetPath': 'assets/sutras_ascii/T30/T30n1564_001.txt',
      'translator': '龙树造·青目释·姚秦 鸠摩罗什译',
      'base': '中论',
      'partName': '卷第一',
      'vol': 1,
      'words': 100,
      ...fields,
    };

void main() {
  group('SectSutraVolume.displayName', () {
    SectSutraVolume of(String base, String part) => SectSutraVolume.fromJson(
          _volume({'base': base, 'partName': part}),
        );

    test('主干 + 卷次', () {
      expect(of('中论', '卷第一').displayName, '中论卷一');
      expect(of('佛说无量寿经', '卷上').displayName, '佛说无量寿经卷上');
    });

    test('CBETA「卷第N」统一成 App 体例「卷N」', () {
      expect(of('楞伽阿跋多罗宝经', '卷第二').displayName, '楞伽阿跋多罗宝经卷二');
      expect(of('瑜伽师地论', '卷第一百').displayName, '瑜伽师地论卷一百');
      // 带分卷注的只换前半段，注释保留。
      expect(of('四分律', '卷第二十二(二分之一明尼戒法)').displayName,
          '四分律卷二十二(二分之一明尼戒法)');
    });

    test('续卷无卷标时只显示主干', () {
      expect(of('大方广佛华严经', '').displayName, '大方广佛华严经');
    });

    test('序是正文一部分，保留', () {
      expect(of('四分律', '序').displayName, '四分律序');
      expect(of('净土论', '序').displayName, '净土论序');
    });

    test('目录/品目/一卷是 CBETA 排版残留，抑制', () {
      expect(of('六祖大师法宝坛经', '目录').displayName, '六祖大师法宝坛经');
      expect(of('十二门论', '品目').displayName, '十二门论');
      expect(of('广百论本', '一卷').displayName, '广百论本');
    });

    test('主干不带卷标，避免与 partName 重复', () {
      final v = of('百论', '卷下');
      expect(v.displayName, '百论卷下');
      expect(v.displayName, isNot(contains('卷下卷下')));
    });
  });

  group('解析', () {
    test('缺失字段降级为空串 / 0，不抛异常', () {
      final v = SectSutraVolume.fromJson(<String, dynamic>{'id': 'T01n0001_001'});
      expect(v.title, '');
      expect(v.partName, '');
      expect(v.vol, 0);
      expect(v.words, 0);
      expect(v.displayName, '');
    });

    test('按宗名取数，卷数与字数为逐层累加', () {
      final m = _parse(jsonEncode({
        'totalGroups': 1,
        'totalEditions': 2,
        'totalVolumes': 3,
        'totalWords': 300,
        'sects': [
          {
            'key': 'menpai:sanlun',
            'name': '三论宗',
            'desc': '以中观空义为核心',
            'groups': [
              {
                'key': 'menpai:sanlun#中论',
                'name': '中论',
                'note': '',
                'editions': [
                  {
                    'name': '中论·鸠摩罗什译',
                    'label': '鸠摩罗什译',
                    'cbeta': 'T1564',
                    'note': '',
                    'translator': '龙树造·青目释·姚秦 鸠摩罗什译',
                    'volumes': [
                      _volume({}),
                      _volume({
                        'title': '中论卷第二T30n1564_002',
                        'id': 'T30n1564_002',
                        'partName': '卷第二',
                        'vol': 2,
                        'words': 100,
                      }),
                    ],
                  },
                  {
                    'name': '中论·第二译',
                    'label': '第二译',
                    'cbeta': 'T9999',
                    'note': '',
                    'translator': '某 译者',
                    'volumes': [
                      _volume({
                        'title': '中论卷第一T30n9999_001',
                        'id': 'T30n9999_001',
                        'partName': '卷第一',
                        'vol': 1,
                        'words': 100,
                      }),
                    ],
                  },
                ],
              },
            ],
          },
        ],
      }));

      final sect = m.byName('三论宗');
      expect(sect, isNotNull);
      expect(sect!.groups.single.name, '中论');
      expect(sect.groups.single.editions.length, 2);
      expect(sect.groups.single.hasMultipleEditions, isTrue);
      expect(sect.groups.single.totalVolumes, 3);
      expect(sect.totalEditions, 2);
      expect(sect.totalVolumes, 3);
      expect(sect.totalWords, 300);
      expect(m.byName('不存在的宗'), isNull);
    });

    test('byName 同时查宗门与法门', () {
      final m = _parse(jsonEncode({
        'sects': [
          {'key': 'menpai:jingtu', 'name': '净土宗', 'desc': '', 'groups': []},
        ],
        'gates': [
          {'key': 'famen:jingtu', 'name': '净土法门', 'desc': '', 'groups': []},
        ],
      }));
      expect(m.byName('净土宗')!.key, 'menpai:jingtu');
      expect(m.byName('净土法门')!.key, 'famen:jingtu');
      expect(m.byName('禅宗'), isNull);
    });

    test('gates 字段缺失时降级为空，不抛异常', () {
      final m = _parse(jsonEncode({'sects': []}));
      expect(m.sects, isEmpty);
      expect(m.gates, isEmpty);
    });
  });

  group('清单文件（assets/sect_sutras/manifest.json）', () {
    late SectSutraManifest manifest;
    late String raw;

    setUpAll(() {
      raw = File('assets/sect_sutras/manifest.json').readAsStringSync();
      manifest = _parse(raw);
    });

    test('8 宗 + 12 法门，且每栏都能按 SectPage 的名字对上', () {
      expect(manifest.sects.length, 8);
      expect(manifest.gates.length, 12);
      for (final sect in kSectList) {
        expect(manifest.byName(sect.name), isNotNull, reason: '${sect.name} 缺清单');
        expect(sect.kind, SectMenuKind.sect, reason: sect.name);
      }
      for (final gate in kGateList) {
        expect(manifest.byName(gate.name), isNotNull, reason: '${gate.name} 缺清单');
        expect(gate.kind, SectMenuKind.gate, reason: gate.name);
      }
    });

    test('宗门名与法门名不撞车', () {
      final sectNames = kSectList.map((s) => s.name).toSet();
      for (final gate in kGateList) {
        expect(sectNames.contains(gate.name), isFalse, reason: gate.name);
      }
    });

    test('法门图标用 assets/famen/ 拼音切图，宗门仍走 menpai 切图/手绘', () {
      for (final gate in kGateList) {
        final code = gate.icon.gateCode;
        expect(code, isNotEmpty, reason: gate.name);
        expect(gate.icon.isGate, isTrue, reason: gate.name);
        // 素白无后缀、米黄加 2，两张都要在。
        for (final suffix in ['', '2']) {
          final path = 'assets/famen/$code$suffix.png';
          expect(File(path).existsSync(), isTrue, reason: '$gate.name 缺图：$path');
        }
      }
      for (final sect in kSectList) {
        expect(sect.icon.gateCode, isEmpty, reason: sect.name);
      }
    });

    test('汇总数与逐卷累加一致', () {
      expect(manifest.totalGroups, 51);
      expect(manifest.totalEditions, 85);
      expect(manifest.totalVolumes, 1280);
      final all = menus(manifest);
      final volumes = all
          .expand((s) => s.groups)
          .expand((g) => g.editions)
          .fold<int>(0, (sum, e) => sum + e.volumes.length);
      expect(volumes, manifest.totalVolumes);
      final editions = all
          .expand((s) => s.groups)
          .fold<int>(0, (sum, g) => sum + g.editions.length);
      expect(editions, manifest.totalEditions);
      final groups = all.fold<int>(0, (sum, s) => sum + s.groups.length);
      expect(groups, manifest.totalGroups);
    });

    test('多译本归在同一文件夹：文件夹名 = 译本题名的前缀', () {
      for (final sect in menus(manifest)) {
        for (final g in sect.groups) {
          if (!g.hasMultipleEditions) continue;
          for (final e in g.editions) {
            expect(e.name, startsWith('${g.name}·'), reason: e.name);
            expect(e.label, isNotEmpty, reason: e.name);
          }
          // 译本标签互不相同，否则同一文件夹里出现两行一样的名字。
          final labels = g.editions.map((e) => e.label).toList();
          expect(labels.toSet().length, labels.length, reason: '${g.name} 译本重名');
        }
      }
    });

    test('同一层不会出现两行同名', () {
      for (final sect in menus(manifest)) {
        for (final g in sect.groups) {
          // 直挂在文件夹下的行（单卷译本）用译本题名，彼此不能重名。
          final unitTitles = g.editions
              .where((e) => e.isSingleUnit)
              .map((e) => e.rowTitle(e.volumes.single))
              .toList();
          expect(unitTitles.toSet().length, unitTitles.length,
              reason: '${sect.name}/${g.name} 直挂行重名');
          // 译本小标题下的卷行彼此不能重名。
          for (final e in g.editions.where((e) => !e.isSingleUnit)) {
            final volTitles = e.volumes.map(e.rowTitle).toList();
            expect(volTitles.toSet().length, volTitles.length,
                reason: '${sect.name}/${g.name}/${e.name} 卷行重名');
          }
        }
      }
    });

    test('行标题取值正确：单卷译本用「经名·某某译」，多分卷用「经名+卷次」', () {
      final vg = manifest.byName('禅宗')!.groups
          .firstWhere((g) => g.name == '金刚经');
      expect(vg.editions.length, 6);
      for (final e in vg.editions) {
        expect(e.isSingleUnit, isTrue, reason: e.name);
        expect(e.rowTitle(e.volumes.single), e.name, reason: e.name);
        expect(e.rowTitle(e.volumes.single), startsWith('金刚经·'), reason: e.name);
      }
      // 多分卷译本仍用经名 + 卷次。
      final lq = manifest.byName('禅宗')!.groups
          .firstWhere((g) => g.name == '楞伽经');
      final flow = lq.editions.first;
      expect(flow.isSingleUnit, isFalse);
      expect(flow.rowTitle(flow.volumes[1]), '楞伽阿跋多罗宝经卷二');
    });

    test('每卷字段齐全：题名含 CBETA 编号、路径规范、译者优先', () {
      for (final sect in menus(manifest)) {
        for (final g in sect.groups) {
          for (final e in g.editions) {
            expect(e.translator, isNotEmpty, reason: e.name);
            expect(e.volumes, isNotEmpty, reason: e.name);
            for (final v in e.volumes) {
              expect(v.id, matches(RegExp(r'^T\d+n[0-9A-Za-z]+_\d+$')), reason: v.title);
              expect(v.title, contains(v.id), reason: v.title);
              expect(v.assetPath,
                  'assets/sutras_ascii/${v.id.substring(0, 3)}/${v.id}.txt');
              expect(File(v.assetPath).existsSync(), isTrue, reason: v.assetPath);
              expect(v.translator, e.translator, reason: v.id);
              expect(v.words, greaterThan(0), reason: v.id);
              expect(v.base, isNotEmpty, reason: v.id);
            }
          }
        }
      }
    });

    test('同一文件夹内不重复收录同一卷', () {
      for (final sect in menus(manifest)) {
        for (final g in sect.groups) {
          final ids = g.editions
              .expand((e) => e.volumes)
              .map((v) => v.id)
              .toList();
          expect(ids.toSet().length, ids.length,
              reason: '${sect.name}/${g.name} 同一文件夹重复收录');
        }
      }
    });

    test('跨菜单复用同一卷是允许的（仍只指向同一份正文）', () {
      final paths = <String, List<String>>{};
      for (final sect in menus(manifest)) {
        for (final g in sect.groups) {
          for (final e in g.editions) {
            for (final v in e.volumes) {
              paths.putIfAbsent(v.assetPath, () => []).add('${sect.name}/${g.name}');
            }
          }
        }
      }
      // 楞严经 T19n0945_005 同时在净土法门与楞严法门，两处 assetPath 必须一致。
      final shared = 'assets/sutras_ascii/T19/T19n0945_005.txt';
      expect(paths[shared]?.length, greaterThan(1), reason: '楞严经应可从多处进入');
      expect(paths[shared]?.toSet().length, paths[shared]!.length,
          reason: '同一路径不该在同一文件夹里出现两次');
    });

    test('显示名不重复卷标，也不残留 CBETA 标记', () {
      for (final sect in menus(manifest)) {
        for (final g in sect.groups) {
          for (final e in g.editions) {
            for (final v in e.volumes) {
              final name = v.displayName;
              expect(name, isNot(contains('[*')), reason: v.id);
              expect(name, isNot(contains(v.id)),
                  reason: '$name（不该带 CBETA 编号）');
              expect(name, isNot(contains('卷第')),
                  reason: '$name（不该用 CBETA 汉字卷次）');
              expect(name, isNot(contains('卷下卷下')), reason: v.id);
              expect(name, isNot(contains('序序')), reason: v.id);
              // 楞严经卷二的「(一名…)」别名注不是卷次，不该留在行标题里。
              expect(name, isNot(contains('一名')), reason: v.id);
            }
          }
        }
      }
    });

    test('每部经典至少一个译本，且文件夹名不重复', () {
      for (final sect in menus(manifest)) {
        final names = sect.groups.map((g) => g.name).toList();
        expect(names.toSet().length, names.length, reason: '${sect.name} 文件夹重名');
        for (final g in sect.groups) {
          expect(g.name, isNotEmpty, reason: '${sect.name} 有空文件夹名');
          expect(g.editions, isNotEmpty, reason: '${sect.name}/${g.name} 无译本');
          expect(g.key, startsWith('${sect.key}#'),
              reason: '${sect.name}/${g.name} key 不隶属于本栏');
        }
      }
    });

    test('菜单 key 唯一且分栏前缀正确', () {
      final keys = menus(manifest).map((s) => s.key).toList();
      expect(keys.toSet().length, keys.length, reason: '菜单 key 重复');
      for (final s in manifest.sects) {
        expect(s.key, startsWith('menpai:'), reason: s.key);
      }
      for (final s in manifest.gates) {
        expect(s.key, startsWith('famen:'), reason: s.key);
      }
    });

    test('大般若按十六会切分，卷号全局连续 1–600', () {
      final gate = manifest.byName('般若法门')!;
      final group = gate.groups.firstWhere((g) => g.name == '大般若波罗蜜多经');
      expect(group.editions.length, 16, reason: '应为十六会');
      final vols = group.editions.expand((e) => e.volumes).toList();
      expect(vols.length, 600);
      final ords = vols.map((v) => v.vol).toList()..sort();
      expect(ords, List<int>.generate(600, (i) => i + 1));
      // 会序文件题名一律是「序」，卷次必须取自 CBETA 序号才唯一。
      expect(vols.map((v) => v.partName).toSet().length, 600);
      expect(group.editions.first.volumes.length, 400, reason: '初会应为四百卷');
    });

    test('品/章条目钉在所在卷，且注明同卷其他内容', () {
      final pinned = <String, String>{
        '观世音菩萨普门品': 'T09n0262_007',
        '观世音菩萨耳根圆通章': 'T19n0945_006',
        '大势至菩萨念佛圆通章': 'T19n0945_005',
      };
      for (final entry in pinned.entries) {
        SectSutraGroup? found;
        for (final sect in manifest.gates) {
          for (final g in sect.groups) {
            if (g.name == entry.key) found = g;
          }
        }
        expect(found, isNotNull, reason: '${entry.key} 未收录');
        final g = found!;
        expect(g.editions.length, 1);
        expect(g.editions.single.volumes.single.id, entry.value,
            reason: '${entry.key} 应指向所在卷');
        expect(g.note, contains('卷'), reason: '${entry.key} 应注明所在卷');
      }
    });

    test('替代经文都带说明，读者不会误以为是原书', () {
      final substitutes = <String, String>{
        '华严经普贤行愿品': '普贤行愿品',
        '大悲经': '大悲忏',
        '佛说三十五佛名礼忏文': '八十八佛',
        '妙法圣念处经': '大念处经',
        '往生论': '往生论',
      };
      for (final entry in substitutes.entries) {
        SectSutraGroup? found;
        for (final sect in manifest.gates) {
          for (final g in sect.groups) {
            if (g.name == entry.key) found = g;
          }
        }
        expect(found, isNotNull, reason: '${entry.key} 未收录');
        expect(found!.note, contains(entry.value),
            reason: '${entry.key} 的说明里应提到原书 ${entry.value}');
      }
    });
  });
}
