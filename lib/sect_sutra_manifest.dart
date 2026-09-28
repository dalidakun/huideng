import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'note_sutra_links.dart' show sutraVolumeLabel;
import 'sutra_list_page.dart' show parseChineseVolumeNumber;

/// 宗门与法门核心经典索引（assets/sect_sutras/manifest.json）。
///
/// 清单只存索引与元数据，正文仍走 [SutraDownloader] 的统一下载目录，
/// 因此宗门/法门入口与经藏页共用同一份本地文件，不会出现副本漂移。
/// 清单由 `tools/build_sect_sutras.py` 生成，请勿手改。
const String kSectSutraManifestAsset = 'assets/sect_sutras/manifest.json';

class SectSutraVolume {
  /// 清单原始题名（含 CBETA 编号），与经藏页保持一致，用于复用其阅读/下载逻辑。
  final String title;

  /// CBETA 编号，如 `T30n1564_001`。
  final String id;

  /// 资源路径，如 `assets/sutras_ascii/T30/T30n1564_001.txt`。
  final String assetPath;

  /// 人工标定的译者/作者（权威值，不从正文抓取）。
  final String translator;

  /// 经名主干，不含卷次，如「中论」。分卷行靠它与 [partName] 拼出显示名。
  final String base;

  /// 文件头抓到的卷次/篇次标记，如「卷第二」「卷上」「序」。
  /// 部分续卷文件无标记，此时为空串。
  final String partName;

  /// CBETA 编号末段（卷序号），用于排序与进度定位。
  final int vol;

  final int words;

  SectSutraVolume({
    required this.title,
    required this.id,
    required this.assetPath,
    required this.translator,
    required this.base,
    required this.partName,
    required this.vol,
    required this.words,
  });

  factory SectSutraVolume.fromJson(Map<String, dynamic> json) {
    return SectSutraVolume(
      title: json['title'] as String? ?? '',
      id: json['id'] as String? ?? '',
      assetPath: json['assetPath'] as String? ?? '',
      translator: json['translator'] as String? ?? '',
      base: json['base'] as String? ?? '',
      partName: json['partName'] as String? ?? '',
      vol: (json['vol'] as num?)?.toInt() ?? 0,
      words: (json['words'] as num?)?.toInt() ?? 0,
    );
  }

  /// CBETA 纯文本卷标只是排版残留，对读者没有意义，展示时去掉。
  static const Set<String> _frontMatterLabels = {'目录', '品目', '一卷'};

  /// CBETA 卷次写法「卷第二」，与 App 其余页面的「卷二」不是同一体例，
  /// 这里统一成后者；「卷第二十二(二分之五)」这类带分卷注的只换前半段。
  static final RegExp _cbetaVolumeRe =
      RegExp(r'^卷第[一二三四五六七八九十百零]+');

  /// 列表行显示名：`经名 + 卷次`。
  String get displayName {
    if (partName.isEmpty || _frontMatterLabels.contains(partName)) return base;
    final m = _cbetaVolumeRe.matchAsPrefix(partName);
    if (m == null) return '$base$partName';
    // parseChineseVolumeNumber 只认「卷十一」，CBETA 的「第」要先去掉。
    final n = parseChineseVolumeNumber(m.group(0)!.replaceAll('第', ''));
    // 解析不出来就保持 CBETA 原样，不硬凑。
    final label = sutraVolumeLabel(n);
    return '$base${label.isEmpty ? m.group(0)! : label}${partName.substring(m.end)}';
  }

  /// 本卷是否有独立卷次标签。整卷即一部经时为 false，
  /// 详情页据此决定行标题是用「经名·某某译」还是「经名 + 卷次」。
  bool get hasVolumeLabel =>
      partName.isNotEmpty && !_frontMatterLabels.contains(partName);
}

/// 译本：同一部经的一个译者/一种卷本，题名为「经名·某某译」。
class SectSutraEdition {
  /// 完整题名，如「金刚经·鸠摩罗什译」。
  final String name;

  /// 译者/撰述简称，如「鸠摩罗什译」。
  final String label;

  /// CBETA 编号，如「T235」。
  final String cbeta;

  /// 收录说明（缺卷、替代文本等），无则为空串。
  final String note;

  /// 译者/造论者全称，权威值。
  final String translator;

  final List<SectSutraVolume> volumes;

  SectSutraEdition({
    required this.name,
    required this.label,
    required this.cbeta,
    required this.note,
    required this.translator,
    required this.volumes,
  });

