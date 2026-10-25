import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/update_service.dart';

/// 后台下载状态与「下载完成提示安装」的回归测试。
///
/// 真正的下载走系统 DownloadManager，无法在单元测试里跑；
/// 这里覆盖纯逻辑（状态文案）与界面提示（下载完成 → 弹窗提示安装）。
void main() {
  tearDown(() {
    UpdateService.downloadStatus.value = UpdateDownloadStatus.idle;
  });

  group('UpdateDownloadStatus', () {
    test('百分比与大小文案', () {
      const status = UpdateDownloadStatus(
        phase: UpdateDownloadPhase.downloading,
        progress: 0.456,
        received: 12 * 1024 * 1024,
        total: 60 * 1024 * 1024,
      );
      expect(status.percentText, '46%');
      expect(status.sizeText, '12.0 MB / 60.0 MB');
      expect(status.isDownloading, isTrue);
      expect(status.isCompleted, isFalse);
    });

    test('总大小未知时只显示已下载量', () {
      const status = UpdateDownloadStatus(
        phase: UpdateDownloadPhase.downloading,
        received: 2048,
      );
      expect(status.sizeText, '2 KB');
    });

    test('copyWith 只改指定字段', () {
      const status = UpdateDownloadStatus(
        phase: UpdateDownloadPhase.downloading,
        version: '1.4.1',
        progress: 0.1,
      );
      final next = status.copyWith(progress: 0.9);
      expect(next.phase, UpdateDownloadPhase.downloading);
      expect(next.version, '1.4.1');
      expect(next.progress, 0.9);
    });
  });

  group('UpdateInstallPrompt', () {
    testWidgets('后台下载完成后弹窗提示安装', (tester) async {
      UpdateService.downloadStatus.value = const UpdateDownloadStatus(
        phase: UpdateDownloadPhase.completed,
        version: '9.9.9',
        progress: 1,
        path: '/tmp/huideng_v9.9.9.apk',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: UpdateInstallPrompt(child: Scaffold(body: Text('主页'))),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('v9.9.9'), findsOneWidget);
      expect(find.text('立即安装'), findsOneWidget);
      expect(find.text('稍后安装'), findsOneWidget);
    });

    testWidgets('下载中不打扰，下载完成后才弹安装提示', (tester) async {
      UpdateService.downloadStatus.value = const UpdateDownloadStatus(
        phase: UpdateDownloadPhase.downloading,
        version: '9.9.6',
        progress: 0.3,
        received: 30,
        total: 100,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: UpdateInstallPrompt(child: Scaffold(body: Text('主页'))),
        ),
      );
      await tester.pumpAndSettle();
      // 下载过程中不弹任何提示。
      expect(find.text('立即安装'), findsNothing);

      // 后台下载完成：状态从 downloading 转为 completed。
      UpdateService.downloadStatus.value = const UpdateDownloadStatus(
        phase: UpdateDownloadPhase.completed,
        version: '9.9.6',
        progress: 1,
        path: '/tmp/huideng_v9.9.6.apk',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('v9.9.6'), findsOneWidget);
      expect(find.text('立即安装'), findsOneWidget);
    });

    testWidgets('更新弹窗正开着时不再叠一层提示', (tester) async {
      UpdateService.markDialogVisible(true);
      addTearDown(() => UpdateService.markDialogVisible(false));
      UpdateService.downloadStatus.value = const UpdateDownloadStatus(
        phase: UpdateDownloadPhase.completed,
        version: '9.9.8',
        progress: 1,
        path: '/tmp/huideng_v9.9.8.apk',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: UpdateInstallPrompt(child: Scaffold(body: Text('主页'))),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('v9.9.8'), findsNothing);
    });

    testWidgets('同一次下载只提示一次，稍后安装不会反复弹', (tester) async {      UpdateService.downloadStatus.value = const UpdateDownloadStatus(
        phase: UpdateDownloadPhase.completed,
        version: '9.9.7',
        progress: 1,
        path: '/tmp/huideng_v9.9.7.apk',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: UpdateInstallPrompt(child: Scaffold(body: Text('主页'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('稍后安装'), findsOneWidget);

      await tester.tap(find.text('稍后安装'));
      await tester.pumpAndSettle();
      expect(find.text('稍后安装'), findsNothing);

      // 状态再变化一次（例如轮询刷新），同一路径不应再次弹窗。
      UpdateService.downloadStatus.value =
          UpdateService.downloadStatus.value.copyWith(progress: 1);
      await tester.pumpAndSettle();
      expect(find.text('稍后安装'), findsNothing);
    });
  });

  group('UpdateDialog 按钮', () {
    const info = UpdateInfo(
      version: '2.0.0',
      versionCode: 99,
      downloadPage: 'https://example.com/download.html',
      downloadUrl: 'https://example.com/huideng.apk',
      notes: '修复若干问题',
    );

    Future<void> pumpDialog(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: UpdateDialog(info: info)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('还没开始下载时没有「后台下载」', (tester) async {
      UpdateService.downloadStatus.value = UpdateDownloadStatus.idle;
      await pumpDialog(tester);

      expect(find.text('稍后再说'), findsOneWidget);
      expect(find.text('立即下载'), findsOneWidget);
      expect(find.text('后台下载'), findsNothing);
    });

    testWidgets('下载过程中才出现「后台下载」', (tester) async {
      UpdateService.downloadStatus.value = const UpdateDownloadStatus(
        phase: UpdateDownloadPhase.downloading,
        version: '2.0.0',
        progress: 0.4,
        received: 40,
        total: 100,
      );
      await pumpDialog(tester);

      expect(find.text('后台下载'), findsOneWidget);
      expect(find.text('取消下载'), findsOneWidget);
      expect(find.text('立即下载'), findsNothing);
      expect(find.textContaining('正在下载 40%'), findsOneWidget);
    });

    testWidgets('下载完成后按钮变成「立即安装」', (tester) async {
      UpdateService.downloadStatus.value = const UpdateDownloadStatus(
        phase: UpdateDownloadPhase.completed,
        version: '2.0.0',
        progress: 1,
        path: '/tmp/huideng_v2.0.0.apk',
      );
      await pumpDialog(tester);

      expect(find.text('立即安装'), findsOneWidget);
      expect(find.text('稍后安装'), findsOneWidget);
      expect(find.text('后台下载'), findsNothing);
    });
  });

  group('自动检查频率', () {
    test('从未检查过时立即检查', () {
      expect(
        UpdateService.isAutoCheckDue(
          lastCheckAt: 0,
          now: DateTime(2026, 10, 25, 12),
        ),
        isTrue,
      );
    });

    test('不满一周不重复检查', () {
      final now = DateTime(2026, 10, 25, 12);
      final last = now.subtract(const Duration(days: 6, hours: 23));
      expect(
        UpdateService.isAutoCheckDue(
          lastCheckAt: last.millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });

    test('满一周后再次检查', () {
      final now = DateTime(2026, 10, 25, 12);
      final last = now.subtract(const Duration(days: 7));
      expect(
        UpdateService.isAutoCheckDue(
          lastCheckAt: last.millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
    });
  });

  test('formatBytes 友好显示', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '2 KB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
  });
}
