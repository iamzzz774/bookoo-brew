import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bookoo_brew/main.dart';
import 'package:bookoo_brew/models.dart';
import 'package:bookoo_brew/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('MT80 可选且不显示 Mac 协同设置', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings()..grinderPresets = ['手动磨豆机'];
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settings: settings)),
    );
    final option = find.text('使用 BOOKOO MT80');
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    expect(settings.mt80Enabled, isFalse);
    expect(find.textContaining('Mac'), findsNothing);
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(settings.mt80Enabled, isTrue);
    expect(settings.lastGrinder, 'BOOKOO MT80');
    expect((await Settings.load()).mt80Enabled, isTrue);
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(settings.mt80Enabled, isFalse);
    expect(settings.lastGrinder, '手动磨豆机');
    expect(settings.grinderChoices, ['手动磨豆机']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('设置页可切换并保存外观', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings();
    AppThemePreference? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settings: settings,
          onThemePreferenceChanged: (value) => selected = value,
        ),
      ),
    );

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(settings.themePreference, AppThemePreference.dark);
    expect(selected, AppThemePreference.dark);
    expect((await Settings.load()).themePreference, AppThemePreference.dark);
  });

  testWidgets('设置页可添加滤杯和磨豆机', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settings: settings)),
    );

    final dripperInput = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '名称，如 V60',
    );
    await tester.enterText(dripperInput, 'V60');
    await tester.tap(find.byTooltip('添加滤杯'));
    await tester.pump();

    final grinderInput = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '名称，如 K-Ultra',
    );
    await tester.ensureVisible(grinderInput);
    await tester.enterText(grinderInput, 'K-Ultra');
    await tester.tap(find.byTooltip('添加磨豆机'));
    await tester.pump();

    final rangeButton = find.byTooltip('设置 K-Ultra 刻度范围');
    await tester.ensureVisible(rangeButton);
    await tester.tap(rangeButton);
    await tester.pumpAndSettle();
    final minInput = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '最小刻度',
    );
    final maxInput = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '最大刻度',
    );
    await tester.tap(find.text('小数  0.1'));
    await tester.enterText(minInput, '1.1');
    await tester.enterText(maxInput, '3.0');
    await tester.tap(find.text('保存刻度'));
    await tester.pumpAndSettle();

    expect(settings.dripperPresets, contains('V60'));
    expect(settings.grinderPresets, contains('K-Ultra'));
    expect(settings.grinderMin('K-Ultra'), 1.1);
    expect(settings.grinderMax('K-Ultra'), 3.0);
    expect(settings.grinderStep('K-Ultra'), 0.1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内嵌设置页的数据连接按回车后保存', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings();
    var saved = false;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: settings,
            embedded: true,
            onSaved: () => saved = true,
          ),
        ),
      ),
    );

    expect(find.byType(AppBar), findsNothing);
    await tester.scrollUntilVisible(
      find.text('数据连接'),
      500,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final urlInput = find.byKey(const ValueKey('supabase-url-field'));
    await tester.enterText(urlInput, 'https://example.supabase.co');
    await tester.pump(const Duration(milliseconds: 600));

    expect(saved, isFalse);
    expect(settings.supabaseUrl, isEmpty);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(saved, isTrue);
    expect(settings.supabaseUrl, 'https://example.supabase.co');
    expect((await Settings.load()).supabaseUrl, 'https://example.supabase.co');
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('修改后自动保存'), findsNothing);
    expect(find.text('保存'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('研磨刻度尺从左到右递减并在结束时提交', (tester) async {
    var value = 60.0;
    double? endedValue;
    var tapped = false;
    var hapticCount = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') hapticCount++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: GrindScalePicker(
                value: value,
                onTap: () => tapped = true,
                onChanged: (next) => value = next,
                onChangeEnd: (next) => endedValue = next,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('55'), findsOneWidget);
    expect(find.text('65'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('grind-scale-scroll')));
    expect(tapped, isTrue);

    await tester.drag(
      find.byKey(const ValueKey('grind-scale-scroll')),
      const Offset(-64, 0),
    );
    await tester.pumpAndSettle();

    expect(value, lessThan(60));
    expect(value, inInclusiveRange(1.0, 120.0));
    expect(endedValue, value);
    expect(hapticCount, greaterThan(0));
    final indicator = tester.widget<Text>(
      find.byKey(const ValueKey('grind-scale-value')),
    );
    expect(indicator.data, '${value.toInt()}');
    final ruler = tester.widget<ListView>(
      find.byKey(const ValueKey('grind-scale-scroll')),
    );
    expect(ruler.controller!.offset % 16, closeTo(0, 0.001));
  });

  testWidgets('磨豆机刻度范围变化时重新定位', (tester) async {
    Widget buildRuler(int max) => MaterialApp(
      home: Scaffold(
        body: GrindScalePicker(
          value: 60.0,
          min: 1.0,
          max: max.toDouble(),
          onChanged: (_) {},
          onChangeEnd: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(buildRuler(120));
    var ruler = tester.widget<ListView>(
      find.byKey(const ValueKey('grind-scale-scroll')),
    );
    expect(ruler.controller!.offset, 60 * 16);

    await tester.pumpWidget(buildRuler(80));
    await tester.pump();
    ruler = tester.widget<ListView>(
      find.byKey(const ValueKey('grind-scale-scroll')),
    );
    expect(ruler.controller!.offset, 20 * 16);
  });

  testWidgets('0.1 刻度按小数档位吸附', (tester) async {
    var value = 1.5;
    double? endedValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GrindScalePicker(
            value: value,
            min: 1.0,
            max: 3.0,
            step: 0.1,
            enableHaptics: false,
            onChanged: (next) => value = next,
            onChangeEnd: (next) => endedValue = next,
          ),
        ),
      ),
    );

    expect(find.text('1.5'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('grind-scale-scroll')),
      const Offset(-40, 0),
    );
    await tester.pumpAndSettle();
    expect(value, lessThan(1.5));
    expect((value * 10).roundToDouble(), value * 10);
    expect(endedValue, value);
  });

  testWidgets('实时重量和流速曲线可渲染', (tester) async {
    final samples = [
      Sample(0, 0, 0),
      Sample(10, 45, 4.5),
      Sample(20, 110, 6.2),
      Sample(30, 176.2, 0),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 360, child: LiveBrewChart(samples: samples)),
        ),
      ),
    );

    expect(find.text('实时曲线'), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);
    expect(find.byKey(const ValueKey('live-brew-chart')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('beanLabel includes roaster when present', () {
    final bean = Bean(
      id: '1',
      name: 'Ethiopia Sidama',
      roastLevel: 'light',
      remaining: 100,
      roaster: 'Bookoo',
      raw: const {},
    );

    expect(beanLabel(bean), 'Bookoo Ethiopia Sidama');
  });

  test('beanLabel falls back to bean name without roaster', () {
    final bean = Bean(
      id: '1',
      name: 'Ethiopia Sidama',
      roastLevel: 'light',
      remaining: 100,
      raw: const {},
    );

    expect(beanLabel(bean), 'Ethiopia Sidama');
  });
}