  factory SectSutraEdition.fromJson(Map<String, dynamic> json) {
    return SectSutraEdition(
      name: json['name'] as String? ?? '',
      label: json['label'] as String? ?? '',
      cbeta: json['cbeta'] as String? ?? '',
      note: json['note'] as String? ?? '',
      translator: json['translator'] as String? ?? '',
      volumes: ((json['volumes'] as List<dynamic>?) ?? const [])
          .map((e) => SectSutraVolume.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  int get totalWords => volumes.fold(0, (sum, v) => sum + v.words);

  /// 整卷就是一部经（无分卷）。此时详情页直接用译本题名作行标题，
  /// 不再套一层译本小标题，否则同一文件夹下会出现多行同名经名。
  bool get isSingleUnit => volumes.length == 1;

  /// 详情页行标题：单卷译本用「经名·某某译」，多分卷译本用「经名 + 卷次」。
  String rowTitle(SectSutraVolume volume) =>
      isSingleUnit ? name : volume.displayName;
}

/// 核心经典：详情页里的一个「文件夹」。同一部经的所有译本归在同一文件夹下。
class SectSutraGroup {
  /// 稳定标识，如 `menpai:zen#金刚经`。详情页用它记录展开状态，
  /// 这样同名文件夹在不同宗门/法门下也不会互相串状态。
  final String key;

  /// 文件夹名，如「金刚经」「华严经」。
  final String name;

  /// 收录说明，无则为空串。
  final String note;

  final List<SectSutraEdition> editions;

  SectSutraGroup({
    required this.key,
    required this.name,
    required this.note,
    required this.editions,
  });

  factory SectSutraGroup.fromJson(Map<String, dynamic> json) {
    return SectSutraGroup(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      note: json['note'] as String? ?? '',
      editions: ((json['editions'] as List<dynamic>?) ?? const [])
          .map((e) => SectSutraEdition.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  bool get hasMultipleEditions => editions.length > 1;

  int get totalVolumes => editions.fold(0, (sum, e) => sum + e.volumes.length);
  int get totalWords => editions.fold(0, (sum, e) => sum + e.totalWords);
}

/// 一个菜单入口的经典清单：八大宗门之一，或十二法门之一。
class SectSutraSect {
  /// 稳定标识，如 `menpai:zen` / `famen:dizang`。
  final String key;

  final String name;
  final String desc;
  final List<SectSutraGroup> groups;

  SectSutraSect({
    required this.key,
    required this.name,
    required this.desc,
    required this.groups,
  });

  factory SectSutraSect.fromJson(Map<String, dynamic> json) {
    return SectSutraSect(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      desc: json['desc'] as String? ?? '',
      groups: ((json['groups'] as List<dynamic>?) ?? const [])
          .map((e) => SectSutraGroup.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  int get totalVolumes => groups.fold(0, (sum, g) => sum + g.totalVolumes);
  int get totalWords => groups.fold(0, (sum, g) => sum + g.totalWords);
  int get totalEditions =>
      groups.fold(0, (sum, g) => sum + g.editions.length);
}

/// 清单解析与缓存。
class SectSutraManifest {
  const SectSutraManifest({
    required this.sects,
    required this.gates,
    required this.totalGroups,
    required this.totalEditions,
    required this.totalVolumes,
    required this.totalWords,
  });

  /// 八大宗门。
  final List<SectSutraSect> sects;

  /// 十二法门。与 [sects] 结构相同，只是入口语义不同。
  final List<SectSutraSect> gates;

  final int totalGroups;
  final int totalEditions;
  final int totalVolumes;
  final int totalWords;

  static const SectSutraManifest empty = SectSutraManifest(
    sects: <SectSutraSect>[],
    gates: <SectSutraSect>[],
    totalGroups: 0,
    totalEditions: 0,
    totalVolumes: 0,
    totalWords: 0,
  );

  static Future<SectSutraManifest> load() async {
    try {
      final raw = await rootBundle.loadString(kSectSutraManifestAsset);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return SectSutraManifest(
        sects: _parseSects(data['sects']),
        gates: _parseSects(data['gates']),
        totalGroups: (data['totalGroups'] as num?)?.toInt() ?? 0,
        totalEditions: (data['totalEditions'] as num?)?.toInt() ?? 0,
        totalVolumes: (data['totalVolumes'] as num?)?.toInt() ?? 0,
        totalWords: (data['totalWords'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // 清单缺失或损坏时降级为空，页面显示提示而不是崩溃。
      return empty;
    }
  }

  static List<SectSutraSect> _parseSects(Object? raw) {
    return ((raw as List<dynamic>?) ?? const [])
        .map((e) => SectSutraSect.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// 按清单里的 [SectInfo.name] 取宗门或法门。
  ///
  /// 两侧名称不会相撞（`净土宗` vs `净土法门`），所以一次查完即可，
  /// 详情页也就能被两种入口共用。
  SectSutraSect? byName(String name) {
    for (final s in [...sects, ...gates]) {
      if (s.name == name) return s;
    }
    return null;
  }
}
