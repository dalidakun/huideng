import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/cloud_notes_service.dart';
import 'package:my_flutter_app/community_feed_cache.dart';

void main() {
  /// 造一条社区帖子，供缓存键与合并逻辑这些纯逻辑用例使用。
  PlazaNote note(String id) => PlazaNote(
        id: id,
        ownerUserId: 'u_$id',
        title: '',
        content: '正文 $id',
        authorName: '行深',
        visibility: 'public',
        status: 'published',
        likeCount: 0,
        commentCount: 0,
        createdAt: 1,
        updatedAt: 1,
      );

  setUp(CommunityFeedCache.clear);
  tearDown(CommunityFeedCache.clear);

  test('热门与最新各存各的，作废一份不牵连另一份', () {
    final hot = [note('h1')];
    final latest = [note('l1')];
    CommunityFeedCache.put('天台宗社区', 'hot', hot);
    CommunityFeedCache.put('天台宗社区', 'latest', latest);

    expect(CommunityFeedCache.peek('天台宗社区', 'hot'), hot);
    expect(CommunityFeedCache.peek('天台宗社区', 'latest'), latest);
    expect(CommunityFeedCache.peek('天台宗社区', 'hot'), isNot(latest),
        reason: '热门与最新是两份数据，不能互相顶掉');

    CommunityFeedCache.drop('天台宗社区', 'hot');
    expect(CommunityFeedCache.peek('天台宗社区', 'hot'), isNull);
    expect(CommunityFeedCache.peek('天台宗社区', 'latest'), latest,
        reason: '只作废热门，最新那份留着');
  });

  test('不同社区互不串数据', () {
    CommunityFeedCache.put('天台宗社区', 'hot', [note('a')]);
    CommunityFeedCache.put('华严宗社区', 'hot', [note('b')]);

    expect(CommunityFeedCache.peek('华严宗社区', 'hot')!.single.id, 'b');
    CommunityFeedCache.drop('华严宗社区', 'hot');
    expect(CommunityFeedCache.peek('华严宗社区', 'hot'), isNull);
    expect(CommunityFeedCache.peek('天台宗社区', 'hot'), hasLength(1),
        reason: '作废一个社区，另一个社区那份还在');
  });

  test('没缓存就是 null（打开社区页不能凭空有东西）', () {
    expect(CommunityFeedCache.peek('天台宗社区', 'hot'), isNull);
  });

  test('同一社区同一排序的并发只打一次云端', () async {
    var calls = 0;
    // 手动放行的 Completer 代替延时：更确定，也不受测试环境时钟影响。
    final gate = Completer<List<PlazaNote>>();
    Future<List<PlazaNote>> fetch() {
      calls++;
      return gate.future;
    }

    final a = CommunityFeedCache.coalesce('天台宗社区', 'hot', fetch);
    final b = CommunityFeedCache.coalesce('天台宗社区', 'hot', fetch);
    expect(identical(a, b), isTrue, reason: '第二次并发复用同一份在途请求');
    expect(calls, 1, reason: '只该打一次云端');

    gate.complete([note('n1')]);
    expect(await a, hasLength(1));
    expect(await b, hasLength(1));
    expect(calls, 1);
  });

  test('不同排序档 / 不同社区各自打各自的，不互相借用', () async {
    var calls = 0;
    final gate = Completer<List<PlazaNote>>();
    Future<List<PlazaNote>> fetch() {
      calls++;
      return gate.future;
    }

    final hot = CommunityFeedCache.coalesce('天台宗社区', 'hot', fetch);
    final latest = CommunityFeedCache.coalesce('天台宗社区', 'latest', fetch);
    final other = CommunityFeedCache.coalesce('华严宗社区', 'hot', fetch);
    expect(calls, 3, reason: '三个不同的键各打各的');
    expect(identical(latest, hot), isFalse);
    expect(identical(other, hot), isFalse);

    gate.complete([note('n1')]);
    await hot;
    await latest;
    await other;
  });

  test('跑完之后销掉在途登记，下一次会重新发起', () async {
    var calls = 0;
    Future<List<PlazaNote>> fetch() async {
      calls++;
      return [note('n$calls')];
    }

    final a = await CommunityFeedCache.coalesce('天台宗社区', 'hot', fetch);
    final b = await CommunityFeedCache.coalesce('天台宗社区', 'hot', fetch);
    expect(identical(a, b), isFalse, reason: '上一次已经结束了，不再合并');
    expect(calls, 2);
  });

  test('失败也销掉在途登记，不把后续请求卡死', () async {
    Future<List<PlazaNote>> boom() async => throw StateError('network down');

    await expectLater(
      CommunityFeedCache.coalesce('天台宗社区', 'hot', boom),
      throwsStateError,
    );

    var retried = false;
    final again = await CommunityFeedCache.coalesce('天台宗社区', 'hot', () async {
      retried = true;
      return [note('n1')];
    });
    expect(retried, isTrue, reason: '上一次失败不该留下登记把后续请求一起卡住');
    expect(again, hasLength(1));
  });
}