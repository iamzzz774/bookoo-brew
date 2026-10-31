import 'dart:convert';

const kWebCloudConfigChannel = 'BookooCloudConfigBridge';
const _messageType = 'bookoo.webCloudConfig.v1';

/// No network, preferences, Flutter, or WebView dependency.
enum WebCloudConfigStatus { ready, missing, disabled, unsupported }

class WebCloudConfig {
  const WebCloudConfig._(this.url, this.key, this.userId);
  final String url;
  final String key;
  final String userId;

  @override
  String toString() => 'WebCloudConfig([redacted])';
}

class WebCloudConfigResult {
  const WebCloudConfigResult._(this.status, [this.config]);
  final WebCloudConfigStatus status;
  final WebCloudConfig? config;

  @override
  String toString() => 'WebCloudConfigResult(${status.name})';
}

bool _bounded(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

bool _correlation(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value);

// Reject URL parser repairs and credentials (including empty userinfo). Preserve
// the original endpoint, key and identity; validation must never normalize them.
bool _endpoint(Object? value) {
  if (!_bounded(value, 2048) || value is! String) return false;
  if (!value.startsWith('https://') || RegExp(r'[\s\\@?#]').hasMatch(value)) {
    return false;
  }
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || (uri.port > 0 && uri.port <= 65535));
}

bool _origin(String origin) {
  if (!_endpoint(origin)) return false;
  final uri = Uri.parse(origin);
  return uri.path.isEmpty && uri.origin == origin;
}

bool _keys(Map<String, dynamic> map, Set<String> keys) =>
    map.length == keys.length && map.keys.every(keys.contains);

/// Returns null for malformed, untrusted, stale, or oversized messages. Never
/// includes decoded inputs in an exception, diagnostic, or toString output.
/// Caller must additionally verify current document URL/generation and consume
/// the request once; JavaScript channel messages do not authenticate a document.
WebCloudConfigResult? parseWebCloudConfigMessage(
  String raw, {
  required String origin,
  required String token,
  required String requestId,
}) {
  if (raw.length > 24576 ||
      !_origin(origin) ||
      !_correlation(token) ||
      !_correlation(requestId)) {
    return null;
  }
  try {
    final message = jsonDecode(raw);
    if (message is! Map<String, dynamic> ||
        message['type'] != _messageType ||
        message['origin'] != origin ||
        message['token'] != token ||
        message['requestId'] != requestId) {
      return null;
    }
    final status = switch (message['status']) {
      'ready' => WebCloudConfigStatus.ready,
      'missing' => WebCloudConfigStatus.missing,
      'disabled' => WebCloudConfigStatus.disabled,
      'unsupported' => WebCloudConfigStatus.unsupported,
      _ => null,
    };
    if (status == null ||
        !_keys(message, {
          'type',
          'origin',
          'token',
          'requestId',
          'status',
          if (status == WebCloudConfigStatus.ready) 'config',
        })) {
      return null;
    }
    if (status != WebCloudConfigStatus.ready) {
      return WebCloudConfigResult._(status);
    }
    final config = message['config'];
    if (config is! Map<String, dynamic> ||
        !_keys(config, {'url', 'key', 'userId'}) ||
        !_endpoint(config['url']) ||
        !_bounded(config['key'], 8192) ||
        (config['key'] as String).trim() != config['key'] ||
        !_bounded(config['userId'], 256) ||
        (config['userId'] as String).trim().isEmpty) {
      return null;
    }
    return WebCloudConfigResult._(
      status,
      WebCloudConfig._(config['url'], config['key'], config['userId']),
    );
  } catch (_) {
    return null;
  }
}

/// One-shot, read-only reader. The nonce is [token], bound to [requestId].
/// Schema evidence and executable fixtures: test/web_cloud_config_source.md.
/// Only reads BrewGuideDB/appSettings.get('main').data.supabaseSync. No legacy
/// localStorage fallback: that migration source can be stale after IDB edits.
/// Current upstream fixes cloud identity to default_user (not a userId setting).
String webCloudConfigReadScript({
  required String origin,
  required String token,
  required String requestId,
}) {
  if (!_origin(origin) || !_correlation(token) || !_correlation(requestId)) {
    throw const FormatException('Invalid cloud config request scope');
  }
  return '(async (origin, token, requestId) => {\n'
      '"use strict";\n'
      'const type = ${jsonEncode(_messageType)};\n'
      'const channel = ${jsonEncode(kWebCloudConfigChannel)};\n'
      '$_readerJavaScript\n'
      '})(${jsonEncode(origin)}, ${jsonEncode(token)}, '
      '${jsonEncode(requestId)});';
}

