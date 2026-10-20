import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'web_download_bridge.dart';

/// Only an explicit, credential-free HTTPS URL can establish a trust boundary.
Uri? parseBrewGuideUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      RegExp(r'[\s%]').hasMatch(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.port < 1 ||
      uri.port > 65535) {
    return null;
  }
  return uri;
}

/// URI.port includes the effective default (443), not just explicit ports.
bool isTrustedBrewGuideUrl(String configuredUrl, String candidateUrl) {
  final configured = parseBrewGuideUrl(configuredUrl);
  final candidate = parseBrewGuideUrl(candidateUrl);
  return configured != null &&
      candidate != null &&
      configured.host.toLowerCase() == candidate.host.toLowerCase() &&
      configured.port == candidate.port;
}

/// Recheck inside the document too: a navigation can race native injection.
String brewGuidePageScript(String configuredUrl, String downloadToken) {
  final origin = parseBrewGuideUrl(configuredUrl)?.origin;
  if (origin == null) return '';
  final bridge = kInstallWebDownloadBridgeScript.replaceFirst(
    'const bridge = window.BookooFileBridge;',
    'const nativeBridge = window.BookooFileBridge;'
        'const bridge = nativeBridge && { postMessage: message => '
        'nativeBridge.postMessage(JSON.stringify({token: '
        '${jsonEncode(downloadToken)}, message})) };',
  );
  return '(() => { if (window !== window.top || '
      'location.origin !== ${jsonEncode(origin)}) return;\n'
      '$kSuppressBeforeUnloadPromptScript\n'
      '$kAdjustEmbeddedLayoutScript\n$bridge\n})();';
}

/// Brew Guide 更新页面时可能在同步状态下注册 `beforeunload`，Android
/// WebView 会为此显示一套无法跟随应用主题的系统确认框。内嵌模式由应用
/// 自己负责页面生命周期，因此在捕获阶段拦截该提示，让站点更新可以直接刷新。
const String kSuppressBeforeUnloadPromptScript = r'''
(() => {
  if (window.__bookooBrewSuppressBeforeUnloadPrompt) return;
  window.__bookooBrewSuppressBeforeUnloadPrompt = true;
  window.addEventListener(
    'beforeunload',
    (event) => event.stopImmediatePropagation(),
    { capture: true },
  );
})();
''';

/// 内嵌页面由 Flutter 负责系统安全区。站点的 browser-edge-top 色条会再次
/// 使用 Android WebView 的 safe-area-inset-top，盖住已有的顶部导航；仅隐藏
/// 这条浏览器装饰层，不改变导航、下拉上传或站点保存的边距设置。
/// 页面下方已有应用导航栏，保留原有的 24px 底部操作栏间距。
const String kAdjustEmbeddedLayoutScript = r'''
(() => {
  const styleId = 'bookoo-brew-embedded-layout';
  if (document.getElementById(styleId)) return;
  const style = document.createElement('style');
  style.id = styleId;
  style.textContent = `
    :root { --safe-area-bottom: 24px !important; }
    .browser-edge-top { display: none !important; }
  `;
  document.head.appendChild(style);
})();
''';

/// 内嵌 Brew Guide。控制器只创建一次，因此切换到萃取页后网页状态仍保留。
class BrewGuideWebPane extends StatefulWidget {
  const BrewGuideWebPane({super.key, required this.url});

  final String url;

  @override
  State<BrewGuideWebPane> createState() => BrewGuideWebPaneState();
}

class BrewGuideWebPaneState extends State<BrewGuideWebPane> {
  static const _filePickerChannel = MethodChannel(
    'coffee.bookoo.bookoo_brew/file_picker',
  );
  WebViewController? _controller;
  final WebDownloadAssembler _downloadAssembler = WebDownloadAssembler();
  int _generation = 0;
  int _documentGeneration = 0;
  int _progress = 0;
  String? _mainFrameError;
  String _currentUrl = '';
  String _downloadToken = '';

  @override
  void initState() {
    super.initState();
    _configureUrl();
  }

  @override
  void didUpdateWidget(covariant BrewGuideWebPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _configureUrl();
  }

