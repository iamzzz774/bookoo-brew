import 'dart:async';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'support/offline_webview.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bookoo_brew/main.dart';
import 'package:bookoo_brew/bookoo_ble.dart';
import 'package:bookoo_brew/mt80_ble.dart';
import 'package:bookoo_brew/brew_controller.dart';
import 'package:bookoo_brew/brewguide_api.dart';
import 'package:bookoo_brew/models.dart';
import 'package:bookoo_brew/settings.dart';

// Fake transports/cloud only; buttons, save completion, navigation and app
// lifecycle all run the real HomeScreen state machine. No real records/writes.
class OfflineWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

class Scale extends BookooBle {
  final changes = StreamController<bool>.broadcast();
  bool live = false;
  int scans = 0, releases = 0;
  Completer<void>? releaseGate;
  @override
  Stream<bool> get connection => changes.stream;
  @override
  bool get isConnected => live;
  @override
  String get deviceName => 'BOOKOO test scale';
  @override
  Future<void> scanAndConnect({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    scans++;
    live = true;
    changes.add(true);
  }

  @override
  Future<void> releaseConnection() async {
    releases++;
    if (releaseGate != null) await releaseGate!.future;
    live = false;
    changes.add(false);
  }

  @override
  Future<void> dispose() async {
    await changes.close();
    await super.dispose();
  }
}

class Grinder extends Mt80Ble {
  bool live = false;
  int connections = 0, releases = 0;
  @override
  bool get ready => live;
  @override
  Future<void> setEnabled(bool value) async {
    if (value && !live) {
      connections++;
      live = true;
      status = 'MT80 已连接';
      notifyListeners();
    } else if (!value) {
      live = false;
    }
  }

  @override
  Future<void> releaseConnection() async {
    releases++;
    live = false;
    status = 'MT80 未连接';
    notifyListeners();
  }
}

class Api extends BrewGuideApi {
  Api()
    : super(baseUrl: 'https://example.invalid', key: 'test', userId: 'test');
  @override
  Future<List<Bean>> listFilterBeans() async => [];
  @override
  Future<Map<String, dynamic>?> getNoteData(String id) async => null;
}

class Controller extends BrewController {
  Controller(super.ble);
  int starts = 0, saves = 0;
  Completer<void>? saving;
  bool failSave = false;
  bool shortCup = false;
  int discards = 0;
  @override
  bool get needsEarlyStopConfirmation => shortCup && capturing;
  @override
  Future<void> discard() async {
    discards++;
    capturing = false;
    lastSavedNoteId = null;
    notifyListeners();
  }

  @override
  Future<void> start({String? grinder}) async {
    starts++;
    capturing = true;
    lastSavedNoteId = null;
    notifyListeners();
  }

