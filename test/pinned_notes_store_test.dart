import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/pinned_notes_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PinnedNotesStore.debugReset();
  });

  test('置顶新内容会替换旧置顶，始终只保留一条', () async {
    expect(await PinnedNotesStore.toggle('note-a'), isTrue);
    expect(await PinnedNotesStore.load(), {'note-a'});
    expect(PinnedNotesStore.isPinned('note-a'), isTrue);

    // 置顶 B：A 的置顶必须自动取消（不是再新增一条）。
    expect(await PinnedNotesStore.toggle('note-b'), isTrue);
    expect(await PinnedNotesStore.load(), {'note-b'});
    expect(PinnedNotesStore.isPinned('note-b'), isTrue);
    expect(PinnedNotesStore.isPinned('note-a'), isFalse);
    expect(PinnedNotesStore.currentId, 'note-b');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PinnedNotesStore.storageKey), ['note-b']);
  });

  test('再次点击同一条置顶会取消置顶', () async {
    await PinnedNotesStore.toggle('note-a');

    expect(await PinnedNotesStore.toggle('note-a'), isFalse);
    expect(await PinnedNotesStore.load(), isEmpty);
    expect(PinnedNotesStore.currentId, isEmpty);
  });

  test('内存缓存同步可读：不 await 也能判断当前置顶', () async {
    // 模拟「列表页在置顶后立即重建」：不等待 load()，直接同步判断。
    await PinnedNotesStore.toggle('note-a');
    expect(PinnedNotesStore.isPinned('note-a'), isTrue);
    expect(PinnedNotesStore.isPinned('note-b'), isFalse);
  });

  test('删除内容只清理与它匹配的置顶记录', () async {
    await PinnedNotesStore.toggle('note-a');
    await PinnedNotesStore.remove('note-b');
    expect(PinnedNotesStore.currentId, 'note-a');

    await PinnedNotesStore.remove('note-a');
    expect(PinnedNotesStore.currentId, isEmpty);
  });

  test('连续置顶/取消串行落盘，不会互相覆盖', () async {
    // 连点：置顶 a → 置顶 b → 取消 b。最终必须是没有置顶，而不是残留 a 或 b。
    final futures = <Future<bool>>[
      PinnedNotesStore.toggle('note-a'),
      PinnedNotesStore.toggle('note-b'),
      PinnedNotesStore.toggle('note-b'),
    ];
    await Future.wait(futures);

    expect(PinnedNotesStore.currentId, isEmpty);
    expect(await PinnedNotesStore.load(), isEmpty);
  });

  test('兼容旧版本残留的多条置顶：只认最后一条并规整为单条', () async {
    SharedPreferences.setMockInitialValues({
      PinnedNotesStore.storageKey: ['old-a', 'old-b'],
    });
    PinnedNotesStore.debugReset();

    expect(await PinnedNotesStore.load(), {'old-b'});
    expect(PinnedNotesStore.isPinned('old-b'), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PinnedNotesStore.storageKey), ['old-b']);
  });

  test('置顶/取消置顶都会 bump revision，让各页面即时刷新', () async {
    final before = PinnedNotesStore.revision.value;
    await PinnedNotesStore.toggle('note-a');
    await PinnedNotesStore.toggle('note-a');
    expect(PinnedNotesStore.revision.value, before + 2);
  });

  group('三点菜单的置顶入口：只有帖子能置顶，回复帖不出现置顶', () {
    test('帖子（非回复）始终显示置顶入口', () {
      expect(PinnedNotesStore.showsPinEntry('post-a', isReply: false), isTrue);
      expect(PinnedNotesStore.showsPinEntry('post-a', isReply: true), isFalse);
    });

    test('回复帖不显示置顶；历史遗留的已置顶回复仍可取消', () async {
      // 未置顶的回复：菜单里不该出现置顶。
      expect(PinnedNotesStore.showsPinEntry('reply-a', isReply: true), isFalse);

      // 旧版本置顶过的回复：显示「取消置顶」，避免取消不掉。
      await PinnedNotesStore.toggle('reply-a');
      expect(PinnedNotesStore.showsPinEntry('reply-a', isReply: true), isTrue);
      // 同一时间别的帖子仍可置顶。
      expect(PinnedNotesStore.showsPinEntry('post-b', isReply: false), isTrue);
    });
  });
}
