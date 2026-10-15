import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/sutra_availability.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return Directory.systemTemp.path;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
  });

  group('resolveSutraId', () {
    test('从路径中提取规范 ID', () async {
      final id = await resolveSutraId(
        title: '金刚般若波罗蜜经',
        filePath: 'assets/sutras_ascii/T08/T08n0235_001.txt',
      );
      expect(id, 'T08n0235_001');
    });

    test('从标题中提取规范 ID', () async {
      final id = await resolveSutraId(
        title: '地藏菩萨本愿经T13n0412_001',
        filePath: '',
      );
      expect(id, 'T13n0412_001');
    });
  });

  group('isSutraDownloaded 统一口径', () {
    test('持久化的已下载 ID 记录也视为已下载', () async {
      SharedPreferences.setMockInitialValues({
        kDownloadedSutraIdsKey: ['T08n0235_001'],
      });
      final ok = await isSutraDownloaded(
        title: '金刚般若波罗蜜经',
        filePath: 'assets/sutras_ascii/T08/T08n0235_001.txt',
      );
      expect(ok, true);
    });

    test('磁盘存在下载副本时视为已下载（不依赖持久化记录）', () async {
      SharedPreferences.setMockInitialValues({});
      final file = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}sutras'
          '${Platform.pathSeparator}T08${Platform.pathSeparator}T08n0235_001.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString('正文');
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });
      final ok = await isSutraDownloaded(
        title: '金刚般若波罗蜜经',
        filePath: 'assets/sutras_ascii/T08/T08n0235_001.txt',
      );
      expect(ok, true);
    });

    test('未下载时返回 false', () async {
      SharedPreferences.setMockInitialValues({});
      final ok = await isSutraDownloaded(
        title: '某部未下载经T99n9999_001',
        filePath: 'assets/sutras_ascii/T99/T99n9999_001.txt',
      );
      expect(ok, false);
    });
  });

  test('markSutraDownloaded 写入统一记录', () async {
    SharedPreferences.setMockInitialValues({});
    await markSutraDownloaded('T08n0235_001');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(kDownloadedSutraIdsKey), contains('T08n0235_001'));
  });
}
