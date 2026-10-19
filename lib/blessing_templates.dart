/// 祈福共修的预设内容：事由模板、功课方式、默认回向文。
library;

/// 一条祈福事由模板。
class BlessingTemplate {
  final String title;
  final String target;
  final String dedication;

  const BlessingTemplate({
    required this.title,
    required this.target,
    required this.dedication,
  });
}

/// 一组事由模板。
class BlessingTemplateGroup {
  final String name;
  final List<BlessingTemplate> templates;

  const BlessingTemplateGroup(this.name, this.templates);
}

/// 一种功课方式（类别 + 单位 + 默认数量），如 念佛 · 声 · 108。
class BlessingMethodOption {
  final String category;
  final String unit;
  final String defaultCount;

  const BlessingMethodOption(this.category, this.unit, this.defaultCount);
}

/// 可选的祈福州方式，与功课打卡的类别/单位保持一致。
const List<BlessingMethodOption> kBlessingMethodOptions = [
  BlessingMethodOption('诵经', '遍', '1'),
  BlessingMethodOption('念佛', '声', '108'),
  BlessingMethodOption('称名', '声', '1000'),
  BlessingMethodOption('持咒', '遍', '21'),
  BlessingMethodOption('抄经', '篇', '1'),
  BlessingMethodOption('静坐', '分钟', '10'),
];

/// 统一的回向文：把具体对象填进去。
String blessingDedication(String target) {
  final t = target.trim().isEmpty ? '一切众生' : target.trim();
  return '愿以此功课之功德，回向$t：'
      '愿其离诸苦恼，身心安隐，善根增长，福慧具足，早成佛道。';
}

BlessingTemplate _t(String title, String target) =>
    BlessingTemplate(title: title, target: target, dedication: blessingDedication(target));

/// 事由模板分组：社会事件 / 为亲友 / 为己心愿 / 法界众生。
final List<BlessingTemplateGroup> kBlessingGroups = [
  BlessingTemplateGroup('社会事件', [
    _t('为地震灾区众生祈愿', '地震灾区的一切众生'),
    _t('为战乱中的人们祈愿', '战乱中受苦的一切众生'),
    _t('为疫病中的人们祈愿', '受疫病侵扰的一切众生'),
    _t('为意外事故受难者祈愿', '意外事故中的受难众生'),
  ]),
  BlessingTemplateGroup('为亲友', [
    _t('为父母健康长寿祈愿', '我的父母'),
    _t('为师长平安康泰祈愿', '我的师长'),
    _t('为子女顺遂祈愿', '我的子女'),
    _t('为亡者往生净土祈愿', '已故的亲人'),
  ]),
  BlessingTemplateGroup('为己心愿', [
    _t('为自己消业除障祈愿', '我自己'),
    _t('为自己安康顺遂祈愿', '我自己'),
    _t('为学业考试祈愿', '求学中的自己'),
    _t('为事业顺遂祈愿', '我的事业'),
  ]),
  BlessingTemplateGroup('法界众生', [
    _t('为世界和平祈愿', '世界一切众生'),
    _t('为六道众生离苦得乐祈愿', '六道一切众生'),
    _t('为法界众生同生净土祈愿', '法界一切众生'),
  ]),
];
