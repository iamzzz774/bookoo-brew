import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:bookoo_brew/brew_controller.dart';
import 'package:bookoo_brew/models.dart';

/// 合成一条像「聪明杯三段、按阀冲击」的曲线，验证 _despike：
///  - 重量是分段上升+静置，叠加 5 处单点毛刺（上冲/下跌）
///  - 毛刺采样点的流速设成 100~200（模拟秤对脉冲求导出的尖峰）
/// 跑：flutter test test/despike_test.dart
void main() {
  // 基础重量曲线（无毛刺）：三段注水，段间静置。
  double baseWeight(double t) {
    if (t < 12) return t / 12 * 52; // 第一段升到 ~52
    if (t < 40) return 52; // 静置
    if (t < 65) return 52 + (t - 40) / 25 * 98; // 第二段升到 ~150
    if (t < 100) return 150; // 静置
    if (t < 113) return 150 + (t - 100) / 13 * 80; // 第三段升到 ~230
    return 230; // 收尾静置
  }

  // 真实小流速（基础曲线的近似导数），数值都 < ~9 g/s。
  double baseFlow(double t) {
    const dt = 0.1;
    return (baseWeight(t + dt) - baseWeight(t - dt)) / (2 * dt);
  }

  // 毛刺：时间 → (重量偏移, 该点流速尖峰)。模拟手指按阀/碰秤。
  final spikes = <double, List<double>>{
    30.0: [22, 120], // 上冲
    41.0: [-50, -130], // 下跌到接近 0
    89.0: [85, 205], // 大上冲
    102.0: [-35, -148], // 下跌
    147.0: [18, 95], // 小上冲
  };

  List<Sample> synth() {
    final out = <Sample>[];
    for (var i = 0; i <= 1600; i++) {
      final t = i / 10.0; // 10Hz，0~160s
      var w = baseWeight(t);
      var f = baseFlow(t);
      for (final e in spikes.entries) {
        if ((t - e.key).abs() < 0.05) {
          w += e.value[0];
          f = e.value[1];
        }
      }
      out.add(Sample(
          double.parse(t.toStringAsFixed(2)),
          double.parse(w.toStringAsFixed(2)),
          double.parse(f.toStringAsFixed(2))));
    }
    return out;
  }

  Future<void> dump(String name, List<Sample> s) async {
    final url = await BrewController.curveForTest(s, 1750000000);
    expect(url, isNotNull);
    final b64 = url!.split(',')[1];
    final path = '${Directory.systemTemp.path}/$name';
    File(path).writeAsBytesSync(base64Decode(b64));
    // ignore: avoid_print
    print('WROTE $path');
  }

  testWidgets('despike removes finger-press spikes and renders curves',
      (tester) async {
    final raw = synth();
    final cleaned = BrewController.despikeForTest(raw);

    // 原始数据里有 5 个 |flow|>20 的尖峰点
    expect(raw.where((s) => s.flow.abs() > kFlowSpike).length, 5);
    // 去毛刺后不应再有任何 |flow|>20 的点
    expect(cleaned.where((s) => s.flow.abs() > kFlowSpike).length, 0);
    // 重量峰值不应被毛刺抬高（基础最高 230，容忍小误差）
    final maxW = cleaned.map((s) => s.w).reduce((a, b) => a > b ? a : b);
    expect(maxW, lessThan(232));

    // toImage() 依赖真实事件循环，必须在 runAsync 里跑，否则 fake-async 会挂死。
    await tester.runAsync(() async {
      await dump('bookoo_raw.png', raw);
      await dump('bookoo_cleaned.png', cleaned);
    });
  });

  test('despike clamps negative weight and flow for saved curves', () {
    final raw = [
      Sample(0, -0.12, -0.2),
      Sample(1, 1.25, -0.04),
      Sample(2, 3.5, 2.25),
      Sample(3, -0.01, 0),
    ];
    final cleaned = BrewController.despikeForTest(raw);

    expect(cleaned.map((s) => s.w), [0.0, 1.25, 3.5, 0.0]);
    expect(cleaned.map((s) => s.flow), [0.0, 0.0, 2.25, 0.0]);
  });

  test('saved yield uses final cleaned weight instead of middle maximum', () {
    final raw = [
      Sample(0, 170, 0),
      Sample(1, 265, 45),
      Sample(2, 265, 0),
      Sample(3, 171.5, -20),
      Sample(4, 182.4, 0),
    ];
    final cleaned = BrewController.despikeForTest(raw);

    expect(cleaned.map((s) => s.w).reduce((a, b) => a > b ? a : b), 265.0);
    expect(BrewController.yieldForTest(cleaned), 182.4);
  });

  test('despike keeps real pour jump from low starting weight', () {
    final raw = [
      Sample(0, 22.7, 0),
      Sample(1, 176.0, 5.7),
      Sample(2, 176.2, 0),
      Sample(152, 176.2, 0),
    ];
    final cleaned = BrewController.despikeForTest(raw);

    expect(cleaned.map((s) => s.w), [22.7, 176.0, 176.2, 176.2]);
    expect(BrewController.yieldForTest(cleaned), 176.2);
  });

  test('despike filters valve spikes above 20 g/s but keeps the boundary', () {
    final raw = [
      Sample(0, 0, 0),
      Sample(1, 4, 20),
      Sample(2, 40, 20.01),
      Sample(3, 45, 24),
      Sample(4, 16, 4),
    ];
    final cleaned = BrewController.despikeForTest(raw);

    expect(kFlowSpike, 20);
    expect(cleaned[1].flow, 20); // 阈值本身保留
    expect(cleaned[2].w, 8); // 连续开关阀冲击按相邻正常重量插值
    expect(cleaned[3].w, 12);
    expect(cleaned[2].flow, 4);
    expect(cleaned[3].flow, 4);
  });
}
