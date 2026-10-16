/// 「廿册精选经典」的经典编排。
///
/// 复用「百册经论指南」的 [ReadingStage] / [ReadingStageSutra] /
/// [ReadingStageEdition] 结构，因此可以直接用 [ReadingStagePage] 渲染出
/// 与阶段读经页完全一致的「经典文件夹 → 译本 → 分卷」页面。
///
/// CBETA 编号与译者署名与 [reading_stage_data] 保持一致，卷数、卷标题、字数
/// 仍由经藏页已加载的目录在运行时解析。
library;

import 'reading_stage_data.dart';

/// 廿册精选经典（佛教经典精选 20 部）。顺序即展示顺序。
const ReadingStage kTwentyClassics = ReadingStage(
  // 徽标首行留空：本区不在阶段体系内，读经页用 headerTitle 覆盖显示。
  stageNo: '',
  badgeName: '廿册精选',
  title: '汇聚佛门经典，传承千年诵读名篇',
  desc: '佛教经典精选 20 部',
  icon: '',
  sutras: [
    ReadingStageSutra(
      name: '般若波罗蜜多心经',
      intro: '简称《心经》，以精炼的篇幅阐述五蕴皆空、般若智慧与空性思想，'
          '是汉传佛教最广为人知的经典之一。',
      editions: [
        ReadingStageEdition(
          label: '玄奘译',
          translator: '唐 玄奘',
          cbeta: 'T08n0251',
          ids: ['T08n0251'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '金刚般若波罗蜜经',
      intro: '简称《金刚经》，阐述般若智慧、无相与无所执著的菩萨行，'
          '对禅宗及汉传佛教影响深远。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T08n0235',
          ids: ['T08n0235'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '地藏菩萨本愿经',
      intro: '简称《地藏经》，讲述地藏菩萨的本愿与修行，涉及孝亲报恩、因果、'
          '忏悔、布施和回向，是民间流通十分广泛的经典。',
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
      name: '佛说阿弥陀经',
      intro: '简称《阿弥陀经》，介绍西方极乐世界、阿弥陀佛及持名念佛等内容，'
          '是净土宗日常诵读的重要经典。',
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
      intro: '简称《药师经》，讲述药师佛的十二大愿、净琉璃世界及相关修持，'
          '是药师法门的核心经典。',
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
      name: '佛说无量寿经',
      intro: '简称《无量寿经》，以阿弥陀佛的本愿、极乐世界及往生净土的教义'
          '为核心，是净土宗的重要经典。',
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
      name: '佛说观无量寿佛经',
      intro: '简称《观无量寿经》，讲述净土观想、修行方法及九品往生等内容，'
          '是净土三经之一。',
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
      name: '观世音菩萨普门品',
      intro: '简称《普门品》，是《妙法莲华经》中的一品，主要讲述观世音菩萨'
          '应机救度众生的慈悲愿行，常作为独立经本流通和诵读。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T09n0262',
          ids: ['T09n0262'],
          volFrom: 7,
          volTo: 7,
        ),
      ],
    ),
    ReadingStageSutra(
      name: '妙法莲华经',
      intro: '简称《法华经》，阐述一佛乘、方便善巧及众生皆有成佛可能等思想，'
          '是天台宗的根本经典之一。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T09n0262',
          ids: ['T09n0262'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '大佛顶首楞严经',
      intro: '简称《楞严经》，探讨心性、觉悟、禅定、戒行及修行中的辨识问题，'
          '在汉传佛教中影响深远。',
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
      name: '大方广佛华严经',
      intro: '简称《华严经》，阐述法界缘起、菩萨行愿及诸法相互关联的思想，'
          '是华严宗的根本经典。',
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
      name: '大方广圆觉修多罗了义经',
      intro: '简称《圆觉经》，围绕圆满觉悟、心性、修行次第与禅观展开，'
          '是汉传佛教常见的修学经典。',
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
      name: '六祖大师法宝坛经',
      intro: '简称《坛经》，记录六祖惠能的讲法与禅宗思想，阐述顿悟、般若与'
          '自性等重要观念，是中国佛教的重要典籍。',
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
      name: '普贤菩萨行愿品',
      intro: '讲述普贤菩萨的十大愿王，包括礼敬诸佛、广修供养、忏悔业障、'
          '普皆回向等内容，是华严经典体系中广为流通的修行篇章。',
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
    ReadingStageSutra(
      name: '维摩诘所说经',
      intro: '简称《维摩诘经》，通过维摩诘居士与佛弟子的问答，阐述般若、'
          '不二法门与菩萨行，展现在家修行的智慧。',
      editions: [
        ReadingStageEdition(
          label: '鸠摩罗什译',
          translator: '姚秦 鸠摩罗什',
          cbeta: 'T14n0475',
          ids: ['T14n0475'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '四十二章经',
      intro: '以简短章节汇集佛教修行与人生智慧相关教导，是中国早期流传的'
          '重要佛教经典之一。',
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
      intro: '简称《八大人觉经》，围绕无常、少欲、知足、精进、布施与智慧等'
          '主题，概述佛教修行的重要观念。',
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
      name: '佛说盂兰盆经',
      intro: '简称《盂兰盆经》，讲述目连救母的因缘及供养僧众、报答亲恩等内容，'
          '与汉传佛教的盂兰盆节传统密切相关。',
      editions: [
        ReadingStageEdition(
          label: '竺法护译',
          translator: '西晋 竺法护',
          cbeta: 'T16n0685',
          ids: ['T16n0685'],
        ),
      ],
    ),
    ReadingStageSutra(
      name: '金光明最胜王经',
      intro: '简称《金光明经》的一种重要译本，涉及忏悔、护国、福德及诸佛功德'
          '等内容，在汉传佛教的法会与相关仪轨中具有重要地位。',
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
      name: '楞伽阿跋多罗宝经',
      intro: '简称《楞伽经》，探讨心识、分别、如来藏及自觉圣智等思想，'
          '与中国禅宗的思想发展有重要关联。',
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
  ],
);
