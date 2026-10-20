import 'dart:convert';
import 'dart:typed_data';

const String kWebDownloadChannelName = 'BookooFileBridge';

/// Brew Guide 网页版通过 `Blob` + 隐藏下载链接导出 JSON。Android WebView
/// 不会替网页保存 `blob:` URL，因此把文件分块送回 Flutter，再交给系统文档
/// 选择器保存。分块可避免单条 JavaScript channel 消息过大。
const String kInstallWebDownloadBridgeScript = r'''
(() => {
  const bridge = window.BookooFileBridge;
  if (!bridge || window.__bookooBrewDownloadBridgeInstalled) return;
  window.__bookooBrewDownloadBridgeInstalled = true;

  const blobUrls = new Map();
  const retainedUrls = new Set();
  const originalCreateObjectURL = URL.createObjectURL.bind(URL);
  const originalRevokeObjectURL = URL.revokeObjectURL.bind(URL);
  URL.createObjectURL = function(value) {
    const url = originalCreateObjectURL(value);
    if (value instanceof Blob) blobUrls.set(url, value);
    return url;
  };
  URL.revokeObjectURL = function(url) {
    const key = String(url);
    // Brew Guide 的部分 ZIP 下载会在 click() 后立刻释放 URL。桥接读取完成
    // 前先保留 Blob，随后由桥接主动释放。
    if (retainedUrls.has(key)) return;
    blobUrls.delete(key);
    originalRevokeObjectURL(url);
  };

  const originalClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function(...args) {
    const href = this.href || '';
    const fileName = this.download || '';
    if (!fileName || !href.startsWith('blob:')) {
      return originalClick.apply(this, args);
    }

    const id = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    retainedUrls.add(href);
    const releaseBlob = () => {
      retainedUrls.delete(href);
      blobUrls.delete(href);
      originalRevokeObjectURL(href);
    };
    Promise.resolve(blobUrls.get(href))
      .then((blob) => blob || fetch(href).then((response) => response.blob()))
      .then((blob) => new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve({ blob, dataUrl: reader.result });
        reader.onerror = () => reject(reader.error || new Error('读取导出文件失败'));
        reader.readAsDataURL(blob);
      }))
      .then(({ blob, dataUrl }) => {
        const value = String(dataUrl || '');
        const comma = value.indexOf(',');
        if (comma < 0) throw new Error('导出文件格式无效');

        const encoded = value.slice(comma + 1);
        const chunkSize = 256 * 1024;
        const totalChunks = Math.ceil(encoded.length / chunkSize);
        bridge.postMessage(JSON.stringify({
          kind: 'start',
          id,
          fileName,
          mimeType: blob.type || 'application/json',
          totalChunks,
        }));
        for (let index = 0; index < totalChunks; index += 1) {
          bridge.postMessage(JSON.stringify({
            kind: 'chunk',
            id,
            index,
            data: encoded.slice(index * chunkSize, (index + 1) * chunkSize),
          }));
        }
        bridge.postMessage(JSON.stringify({ kind: 'end', id }));
        releaseBlob();
      })
      .catch((error) => {
        releaseBlob();
        bridge.postMessage(JSON.stringify({
          kind: 'error',
          id,
          message: error instanceof Error ? error.message : String(error),
        }));
      });
  };
})();
''';

class WebDownloadPayload {
  const WebDownloadPayload({
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });

  final String fileName;
  final String mimeType;
  final Uint8List bytes;
}

class WebDownloadAssembler {
  static const int _maxChunks = 4096;
  static const int _maxChunkCharacters = 300 * 1024;

  final Map<String, _PendingWebDownload> _pending = {};

  WebDownloadPayload? addMessage(String rawMessage) {
    final decoded = jsonDecode(rawMessage);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('导出消息格式无效');
    }

    final kind = decoded['kind'];
    final id = decoded['id'];
    if (kind is! String || id is! String || id.isEmpty) {
      throw const FormatException('导出消息缺少标识');
    }

    switch (kind) {
      case 'start':
        final fileName = decoded['fileName'];
        final mimeType = decoded['mimeType'];
        final totalChunks = decoded['totalChunks'];
        if (fileName is! String ||
            fileName.trim().isEmpty ||
            mimeType is! String ||
            totalChunks is! int ||
            totalChunks < 0 ||
            totalChunks > _maxChunks) {
          throw const FormatException('导出文件信息无效');
        }
        _pending[id] = _PendingWebDownload(
          fileName: fileName,
          mimeType: mimeType.isEmpty ? 'application/octet-stream' : mimeType,
          chunks: List<String?>.filled(totalChunks, null),
        );
        return null;
      case 'chunk':
        final pending = _pending[id];
        final index = decoded['index'];
        final data = decoded['data'];
        if (pending == null ||
            index is! int ||
            index < 0 ||
            index >= pending.chunks.length ||
            data is! String ||
            data.length > _maxChunkCharacters) {
          _pending.remove(id);
          throw const FormatException('导出文件分块无效');
        }
        pending.chunks[index] = data;
        return null;
      case 'end':
        final pending = _pending.remove(id);
        if (pending == null || pending.chunks.any((chunk) => chunk == null)) {
          throw const FormatException('导出文件接收不完整');
        }
        final encoded = StringBuffer();
        for (final chunk in pending.chunks) {
          encoded.write(chunk);
        }
        return WebDownloadPayload(
          fileName: pending.fileName,
          mimeType: pending.mimeType,
          bytes: base64Decode(encoded.toString()),
        );
      case 'error':
        _pending.remove(id);
        final message = decoded['message'];
        throw StateError(
            message is String && message.isNotEmpty ? message : '网页导出文件失败');
      default:
        throw const FormatException('未知的导出消息');
    }
  }

  void clear() => _pending.clear();
}

class _PendingWebDownload {
  const _PendingWebDownload({
    required this.fileName,
    required this.mimeType,
    required this.chunks,
  });

  final String fileName;
  final String mimeType;
  final List<String?> chunks;
}
