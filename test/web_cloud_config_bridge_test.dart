import 'dart:async';
import 'package:bookoo_brew/brewguide_webview.dart';
import 'package:bookoo_brew/web_cloud_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'support/cloud_config_webview.dart';

void main() {
  late CloudConfigWebViewPlatform platform;
  late GlobalKey<BrewGuideWebPaneState> key;
  late CloudConfigController web;
  setUp(() {
    platform = CloudConfigWebViewPlatform();
    WebViewPlatform.instance = platform;
    key = GlobalKey<BrewGuideWebPaneState>();
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BrewGuideWebPane(key: key, url: 'https://guide.invalid/'),
      ),
    );
    web = platform.controllers.single;
    web.start();
    web.finish();
    await tester.pump();
    expect(
      web.channels.keys,
      containsAll(['BookooCloudConfigBridge', 'BookooFileBridge']),
    );
  }

  Future<WebCloudConfigResult?> begin(WidgetTester tester) {
    return key.currentState!.readCloudConfig();
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'trusted current document ready returns exact web credentials through native channel',
    (tester) async {
      await open(tester);
      final pending = begin(tester);
      await tester.pump();
      web.send(
        web.response(
          config: {
            'url': 'https://cloud.invalid/path/',
            'key': 'Exact-Key',
            'userId': ' exact uid ',
          },
        ),
      );
      await tester.pump();
      final result = await pending;
      expect(result!.status, WebCloudConfigStatus.ready);
      expect(result.config!.url, 'https://cloud.invalid/path/');
      expect(result.config!.key, 'Exact-Key');
      expect(result.config!.userId, ' exact uid ');
      await cleanup(tester);
    },
  );

  for (final field in ['token', 'requestId', 'origin']) {
    testWidgets(
      'wrong $field channel message is ignored until matching callback',
      (tester) async {
        await open(tester);
        bool complete = false;
        final pending = begin(tester)..then((_) => complete = true);
        await tester.pump();
        web.send({
          ...web.response(),
          field: field == 'origin' ? 'https://evil.invalid' : 'wrong',
        });
        await tester.pump();
        expect(complete, isFalse);
        web.send(web.response());
        await tester.pump();
        expect((await pending)!.status, WebCloudConfigStatus.ready);
        await cleanup(tester);
      },
    );
  }

  testWidgets(
    'navigation invalidates in-flight read and late ready cannot satisfy next document',
    (tester) async {
      await open(tester);
      final old = begin(tester);
      await tester.pump();
      final late = web.response();
      final decision = await web.delegate!.request!(
        const NavigationRequest(
          url: 'https://guide.invalid/next',
          isMainFrame: true,
        ),
      );
      expect(decision, NavigationDecision.navigate);
      await tester.pump();
      expect(await old, isNull);
      web.start('https://guide.invalid/next');
      web.finish();
      await tester.pump();
      bool complete = false;
      final next = begin(tester)..then((_) => complete = true);
      await tester.pump();
      web.send(late);
      await tester.pump();
      expect(complete, isFalse);
      expect(web.response()['token'], isNot(late['token']));
      web.send(web.response());
      await tester.pump();
      expect((await next)!.status, WebCloudConfigStatus.ready);
      await cleanup(tester);
    },
  );

  testWidgets(
    'channel has no native source authentication: scoped payload AND current top URL are required',
    (tester) async {
      await open(tester);
      bool complete = false;
      final pending = begin(tester)..then((_) => complete = true);
      await tester.pump();
      final scoped = web.response();
      // A raw callback could originate from any frame; no native frame metadata
      // exists. An iframe without the one-shot token cannot complete this read.
      web.send({...scoped, 'token': 'iframe-guess'});
      await tester.pump();
      expect(complete, isFalse);
      expect(web.reads.last, contains('window.top === window'));
      web.url = 'https://untrusted.invalid/';
      web.send(scoped);
      await tester.pump();
      expect(complete, isFalse);
      web.url = 'https://guide.invalid/';
      web.send(scoped);
      await tester.pump();
      expect((await pending)!.status, WebCloudConfigStatus.ready);
      await cleanup(tester);
    },
  );

  testWidgets(
    'concurrent duplicate callbacks complete once even across async URL verification',
    (tester) async {
      await open(tester);
      int completions = 0;
      final pending = begin(tester)..then((_) => completions++);
      await tester.pump();
      final gate = Completer<String?>();
      web.currentUrlOverride = () => gate.future;
      final message = web.response();
      web.send(message);
      web.send(message);
      await tester.pump();
      expect(completions, 0);
      gate.complete('https://guide.invalid/');
      await tester.pump();
      expect((await pending)!.status, WebCloudConfigStatus.ready);
      expect(completions, 1);
      web.send(message);
      await tester.pump();
      expect(completions, 1);
      await cleanup(tester);
    },
  );

  testWidgets(
    'document changes during asynchronous callback trust check discard old response',
    (tester) async {
      await open(tester);
      final pending = begin(tester);
      await tester.pump();
      final gate = Completer<String?>();
      web.currentUrlOverride = () => gate.future;
      web.send(web.response());
      await tester.pump();
      web.start('https://guide.invalid/next');
      gate.complete('https://guide.invalid/next');
      await tester.pump();
      expect(await pending, isNull);
      await cleanup(tester);
    },
  );

  testWidgets(
    'dispose cancels pending read and late callback stays harmless beyond timeout',
    (tester) async {
      await open(tester);
      final pending = begin(tester);
      await tester.pump();
      final late = web.response();
      await cleanup(tester);
      expect(await pending, isNull);
      web.send(late);
      await tester.pump(const Duration(seconds: 6));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'concurrent reads share one native request after async initial trust check',
    (tester) async {
      await open(tester);
      final gate = Completer<String?>();
      web.currentUrlOverride = () => gate.future;
      final first = begin(tester);
      final second = begin(tester);
      gate.complete('https://guide.invalid/');
      await tester.pump();
      expect(web.reads.length, 1);
      web.send(web.response());
      await tester.pump();
      expect((await first)!.status, WebCloudConfigStatus.ready);
      expect((await second)!.status, WebCloudConfigStatus.ready);
      await cleanup(tester);
    },
  );

  testWidgets(
    'iframe and fragment navigation do not invalidate top document request',
    (tester) async {
      await open(tester);
      final pending = begin(tester);
      await tester.pump();
      expect(
        await web.delegate!.request!(
          const NavigationRequest(
            url: 'https://guide.invalid/frame',
            isMainFrame: false,
          ),
        ),
        NavigationDecision.navigate,
      );
      expect(
        await web.delegate!.request!(
          const NavigationRequest(
            url: 'https://guide.invalid/#beans',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.navigate,
      );
      web.send(web.response());
      await tester.pump();
      expect((await pending)!.status, WebCloudConfigStatus.ready);
      await cleanup(tester);
    },
  );

  testWidgets(
    'untrusted initial native URL fails closed without injecting reader',
    (tester) async {
      await open(tester);
      web.url = 'https://evil.invalid/';
      final pending = begin(tester);
      await tester.pump();
      expect(await pending, isNull);
      expect(web.reads, isEmpty);
      await cleanup(tester);
    },
  );

  testWidgets(
    'navigation during initial asynchronous trust check never injects old reader',
    (tester) async {
      await open(tester);
      final gate = Completer<String?>();
      web.currentUrlOverride = () => gate.future;
      final pending = begin(tester);
      web.start('https://guide.invalid/new');
      gate.complete('https://guide.invalid/new');
      await tester.pump();
      expect(await pending, isNull);
      expect(web.reads, isEmpty);
      await cleanup(tester);
    },
  );

  testWidgets(
    'five second timeout returns null and old callback cannot satisfy retry',
    (tester) async {
      await open(tester);
      bool complete = false;
      final pending = begin(tester)..then((_) => complete = true);
      await tester.pump();
      final late = web.response();
      await tester.pump(const Duration(milliseconds: 4999));
      expect(complete, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(await pending, isNull);
      final retry = begin(tester);
      await tester.pump();
      web.send(late);
      await tester.pump();
      web.send(web.response(status: 'disabled'));
      await tester.pump();
      expect((await retry)!.status, WebCloudConfigStatus.disabled);
      await cleanup(tester);
    },
  );
}
