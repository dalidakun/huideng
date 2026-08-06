import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:my_flutter_app/image_crop_page.dart';

Uint8List _makeImage(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(120, 80, 40));
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  group('ImageCropPage', () {
    testWidgets('square crop of wide image returns square JPEG', (tester) async {
      final bytes = _makeImage(800, 400);
      Uint8List? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<Uint8List>(
                    MaterialPageRoute(
                      builder: (_) => ImageCropPage(
                          bytes: bytes, ratio: 1.0, maxOutput: 256),
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          );
        }),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // 初始矩阵应把图片居中：宽图 1200x600 铺进 600x600 裁剪框，
      // 水平位移 (600-1200)/2=-300，垂直 0。默认测试画布 800x600。
      expect(result, isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      final decoded = img.decodeImage(result!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 256);
      expect(decoded.height, 256);
    });

    testWidgets('banner crop keeps wide ratio and fits maxOutput', (tester) async {
      final bytes = _makeImage(800, 800);
      Uint8List? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<Uint8List>(
                    MaterialPageRoute(
                      builder: (_) => ImageCropPage(
                          bytes: bytes, ratio: 2.5, maxOutput: 800),
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          );
        }),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      final decoded = img.decodeImage(result!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 800);
      expect(decoded.height, 320);
    });

    testWidgets('cancel returns null without saving', (tester) async {
      final bytes = _makeImage(200, 200);
      Uint8List? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<Uint8List>(
                    MaterialPageRoute(
                      builder: (_) =>
                          ImageCropPage(bytes: bytes, ratio: 1.0),
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          );
        }),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('crop follows pan: showing right half yields right half output',
        (tester) async {
      // 宽图 1200x800：左 1/3 红、中 1/3 绿、右 1/3 蓝。
      final image = img.Image(width: 1200, height: 800);
      for (var y = 0; y < 800; y++) {
        for (var x = 0; x < 1200; x++) {
          final c = x < 400
              ? img.ColorRgb8(255, 0, 0)
              : (x < 800 ? img.ColorRgb8(0, 255, 0) : img.ColorRgb8(0, 0, 255));
          image.setPixel(x, y, c);
        }
      }
      final bytes = Uint8List.fromList(img.encodeJpg(image));

      Uint8List? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<Uint8List>(
                    MaterialPageRoute(
                      builder: (_) => ImageCropPage(
                          bytes: bytes, ratio: 1.0, maxOutput: 400),
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          );
        }),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // 默认测试画布 800x600：裁剪框 600x600，cover 铺满 => 子图 900x600。
      // 模拟手势产生的矩阵：T(t)·S(z)。把图向左拖到头（t.x = Fw - W = -300），
      // 可见区域应为图片右侧：源坐标 x ∈ [400, 1200]。
      final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer));
      viewer.transformationController!.value = Matrix4.identity()
        ..translateByDouble(-300, 0, 0, 1);
      await tester.pump();

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      final out = img.decodeImage(result!)!;
      // 左边缘应来自绿色带（源 x=400），右边缘来自蓝色带（源 x=1200）。
      final left = out.getPixel(0, out.height ~/ 2);
      final right = out.getPixel(out.width - 1, out.height ~/ 2);
      expect(left.g, greaterThan(150));
      expect(left.r, lessThan(100));
      expect(left.b, lessThan(100));
      expect(right.b, greaterThan(150));
      expect(right.r, lessThan(100));
      expect(right.g, lessThan(100));
    });

    testWidgets('crop follows zoom: 2x centered shows only red quadrant',
        (tester) async {
      // 800x800：左上 1/4 红，其余绿。
      final image = img.Image(width: 800, height: 800);
      for (var y = 0; y < 800; y++) {
        for (var x = 0; x < 800; x++) {
          final c = (x < 400 && y < 400)
              ? img.ColorRgb8(255, 0, 0)
              : img.ColorRgb8(0, 255, 0);
          image.setPixel(x, y, c);
        }
      }
      final bytes = Uint8List.fromList(img.encodeJpg(image));

      Uint8List? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<Uint8List>(
                    MaterialPageRoute(
                      builder: (_) => ImageCropPage(
                          bytes: bytes, ratio: 1.0, maxOutput: 256),
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          );
        }),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // 2x 放大且不偏移：可见 300x300 子区域 = 源坐标 (0,0,400,400) = 纯红。
      final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer));
      viewer.transformationController!.value = Matrix4.identity()
        ..translateByDouble(0, 0, 0, 1)
        ..scaleByDouble(2, 2, 2, 1);
      await tester.pump();

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      final out = img.decodeImage(result!)!;
      // 整图应为红色。
      var redPixels = 0;
      var nonRedPixels = 0;
      for (var y = 0; y < out.height; y += 8) {
        for (var x = 0; x < out.width; x += 8) {
          final p = out.getPixel(x, y);
          if (p.r > 150 && p.g < 100 && p.b < 100) {
            redPixels++;
          } else {
            nonRedPixels++;
          }
        }
      }
      expect(nonRedPixels, 0,
          reason: '2x 放大不偏移时应只看到红色象限，实际非红像素 $nonRedPixels');
      expect(redPixels, greaterThan(0));
    });

    testWidgets('loads from filePath and crops', (tester) async {
      final file = File('${Directory.systemTemp.path}/crop_test.jpg');
      await tester.runAsync(() => file.writeAsBytes(_makeImage(600, 400)));
      addTearDown(() {
        try {
          if (file.existsSync()) file.deleteSync();
        } catch (_) {}
      });

      Uint8List? result;
      // 整个交互放进 runAsync：让裁剪页内真实的文件读取能够完成。
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Builder(builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<Uint8List>(
                      MaterialPageRoute(
                        builder: (_) => ImageCropPage(
                            filePath: file.path, ratio: 1.0, maxOutput: 128),
                      ),
                    );
                  },
                  child: const Text('go'),
                ),
              ),
            );
          }),
        ));
        await tester.tap(find.text('go'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400)); // 路由过渡
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(find.text('完成'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      });

      expect(result, isNotNull);
      final out = img.decodeImage(result!)!;
      expect(out.width, 128);
      expect(out.height, 128);
    });

    testWidgets('embedded mode calls onResult without popping routes',
        (tester) async {
      final bytes = _makeImage(300, 300);
      Uint8List? croppedOut;
      var cancelled = false;
      // 用路由模拟「上一页」：裁剪页内嵌在页面里，确认时不得 pop 任何路由。
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return ImageCropPage(
            bytes: bytes,
            ratio: 1.0,
            maxOutput: 64,
            onResult: (out) => croppedOut = out,
            onCancel: () => cancelled = true,
          );
        }),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('完成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(croppedOut, isNotNull);
      expect(cancelled, isFalse);
      // 页面仍在原位（未被 pop）。
      expect(find.byType(ImageCropPage), findsOneWidget);
      final out = img.decodeImage(croppedOut!)!;
      expect(out.width, 64);
      expect(out.height, 64);
    });

    testWidgets('embedded mode cancel calls onCancel without popping',
        (tester) async {
      final bytes = _makeImage(300, 300);
      var cancelled = false;
      await tester.pumpWidget(MaterialApp(
        home: ImageCropPage(
          bytes: bytes,
          ratio: 1.0,
          onCancel: () => cancelled = true,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('取消'));
      await tester.pump();

      expect(cancelled, isTrue);
      expect(find.byType(ImageCropPage), findsOneWidget);
    });
  });
}