  @override
  Future<String> stopAndSave(
    BrewGuideApi api,
    Bean? bean,
    double dose, {
    required int temp,
    required String dripper,
    required String grinder,
    required double grindSetting,
    Future<Map<String, dynamic>?> Function(String, int)? localMt80Record,
  }) async {
    capturing = false;
    notifyListeners();
    if (saving != null) await saving!.future;
    if (failSave) throw StateError('test save failure');
    saves++;
    lastSavedNoteId = 'test-$saves';
    lastResult = '已保存';
    notifyListeners();
    return '已保存';
  }
}

void main() {
  late Scale scale;
  late Grinder grinder;
  late Controller ctrl;
  setUp(() {
    WakelockPlusPlatformInterface.instance = OfflineWakelock();
    WebViewPlatform.instance = OfflineWebViewPlatform();
    SharedPreferences.setMockInitialValues({});
    scale = Scale();
    grinder = Grinder();
    ctrl = Controller(scale);
  });
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/wakelock'),
      (_) async => null,
    );
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
          api: Api(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('萃取'));
    await tester.pumpAndSettle();
    expect(scale.live, isTrue);
    expect(grinder.ready, isTrue);
    // Begin assertions after the first foreground connection.
    scale.releases = grinder.releases = 0;
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'save first cup keeps both devices live and second cup starts without scanning',
    (tester) async {
      await open(tester);
      await press(tester, '开始');
      await press(tester, '结束并入库');
      expect(ctrl.saves, 1);
      expect(scale.releases, 0);
      expect(grinder.releases, 0);
      expect(scale.live && grinder.ready, isTrue);
      await press(tester, '开始');
      expect(ctrl.starts, 2);
      expect(ctrl.capturing, isTrue);
      expect(scale.scans, 1);
      expect(grinder.connections, 1);
      await press(tester, '结束并入库');
      expect(ctrl.saves, 2);
      expect(scale.releases, 0);
      expect(grinder.releases, 0);
      await cleanup(tester);
    },
  );
  testWidgets(
    'foreground tab switches after save keep both sessions without rescanning',
    (tester) async {
      await open(tester);
      await press(tester, '开始');
      await press(tester, '结束并入库');
      await press(tester, '豆仓');
      expect(scale.releases, 0);
      expect(grinder.releases, 0);
      expect(scale.live && grinder.ready, isTrue);
      await press(tester, '萃取');
      expect(scale.live && grinder.ready, isTrue);
      expect(scale.scans, 1);
      expect(grinder.connections, 1);
      await cleanup(tester);
    },
  );
  testWidgets(
    'background after save retains devices and resume does not rescan',
    (tester) async {
      await open(tester);
      await press(tester, '开始');
      await press(tester, '结束并入库');
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(scale.live && grinder.ready, isTrue);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(scale.live && grinder.ready, isTrue);
      await cleanup(tester);
    },
  );
  testWidgets(
    'recording and delayed save retain connections even in background',
    (tester) async {
      await open(tester);
      await press(tester, '开始');
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(scale.releases, 0);
      expect(grinder.releases, 0);
      ctrl.saving = Completer<void>();
      await press(tester, '结束并入库');
      expect(scale.releases, 0);
      expect(grinder.releases, 0);
      ctrl.saving!.complete();
      await tester.pumpAndSettle();
      expect(ctrl.saves, 1);
      expect(scale.live && grinder.ready, isTrue);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(scale.live && grinder.ready, isTrue);
      await cleanup(tester);
    },
  );
  testWidgets('failed save does not force disconnect on foreground brew page', (
    tester,
  ) async {
    await open(tester);
    await press(tester, '开始');
    ctrl.failSave = true;
    await press(tester, '结束并入库');
    expect(ctrl.saves, 0);
    expect(scale.live && grinder.ready, isTrue);
    expect(scale.releases + grinder.releases, 0);
    await cleanup(tester);
  });
  testWidgets(
    'under 30 seconds asks first, continue does not save or release',
    (tester) async {
      await open(tester);
      ctrl.shortCup = true;
      await press(tester, '开始');
      await press(tester, '结束并入库');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('这杯冲煮时间很短'), findsNothing);
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('放弃'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('结束并入库'), findsNothing);
      final continueButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '继续'),
      );
      final discardButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '放弃'),
      );
      final saveButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '保存'),
      );
      expect(continueButton.style!.backgroundColor!.resolve({}), Colors.black);
      expect(continueButton.style!.foregroundColor!.resolve({}), Colors.white);
      expect(discardButton.style!.backgroundColor!.resolve({}), Colors.red);
      expect(discardButton.style!.foregroundColor!.resolve({}), Colors.white);
      expect(saveButton.style, isNull);

      final rects = [
        '继续',
        '放弃',
        '保存',
      ].map((text) => tester.getRect(find.text(text))).toList();
      expect(rects[0].center.dy, rects[1].center.dy);
      expect(rects[1].center.dy, rects[2].center.dy);
      expect(rects[0].left, lessThan(rects[1].left));
      expect(rects[1].left, lessThan(rects[2].left));
      expect(ctrl.saves, 0);
      expect(ctrl.discards, 0);
      expect(ctrl.capturing, isTrue);
      await press(tester, '继续');
      expect(ctrl.capturing, isTrue);
      expect(ctrl.saves, 0);
      expect(scale.releases + grinder.releases, 0);
      await cleanup(tester);
    },
  );
  testWidgets(
    'discard short cup does not save and next cup reuses live devices',
    (tester) async {
      await open(tester);
      ctrl.shortCup = true;
      await press(tester, '开始');
      await press(tester, '结束并入库');
      await press(tester, '放弃');
      expect(ctrl.saves, 0);
      expect(ctrl.discards, 1);
      expect(ctrl.capturing, isFalse);
      expect(scale.live && grinder.ready, isTrue);
      expect(scale.releases + grinder.releases, 0);
      await press(tester, '开始');
      expect(ctrl.starts, 2);
      expect(scale.scans, 1);
      await cleanup(tester);
    },
  );
  testWidgets('only explicit save permits short cup to reach save path once', (
    tester,
  ) async {
    await open(tester);
    ctrl.shortCup = true;
    await press(tester, '开始');
    await press(tester, '结束并入库');
    expect(ctrl.saves, 0);
    await press(tester, '保存');
    expect(ctrl.saves, 1);
    expect(ctrl.discards, 0);
    expect(scale.live && grinder.ready, isTrue);
    await cleanup(tester);
  });
  testWidgets(
    'repeated stock and settings round trips before brewing retain live devices',
    (tester) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await press(tester, '豆仓');
        await press(tester, '设置');
        await press(tester, '萃取');
        expect(scale.live && grinder.ready, isTrue);
      }
      expect(scale.scans, 1);
      expect(grinder.connections, 1);
      expect(scale.releases + grinder.releases, 0);
      expect(ctrl.starts + ctrl.saves, 0);
      await cleanup(tester);
    },
  );
  testWidgets('temporary focus loss does not disconnect or rescan', (
    tester,
  ) async {
    await open(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(scale.live && grinder.ready, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(scale.scans, 1);
    expect(grinder.connections, 1);
    expect(scale.releases + grinder.releases, 0);
    await cleanup(tester);
  });
  testWidgets('grinder setting changes do not disconnect the scale', (
    tester,
  ) async {
    await open(tester);
    await press(tester, '设置');
    await press(tester, '使用 BOOKOO MT80');
    expect(scale.live, isTrue);
    expect(scale.releases, 0);
    expect(scale.scans, 1);
    expect(grinder.ready, isFalse);
    await press(tester, '使用 BOOKOO MT80');
    expect(grinder.ready, isTrue);
    expect(scale.releases, 0);
    expect(scale.scans, 1);
    expect(grinder.connections, 2);
    await cleanup(tester);
  });
  testWidgets(
    'manual scale header retry drains scale only and ignores repeated taps',
    (tester) async {
      await open(tester);
      scale.live = false;
      scale.changes.add(false);
      await tester.pumpAndSettle();
      scale.releaseGate = Completer<void>();
      final header = find.byKey(const ValueKey('scale-connection-header'));
      await tester.ensureVisible(header);
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(scale.releases, 1);
      expect(grinder.releases, 0);
      expect(grinder.ready, isTrue);
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(scale.releases, 1);
      scale.releaseGate!.complete();
      scale.releaseGate = null;
      await tester.pumpAndSettle();
      expect(scale.live && grinder.ready, isTrue);
      expect(scale.scans, 2);
      expect(grinder.connections, 1);
      expect(grinder.releases, 0);
      await cleanup(tester);
    },
  );
  testWidgets('actual app-view exit releases both devices', (tester) async {
    await open(tester);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(scale.live || grinder.ready, isFalse);
    expect(scale.releases, 1);
    expect(grinder.releases, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(scale.live && grinder.ready, isTrue);
    await cleanup(tester);
  });
}
