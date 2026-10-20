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

/// 一种功课方式（类别 + 单位 + 默认数量 + 具体内容），如 诵经 · 遍 · 1 · 金刚经。
class BlessingMethodOption {
  final String category;
  final String unit;
  final String defaultCount;
  final List<String> names;

  const BlessingMethodOption(
    this.category,
    this.unit,
    this.defaultCount, {
    this.names = const [],
  });
}

/// 可选的祈福方式，与功课打卡的类别/单位保持一致。
const List<BlessingMethodOption> kBlessingMethodOptions = [
  BlessingMethodOption('诵经', '遍', '1', names: [
    '金刚经',
    '心经',
    '地藏经',
    '地藏菩萨本愿经',
    '普门品',
    '阿弥陀经',
    '药师经',
    '无量寿经',
    '法华经',
    '华严经',
    '楞严经',
  ]),
  BlessingMethodOption('念佛', '声', '108', names: [
    '阿弥陀佛',
    '观世音菩萨',
    '地藏王菩萨',
    '药师佛',
    '释迦牟尼佛',
    '百佛名',
  ]),
  BlessingMethodOption('称名', '声', '1000', names: [
    '南无阿弥陀佛',
    '南无观世音菩萨',
    '南无地藏菩萨',
    '南无地藏王菩萨',
    '南无药师佛',
  ]),
  BlessingMethodOption('持咒', '遍', '21', names: [
    '大悲咒',
    '楞严咒',
    '往生咒',
    '药师咒',
    '六字大明咒',
    '准提咒',
  ]),
  BlessingMethodOption('抄经', '篇', '1', names: [
    '心经',
    '金刚经',
    '地藏经',
    '普门品',
    '阿弥陀经',
  ]),
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

/// 事由模板分组：为他人祈愿，不含「为己」类模板。
final List<BlessingTemplateGroup> kBlessingGroups = [
  BlessingTemplateGroup('亲友眷属', [
    _t('为父母及家人祈福', '我的父母及家人'),
    _t('为子女祈福', '我的子女'),
    _t('为伴侣祈福', '我的伴侣'),
    _t('为亲友祈福', '我的亲友'),
    _t('为师长祈福', '我的师长'),
  ]),
  BlessingTemplateGroup('特定事件', [
    _t('为地震受灾区祈福', '地震灾区的一切众生'),
    _t('为洪涝及自然灾害受灾区祈福', '遭受自然灾害的一切众生'),
    _t('为火灾事故受难者祈福', '火灾事故中的受难众生'),
    _t('为交通事故受难者祈福', '交通事故中的受难众生'),
    _t('为突发公共事件中的众生祈福', '突发公共事件中受苦的众生'),
  ]),
  BlessingTemplateGroup('病苦众生', [
    _t('为患病者祈福', '一切患病众生'),
    _t('为重症及长期病患者祈福', '重症及长期病患众生'),
    _t('为手术及康复中的患者祈福', '手术及康复中的患者'),
    _t('为临终病苦者祈福', '临终病苦的众生'),
  ]),
  BlessingTemplateGroup('生活困境者', [
    _t('为贫困及失业者祈福', '贫困及失业的众生'),
    _t('为债务困境者祈福', '陷入债务困境的众生'),
    _t('为流离失所者祈福', '流离失所的众生'),
    _t('为孤寡老人祈福', '孤寡老人'),
    _t('为困境中的儿童祈福', '身处困境的儿童'),
    _t('为残障人士祈福', '残障人士'),
    _t('为遭受欺凌及伤害者祈福', '遭受欺凌及伤害的众生'),
  ]),
  BlessingTemplateGroup('社会守护者', [
    _t('为医护人员祈福', '医护人员'),
    _t('为救援人员祈福', '消防、搜救及灾害救援人员'),
    _t('为公共安全一线人员祈福', '公共安全一线人员'),
    _t('为教师及教育工作者祈福', '教师及教育工作者'),
    _t('为公益工作者及志愿者祈福', '公益工作者及志愿者'),
  ]),
  BlessingTemplateGroup('世界与社会', [
    _t('为世界和平祈愿', '世界一切众生'),
    _t('为战乱止息祈愿', '战乱中受苦的一切众生'),
    _t('为社会安宁祈愿', '社会一切众生'),
    _t('为民族和睦祈愿', '各民族众生'),
    _t('为人类与自然和谐共存祈愿', '人类与自然'),
  ]),
  BlessingTemplateGroup('一切众生', [
    _t('为一切众生离苦得乐祈愿', '一切众生'),
    _t('为六道众生祈福回向', '六道一切众生'),
    _t('为受苦受难的众生祈愿', '受苦受难的一切众生'),
    _t('为流浪及受伤动物祈愿', '流浪及受伤的动物'),
  ]),
];
