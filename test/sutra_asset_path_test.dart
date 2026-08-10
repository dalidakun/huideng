import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/sutra_asset_path.dart';
import 'package:my_flutter_app/sutra_downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SutraAssetPath.resolve', () {
    test('legacy Chinese asset path maps to ASCII path by ID', () {
      expect(
        SutraAssetPath.resolve(
          title: '一切流摄守因经T01n0031_001',
          filePath: 'assets/大正藏经简体txt/T01阿含部类/一切流摄守因经T01n0031_001.txt',
        ),
        'assets/sutras_ascii/T01/T01n0031_001.txt',
      );
    });

    test('local download absolute path with ID maps to ASCII path', () {
      // 旧版本曾把本机绝对路径写进 prefs 并同步到云端，重新登录/换机后
      // 恢复出来的是别的设备上的绝对路径，必须能按 ID 归一到下载目录。
      expect(
        SutraAssetPath.resolve(
          title: '中阿含经T01n0026_001',
          filePath: '/data/user/0/com.example/app_flutter/sutras/T01/T01n0026_001.txt',
        ),
        'assets/sutras_ascii/T01/T01n0026_001.txt',
      );
    });

    test('user-picked local file without ID stays unchanged', () {
      final p = '/storage/emulated/0/Download/自选经文.txt';
      expect(
        SutraAssetPath.resolve(title: '自选经文', filePath: p),
        p,
      );
    });

    test('null filePath resolves from title ID', () {
      expect(
        SutraAssetPath.resolve(title: '七佛经T01n0002_001'),
        'assets/sutras_ascii/T01/T01n0002_001.txt',
      );
    });
  });

  group('SutraDownloader.progressFromDailyHistory', () {
    test('restores latest non-zero progress after reinstall', () async {
      SharedPreferences.setMockInitialValues({
        'daily_sutra_history': jsonEncode({
          '2026-08-06': [
            {
              'title': '地藏菩萨本愿经T13n0412_001',
              'filePath': 'assets/sutras_ascii/T13/T13n0412_001.txt',
              'progress': 0.0,
            }
          ],
          '2026-08-07': [
            {
              'title': '地藏菩萨本愿经T13n0412_001',
              'filePath': 'assets/sutras_ascii/T13/T13n0412_001.txt',
              'progress': 0.1639151395797945,
            }
          ],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        SutraDownloader.progressFromDailyHistory(
            prefs, '地藏菩萨本愿经T13n0412_001'),
        closeTo(0.1639, 0.0001),
      );
      expect(SutraDownloader.progressFromDailyHistory(prefs, '不存在的经'), 0.0);
    });

    test('returns 0 when history is empty or corrupt', () async {
      SharedPreferences.setMockInitialValues({'daily_sutra_history': '{}'});
      final prefs = await SharedPreferences.getInstance();
      expect(SutraDownloader.progressFromDailyHistory(prefs, '任何经'), 0.0);
      SharedPreferences.setMockInitialValues(
          {'daily_sutra_history': 'not json'});
      final prefs2 = await SharedPreferences.getInstance();
      expect(SutraDownloader.progressFromDailyHistory(prefs2, '任何经'), 0.0);
    });
  });

  group('SutraDownloader.latestProgressForPath', () {
    const localPath =
        '/data/user/0/com.example/app_flutter/sutras/T13/T13n0412_001.txt';
    const assetPath = 'assets/sutras_ascii/T13/T13n0412_001.txt';
    const title = '地藏菩萨本愿经T13n0412_001';

    test('latest canonical progress wins over older higher variant', () async {
      // 本地路径是最近一次阅读使用的路径（进度 0.07 为最新），
      // 资产路径下残留更早会话的 0.16，不能覆盖最新进度。
      SharedPreferences.setMockInitialValues({
        'progress_$localPath': 0.07,
        'progress_$assetPath': 0.16,
      });
      final prefs = await SharedPreferences.getInstance();
      final p =
          await SutraDownloader.latestProgressForPath(prefs, localPath,
              title: title);
      expect(p, closeTo(0.07, 1e-9));
    });

    test('canonical zero is honored as latest (closed at top of book)', () async {
      SharedPreferences.setMockInitialValues({
        'progress_$localPath': 0.0,
        'progress_$assetPath': 0.16,
      });
      final prefs = await SharedPreferences.getInstance();
      final p =
          await SutraDownloader.latestProgressForPath(prefs, localPath,
              title: title);
      expect(p, 0.0);
    });

    test('falls back to old key variant when canonical key is missing',
        () async {
      SharedPreferences.setMockInitialValues({'progress_$assetPath': 0.16});
      final prefs = await SharedPreferences.getInstance();
      final p =
          await SutraDownloader.latestProgressForPath(prefs, localPath,
              title: title);
      expect(p, closeTo(0.16, 1e-9));
    });

    test('falls back to daily history when all progress keys are missing',
        () async {
      SharedPreferences.setMockInitialValues({
        'daily_sutra_history': jsonEncode({
          '2026-08-07': [
            {'title': title, 'filePath': assetPath, 'progress': 0.1639151395797945},
          ],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final p =
          await SutraDownloader.latestProgressForPath(prefs, localPath,
              title: title);
      expect(p, closeTo(0.1639, 0.0001));
    });
  });
}