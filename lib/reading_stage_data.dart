/// 「百册经论指南」各阶段的经典编排。
///
/// 这里只放**编排元数据**：阶段信息、每部经的文件夹名与介绍、以及该经收录的
/// 译本（CBETA 编号 + 译者）。卷数、卷标题、字数均由经藏页已加载的目录
/// （[Sutra] 列表）在运行时按 CBETA 编号解析，做到「以 App 实际数据为准」。
///
/// 译者署名取自各卷正文首部的真实题署（如《贤愚经》「元魏凉州沙门慧觉等在高昌郡译」），
/// 不采用外部资料。
library;

/// 一个译本的编排信息。
class ReadingStageEdition {
  /// 译者简称，用于拼出译本题名：「经名·译者简称」，如「阿弥陀经·鸠摩罗什译」。
  final String label;

  /// 译者/作者完整署名，如「姚秦 鸠摩罗什」。
  final String translator;

  /// CBETA 编号主干，如「T12n0366」。
  final String cbeta;

  /// 该译本对应的 CBETA 编号（不含卷序号），如 `['T14n0454']`。
  final List<String> ids;

  /// 只收录该经的指定卷范围（含端点，按卷序号）。用于某部大经中的「分」，
  /// 如《大集经·月藏分》只取 T13n0397 第 46~56 卷、《普贤行愿品》只取
  /// T10n0293 第 40 卷。为空表示收录全部卷。
  final int? volFrom;
  final int? volTo;

  const ReadingStageEdition({
    required this.label,
    required this.translator,
    required this.cbeta,
    required this.ids,
    this.volFrom,
    this.volTo,
  });
}

/// 一部经 = 详情页里的一个「经典文件夹」。
class ReadingStageSutra {
  /// 文件夹名，如「百喻经」。
  final String name;

  /// 展开该文件夹时显示在顶部的介绍。
  final String intro;

  final List<ReadingStageEdition> editions;

  const ReadingStageSutra({
    required this.name,
    required this.intro,
    required this.editions,
  });
}

/// 一个读经阶段（阶段一 ~ 阶段五）。
class ReadingStage {
  /// 徽标首行，如「阶段一」。
  final String stageNo;

  /// 徽标次行/阶段名，如「入门基础」。
  final String badgeName;

  final String title;
  final String desc;

  /// 阶段图标（与经藏页进度圆点同一张）。
  final String icon;

  final List<ReadingStageSutra> sutras;

  const ReadingStage({
    required this.stageNo,
    required this.badgeName,
    required this.title,
    required this.desc,
    required this.icon,
    required this.sutras,
  });
}

