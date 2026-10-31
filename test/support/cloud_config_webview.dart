import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:bookoo_brew/web_cloud_config.dart';

/// Offline platform: channel callbacks intentionally have no frame/origin metadata,
/// exactly like the real Flutter JavaScript channel API.
class CloudConfigWebViewPlatform extends WebViewPlatform {
  final controllers = <CloudConfigController>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = CloudConfigController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => CloudConfigDelegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _View(params);
}

class CloudConfigController extends PlatformWebViewController {
  CloudConfigController(super.params) : super.implementation();
  final channels = <String, JavaScriptChannelParams>{};
  final scripts = <String>[];
  String? url;
  CloudConfigDelegate? delegate;
  Future<String?> Function()? currentUrlOverride;
  Future<void> Function(String)? execute;
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    url = params.uri.toString();
  }

  @override
  Future<String?> currentUrl() async =>
      currentUrlOverride == null ? url : await currentUrlOverride!();
  @override
  Future<void> runJavaScript(String script) async {
    scripts.add(script);
    await execute?.call(script);
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channels[params.name] = params;
  }

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest) callback,
  ) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    delegate = handler as CloudConfigDelegate;
  }

  List<String> get reads => scripts
      .where((s) => s.contains('async (origin, token, requestId)'))
      .toList();
  Map<String, dynamic> response({
    String? script,
    String status = 'ready',
    Map<String, dynamic>? config,
  }) {
    final match = RegExp(
      r'\}\)\(("[^"\n]*"), ("[^"\n]*"), ("[^"\n]*")\);$',
    ).firstMatch(script ?? reads.last)!;
    return {
      'type': 'bookoo.webCloudConfig.v1',
      'origin': jsonDecode(match.group(1)!),
      'token': jsonDecode(match.group(2)!),
      'requestId': jsonDecode(match.group(3)!),
      'status': status,
      if (status == 'ready')
        'config':
            config ??
            {
              'url': 'https://cloud.invalid',
              'key': 'fixture-key',
              'userId': 'default_user',
            },
    };
  }

  void send(Map<String, dynamic> message) => channels[kWebCloudConfigChannel]!
      .onMessageReceived(JavaScriptMessage(message: jsonEncode(message)));
  void start([String next = 'https://guide.invalid/']) {
    url = next;
    delegate!.started!(next);
  }

  void finish() => delegate!.finished!(url!);
}

class CloudConfigDelegate extends PlatformNavigationDelegate {
  CloudConfigDelegate(super.params) : super.implementation();
  NavigationRequestCallback? request;
  PageEventCallback? started, finished;
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

class _View extends PlatformWebViewWidget {
  _View(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox();
}
