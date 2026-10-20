import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/shanzhishi_mantra_store.dart';
import 'package:my_flutter_app/shanzhishi_store.dart';
import 'package:my_flutter_app/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShanZhiShiStore.instance.resetForTest();
    ShanZhiShiMantraStore.instance.resetForTest();
  });

  group('善知识云端恢复', () {
    test('首次种子在云端有名单时被覆盖，并清除临时标记', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      expect(store.length, 113);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(ShanZhiShiStore.provisionalMarkerKey), isTrue);

      final cloud = <String, dynamic>{
        'prefs': <String, dynamic>{
          'shanzhishi_names': jsonEncode([
            {
              'name': '云端菩萨',
              'sutras': ['地藏菩萨本愿经'],
              'createdAt': 1,
            }
          ]),
        },
      };
      expect(await SyncService.instance.applyCloudForTest(cloud), isTrue);
      expect(prefs.getBool(ShanZhiShiStore.provisionalMarkerKey), isNull);

      await store.reload();
      expect(store.length, 1);
      expect(store[0]!.name, '云端菩萨');
    });

    test('用户改过名单后保留本地数据，不被云端旧名单覆盖', () async {
      final store = ShanZhiShiStore.instance;
      await store.load();
      await store.add('本地新增菩萨', const []);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(ShanZhiShiStore.provisionalMarkerKey), isNull);

      final cloud = <String, dynamic>{
        'prefs': <String, dynamic>{
          'shanzhishi_names': jsonEncode([
            {
              'name': '云端旧菩萨',
              'sutras': const <String>[],
              'createdAt': 1,
            }
          ]),
        },
      };
      await SyncService.instance.applyCloudForTest(cloud);
      await store.reload();

      expect(store.entries.any((e) => e.name == '本地新增菩萨'), isTrue);
      expect(store.entries.any((e) => e.name == '云端旧菩萨'), isFalse);
    });

    test('密咒仓库 reload 后能看到云端恢复的自建密咒', () async {
      final store = ShanZhiShiMantraStore.instance;
      await store.load();
      expect(store.mantras.contains('云端密咒'), isFalse);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'shanzhishi_mantra_entries',
        jsonEncode([
          {'id': 'cloud_1', 'name': '云端密咒'}
        ]),
      );
      await store.reload();
      expect(store.mantras, contains('云端密咒'));

      await prefs.setString('shanzhishi_mantra_entries', '[]');
      await store.reload();
      expect(store.mantras.contains('云端密咒'), isFalse);
    });
  });

  group('经书状态云端合并', () {
    test('本地与云端的已读/收藏/置顶状态取并集', () async {
      SharedPreferences.setMockInitialValues({
        'sutra_states': jsonEncode({
          '本地经': {'r': true, 'rt': '2026-10-01T00:00:00.000'}
        }),
      });

      final cloud = <String, dynamic>{
        'prefs': <String, dynamic>{
          'sutra_states': jsonEncode({
            '本地经': {'f': true},
            '云端经': {'p': true},
          }),
        },
      };
      await SyncService.instance.applyCloudForTest(cloud);

      final prefs = await SharedPreferences.getInstance();
      final merged =
          jsonDecode(prefs.getString('sutra_states')!) as Map<String, dynamic>;
      expect(merged['本地经']['r'], isTrue);
      expect(merged['本地经']['f'], isTrue);
      expect(merged['本地经']['rt'], '2026-10-01T00:00:00.000');
      expect(merged['云端经']['p'], isTrue);
    });
  });

  group('学习天数云端合并', () {
    test('云端累计天数更大时采用云端，并保留日期供 reload 补记今天', () async {
      SharedPreferences.setMockInitialValues({
        'study_day_count': 1,
        'study_last_date': '2026-10-20',
        '_provisional_study_day': true,
      });

      final cloud = <String, dynamic>{
        'prefs': <String, dynamic>{
          'study_day_count': 100,
          'study_last_date': '2026-10-19',
        },
      };
      expect(await SyncService.instance.applyCloudForTest(cloud), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('study_day_count'), 100);
      expect(prefs.getString('study_last_date'), '2026-10-19');
      expect(prefs.getBool('_provisional_study_day'), isNull);
    });

    test('本地累计天数更大时保留本地，仅清除临时标记', () async {
      SharedPreferences.setMockInitialValues({
        'study_day_count': 200,
        'study_last_date': '2026-10-20',
        '_provisional_study_day': true,
      });

      final cloud = <String, dynamic>{
        'prefs': <String, dynamic>{
          'study_day_count': 100,
          'study_last_date': '2026-10-19',
        },
      };
      await SyncService.instance.applyCloudForTest(cloud);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('study_day_count'), 200);
      expect(prefs.getString('study_last_date'), '2026-10-20');
      expect(prefs.getBool('_provisional_study_day'), isNull);
    });
  });
}
