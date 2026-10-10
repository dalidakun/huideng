import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/main.dart';
import 'package:my_flutter_app/reading_page.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// 测试环境没有云端后端：CloudBase SDK 走 dart:io 的 HttpClient 发请求。这里用
/// HttpOverrides 让所有请求立刻返回一个固定的「成功」JSON，云函数统一解析为空
/// 数据。这样既不会出现并发请求有一条先报错、抛未处理异步异常，也不会有请求
/// 悬挂而遗留 Dio 的 30s 超时定时器。
class _OkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpClientRequest();

  @override
  Future<void> close({bool force = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeHttpClientResponse();

  @override
  Future<HttpClientResponse> get done async => _FakeHttpClientResponse();

  int _contentLength = 0;

  @override
  int get contentLength => _contentLength;

  @override
  set contentLength(int? value) {
    if (value != null) _contentLength = value;
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  void write(Object? object) {}

  @override
  void add(List<int> data) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final List<int> _bytes = utf8.encode('{"result":{"ok":true}}');

  @override
  int get statusCode => 200;

  @override
  String get reasonPhrase => 'OK';

  @override
  int get contentLength => _bytes.length;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  HttpHeaders get headers =>
      _FakeHttpHeaders(seed: {HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8'});

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_bytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  _FakeHttpHeaders({Map<String, String>? seed}) {
    seed?.forEach((k, v) => _map[k.toLowerCase()] = [v]);
  }

  final Map<String, List<String>> _map = <String, List<String>>{};

  @override
  String? value(String name) {
    final list = _map[name.toLowerCase()];
    return (list == null || list.isEmpty) ? null : list.first;
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = true}) {
    _map
        .putIfAbsent(name.toLowerCase(), () => <String>[])
        .add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = true}) {
    _map[name.toLowerCase()] = [value.toString()];
  }

  bool contains(String name) => _map.containsKey(name.toLowerCase());

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  void remove(String name, Object? value) => _map.remove(name.toLowerCase());

  @override
  void removeAll(String name) => _map.remove(name.toLowerCase());

  @override
  void clear() => _map.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 取当前树上「圆形展开路由」裁剪出的圆直径（未展开时为 null）。
double? _revealDiameter(WidgetTester tester) {
  for (final clip in tester.widgetList<ClipPath>(find.byType(ClipPath))) {
    final clipper = clip.clipper;
    if (clipper == null) continue;
    if (!clipper.runtimeType.toString().contains('CircleRevealClipper')) {
      continue;
    }
    final b = clipper.getClip(const Size(400, 900)).getBounds();
    if (b.width <= 0) continue;
    if ((b.width - b.height).abs() > 0.5) continue;
    return b.width;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('右下角继续阅读按钮在正文就绪后以圆形逐渐展开打开阅读页', (tester) async {
    // 云函数统一返回「成功」空数据，避免测试环境网络失败/悬挂带来的干扰。
    HttpOverrides.global = _OkHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);

    // 读经页加载正文会调用 getApplicationDocumentsDirectory()，测试环境需 mock，
    // 否则正文加载卡住、就绪通知永不触发。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationSupportDirectory') {
        return Directory.systemTemp.path;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null));

    // 造一份真实存在的正文文件，作为「最近阅读」记录。
    final dir = Directory.systemTemp.createTempSync('reading_fab_reveal_');
    final file = File('${dir.path}/sutra.txt');
    final sb = StringBuffer();
    for (var i = 1; i <= 200; i++) {
      sb.writeln('第$i段正文内容，用来模拟较长经文以便观察首帧布局耗时。');
    }
    file.writeAsStringSync(sb.toString());
    addTearDown(() => dir.deleteSync(recursive: true));

    const title = '测试经·圆形展开';
    SharedPreferences.setMockInitialValues({
      'privacy_agreed_version': 1,
      'last_read_title': title,
      'last_read_filePath': file.path,
    });

    await tester.pumpWidget(const MyApp(privacyAgreed: true));
    // 过启动图（2s）+ 让最近阅读记录异步读完。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));

    final fabFinder = find.byWidgetPredicate(
      (w) => w is FloatingActionButton && w.heroTag == 'continue_reading_fab',
    );
    expect(fabFinder, findsOneWidget, reason: '首页右下角应有继续阅读按钮');
    expect(_revealDiameter(tester), isNull, reason: '点击前不应有圆形展开裁剪');

    await tester.tap(fabFinder);
    await tester.pump();

    // 正文尚未就绪：圆形应保持半径 0（不可见），避免「先冒小圆再猛地跳满」。
    expect(_revealDiameter(tester), isNull, reason: '正文未就绪时不应展开圆形');

    // 正文涉及真实文件 IO：用 runAsync 等它加载完成，再泵出首帧、派发就绪通知，
    // 圆形随后才开始生长。
    double? first;
    for (var i = 0; i < 30 && first == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 20));
      first = _revealDiameter(tester);
    }
    expect(first, isNotNull, reason: '正文就绪后应出现圆形裁剪');
    expect(first, greaterThan(0), reason: '圆应已从按钮处长出');

    await tester.pump(const Duration(milliseconds: 150));
    final second = _revealDiameter(tester);
    expect(second, isNotNull, reason: '展开过程中应一直存在圆形裁剪');
    expect(second, greaterThan(first!), reason: '圆应随时间逐渐放大');

    // 返回：圆形收回，顺带结束阅读页里的计时器。
    Navigator.of(tester.element(find.byType(ReadingPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReadingPage), findsNothing);

    // 释放整棵树并推进时间，冲掉遗留的异步计时器。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  });
}
