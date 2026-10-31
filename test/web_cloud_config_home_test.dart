import 'dart:async';
import 'package:bookoo_brew/main.dart';
import 'package:bookoo_brew/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'next_cup_lifecycle_test.dart' as devices;
import 'support/cloud_config_webview.dart';

void main() {
  late CloudConfigWebViewPlatform platform;
  late devices.Scale scale;
  late devices.Grinder grinder;
  late devices.Controller controller;
  late List<http.Request> requests;
  late MockClient client;
  setUp(() {
    platform = CloudConfigWebViewPlatform();
    WebViewPlatform.instance = platform;
    WakelockPlusPlatformInterface.instance = devices.OfflineWakelock();
    SharedPreferences.setMockInitialValues({});
    scale = devices.Scale();
    grinder = devices.Grinder();
    controller = devices.Controller(scale);
    requests = [];
    client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        '[]',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });
  Future<CloudConfigController> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await (Settings()
          ..brewGuideUrl = 'https://guide.invalid/'
          ..supabaseUrl = 'https://old-credentials.invalid'
          ..supabaseKey = 'old-key'
          ..userId = 'old-user')
        .save();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          scale: scale,
          grinder: grinder,
          controller: controller,
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final web = platform.controllers.last;
    web.start();
    web.finish();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(web.reads, isNotEmpty);
    expect(
      requests,
      isEmpty,
      reason: 'stored credentials alone must never start a native request',
    );
    return web;
  }

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'Home reuses ready web URL/key/UID for native requests without manual fields',
    (tester) => http.runWithClient(() async {
      final web = await open(tester);
      web.send(
        web.response(
          config: {
            'url': 'https://web-cloud.invalid',
            'key': 'Web-Exact-Key',
            'userId': 'web-uid',
          },
        ),
      );
      await flush(tester);
      expect(requests, isNotEmpty);
      for (final request in requests) {
        expect(request.url.host, 'web-cloud.invalid');
        expect(request.url.queryParameters['user_id'], 'eq.web-uid');
        expect(request.headers['apikey'], 'Web-Exact-Key');
        expect(request.headers['Authorization'], 'Bearer Web-Exact-Key');
      }
      final saved = await Settings.load();
      expect(saved.supabaseUrl, 'https://web-cloud.invalid');
      expect(saved.supabaseKey, 'Web-Exact-Key');
      expect(saved.userId, 'web-uid');
      await tester.tap(find.text('设置'));
      await flush(tester);
      expect(find.byKey(const ValueKey('supabase-url-field')), findsNothing);
      expect(find.byKey(const ValueKey('supabase-key-field')), findsNothing);
      expect(
        find.byKey(const ValueKey('supabase-user-id-field')),
        findsNothing,
      );
      await cleanup(tester);
    }, () => client),
  );

  for (final status in ['missing', 'disabled']) {
    testWidgets(
      'Home $status blocks native requests with no old credentials fallback',
      (tester) => http.runWithClient(() async {
        final web = await open(tester);
        web.send(web.response(status: status));
        await flush(tester);
        expect(requests, isEmpty);
        await tester.tap(find.text('萃取'));
        await flush(tester);
        web.send(web.response(status: status));
        await flush(tester);
        await tester.ensureVisible(find.text('开始'));
        await tester.tap(find.text('开始'));
        await flush(tester);
        expect(controller.starts, 0);
        expect(controller.capturing, isFalse);
        expect(requests, isEmpty);
        final saved = await Settings.load();
        expect(saved.supabaseUrl, 'https://old-credentials.invalid');
        await cleanup(tester);
      }, () => client),
    );
  }

  testWidgets(
    'Home capture freezes established connection across navigation and changed web config',
    (tester) => http.runWithClient(() async {
      final web = await open(tester);
      web.send(web.response());
      await flush(tester);
      await tester.tap(find.text('萃取'));
      await flush(tester);
      web.send(web.response());
      await flush(tester);
      await tester.ensureVisible(find.text('开始'));
      await tester.tap(find.text('开始'));
      await flush(tester);
      expect(controller.capturing, isTrue);
      final beforeReads = web.reads.length;
      final beforeRequests = requests.length;
      web.start('https://guide.invalid/new-document');
      web.finish();
      await flush(tester);
      web.send(
        web.response(
          config: {
            'url': 'https://changed.invalid',
            'key': 'changed',
            'userId': 'changed',
          },
        ),
      );
      await flush(tester);
      expect(web.reads.length, beforeReads);
      expect(requests.length, beforeRequests);
      final saved = await Settings.load();
      expect(saved.supabaseUrl, 'https://cloud.invalid');
      expect(saved.supabaseKey, 'fixture-key');
      expect(saved.userId, 'default_user');
      expect(controller.capturing, isTrue);
      await cleanup(tester);
    }, () => client),
  );

  testWidgets(
    'unchanged configuration on repeated tab visits never reloads cloud beans',
    (tester) => http.runWithClient(() async {
      final web = await open(tester);
      web.send(web.response());
      await flush(tester);
      final initialRequests = requests.length;
      expect(initialRequests, greaterThan(0));
      for (final tab in ['设置', '萃取', '设置', '萃取']) {
        await tester.tap(find.text(tab));
        await flush(tester);
        web.send(web.response());
        await flush(tester);
        expect(requests.length, initialRequests);
      }
      await cleanup(tester);
    }, () => client),
  );

  testWidgets(
    'a hanging automatic bean refresh does not block capture after config is read',
    (tester) async {
      final pending = Completer<http.Response>();
      client = MockClient((request) {
        requests.add(request);
        return pending.future;
      });
      await http.runWithClient(() async {
        final web = await open(tester);
        web.send(web.response());
        await flush(tester);
        expect(requests, hasLength(1));
        await tester.tap(find.text('萃取'));
        await flush(tester);
        web.send(web.response());
        await flush(tester);
        expect(requests, hasLength(1));
        await tester.ensureVisible(find.text('开始'));
        await tester.tap(find.text('开始'));
        await flush(tester);
        expect(controller.capturing, isTrue);
        pending.complete(http.Response('[]', 200));
        await flush(tester);
        await cleanup(tester);
      }, () => client);
    },
  );

  testWidgets(
    'automatic bean timeout stays silent and does not invalidate ready config',
    (tester) async {
      client = MockClient((request) async {
        requests.add(request);
        throw TimeoutException('private diagnostic fixture');
      });
      await http.runWithClient(() async {
        final web = await open(tester);
        web.send(web.response());
        await flush(tester);
        expect(requests, hasLength(1));
        expect(find.byType(SnackBar), findsNothing);
        await tester.tap(find.text('萃取'));
        await flush(tester);
        web.send(web.response());
        await flush(tester);
        expect(requests, hasLength(1));
        await tester.ensureVisible(find.text('开始'));
        await tester.tap(find.text('开始'));
        await flush(tester);
        expect(controller.capturing, isTrue);
        expect(find.textContaining('TimeoutException'), findsNothing);
        await cleanup(tester);
      }, () => client);
    },
  );
}