/// 阶段一 · 初识佛法。
const ReadingStage kReadingStageOne = ReadingStage(
  stageNo: '阶段一',
  badgeName: '初识佛法',
  title: '认识佛法，明了因果',
  desc: '学习基础教义，认识解脱之道',
  icon: 'assets/menpai/jd1.png',
  sutras: [
    ReadingStageSutra(
      name: '百喻经',
      intro: '通过生动幽默的寓言故事，揭示愚痴、贪欲与执著带来的问题，'
          '以浅显易懂的方式阐释佛法道理，适合初学者入门。',
      editions: [
        ReadingStageEdition(
          label: '求那毘地译',
          translator: '萧齐 求那毘地',
          cbeta: 'T04n0209',
          ids: ['T04n0209'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '四十二章经',
      intro: '以简短的格言和问答形式，阐述欲望、无常、修行、智慧与解脱等'
          '内容，帮助读者初步认识佛教的基本教义。',
      editions: [
        ReadingStageEdition(
          label: '迦叶摩腾共法兰译',
          translator: '后汉 迦叶摩腾共竺法兰',
          cbeta: 'T17n0784',
          ids: ['T17n0784'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '八大人觉经',
      intro: '总结八种重要的觉悟与修行要点，涉及无常、少欲、知足、精进、'
          '智慧与慈悲，引导读者培养正确的修行观念。',
      editions: [
        ReadingStageEdition(
          label: '安世高译',
          translator: '后汉 安世高',
          cbeta: 'T17n0779',
          ids: ['T17n0779'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛遗教经',
      intro: '围绕持戒、节制欲望、知足、精进与智慧展开，教导修行者培养'
          '自律、清净与坚定的修行态度。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '后秦 鸠摩罗什',
          cbeta: 'T12n0389',
          ids: ['T12n0389'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '尸迦罗越六方礼经',
      intro: '从父母、师长、夫妻、朋友等日常关系出发，阐述家庭责任、待人之道'
          '与社会伦理，展现佛法在现实生活中的实践。',
      editions: [
        ReadingStageEdition(
          label: '安世高译',
          translator: '后汉 安世高',
          cbeta: 'T01n0016',
          ids: ['T01n0016'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '贤愚经',
      intro: '通过佛陀及相关人物的因缘故事，展现善恶行为与不同果报之间的联系，'
          '引导读者认识因果业报，培养行善止恶的观念。',
      editions: [
        ReadingStageEdition(
          label: '慧觉等译',
          translator: '元魏 慧觉等',
          cbeta: 'T04n0202',
          ids: ['T04n0202'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '六度集经',
      intro: '讲述佛陀过去世修行的种种故事，围绕布施、持戒、忍辱、精进、'
          '禅定与智慧六种实践，展现菩萨道的修行精神。',
      editions: [
        ReadingStageEdition(
          label: '康僧会译',
          translator: '吴 康僧会',
          cbeta: 'T03n0152',
          ids: ['T03n0152'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '生经',
      intro: '汇集佛陀及相关人物的本生与因缘故事，通过不同人物的经历呈现善恶、'
          '智慧与行为后果，帮助读者认识早期佛教的故事传统。',
      editions: [
        ReadingStageEdition(
          label: '竺法护译',
          translator: '西晋 竺法护',
          cbeta: 'T03n0154',
          ids: ['T03n0154'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛说十善业道经',
      intro: '讲述身、口、意三方面的十种善行，说明行为与心念如何影响个人及'
          '他人，引导读者理解善恶业果与道德实践。',
      editions: [
        ReadingStageEdition(
          label: '实叉难陀译',
          translator: '唐 实叉难陀',
          cbeta: 'T15n0600',
          ids: ['T15n0600'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '法句经',
      intro: '以简短偈颂阐述善恶、心念、智慧、修行与解脱等道理，适合初学者'
          '反复阅读、思考，并将佛法落实到日常生活。',
      editions: [
        ReadingStageEdition(
          label: '维祇难等译',
          translator: '吴 维祇难等',
          cbeta: 'T04n0210',
          ids: ['T04n0210'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '长阿含经',
      intro: '收录多部佛陀说法，涉及人生观、修行、因果及当时不同的思想主张，'
          '帮助读者了解早期佛教的教义与历史背景。',
      editions: [
        ReadingStageEdition(
          label: '佛陀耶舍共竺佛念译',
          translator: '后秦 佛陀耶舍共竺佛念',
          cbeta: 'T01n0001',
          ids: ['T01n0001'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '中阿含经',
      intro: '以佛陀与弟子及不同人物的对话为主，讨论修行方法、道德实践、'
          '禅观与解脱智慧，适合逐篇学习佛教的基本思想。',
      editions: [
        ReadingStageEdition(
          label: '僧伽提婆译',
          translator: '东晋 僧伽提婆',
          cbeta: 'T01n0026',
          ids: ['T01n0026'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '杂阿含经',
      intro: '集中阐述五蕴、六入、因缘与四圣谛等重要教义，是理解无常、无我、'
          '缘起及解脱之道的重要经典，建议结合主题分篇阅读。',
      editions: [
        ReadingStageEdition(
          label: '求那跋陀罗译',
          translator: '刘宋 求那跋陀罗',
          cbeta: 'T02n0099',
          ids: ['T02n0099'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '增一阿含经',
      intro: '按照数字次第组织大量佛教教法，涵盖修行、伦理、禅观与因果等内容，'
          '便于读者按主题逐步掌握佛教的基础观念。',
      editions: [
        ReadingStageEdition(
          label: '僧伽提婆译',
          translator: '东晋 僧伽提婆',
          cbeta: 'T02n0125',
          ids: ['T02n0125'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛说大乘稻竿经',
      intro: '借助稻谷生长的譬喻阐释缘起，说明诸法依赖各种条件而生，并非'
          '独立存在，帮助读者进一步理解缘起与无我。',
      editions: [
        ReadingStageEdition(
          label: '失译',
          translator: '失译',
          cbeta: 'T16n0712',
          ids: ['T16n0712'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛说阿弥陀经',
      intro: '描绘西方极乐世界的庄严景象，介绍阿弥陀佛及其净土信仰，阐述'
          '持名念佛、发愿往生等内容，是认识净土法门的重要经典。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T12n0366',
          ids: ['T12n0366'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '药师琉璃光如来本愿功德经',
      intro: '介绍药师佛的十二大愿及其功德，展现佛教对众生离苦得乐、身心安稳'
          '的关怀，帮助读者认识药师法门。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T14n0450',
          ids: ['T14n0450'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '弥勒下生成佛经',
      intro: '讲述弥勒菩萨未来下生成佛的情景，展现佛教关于未来佛、理想社会'
          '与众生福报的信仰和愿景。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '后秦 鸠摩罗什',
          cbeta: 'T14n0454',
          ids: ['T14n0454'],
        ),
        ReadingStageEdition(
          label: '义净译',
          translator: '唐 义净',
          cbeta: 'T14n0455',
          ids: ['T14n0455'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '坐禅三昧经',
      intro: '介绍早期禅观的修习方法及针对不同烦恼的对治思路，帮助读者初步'
          '认识禅定、专注与观照，了解佛教禅修的基本方向。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T15n0614',
          ids: ['T15n0614'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '维摩诘所说经',
      intro: '以在家居士维摩诘与佛弟子的问答为主线，探讨菩萨行、空性与'
          '不二法门，展现大乘佛教关于智慧、慈悲与世间修行的深刻思想。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T14n0475',
          ids: ['T14n0475'],
        ),
      ],
    ),
  ],
);

/// 阶段二 · 发心向道。
const ReadingStage kReadingStageTwo = ReadingStage(
  stageNo: '阶段二',
  badgeName: '发心向道',
  title: '走入大乘，发菩提心',
  desc: '理解菩萨愿行，体会慈悲智慧',
  icon: 'assets/menpai/jd2.png',
  sutras: [
    ReadingStageSutra(
      name: '妙法莲华经',
      intro: '以譬喻和佛陀开示阐述一佛乘思想，强调众生皆有成佛的可能，'
          '展现大乘佛教普度众生、引导众生走向佛果的宏大愿景。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '后秦 鸠摩罗什',
          cbeta: 'T09n0262',
          ids: ['T09n0262'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '无量义经',
      intro: '阐述诸法从一法而生无量义的思想，强调菩萨应随众生根机施设'
          '不同教法，适合作为理解《法华经》思想的辅助经典。',
      editions: [
        ReadingStageEdition(
          label: '昙摩伽陀耶舍译',
          translator: '萧齐 昙摩伽陀耶舍',
          cbeta: 'T09n0276',
          ids: ['T09n0276'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '观普贤菩萨行法经',
      intro: '讲述普贤菩萨的观想与忏悔修行，强调反省过失、清净身心、发起'
          '菩提心，是理解法华三部经及大乘忏悔思想的重要经典。',
      editions: [
        ReadingStageEdition(
          label: '昙无蜜多译',
          translator: '刘宋 昙无蜜多',
          cbeta: 'T09n0277',
          ids: ['T09n0277'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大方广佛华严经',
      intro: '展现菩萨从发心到成佛的广大修行历程，阐述法界缘起、重重无尽'
          '与事事无碍的思想，帮助读者建立宏大的大乘世界观。建议先读'
          '《入法界品》等重点篇章。',
      editions: [
        ReadingStageEdition(
          label: '佛驮跋陀罗译',
          translator: '东晋 佛驮跋陀罗',
          cbeta: 'T09n0278',
          ids: ['T09n0278'],
        ),
        ReadingStageEdition(
          label: '实叉难陀译',
          translator: '唐 实叉难陀',
          cbeta: 'T10n0279',
          ids: ['T10n0279'],
        ),
        ReadingStageEdition(
          label: '般若译',
          translator: '唐 般若',
          cbeta: 'T10n0293',
          ids: ['T10n0293'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大般涅槃经',
      intro: '深入探讨佛性、涅槃与众生能否成佛等问题，强调一切众生皆有'
          '佛性，是认识大乘佛教佛性思想的重要经典。',
      editions: [
        ReadingStageEdition(
          label: '昙无谶译',
          translator: '北凉 昙无谶',
          cbeta: 'T12n0374',
          ids: ['T12n0374'],
        ),
        ReadingStageEdition(
          label: '慧严等译',
          translator: '刘宋 慧严等',
          cbeta: 'T12n0375',
          ids: ['T12n0375'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '无量寿经',
      intro: '讲述法藏比丘发四十八大愿、成就西方极乐世界的因缘，展现'
          '大乘愿力、慈悲救度与净土信仰的核心精神。',
      editions: [
        ReadingStageEdition(
          label: '康僧铠译',
          translator: '曹魏 康僧铠',
          cbeta: 'T12n0360',
          ids: ['T12n0360'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '观无量寿佛经',
      intro: '通过十六观法及九品往生等内容，介绍净土观想、发愿与修行次第，'
          '帮助读者理解净土法门的修行思想。',
      editions: [
        ReadingStageEdition(
          label: '畺良耶舍译',
          translator: '刘宋 畺良耶舍',
          cbeta: 'T12n0365',
          ids: ['T12n0365'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '不退转法轮经',
      intro: '围绕菩萨修行中的不退转境界及成佛道路展开，帮助读者理解'
          '大乘菩萨如何坚定菩提心、持续修行并趋向佛果。',
      editions: [
        ReadingStageEdition(
          label: '失译',
          translator: '失译',
          cbeta: 'T09n0267',
          ids: ['T09n0267'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '悲华经',
      intro: '讲述诸菩萨过去世发愿修行、选择佛土与救度众生的因缘，展现'
          '大乘佛教关于菩萨愿力、净秽佛土与慈悲救度的宏大思想。',
      editions: [
        ReadingStageEdition(
          label: '昙无谶译',
          translator: '北凉 昙无谶',
          cbeta: 'T03n0157',
          ids: ['T03n0157'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '地藏菩萨本愿经',
      intro: '围绕地藏菩萨的广大誓愿，阐述孝亲报恩、因果业报、忏悔与'
          '救度众生等思想，帮助读者理解大乘菩萨愿行。',
      editions: [
        ReadingStageEdition(
          label: '实叉难陀译',
          translator: '唐 实叉难陀',
          cbeta: 'T13n0412',
          ids: ['T13n0412'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '金光明最胜王经',
      intro: '融合佛法智慧、忏悔、护国与利益众生等内容，展现大乘经典'
          '如何将个人修行、社会责任与护持正法联系起来。',
      editions: [
        ReadingStageEdition(
          label: '义净译',
          translator: '唐 义净',
          cbeta: 'T16n0665',
          ids: ['T16n0665'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛说宝雨经',
      intro: '围绕菩萨修行、发心、智慧与利益众生等内容展开，帮助读者'
          '进一步认识大乘佛教对于菩萨实践与成佛道路的系统阐述。',
      editions: [
        ReadingStageEdition(
          label: '达摩流支译',
          translator: '唐 达摩流支',
          cbeta: 'T16n0660',
          ids: ['T16n0660'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '菩萨璎珞本业经',
      intro: '阐述菩萨的修行阶位、发心与戒行等内容，帮助读者认识大乘'
          '菩萨道的修学次第及其行为规范。',
      editions: [
        ReadingStageEdition(
          label: '竺佛念译',
          translator: '姚秦 竺佛念',
          cbeta: 'T24n1485',
          ids: ['T24n1485'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛藏经',
      intro: '围绕佛法正见、诸法实相、净戒与修行展开，帮助读者理解'
          '大乘佛教对于正法、智慧及清净修行的重视。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T15n0653',
          ids: ['T15n0653'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大集经·月藏分',
      intro: '涉及正法住世、众生根机、修行环境与护持佛法等主题，帮助'
          '读者了解大乘经典对于时代变化、修行实践及正法传承的思考。',
      editions: [
        ReadingStageEdition(
          label: '那连提耶舍译',
          translator: '高齐 那连提耶舍',
          cbeta: 'T13n0397',
          ids: ['T13n0397'],
          volFrom: 46,
          volTo: 56,
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛说阿閦佛国经',
      intro: '介绍阿閦佛及其清净佛国，讲述菩萨发愿、持行与成就佛土的'
          '因缘，使读者认识西方极乐世界之外的大乘净土思想。',
      editions: [
        ReadingStageEdition(
          label: '支娄迦谶译',
          translator: '后汉 支娄迦谶',
          cbeta: 'T11n0313',
          ids: ['T11n0313'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛说观弥勒菩萨上生兜率天经',
      intro: '介绍弥勒菩萨居于兜率天的信仰及相关修行内容，展现弥勒信仰'
          '对于未来佛、愿生兜率与亲近菩萨的期待。',
      editions: [
        ReadingStageEdition(
          label: '沮渠京声译',
          translator: '刘宋 沮渠京声',
          cbeta: 'T14n0452',
          ids: ['T14n0452'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘本生心地观经',
      intro: '结合报恩、孝亲、菩萨行与心地修行等主题，阐述如何从日常'
          '伦理走向大乘菩萨道，帮助读者理解修行与现实生活的联系。',
      editions: [
        ReadingStageEdition(
          label: '般若译',
          translator: '唐 般若',
          cbeta: 'T03n0159',
          ids: ['T03n0159'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘庄严宝王经',
      intro: '以观世音菩萨相关教法为重要内容，展现观音信仰、慈悲救度'
          '与大乘修行的精神，适合进一步认识观音法门及其经典传统。',
      editions: [
        ReadingStageEdition(
          label: '天息灾译',
          translator: '宋 天息灾',
          cbeta: 'T20n1050',
          ids: ['T20n1050'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '普贤行愿品',
      intro: '阐述礼敬诸佛、称赞如来、广修供养、忏悔业障、随喜功德、'
          '请转法轮、恒顺众生等十大愿王，强调将广大愿心落实于实际行动，'
          '是学习大乘菩萨行的重要经典。',
      editions: [
        ReadingStageEdition(
          label: '般若译',
          translator: '唐 般若',
          cbeta: 'T10n0293',
          ids: ['T10n0293'],
          volFrom: 40,
          volTo: 40,
        ),
      ],
    ),
  ],
);

/// 阶段三 · 般若观空。
const ReadingStage kReadingStageThree = ReadingStage(
  stageNo: '阶段三',
  badgeName: '般若观空',
  title: '深入般若，体悟空性',
  desc: '学习缘起无我，破除执著分别',
  icon: 'assets/menpai/jd3.png',
  sutras: [
    ReadingStageSutra(
      name: '般若波罗蜜多心经',
      intro: '以精炼的篇幅阐述五蕴皆空、诸法无自性等般若思想，帮助读者'
          '理解色与空的关系，是入门学习空性智慧的重要经典。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T08n0251',
          ids: ['T08n0251'],
        ),
        ReadingStageEdition(
          label: '法月译',
          translator: '唐 法月',
          cbeta: 'T08n0252',
          ids: ['T08n0252'],
        ),
        ReadingStageEdition(
          label: '般若共利言等译',
          translator: '唐 般若共利言等',
          cbeta: 'T08n0253',
          ids: ['T08n0253'],
        ),
        ReadingStageEdition(
          label: '智慧轮译',
          translator: '唐 智慧轮',
          cbeta: 'T08n0254',
          ids: ['T08n0254'],
        ),
        ReadingStageEdition(
          label: '法成译',
          translator: '唐 法成',
          cbeta: 'T08n0255',
          ids: ['T08n0255'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '金刚般若波罗蜜经',
      intro: '通过对话阐述无相、无住、无所得等思想，引导读者放下对自我、'
          '事物及功德的固执，深入理解般若智慧。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T08n0235',
          ids: ['T08n0235'],
        ),
        ReadingStageEdition(
          label: '菩提流支译',
          translator: '元魏 菩提流支',
          cbeta: 'T08n0236a',
          ids: ['T08n0236a'],
        ),
        ReadingStageEdition(
          label: '真谛译',
          translator: '陈 真谛',
          cbeta: 'T08n0237',
          ids: ['T08n0237'],
        ),
        ReadingStageEdition(
          label: '笈多译',
          translator: '隋 笈多',
          cbeta: 'T08n0238',
          ids: ['T08n0238'],
        ),
        ReadingStageEdition(
          label: '义净译',
          translator: '唐 义净',
          cbeta: 'T08n0239',
          ids: ['T08n0239'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '小品般若波罗蜜经',
      intro: '围绕般若智慧与菩萨行展开，探讨菩萨如何在不执著于自我、'
          '众生及所得的前提下修行，是学习般若思想的重要经典。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '后秦 鸠摩罗什',
          cbeta: 'T08n0227',
          ids: ['T08n0227'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '摩诃般若波罗蜜经',
      intro: '系统阐述般若波罗蜜多、诸法空性及菩萨修行，进一步探讨'
          '一切法无自性与菩萨如何行于世间而不执著。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '后秦 鸠摩罗什',
          cbeta: 'T08n0223',
          ids: ['T08n0223'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '放光般若经',
      intro: '属于早期大型般若经典的重要汉译本，广泛讨论诸法空性、'
          '菩萨般若行与无所得思想，帮助读者认识般若教义的发展。',
      editions: [
        ReadingStageEdition(
          label: '无罗叉译',
          translator: '西晋 无罗叉',
          cbeta: 'T08n0221',
          ids: ['T08n0221'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '光赞般若经',
      intro: '是早期般若经典的重要汉译本，围绕菩萨修行、般若智慧与'
          '诸法空性展开，适合与其他般若经典对照阅读。',
      editions: [
        ReadingStageEdition(
          label: '竺法护译',
          translator: '西晋 竺法护',
          cbeta: 'T08n0222',
          ids: ['T08n0222'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '道行般若经',
      intro: '保存了早期般若思想的重要内容，涉及菩萨发心、般若修行与'
          '无所得等观念，适合了解般若经典早期的汉译传统。',
      editions: [
        ReadingStageEdition(
          label: '支娄迦谶译',
          translator: '后汉 支娄迦谶',
          cbeta: 'T08n0224',
          ids: ['T08n0224'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大般若波罗蜜多经',
      intro: '由多个般若经典部分汇集而成，系统阐释空性、无所得与菩萨行，'
          '是研究般若思想的重要总集。全经规模庞大，建议选择重点会、重点品阅读。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T05n0220',
          ids: ['T05n0220', 'T06n0220'],
          volFrom: 1,
          volTo: 400,
        ),
      ],
    ),
    ReadingStageSutra(
      name: '文殊师利所说摩诃般若波罗蜜经',
      intro: '通过文殊师利与佛陀的问答，阐述无分别、无所得与不执著等思想，'
          '帮助读者进一步认识般若智慧与禅观之间的关系。',
      editions: [
        ReadingStageEdition(
          label: '曼陀罗仙译',
          translator: '梁 曼陀罗仙',
          cbeta: 'T08n0232',
          ids: ['T08n0232'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '文殊师利问菩提经',
      intro: '围绕菩提、菩萨修行与智慧展开，探讨菩萨如何理解诸法、'
          '不执著于相，并以智慧与方便利益众生。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T14n0464',
          ids: ['T14n0464'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '中论',
      intro: '龙树菩萨的重要论著，通过对缘起、生灭、因果等问题的分析，'
          '阐明诸法无自性、中道与空性的关系，是学习中观思想的核心论典。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T30n1564',
          ids: ['T30n1564'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '十二门论',
      intro: '从观因缘、观有果无果等多个角度分析诸法，破除对事物具有'
          '独立自性的执著，帮助读者理解缘起性空的逻辑。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T30n1568',
          ids: ['T30n1568'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '百论',
      intro: '系统辨析多种哲学观点与执著，通过论辩破除对自我、世界及'
          '各种概念的固守，是认识三论宗思想传统的重要论典。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T30n1569',
          ids: ['T30n1569'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大智度论',
      intro: '围绕般若经义展开广泛解释，涉及空性、菩萨道、六度、因果与'
          '佛教哲学等内容，是深入理解般若思想的重要论著，篇幅较大，'
          '建议分专题阅读。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T25n1509',
          ids: ['T25n1509'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '回诤论',
      intro: '龙树菩萨的重要论著，回应对空性思想的质疑，讨论语言、'
          '认识与论证的局限，帮助读者理解空性并非简单否定一切。',
      editions: [
        ReadingStageEdition(
          label: '毘目智仙共瞿昙流支译',
          translator: '后魏 毘目智仙共瞿昙流支',
          cbeta: 'T32n1631',
          ids: ['T32n1631'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '广百论本',
      intro: '以严密的论证分析常见的哲学观点，批判对事物、自我及'
          '认识对象的实有执著，进一步深化对中观空性思想的理解。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T30n1570',
          ids: ['T30n1570'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘掌珍论',
      intro: '通过因明论证阐释有为法与无为法的空性，探讨事物与空性之间的'
          '关系，适合在具备一定般若基础后深入研读。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T30n1578',
          ids: ['T30n1578'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '般若灯论释',
      intro: '对中观思想进行系统论述，通过分析因缘、生灭及诸法自性等问题，'
          '帮助读者进一步理解空性的理论论证。',
      editions: [
        ReadingStageEdition(
          label: '波罗颇蜜多罗译',
          translator: '唐 波罗颇蜜多罗',
          cbeta: 'T30n1566',
          ids: ['T30n1566'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘中观释论',
      intro: '围绕中观思想展开解释与论证，讨论缘起、空性及诸法无自性等问题，'
          '适合进一步认识印度大乘中观学的发展。',
      editions: [
        ReadingStageEdition(
          label: '惟净等译',
          translator: '宋 惟净等',
          cbeta: 'T30n1567',
          ids: ['T30n1567'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '顺中论义入大般若波罗蜜经初品法门',
      intro: '围绕般若与中观思想展开阐释，帮助读者从诸法空性、无所得等'
          '角度理解大乘智慧，适合作为进一步研读中观论典的补充。',
      editions: [
        ReadingStageEdition(
          label: '瞿昙般若流支译',
          translator: '元魏 瞿昙般若流支',
          cbeta: 'T30n1565',
          ids: ['T30n1565'],
        ),
      ],
    ),
  ],
);

/// 阶段四 · 深研经义。
const ReadingStage kReadingStageFour = ReadingStage(
  stageNo: '阶段四',
  badgeName: '深研经义',
  title: '深研经论，通达宗义',
  desc: '探究心性唯识，理解诸宗思想',
  icon: 'assets/menpai/jd4.png',
  sutras: [
    ReadingStageSutra(
      name: '六祖大师法宝坛经',
      intro: '从自性、顿悟与日常修行入手，理解禅宗的核心思想。',
      editions: [
        ReadingStageEdition(
          label: '法海集记',
          translator: '唐 释慧能说·法海集记',
          cbeta: 'T48n2008',
          ids: ['T48n2008'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '胜鬘师子吼一乘大方便方广经',
      intro: '阐述如来藏、一乘思想与菩萨修行，帮助理解大乘佛教的深层教义。',
      editions: [
        ReadingStageEdition(
          label: '求那跋陀罗译',
          translator: '刘宋 求那跋陀罗',
          cbeta: 'T12n0353',
          ids: ['T12n0353'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大方等如来藏经',
      intro: '阐述众生本具如来藏的思想，探讨烦恼与佛性之间的关系。',
      editions: [
        ReadingStageEdition(
          label: '佛陀跋陀罗译',
          translator: '东晋 佛陀跋陀罗',
          cbeta: 'T16n0666',
          ids: ['T16n0666'],
        ),
        ReadingStageEdition(
          label: '不空译',
          translator: '唐 不空',
          cbeta: 'T16n0667',
          ids: ['T16n0667'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛说不增不减经',
      intro: '探讨众生界、法身与如来藏的关系，深化对大乘心性思想的认识。',
      editions: [
        ReadingStageEdition(
          label: '菩提流支译',
          translator: '元魏 菩提流支',
          cbeta: 'T16n0668',
          ids: ['T16n0668'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '楞伽阿跋多罗宝经',
      intro: '阐述八识、唯心、三自性与如来藏等思想，是理解禅宗与'
          '唯识思想的重要经典。',
      editions: [
        ReadingStageEdition(
          label: '求那跋陀罗译',
          translator: '刘宋 求那跋陀罗',
          cbeta: 'T16n0670',
          ids: ['T16n0670'],
        ),
        ReadingStageEdition(
          label: '菩提流支译',
          translator: '元魏 菩提流支',
          cbeta: 'T16n0671',
          ids: ['T16n0671'],
        ),
        ReadingStageEdition(
          label: '实叉难陀译',
          translator: '唐 实叉难陀',
          cbeta: 'T16n0672',
          ids: ['T16n0672'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '解深密经',
      intro: '系统阐述阿赖耶识、三性三无性与唯识思想，是理解唯识学的'
          '重要经典。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T16n0676',
          ids: ['T16n0676'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘显识经',
      intro: '围绕识的显现、业力与生死流转展开，帮助理解大乘心识理论。',
      editions: [
        ReadingStageEdition(
          label: '地婆诃罗译',
          translator: '唐 地婆诃罗',
          cbeta: 'T12n0347',
          ids: ['T12n0347'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘密严经',
      intro: '深入探讨阿赖耶识、如来藏与密严净土等思想，适合进一步'
          '研读唯识相关教义。',
      editions: [
        ReadingStageEdition(
          label: '地婆诃罗译',
          translator: '唐 地婆诃罗',
          cbeta: 'T16n0681',
          ids: ['T16n0681'],
        ),
        ReadingStageEdition(
          label: '不空译',
          translator: '唐 不空',
          cbeta: 'T16n0682',
          ids: ['T16n0682'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛说佛地经',
      intro: '阐述佛地的智慧、功德与清净境界，为理解佛果理论打下基础。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T16n0680',
          ids: ['T16n0680'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '显扬圣教论',
      intro: '系统整理大乘佛教的教义、心识分类、修行道次第与智慧等内容，'
          '适合在掌握唯识基础后进一步建立系统的理论框架。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T31n1602',
          ids: ['T31n1602'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘起信论',
      intro: '从一心二门、真如与生灭等角度，系统阐述大乘心性思想。',
      editions: [
        ReadingStageEdition(
          label: '真谛译',
          translator: '梁 真谛',
          cbeta: 'T32n1666',
          ids: ['T32n1666'],
        ),
        ReadingStageEdition(
          label: '实叉难陀译',
          translator: '唐 实叉难陀',
          cbeta: 'T32n1667',
          ids: ['T32n1667'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '摄大乘论',
      intro: '系统阐述阿赖耶识、种子、三性与菩萨修行，是唯识学的'
          '重要论典。',
      editions: [
        ReadingStageEdition(
          label: '佛陀扇多译',
          translator: '后魏 佛陀扇多',
          cbeta: 'T31n1592',
          ids: ['T31n1592'],
        ),
        ReadingStageEdition(
          label: '真谛译',
          translator: '陈 真谛',
          cbeta: 'T31n1593',
          ids: ['T31n1593'],
        ),
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T31n1594',
          ids: ['T31n1594'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘庄严经论',
      intro: '围绕菩提心、菩萨行、智慧与大乘功德，建立较系统的修学认识。',
      editions: [
        ReadingStageEdition(
          label: '波罗颇蜜多罗译',
          translator: '唐 波罗颇蜜多罗',
          cbeta: 'T31n1604',
          ids: ['T31n1604'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '辨中边论',
      intro: '分析虚妄分别、空性与中道，帮助理解唯识学如何解释'
          '诸法的真实与虚妄。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T31n1600',
          ids: ['T31n1600'],
        ),
        ReadingStageEdition(
          label: '真谛译',
          translator: '陈 真谛',
          cbeta: 'T31n1599',
          ids: ['T31n1599'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '唯识三十论颂',
      intro: '以三十颂概括唯识学的核心思想，适合在具备基础后建立整体框架。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T31n1586',
          ids: ['T31n1586'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '唯识二十论',
      intro: '围绕外境是否实有等问题展开论证，帮助理解唯识学关于'
          '认识与境界的观点。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T31n1590',
          ids: ['T31n1590'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '成唯识论',
      intro: '系统解释八识、心所、种子、三性与转识成智，是唯识学的'
          '重要论典，阅读难度较高。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T31n1585',
          ids: ['T31n1585'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘阿毗达磨集论',
      intro: '系统整理大乘法相、心所、修行与智慧等概念，适合深入研读'
          '法相唯识体系。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T31n1605',
          ids: ['T31n1605'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '瑜伽师地论',
      intro: '全面论述瑜伽行派的修行次第、心理分析与菩萨道，篇幅宏大，'
          '适合分章节长期学习。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T30n1579',
          ids: ['T30n1579'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '佛地经论',
      intro: '结合《佛地经》深入解释佛果、佛智与佛身等思想，帮助建立'
          '对大乘佛果理论的系统认识。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T26n1530',
          ids: ['T26n1530'],
        ),
      ],
    ),
  ],
);

/// 阶段五 · 融会贯通。
const ReadingStage kReadingStageFive = ReadingStage(
  stageNo: '阶段五',
  badgeName: '融会贯通',
  title: '融会诸部，贯通佛法',
  desc: '广研经律论藏，深化整体认知',
  icon: 'assets/menpai/jd5.png',
  sutras: [
    ReadingStageSutra(
      name: '大乘集菩萨学论',
      intro: '汇集大乘经典中的菩萨修行教法，围绕菩提心、戒行、布施、'
          '忍辱与智慧等内容，帮助读者理解菩萨实践的整体要求。',
      editions: [
        ReadingStageEdition(
          label: '法护等译',
          translator: '宋 法护等',
          cbeta: 'T32n1636',
          ids: ['T32n1636'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '成实论',
      intro: '系统讨论苦、集、灭、道及诸法的性质，涉及无我、空与解脱等'
          '思想，帮助读者认识不同佛教论学传统对修行和解脱的阐释。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T32n1646',
          ids: ['T32n1646'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '解脱道论',
      intro: '围绕戒、定、慧及解脱的修行次第展开，介绍禅修、观法与'
          '烦恼对治，帮助读者认识早期佛教的实践体系。',
      editions: [
        ReadingStageEdition(
          label: '僧伽婆罗译',
          translator: '梁 僧伽婆罗',
          cbeta: 'T32n1648',
          ids: ['T32n1648'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大宝积经',
      intro: '汇集多种大乘经典，涵盖菩萨道、净土、般若与佛果等主题，'
          '适合拓展大乘整体视野。',
      editions: [
        ReadingStageEdition(
          label: '菩提流志译',
          translator: '唐 菩提流志',
          cbeta: 'T11n0310',
          ids: ['T11n0310'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大乘理趣六波罗蜜多经',
      intro: '系统阐述布施、持戒、忍辱、精进、静虑、般若六度，帮助将'
          '智慧与实践结合起来。',
      editions: [
        ReadingStageEdition(
          label: '般若译',
          translator: '唐 般若',
          cbeta: 'T08n0261',
          ids: ['T08n0261'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '阿毗达磨大毗婆沙论',
      intro: '广泛讨论佛教法相分类、认识、因果与修行等问题，是了解'
          '说一切有部论学传统的重要典籍，适合具备基础后分专题阅读。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T27n1545',
          ids: ['T27n1545'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '圆觉经',
      intro: '围绕觉悟、心性、烦恼与修行展开，讨论如何认识虚妄执著并'
          '趋向圆满觉悟，适合结合禅观与大乘心性思想研读。',
      editions: [
        ReadingStageEdition(
          label: '佛陀多罗译',
          translator: '唐 佛陀多罗',
          cbeta: 'T17n0842',
          ids: ['T17n0842'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '楞严经',
      intro: '围绕心性、妄识、修行与禅定等问题展开，内容涉及认识心与'
          '境界、辨别修行偏差及修习定慧，适合在有一定佛学基础后阅读。',
      editions: [
        ReadingStageEdition(
          label: '般剌蜜帝译',
          translator: '唐 般剌蜜帝',
          cbeta: 'T19n0945',
          ids: ['T19n0945'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '优婆塞戒经',
      intro: '重点讨论在家菩萨的戒行、布施、持戒、发心与日常修行，'
          '帮助读者理解在家身份下如何实践大乘菩萨道。',
      editions: [
        ReadingStageEdition(
          label: '昙无谶译',
          translator: '北凉 昙无谶',
          cbeta: 'T24n1488',
          ids: ['T24n1488'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '究竟一乘宝性论',
      intro: '系统论述如来藏、佛性、三宝与众生成佛的可能，帮助读者'
          '进一步理解大乘佛教关于佛性与成佛道路的理论体系。',
      editions: [
        ReadingStageEdition(
          label: '勒那摩提译',
          translator: '后魏 勒那摩提',
          cbeta: 'T31n1611',
          ids: ['T31n1611'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '梵网经',
      intro: '重点阐述菩萨戒思想，帮助理解大乘菩萨的行为规范与责任。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '后秦 鸠摩罗什',
          cbeta: 'T24n1484',
          ids: ['T24n1484'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '四分律',
      intro: '系统记载比丘僧团戒律、制度与生活规范，适合进一步了解'
          '律藏及僧团传统。',
      editions: [
        ReadingStageEdition(
          label: '佛陀耶舍共竺佛念译',
          translator: '姚秦 佛陀耶舍共竺佛念等',
          cbeta: 'T22n1428',
          ids: ['T22n1428'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '摩诃僧祇律',
      intro: '保存僧团戒律、生活制度与相关因缘故事，有助于比较'
          '不同律部传统。',
      editions: [
        ReadingStageEdition(
          label: '佛陀跋陀罗共法显译',
          translator: '东晋 佛陀跋陀罗共法显',
          cbeta: 'T22n1425',
          ids: ['T22n1425'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '三论玄义',
      intro: '系统介绍三论宗的基本思想与理论脉络，阐述中观学说中的'
          '二谛、破执与空义，帮助读者将中观经典与宗派思想联系起来。',
      editions: [
        ReadingStageEdition(
          label: '吉藏撰',
          translator: '隋 吉藏',
          cbeta: 'T45n1852',
          ids: ['T45n1852'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '肇论',
      intro: '围绕般若、空性、涅槃与不真空等思想展开论述，体现中国'
          '佛教早期对大乘哲理的理解，有助于认识印度佛学与中国佛教'
          '思想之间的衔接。',
      editions: [
        ReadingStageEdition(
          label: '僧肇作',
          translator: '后秦 僧肇',
          cbeta: 'T45n1858',
          ids: ['T45n1858'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '因明入正理论',
      intro: '介绍佛教因明的基本论证方法与推理结构，帮助读者理解'
          '佛教论师如何辨析观点、建立论证及回应质疑。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T32n1630',
          ids: ['T32n1630'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '异部宗轮论',
      intro: '概述佛教部派分化及不同部派的思想差异，帮助读者从历史'
          '与教义角度认识佛教思想的发展脉络。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T49n2031',
          ids: ['T49n2031'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '摩诃止观',
      intro: '系统阐述天台止观的修行体系，帮助理解天台宗如何将'
          '教理与禅观结合。',
      editions: [
        ReadingStageEdition(
          label: '智者大师说',
          translator: '隋 智顗说·灌顶记',
          cbeta: 'T46n1911',
          ids: ['T46n1911'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '宗镜录',
      intro: '汇集经论与禅宗思想，讨论心性、唯心、修行与悟道等问题，'
          '体现中国佛教融通诸宗的理论尝试，适合作为综合研读的延伸读物。',
      editions: [
        ReadingStageEdition(
          label: '延寿集',
          translator: '宋 延寿集',
          cbeta: 'T48n2016',
          ids: ['T48n2016'],
        ),
      ],
    ),
  ],
);
