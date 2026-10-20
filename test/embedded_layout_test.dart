import 'dart:convert';
import 'dart:io';

import 'package:bookoo_brew/brewguide_webview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// The test double targets the exact platform interface pinned transitively.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  test('embedded layout installs one persistent, narrowly scoped style', () {
    final result = Process.runSync('node', [
      '-e',
      r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
const script = JSON.parse(process.argv[1]);
const styles = [];
const document = {
  getElementById: id => styles.find(s => s.id === id),
  createElement: tag => { assert.equal(tag, 'style'); return {}; },
  head: { appendChild: style => styles.push(style) },
};
const context = vm.createContext({ document });
vm.runInContext(script, context);
vm.runInContext(script, context);
assert.equal(styles.length, 1);
assert.equal(styles[0].id, 'bookoo-brew-embedded-layout');
assert.match(styles[0].textContent,
  /\.browser-edge-top\s*\{\s*display:\s*none\s*!important;\s*\}/);
assert.match(styles[0].textContent, /--safe-area-bottom:\s*24px\s*!important/);
// No navigation/gesture overrides or top-inset resets: only decoration is hidden.
assert.equal(styles[0].textContent.match(/\{/g).length, 2);
assert.doesNotMatch(styles[0].textContent, /--safe-area-top|position:|transform:|opacity:/);
console.log('PASS: one decoration-only style; no storage or gesture APIs accessed');
''',
      jsonEncode(kAdjustEmbeddedLayoutScript),
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('PASS:'));
  });

  test(
    'configured HTTPS origin includes effective port and rejects lookalikes',
    () {
      const configured = 'https://guide.example:8443/app/';
      expect(
        isTrustedBrewGuideUrl(configured, 'https://GUIDE.example:8443/notes'),
        isTrue,
      );
      for (final candidate in [
        'http://guide.example:8443/',
        'https://guide.example/',
        'https://guide.example:443/',
        'https://other.example:8443/',
        'https://guide.example.evil.example:8443/',
        'https://guide.example@other.example:8443/',
        'about:blank',
      ]) {
        expect(
          isTrustedBrewGuideUrl(configured, candidate),
          isFalse,
          reason: candidate,
        );
      }
      expect(
        isTrustedBrewGuideUrl(
          'https://guide.example/',
          'https://guide.example:443/notes',
        ),
        isTrue,
      );
      expect(
        isTrustedBrewGuideUrl(
          'https://guide.example:443/',
          'https://guide.example/',
        ),
        isTrue,
      );
      for (final invalid in [
        '',
        'not a URL',
        'http://guide.example/',
        'https://user:password@guide.example/',
        'https://guide.example:0/',
        'https://guide.example:65536/',
      ]) {
        expect(parseBrewGuideUrl(invalid), isNull, reason: invalid);
        expect(
          isTrustedBrewGuideUrl(invalid, 'https://guide.example/'),
          isFalse,
        );
      }
    },
  );

  testWidgets('empty and invalid setup do not construct a platform WebView', (
    tester,
  ) async {
    // No WebViewPlatform is registered in this test: controller creation throws.
    for (final url in ['', 'bad URL', 'http://guide.example/']) {
      await tester.pumpWidget(MaterialApp(home: BrewGuideWebPane(url: url)));
      expect(find.text('请在设置中配置自己的 Brew Guide HTTPS 地址'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('tab retention, URL replacement and stale downloads are isolated', (
    tester,
  ) async {
    final platform = _TestWebViewPlatform();
    WebViewPlatform.instance = platform;
    var saves = 0;
    const channel = MethodChannel('coffee.bookoo.bookoo_brew/file_picker');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'saveFile') saves++;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    Widget host(String url, int index) => MaterialApp(
      home: Scaffold(
        body: IndexedStack(
          index: index,
          children: [
            BrewGuideWebPane(url: url),
            const Text('Other tab'),
          ],
        ),
      ),
    );
    await tester.pumpWidget(host('https://guide.example:8443/', 0));
    await tester.pump();
    final first = platform.controllers.single;
    final nav = first.delegate!;
    first.url = 'https://guide.example:8443/';
    nav.started!(first.url!);
    nav.finished!(first.url!);
    await tester.pump();
    final script = first.scripts.single;
    final token = RegExp(r'token: "([^"]+)"').firstMatch(script)!.group(1)!;
    void message(String token, Map<String, Object> payload) {
      first.channel!.onMessageReceived(
        JavaScriptMessage(
          message: jsonEncode({'token': token, 'message': jsonEncode(payload)}),
        ),
      );
    }

    message(token, {
      'kind': 'start',
      'id': 'pending',
      'fileName': 'synthetic.json',
      'mimeType': 'application/json',
      'totalChunks': 1,
    });
    await tester.pump();
    await tester.pumpWidget(host('https://guide.example:8443/', 1));
    await tester.pumpWidget(host('https://guide.example:8443/', 0));
    expect(platform.controllers, hasLength(1));
    expect(first.loads, hasLength(1));
    expect(
      await nav.request!(
        const NavigationRequest(
          url: 'https://guide.example:8443/#beans',
          isMainFrame: true,
        ),
      ),
      NavigationDecision.navigate,
    );
    first.url = 'https://guide.example:8443/#beans';
    message(token, {
      'kind': 'chunk',
      'id': 'pending',
      'index': 0,
      'data': 'e30=',
    });
    await tester.pump();
    message(token, {'kind': 'end', 'id': 'pending'});
    await tester.pump();
    expect(saves, 1); // The retained document still has a working bridge.
    message(token, {
      'kind': 'start',
      'id': 'pending',
      'fileName': 'synthetic.json',
      'mimeType': 'application/json',
      'totalChunks': 1,
    });
    await tester.pump();
    for (final url in [
      'https://other.example:8443/',
      'https://guide.example/',
    ]) {
      expect(
        await nav.request!(NavigationRequest(url: url, isMainFrame: true)),
        NavigationDecision.prevent,
      );
    }
    await tester.pump();
    message(token, {
      'kind': 'chunk',
      'id': 'pending',
      'index': 0,
      'data': 'e30=',
    });
    await tester.pump();
    // Navigation invalidates both the assembly and the old document capability.
    expect(
      await nav.request!(
        const NavigationRequest(
          url: 'https://guide.example:8443/next',
          isMainFrame: true,
        ),
      ),
      NavigationDecision.navigate,
    );
    first.url = 'https://guide.example:8443/next';
    nav.started!(first.url!);
    nav.finished!(first.url!);
    await tester.pump();
    final nextToken = RegExp(
      r'token: "([^"]+)"',
    ).firstMatch(first.scripts.last)!.group(1)!;
    expect(nextToken, isNot(token));
    message(nextToken, {'kind': 'end', 'id': 'pending'});
    await tester.pump();
    expect(
      saves,
      1,
    ); // Even the fresh capability cannot finish the old assembly.
    message(token, {'kind': 'end', 'id': 'pending'});
    await tester.pump();
    expect(saves, 1);
    await tester.pumpWidget(host('https://second.example/', 0));
    expect(platform.controllers, hasLength(2));
    expect(first.loads.last.toString(), 'about:blank');
    final oldScriptCount = first.scripts.length;
    nav.finished!('https://guide.example:8443/');
    message(token, {'kind': 'end', 'id': 'pending'});
    await tester.pump();
    expect(first.scripts.length, oldScriptCount);
    expect(saves, 1);
    await tester.pumpWidget(host('', 0));
    expect(platform.controllers, hasLength(2));
    expect(find.text('请在设置中配置自己的 Brew Guide HTTPS 地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('page scripts recheck exact origin and top frame at execution time', () {
    final script = brewGuidePageScript(
      'https://guide.example:8443/',
      'test-token',
    );
    final result = Process.runSync('node', [
      '-e',
      r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
const script = JSON.parse(process.argv[1]);
for (const origin of ['https://other.example:8443', 'https://guide.example',
                      'http://guide.example:8443']) {
  const window = {}; window.top = window;
  vm.runInNewContext(script, {window, location: {origin}});
  assert.deepEqual(Object.keys(window), ['top']);
}
// Even a same-origin subframe must not install the native download capability.
vm.runInNewContext(script, {window: {top: {}},
  location: {origin: 'https://guide.example:8443'}});
console.log('PASS: foreign origins, wrong port and subframes perform no work');
''',
      jsonEncode(script),
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(brewGuidePageScript('', 'test-token'), isEmpty);
    final source = File('lib/brewguide_webview.dart').readAsStringSync();
    expect(source, isNot(contains('enableDebugging(true)')));
  });
}

class _TestWebViewPlatform extends WebViewPlatform {
  final controllers = <_TestController>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _TestController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _TestDelegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _TestView(params);
}

class _TestController extends PlatformWebViewController {
  _TestController(super.params) : super.implementation();
  final loads = <Uri>[];
  final scripts = <String>[];
  String? url;
  _TestDelegate? delegate;
  JavaScriptChannelParams? channel;
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loads.add(params.uri);
    url = params.uri.toString();
  }

  @override
  Future<String?> currentUrl() async => url;
  @override
  Future<void> runJavaScript(String script) async {
    scripts.add(script);
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channel = params;
  }

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) callback,
  ) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    delegate = handler as _TestDelegate;
  }
}

class _TestDelegate extends PlatformNavigationDelegate {
  _TestDelegate(super.params) : super.implementation();
  NavigationRequestCallback? request;
  PageEventCallback? started;
  PageEventCallback? finished;
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {
    request = callback;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {
    started = callback;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {
    finished = callback;
  }

  @override
  Future<void> setOnProgress(ProgressCallback callback) async {}
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

class _TestView extends PlatformWebViewWidget {
  _TestView(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox();
}
