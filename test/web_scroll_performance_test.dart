import 'dart:async';

import 'package:bookoo_brew/brew_controller.dart';
import 'package:bookoo_brew/brewguide_webview.dart';
import 'package:bookoo_brew/main.dart';
import 'package:bookoo_brew/models.dart';
import 'package:bookoo_brew/mt80_panel.dart';
import 'package:bookoo_brew/mt80_protocol.dart';
import 'package:bookoo_brew/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

// Reuse the offline lifecycle fixtures, not their test main().
import 'next_cup_lifecycle_test.dart' as lifecycle;
import 'support/offline_webview.dart';

// Constructing a real Android controller would invoke native platform channels.
// These tests only need its runtime type, never Android implementation methods.
class _AndroidController extends Fake implements AndroidWebViewController {}

class _OtherController extends Fake implements PlatformWebViewController {}

class _Scale extends lifecycle.Scale {
  final samples = StreamController<ScaleReading>.broadcast();

  @override
  Stream<ScaleReading> get readings => samples.stream;

  @override
  Future<void> tareAndStartTimer() async {}

  @override
  Future<void> dispose() async {
    await samples.close();
    await super.dispose();
  }
}

class _CountingController extends BrewController {
  _CountingController(super.ble);

  int liveSamplesReads = 0;

  @override
  List<Sample> get liveSamples {
    liveSamplesReads++;
    return super.liveSamples;
  }
}

class _CountingGrinder extends lifecycle.Grinder {
  int readyReads = 0;

