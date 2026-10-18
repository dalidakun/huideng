import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/shanzhishi_sphere.dart';

void main() {
  group('computeSphereLayout', () {
    for (final n in [0, 1, 2, 3, 5, 8, 50, 300, 1000]) {
      test('n=$n：每点在单位球上、纬度可达、相邻序号球面相邻', () {
        final layout = computeSphereLayout(n);
        expect(layout.n, n);
        expect(layout.points.length, n);
        if (n == 0) return;

        final yMax = math.sin(68 * math.pi / 180) + 1e-9;
        var sumMinDist = 0.0;
        for (var i = 0; i < n; i++) {
          final p = layout.points[i];
          final len = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
          expect(len, closeTo(1.0, 1e-9));
          // 纬度压缩在 ±68° 内：俯仰限位内每位都能转到球心。
          expect(p.y.abs(), lessThan(yMax));
          if (i > 0) {
            final q = layout.points[i - 1];
            final d = math.sqrt(math.pow(p.x - q.x, 2) +
                math.pow(p.y - q.y, 2) +
                math.pow(p.z - q.z, 2));
            sumMinDist += d;
          }
        }
        if (n >= 8) {
          // 斐波那契螺旋：相邻序号彼此相邻，不会东一个西一个。
          final avg = sumMinDist / (n - 1);
          final q = layout.points;
          final first = math.sqrt(
              math.pow(q[1].x - q[0].x, 2) +
                  math.pow(q[1].y - q[0].y, 2) +
                  math.pow(q[1].z - q[0].z, 2));
          expect(first, lessThan(avg * 3.0));
        }
      });
    }

    test('铺排铺满整球：上下半球与前后都有点', () {
      final layout = computeSphereLayout(200);
      var up = 0, down = 0, front = 0, back = 0;
      for (final p in layout.points) {
        if (p.y > 0) up++;
        if (p.y < 0) down++;
        if (p.z > 0) front++;
        if (p.z < 0) back++;
      }
      expect(up, greaterThan(50));
      expect(down, greaterThan(50));
      expect(front, greaterThan(50));
      expect(back, greaterThan(50));
    });
  });

  group('computeSphereRender', () {
    final names = [
      '地藏菩萨', '无边身如来', '宝性如来', '波头摩胜如来', '师子吼如来',
      '拘留孙佛', '毗婆尸佛', '宝胜如来', '宝相如来', '袈裟幢如来',
      '大通山王如来', '净月佛', '山王佛', '智胜佛', '净名王佛',
      '智成就佛', '无上佛', '妙声佛', '满月佛', '月面佛',
      '释迦牟尼佛', '师子奋迅具足万行如来', '觉华定自在王如来', '一切智成就如来',
      '清净莲华目如来', '文殊师利菩萨', '定自在王菩萨', '财首菩萨', '无尽意菩萨',
      '解脱菩萨', '普贤菩萨', '普广菩萨', '观世音菩萨', '虚空藏菩萨', '弥勒菩萨',
    ];

    test('35 位名号：一屏内足够多名号放大成文字，且一个都不丢', () {
      final layout = computeSphereLayout(names.length);
      // 取 yaw/pitch=0 时最靠前的位次当「当前」（与页面初始朝向一致）。
      var front = 0;
      var bestZ = double.negativeInfinity;
      for (var i = 0; i < layout.n; i++) {
        final p = layout.points[i];
        if (p.z > bestZ) {
          bestZ = p.z;
          front = i;
        }
      }
      final res = computeSphereRender(
        layout: layout,
        names: names,
        yaw: 0,
        pitch: 0,
        current: front,
        width: 360,
        height: 360,
      );
      final shown = {...res.texts.map((e) => e.index), ...res.dots.map((e) => e.index)};
      // 正面可见约一半，全部都要么是文字要么是星点（不丢）。
      expect(shown.length, inInclusiveRange(15, 35));
      // 放大成文字的名号不能太少（曾经只有几个）。
      expect(res.texts.length, greaterThanOrEqualTo(10));
      // 选中的那位一定在文字里。
      expect(res.texts.any((e) => e.isCur), isTrue);
    });

    test('长名号自动缩号，字号不超过短名号', () {
      final layout = computeSphereLayout(names.length);
      final res = computeSphereRender(
        layout: layout,
        names: names,
        yaw: 0.7,
        pitch: -0.3,
        current: 3,
        width: 320,
        height: 320,
      );
      for (final t in res.texts) {
        if (t.isCur) continue;
        expect(t.f, lessThanOrEqualTo(9.2 + 1e-9));
        expect(t.f, greaterThanOrEqualTo(5.5 - 1e-9));
      }
    });

    test('空布局 / 尺寸过小不抛异常', () {
      expect(
        computeSphereRender(
          layout: SphereLayout.empty,
          names: const [],
          yaw: 0,
          pitch: 0,
          current: -1,
          width: 360,
          height: 360,
        ).texts,
        isEmpty,
      );
      expect(
        computeSphereRender(
          layout: computeSphereLayout(5),
          names: const ['a', 'b', 'c', 'd', 'e'],
          yaw: 0,
          pitch: 0,
          current: 0,
          width: 20,
          height: 20,
        ).texts,
        isEmpty,
      );
    });
  });

  group('sphereAimAngles / rotateSpherePoint', () {
    test('按瞄准角旋转后点落在正前方 (0,0,1)', () {
      final layout = computeSphereLayout(50);
      for (final p in layout.points) {
        final aim = sphereAimAngles(p.x, p.y, p.z);
        final q = rotateSpherePoint(p.x, p.y, p.z, aim.yaw, aim.pitch);
        expect(q.x, closeTo(0, 1e-9));
        expect(q.y, closeTo(0, 1e-9));
        expect(q.z, closeTo(1, 1e-9));
      }
    });

    test('旋转保持向量长度不变', () {
      final p = (x: 0.3, y: -0.5, z: 0.81);
      final len0 = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
      final q = rotateSpherePoint(p.x, p.y, p.z, 0.7, -0.4);
      final len1 = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
      expect(len1, closeTo(len0, 1e-9));
    });

    test('正前方的点：yaw 增大向右移，pitch 增大向下移（跟手方向）', () {
      final right = rotateSpherePoint(0, 0, 1, 0.2, 0);
      expect(right.x, greaterThan(0));
      final down = rotateSpherePoint(0, 0, 1, 0, 0.2);
      expect(down.y, lessThan(0));
    });

    test('背面点（z<0）旋转后仍在背面时深度为负', () {
      final q = rotateSpherePoint(0, 0, -1, 0, 0);
      expect(q.z, lessThan(0));
    });
  });
}
