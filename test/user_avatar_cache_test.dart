import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/cloud_notes_service.dart';
import 'package:my_flutter_app/user_avatar_cache.dart';

void main() {
  group('UserAvatarCache', () {
    late List<String> fetchedBatches;
    late Map<String, String> avatars;

    setUp(() {
      UserAvatarCache.instance.resetForTest();
      fetchedBatches = [];
      avatars = {
        'u1': 'b64-avatar-1',
        'u2': 'b64-avatar-2',
      };
      UserAvatarCache.instance.fetcher = (ids) async {
        fetchedBatches.add(ids.join(','));
        return ids
            .map((id) => UserProfile(
                  id: id,
                  name: 'n$id',
                  avatar: avatars[id] ?? '',
                ))
            .toList();
      };
    });

    test('batches multiple requests into one fetch', () async {
      final cache = UserAvatarCache.instance;
      cache.request('u1');
      cache.request('u2');
      cache.request('u1'); // 去重
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fetchedBatches, ['u1,u2']);
      expect(cache.peek('u1'), 'b64-avatar-1');
      expect(cache.peek('u2'), 'b64-avatar-2');
    });

    test('cached result returned immediately without refetch', () async {
      final cache = UserAvatarCache.instance;
      cache.request('u1');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fetchedBatches.length, 1);

      // 第二次请求直接命中缓存，不再拉取。
      final direct = cache.request('u1');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(direct, 'b64-avatar-1');
      expect(fetchedBatches.length, 1);
    });

    test('users without avatar are not refetched within TTL', () async {
      final cache = UserAvatarCache.instance;
      cache.request('u3'); // 无头像
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(cache.peek('u3'), isNull);
      expect(fetchedBatches.length, 1);

      cache.request('u3');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fetchedBatches.length, 1, reason: 'TTL 内不重复拉取');
    });

    test('invalidate clears cache and allows refetch', () async {
      final cache = UserAvatarCache.instance;
      cache.request('u1');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fetchedBatches.length, 1);

      cache.invalidate('u1');
      cache.request('u1');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fetchedBatches.length, 2);
    });
  });
}