  bool _isActive(int generation) => mounted && generation == _generation;

  void _invalidateDocument() {
    _documentGeneration++;
    _downloadAssembler.clear();
    _downloadToken = '';
  }

  void _configureUrl() {
    final previous = _controller;
    final generation = ++_generation;
    _invalidateDocument();
    _controller = null;
    _currentUrl = '';
    _progress = 0;
    _mainFrameError = null;
    // Retire the old page without deleting cookies, localStorage or IndexedDB.
    if (previous != null) {
      unawaited(previous.loadRequest(Uri.parse('about:blank')));
    }
    final uri = parseBrewGuideUrl(widget.url);
    if (uri == null) {
      return; // No controller or platform/network calls on setup.
    }
    late final WebViewController controller;
    controller =
        WebViewController(
            onPermissionRequest: (request) {
              if (!_isActive(generation)) {
                unawaited(request.deny());
                return;
              }
              unawaited(_handleWebPermissionRequest(request));
            },
          )
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..addJavaScriptChannel(
            kWebDownloadChannelName,
            onMessageReceived: (message) {
              if (_isActive(generation)) {
                unawaited(_handleWebDownloadMessage(message.message));
              }
            },
          )
          ..setNavigationDelegate(
            NavigationDelegate(
              onNavigationRequest: (request) {
                if (!_isActive(generation) ||
                    !_isTrustedBrewGuideUrl(request.url)) {
                  return NavigationDecision.prevent;
                }
                final previousUrl = Uri.tryParse(_currentUrl);
                final requestedUrl = Uri.tryParse(request.url);
                // Fragment-only navigation does not start a new document and
                // may never emit onPageStarted/onPageFinished.
                final sameDocument =
                    previousUrl != null &&
                    requestedUrl != null &&
                    previousUrl.removeFragment() ==
                        requestedUrl.removeFragment();
                if (request.isMainFrame && !sameDocument) {
                  _invalidateDocument();
                  _currentUrl = ''; // Fail closed while navigation is pending.
                }
                return NavigationDecision.navigate;
              },
              onPageStarted: (url) {
                if (!_isActive(generation)) return;
                _invalidateDocument();
                setState(() {
                  _currentUrl = url;
                  _progress = 0;
                  _mainFrameError = null;
                });
              },
              onProgress: (progress) {
                if (_isActive(generation)) setState(() => _progress = progress);
              },
              onPageFinished: (url) {
                if (!_isActive(generation)) return;
                unawaited(
                  _installBrewGuidePageScripts(url, controller, generation),
                );
                setState(() => _progress = 100);
              },
              onWebResourceError: (error) {
                if (error.isForMainFrame != true || !_isActive(generation)) {
                  return;
                }
                setState(() => _mainFrameError = error.description);
              },
            ),
          );
    _controller = controller;
    final platformController = controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setOnShowFileSelector((params) {
        if (!_isActive(generation)) return Future.value(const <String>[]);
        return _pickFiles(params);
      });
    }
    unawaited(controller.loadRequest(uri));
  }

  bool _isTrustedBrewGuideUrl(String url) =>
      isTrustedBrewGuideUrl(widget.url, url);

  Future<bool> _isCurrentDocumentTrusted() async {
    final controller = _controller;
    final generation = _generation;
    final document = _documentGeneration;
    if (controller == null || !_isTrustedBrewGuideUrl(_currentUrl)) {
      return false;
    }
    final url = await controller.currentUrl();
    return _isActive(generation) &&
        document == _documentGeneration &&
        url != null &&
        _isTrustedBrewGuideUrl(url);
  }

  Future<void> _installBrewGuidePageScripts(
    String url,
    WebViewController controller,
    int generation,
  ) async {
    if (!_isTrustedBrewGuideUrl(url)) return;
    final document = _documentGeneration;
    if (!await _isCurrentDocumentTrusted() ||
        !_isActive(generation) ||
        document != _documentGeneration) {
      return;
    }
    if (_downloadToken.isEmpty) {
      _downloadToken = base64UrlEncode(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      );
    }
    try {
      await controller.runJavaScript(
        brewGuidePageScript(widget.url, _downloadToken),
      );
    } catch (_) {
      // A refresh can race script injection; the next completed page retries.
    }
  }

  Future<void> _handleWebPermissionRequest(
    WebViewPermissionRequest request,
  ) async {
    final generation = _generation;
    final document = _documentGeneration;
    final isTrustedBrewGuide = await _isCurrentDocumentTrusted();
    final isCameraOnly =
        request.types.length == 1 &&
        request.types.contains(WebViewPermissionResourceType.camera);
    if (!isTrustedBrewGuide || !isCameraOnly) {
      await request.deny();
      return;
    }

    final status = await Permission.camera.request();
    if (status.isGranted &&
        _isActive(generation) &&
        document == _documentGeneration &&
        await _isCurrentDocumentTrusted()) {
      await request.grant();
      return;
    }

    await request.deny();
    if (!mounted) return;
    final permanentlyDenied = status.isPermanentlyDenied;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          permanentlyDenied ? '摄像头权限已关闭，请到系统设置中允许后再试' : '需要摄像头权限才能拍照识别咖啡豆',
        ),
        action: permanentlyDenied
            ? SnackBarAction(
                label: '去设置',
                onPressed: () => unawaited(openAppSettings()),
              )
            : null,
      ),
    );
  }

  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    final generation = _generation;
    final document = _documentGeneration;
    if (!await _isCurrentDocumentTrusted()) return const [];
    try {
      final selected =
          await _filePickerChannel.invokeListMethod<String>('pickFiles', {
            'acceptTypes': params.acceptTypes,
            'allowMultiple': params.mode == FileSelectorMode.openMultiple,
          }) ??
          const <String>[];
      if (!_isActive(generation) ||
          document != _documentGeneration ||
          !await _isCurrentDocumentTrusted()) {
        return const [];
      }
      return selected;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法打开文件选择器：$error')));
      }
      return const [];
    }
  }

  Future<void> _handleWebDownloadMessage(String message) async {
    final generation = _generation;
    final document = _documentGeneration;
    if (!await _isCurrentDocumentTrusted()) return;
    try {
      final envelope = jsonDecode(message);
      if (_downloadToken.isEmpty ||
          envelope is! Map<String, dynamic> ||
          envelope['token'] != _downloadToken ||
          envelope['message'] is! String) {
        return;
      }
      final payload = _downloadAssembler.addMessage(
        envelope['message'] as String,
      );
      if (payload == null) return;
      final savedUri = await _filePickerChannel
          .invokeMethod<String>('saveFile', {
            'fileName': payload.fileName,
            'mimeType': payload.mimeType,
            'bytes': payload.bytes,
          });
      if (!mounted ||
          !_isActive(generation) ||
          document != _documentGeneration) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(savedUri == null ? '已取消保存' : '数据已导出')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法导出数据：$error')));
    }
  }

  Future<bool> goBackIfPossible() async {
    final controller = _controller;
    final generation = _generation;
    if (controller == null ||
        !await controller.canGoBack() ||
        !_isActive(generation)) {
      return false;
    }
    await controller.goBack();
    return true;
  }

  Future<void> reload() async {
    if (mounted) {
      setState(() {
        _progress = 0;
        _mainFrameError = null;
      });
    }
    await _controller?.reload();
  }

  @override
  void dispose() {
    _generation++;
    _invalidateDocument();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '请在设置中配置自己的 Brew Guide HTTPS 地址',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              label: 'Brew Guide 豆仓、统计和笔记',
              child: WebViewWidget(
                key: ValueKey('brew-guide-webview-$_generation'),
                controller: controller,
              ),
            ),
          ),
          if (_progress < 100 && _mainFrameError == null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress / 100 : null,
                minHeight: 2,
                color: colors.primary,
                backgroundColor: colors.surfaceContainerHighest,
              ),
            ),
          if (_mainFrameError != null)
            Positioned.fill(
              child: ColoredBox(
                color: colors.surface,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.cloud_off_outlined,
                            size: 42,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            '暂时无法打开 Brew Guide',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _mainFrameError!,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: reload,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重新加载'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
