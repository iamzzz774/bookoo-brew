import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class OfflineWebViewPlatform extends WebViewPlatform {
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
