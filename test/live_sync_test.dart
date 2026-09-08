import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/sutra_live_sync.dart';

void main() {
  group('解析经书段落（与读经页口径一致）', () {
    test('剔除空行与分段标记', () {
      final paragraphs = parseSutraParagraphs('第一段。。。\n\n第二段。。。///\n第三段\n');
      expect(paragraphs, ['第一段', '第二段', '第三段']);
    });

    test('头部标记也剔除', () {
      final paragraphs = parseSutraParagraphs('。。。///第一段\n///。。。第二段');
      expect(paragraphs, ['第一段', '第二段']);
    });

    test('parseSutraTight 返回紧密连段标记', () {
      final r = parseSutraTight('第一段\n第二段。。。///\n第三段。。。///\n第四段');
      expect(r.paragraphs, ['第一段', '第二段', '第三段', '第四段']);
      expect(r.tight, {1, 2}); // 段1→2、段2→3 无间隔
    });
  });

  const paragraphs = ['如是我闻', '一时佛在舍卫国', '树给孤独园', '尔时世尊'];

  const items = [
    {
      'index': 0,
      'underlines': [
        {'start': 0, 'end': 2},
      ],
    },
    {
      'index': 3,
      'underlines': [
        {'start': 1, 'end': 4},
      ],
    },
  ];

  group('实时画线重建 buildLiveHighlights', () {
    test('按云端画线区间重建出当前文本（非连段按段返回）', () {
      final out = buildLiveHighlights(paragraphs, const {}, items);
      expect(out.length, 2);
      expect(out[0].text, '如是');
      expect(out[0].segments, hasLength(1));
      expect(out[0].segments[0].para, 0);
      expect(out[0].segments[0].start, 0);
      expect(out[0].segments[0].end, 2);
      expect(out[1].text, '时世尊');
      expect(out[1].segments[0].para, 3);
    });

    test('重叠区间合并为整块', () {
      final merged = buildLiveHighlights(paragraphs, const {}, const [
        {
          'index': 0,
          'underlines': [
            {'start': 0, 'end': 2},
            {'start': 1, 'end': 4},
          ],
        },
      ]);
      expect(merged.length, 1);
      expect(merged[0].text, '如是我闻');
    });

    test('无画线时返回空列表（对应「作者已删除全部画线」）', () {
      expect(buildLiveHighlights(paragraphs, const {}, const []), isEmpty);
    });

    test('非法条目被跳过', () {
      final out = buildLiveHighlights(paragraphs, const {}, const [
        {
          'index': 'x',
          'underlines': [
            {'start': 0, 'end': 2},
          ],
        },
        {
          'index': 3,
          'underlines': 'bad',
        },
      ]);
      expect(out, isEmpty);
    });

    test('区间越界被裁剪（负值被过滤、超大 end 收敛到段尾）', () {
      final out = buildLiveHighlights(paragraphs, const {}, const [
        {
          'index': 1,
          'underlines': [
            {'start': 0, 'end': 99},
          ],
        },
        {
          'index': 2,
          'underlines': [
            {'start': -5, 'end': 2},
          ],
        },
      ]);
      expect(out.length, 1);
      expect(out[0].text, '一时佛在舍卫国');
    });

    test('相连 `。。。///` 连段簇内的画线合并为一条整段（段间换行）', () {
      // 段0 与段1、段1 与段2 紧密相连：{0,1,2} 为一簇；段3 独立。
      const tight = {0, 1};
      const clusterItems = [
        {
          'index': 0,
          'underlines': [
            {'start': 0, 'end': 2},
          ],
        },
        {
          'index': 2,
          'underlines': [
            {'start': 0, 'end': 2},
          ],
        },
      ];
      final out = buildLiveHighlights(paragraphs, tight, clusterItems);
      expect(out.length, 1);
      expect(out[0].text, '如是\n树给');
      expect(out[0].segments, hasLength(2));
      expect(out[0].segments[0].para, 0);
      expect(out[0].segments[1].para, 2);
    });

    test('连段簇内部分画线也合并为本簇一条，段序保持', () {
      const tight = {0, 1};
      const clusterItems = [
        {
          'index': 1,
          'underlines': [
            {'start': 0, 'end': 4},
          ],
        },
      ];
      final out = buildLiveHighlights(paragraphs, tight, clusterItems);
      expect(out.length, 1);
      expect(out[0].text, '一时佛在');
      expect(out[0].segments[0].para, 1);
    });
  });

  group('实时感想重建 buildLiveThoughts', () {
    const thoughtParagraphs = ['第一段', '第二段', '第三段'];
    const thoughtItems = [
      {'index': 0, 'note': '  好  '},
      {'index': 2, 'note': '妙'},
      {'index': 1, 'note': '  '},
      {'index': 99, 'note': '越界'},
    ];

    test('过滤空感想并按段落顺序输出', () {
      final out = buildLiveThoughts(thoughtParagraphs, const {}, thoughtItems);
      expect(out.length, 2);
      expect(out[0].paragraph, '第一段');
      expect(out[0].note, '好');
      expect(out[1].paragraph, '第三段');
      expect(out[1].note, '妙');
    });

    test('没有感想时返回空列表', () {
      expect(buildLiveThoughts(thoughtParagraphs, const {}, const []), isEmpty);
    });

    test('感想所在段位于连段簇内时，用整簇文本作为经文展示', () {
      const tight = {0, 1}; // 段0-1-2 相连（段1与段2由索引2连到3）。
      final out = buildLiveThoughts(
          ['第一段', '第二段', '第三段'], tight, const [
        {'index': 1, 'note': '妙'},
      ]);
      expect(out.length, 1);
      expect(out[0].paragraph, '第一段\n第二段\n第三段');
      expect(out[0].para, 1);
    });
  });

  group('作者笔记多 key 并集合并 mergeParagraphNotes', () {
    // 回归：分享帖标题是展示名，与读经页存笔记的 key 未必逐字相等。
    // 若只按帖子标题查，作者明明有画线却查到空 → 误报「作者已删除全部画线」。
    test('帖子标题命中空、带编号 key 命中真实笔记时也能找回（不再误判已删除）', () {
      const results = {
        // 帖子标题（展示名「地藏菩萨本愿经」）：作者笔记不在这把 key 下。
        '地藏菩萨本愿经': <Map<String, dynamic>>[],
        // 读经页实际存储 key：基础经名 + CBETA 编号。
        '地藏菩萨本愿经T13n0412_001': <Map<String, dynamic>>[
          {
            'index': 0,
            'underlines': [
              {'start': 0, 'end': 4},
            ],
          },
        ],
      };
      final out = mergeParagraphNotes(results, defaultKey: '地藏菩萨本愿经');
      expect(out.items, hasLength(1));
      expect(out.items[0]['index'], 0);
      expect(out.items[0]['underlines'], hasLength(1));
      // 主 key 指向真实数据所在的位置，供页内删除写回同一处。
      expect(out.key, '地藏菩萨本愿经T13n0412_001');
      expect(buildLiveHighlights(
              ['如是我闻', '第二段'], const {}, out.items),
          hasLength(1));
    });

    test('同一段多 key 命中时画线区间去重合并', () {
      const results = {
        // 主 key 取「先命中的非空候选」（作者笔记实际所在那把 key）。
        '经名': <Map<String, dynamic>>[
          {
            'index': 0,
            'underlines': [
              {'start': 0, 'end': 2},
            ],
          },
        ],
        '经名T99n0001_001': <Map<String, dynamic>>[
          {
            'index': 0,
            'underlines': [
              {'start': 0, 'end': 2}, // 重复区间
              {'start': 3, 'end': 4}, // 补充区间
            ],
          },
        ],
      };
      final out = mergeParagraphNotes(results, defaultKey: '经名');
      expect(out.items, hasLength(1));
      expect(out.items[0]['underlines'], hasLength(2));
      expect(out.key, '经名');
    });

    test('主 key 取先命中且有数据的候选', () {
      const results = {
        '经名': <Map<String, dynamic>>[
          {'index': 0},
        ],
        '经名T99n0001_001': <Map<String, dynamic>>[
          {'index': 0},
          {'index': 1},
        ],
      };
      final out = mergeParagraphNotes(results, defaultKey: '经名');
      expect(out.key, '经名');
      expect(out.items, hasLength(2));
      expect(out.items[1]['index'], 1);
    });

    test('所有候选都拉取失败时返回空条目、主 key 用默认标题', () {
      final out = mergeParagraphNotes(
          const <String, List<Map<String, dynamic>>>{}, defaultKey: '经名');
      expect(out.items, isEmpty);
      expect(out.key, '经名');
    });
  });
}