const _readerJavaScript = r'''
  const trusted = () => {
    try {
      return window.top === window && location.protocol === 'https:' &&
        location.origin === origin && new URL(origin).origin === origin;
    } catch (_) { return false; }
  };
  if (!trusted() || !/^[A-Za-z0-9_-]{1,128}$/.test(token) ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(requestId)) return;
  const bridge = window[channel];
  if (!bridge || typeof bridge.postMessage !== 'function') return;
  let sent = false, db = null, tx = null;
  const emit = (status, config) => {
    if (sent) return;
    sent = true;
    clearTimeout(timer);
    if (db) { try { db.close(); } catch (_) {} }
    if (!trusted()) return;
    const message = {type, origin, token, requestId, status};
    if (status === 'ready') message.config = config;
    try { bridge.postMessage(JSON.stringify(message)); } catch (_) {}
  };
  const timer = setTimeout(() => {
    if (tx) { try { tx.abort(); } catch (_) {} }
    emit('unsupported');
  }, 3000);
  const bounded = (v, n) => typeof v === 'string' && v.length > 0 &&
    v.length <= n && !/[\x00-\x1f\x7f]/.test(v);
  const endpoint = v => {
    if (!bounded(v, 2048) || !/^https:\/\/[^/]+(?:\/.*)?$/.test(v) || /[\s\\@?#]/.test(v)) return false;
    try {
      const u = new URL(v);
      return u.protocol === 'https:' && !!u.hostname && !u.username &&
        !u.password && (!u.port || (+u.port > 0 && +u.port <= 65535));
    } catch (_) { return false; }
  };
  const readConfig = record => {
    if (!record) return emit('missing');
    if (record.id !== 'main' || !record.data || typeof record.data !== 'object' ||
        Array.isArray(record.data)) return emit('unsupported');
    const settings = record.data;
    const c = settings.supabaseSync;
    if (c == null) return emit('missing');
    if (typeof c !== 'object' || Array.isArray(c)) return emit('unsupported');
    if (c.enabled === false) return emit('disabled');
    if (c.enabled !== true) return emit('unsupported');
    // Active provider is authoritative in the current upstream. For records
    // before activeSyncType was introduced upstream infers it from enabled.
    if (Object.prototype.hasOwnProperty.call(settings, 'activeSyncType')) {
      if (!['none', 'supabase', 's3', 'webdav'].includes(settings.activeSyncType))
        return emit('unsupported');
      if (settings.activeSyncType !== 'supabase') return emit('disabled');
    }
    if (c.url == null || c.anonKey == null || c.url === '' || c.anonKey === '')
      return emit('missing');
    if (!endpoint(c.url) || !bounded(c.anonKey, 8192) || c.anonKey.trim() !== c.anonKey)
      return emit('unsupported');
    // Served sync operations use a constant y="default_user" for user_id,
    // including .eq("user_id", y). There is no configurable identity to read.
    emit('ready', {url: c.url, key: c.anonKey, userId: 'default_user'});
  };
  try {
    if (typeof indexedDB === 'undefined' || !indexedDB || typeof indexedDB.open !== 'function')
      return emit('unsupported');
    if (typeof indexedDB.databases === 'function') {
      const names = await indexedDB.databases();
      if (sent) return;
      if (!names.some(item => item.name === 'BrewGuideDB')) return emit('missing');
    }
    if (!trusted() || sent) return;
    // No version argument: never upgrade an existing DB. Even after a successful
    // databases() check a concurrent deletion can occur; ALWAYS abort creation.
    const req = indexedDB.open('BrewGuideDB');
    let creationAborted = false;
    req.onupgradeneeded = () => {
      creationAborted = true;
      try { req.transaction.abort(); } catch (_) {}
      emit('missing');
    };
    req.onerror = () => emit(creationAborted ? 'missing' : 'unsupported');
    req.onblocked = () => emit('unsupported');
    req.onsuccess = () => {
      db = req.result;
      if (sent || creationAborted || !trusted()) { db.close(); return; }
      db.onversionchange = () => {
        if (tx) { try { tx.abort(); } catch (_) {} }
        emit('unsupported');
      };
      try {
        if (!db.objectStoreNames.contains('appSettings')) return emit('unsupported');
        tx = db.transaction(['appSettings'], 'readonly');
        tx.onabort = () => emit('unsupported');
        tx.onerror = () => emit('unsupported');
        const get = tx.objectStore('appSettings').get('main');
        let record;
        get.onsuccess = () => { record = get.result; };
        get.onerror = () => emit('unsupported');
        tx.oncomplete = () => { if (!sent) readConfig(record); };
      } catch (_) { emit('unsupported'); }
    };
  } catch (_) { emit('unsupported'); }
''';