  @override
  bool get ready {
    readyReads++;
    return super.ready;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android WebView params explicitly enable hybrid composition', () {
    final platform = _AndroidController();
    final controller = WebViewController.fromPlatform(platform);

    final params = brewGuideWebViewCreationParams(controller);

    expect(params, isA<AndroidWebViewWidgetCreationParams>());
    expect(
      (params as AndroidWebViewWidgetCreationParams)
          .displayWithHybridComposition,
      isTrue,
    );
    expect(params.controller, same(platform));
  });

  test('non-Android WebView params preserve the generic controller', () {
    final platform = _OtherController();
    final controller = WebViewController.fromPlatform(platform);

    final params = brewGuideWebViewCreationParams(controller);

    expect(params, isNot(isA<AndroidWebViewWidgetCreationParams>()));
    expect(params.runtimeType, PlatformWebViewWidgetCreationParams);
    expect(params.controller, same(platform));
  });

  group('HomeScreen offscreen live UI', () {
    late _Scale scale;
    late _CountingGrinder grinder;
    late _CountingController ctrl;
    late WakelockPlusPlatformInterface previousWakelock;
    WebViewPlatform? previousWebView;

    setUp(() {
      previousWakelock = WakelockPlusPlatformInterface.instance;
      previousWebView = WebViewPlatform.instance;
      WakelockPlusPlatformInterface.instance = lifecycle.OfflineWakelock();
      WebViewPlatform.instance = OfflineWebViewPlatform();
      SharedPreferences.setMockInitialValues({});
      scale = _Scale();
      grinder = _CountingGrinder();
      ctrl = _CountingController(scale);
    });

    tearDown(() {
      WakelockPlusPlatformInterface.instance = previousWakelock;
      // The setter rejects null even though the initial getter can return it.
      if (previousWebView != null) WebViewPlatform.instance = previousWebView;
    });

    Future<void> select(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(500, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = Settings()
        ..brewGuideUrl = 'invalid-for-offline-test'
        ..mt80Enabled = true
        ..lastGrinder = 'BOOKOO MT80';
      await settings.save();
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            scale: scale,
            grinder: grinder,
            controller: ctrl,
            api: lifecycle.Api(),
          ),
        ),
      );
      // Dispose HomeScreen even when a regression assertion fails, so device
      // subscriptions/timers cannot leak into subsequent widget tests.
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      await select(tester, '萃取');
      expect(scale.live, isTrue);
      expect(grinder.ready, isTrue);
      expect(scale.scans, 1);
      expect(grinder.connections, 1);
    }

    void expectSessionRetained() {
      expect(ctrl.capturing, isTrue);
      expect(scale.live, isTrue);
      expect(grinder.live, isTrue);
      expect(scale.releases, 0);
      expect(grinder.releases, 0);
      expect(scale.scans, 1);
      expect(grinder.connections, 1);
    }

    for (final tab in ['豆仓', '设置']) {
      testWidgets(
        '$tab notifications do not recompute hidden live chart; capture resumes visibly',
        (tester) async {
          await open(tester);
          await tester.ensureVisible(find.text('开始'));
          await tester.tap(find.text('开始'));
          await tester.pumpAndSettle();
          // Real BrewController.start waits 300 ms before accepting samples.
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(ctrl.capturing, isTrue);

          scale.samples.add(ScaleReading(1, 1, 1, 80));
          final visibleReads = ctrl.liveSamplesReads;
          await tester.pump();
          await tester.pump();
          expect(ctrl.liveSamplesReads, greaterThan(visibleReads));
          expect(find.text('1.0 g'), findsOneWidget);

          await select(tester, tab);
          final hiddenReads = ctrl.liveSamplesReads;
          // Pump each notification independently: a single batch could hide
          // repeated rebuilds through Flutter's normal frame coalescing.
          for (var i = 2; i <= 25; i++) {
            scale.samples.add(ScaleReading(i.toDouble(), i.toDouble(), 1, 80));
            // Deliver the broadcast stream before pumping its UI frame.
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(ctrl.weight, 25);
          expectSessionRetained();
          expect(
            ctrl.liveSamplesReads,
            hiddenReads,
            reason:
                'Hidden native chart must not clean/copy samples per update',
          );

          await select(tester, '萃取');
          expect(ctrl.liveSamplesReads, greaterThan(hiddenReads));
          expect(find.text('25.0 g'), findsOneWidget);
          final chart = tester.widget<LiveBrewChart>(
            find.byType(LiveBrewChart),
          );
          expect(chart.samples, hasLength(25));
          expect(chart.samples.last.w, 25);
          expectSessionRetained();

          final resumedReads = ctrl.liveSamplesReads;
          scale.samples.add(ScaleReading(26, 26, 1, 80));
          await tester.pump();
          await tester.pump();
          expect(ctrl.liveSamplesReads, greaterThan(resumedReads));
          expect(find.text('26.0 g'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '$tab MT80 notifications do not build hidden panel; latest values return',
        (tester) async {
          await open(tester);
          expect(ctrl.capturing, isFalse);
          // MT80 panel lives in the non-capturing bean card. Test it separately
          // from the chart rather than counting an absent panel during capture.
          grinder.sample = const Mt80Sample(
            atMs: 1,
            bladeGap: 500,
            feedingRpm: 60,
            grindRpm: 800,
            devState: 'IDLE',
          );
          final visibleReads = grinder.readyReads;
          grinder.notifyListeners();
          await tester.pump();
          expect(grinder.readyReads, greaterThan(visibleReads));
          expect(
            tester
                .widget<Mt80GrindPanel>(find.byType(Mt80GrindPanel))
                .currentParameters,
            contains('500 μm'),
          );

          await select(tester, tab);
          final hiddenReads = grinder.readyReads;
          for (var i = 1; i <= 24; i++) {
            grinder.sample = Mt80Sample(
              atMs: i + 1,
              bladeGap: 500 + i,
              feedingRpm: 60,
              grindRpm: 800,
              devState: 'IDLE',
            );
            grinder.notifyListeners();
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(
            grinder.readyReads,
            hiddenReads,
            reason: 'Hidden MT80 AnimatedBuilder must ignore device updates',
          );
          expect(scale.live && grinder.live, isTrue);
          expect(scale.releases + grinder.releases, 0);

          await select(tester, '萃取');
          expect(grinder.readyReads, greaterThan(hiddenReads));
          expect(
            tester
                .widget<Mt80GrindPanel>(find.byType(Mt80GrindPanel))
                .currentParameters,
            contains('524 μm'),
          );
          final resumedReads = grinder.readyReads;
          grinder.notifyListeners();
          await tester.pump();
          expect(grinder.readyReads, greaterThan(resumedReads));
          expect(scale.scans, 1);
          expect(grinder.connections, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}
