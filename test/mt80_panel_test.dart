import 'package:bookoo_brew/mt80.dart';
import 'package:bookoo_brew/mt80_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('idle panel shows only connection state, not permanent help', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Mt80GrindPanel())),
    );
    expect(find.text('MT80 未连接'), findsOneWidget);
    expect(find.text('手机蓝牙采集'), findsNothing);
    expect(find.text('保存后关联本次磨豆的参数'), findsNothing);
    expect(find.textContaining('650'), findsNothing);
  });
  testWidgets('live panel separates grind size from the two speeds', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Mt80GrindPanel(
            connected: true,
            connectionStatus: 'MT80 已连接',
            currentParameters: '研磨度 200 μm · 下豆速度 65 rpm · 刀盘转速 1200 rpm',
          ),
        ),
      ),
    );
    expect(find.text('MT80 已连接'), findsOneWidget);
    expect(
      find.text('研磨度 200 μm\n下豆速度 65 rpm · 刀盘转速 1200 rpm'),
      findsOneWidget,
    );
    expect(find.byType(Text), findsNWidgets(2));
    expect(find.textContaining('当前参数'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('disconnect hides stale live and previously saved parameters', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Mt80GrindPanel(
            result: Mt80Result(
              status: 'complete',
              bladeGapUm: 650,
              feedingRpm: 25,
              grindRpm: 800,
            ),
            connectionStatus: 'MT80 未连接 · 点击重连',
            currentParameters: '研磨度 200 μm · 下豆速度 65 rpm · 刀盘转速 1200 rpm',
          ),
        ),
      ),
    );
    expect(find.text('MT80 未连接 · 点击重连'), findsOneWidget);
    expect(find.textContaining('μm'), findsNothing);
    expect(find.textContaining('rpm'), findsNothing);
  });
  testWidgets(
    'confirmation stays actionable even while reconnect is available',
    (tester) async {
      var selected = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Mt80GrindPanel(
              result: const Mt80Result(status: 'needs_confirmation'),
              onChoose: () => selected = true,
              onConnect: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择'));
      expect(selected, isTrue);
    },
  );
  test('save feedback never treats idle parameters as a complete record', () {
    expect(const Mt80Result(status: 'complete').saveFeedback, '已关联磨豆参数');
    for (final status in [
      'idle',
      'unavailable',
      'pending',
      'needs_confirmation',
    ]) {
      expect(Mt80Result(status: status).saveFeedback, '未记录磨豆参数');
    }
  });
  testWidgets('two-line panel stays readable at narrow width and large font', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Mt80GrindPanel(
              connected: true,
              connectionStatus: 'MT80 已连接',
              currentParameters: '研磨度 999 μm · 下豆速度 65 rpm · 刀盘转速 1500 rpm',
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
