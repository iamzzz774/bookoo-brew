import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

abstract class CoordinationTransport {
  Stream<String> get messages;
  Future<void> send(String value);
  Future<void> close();
}

class _SocketTransport implements CoordinationTransport {
  final WebSocket socket;
  _SocketTransport(this.socket);
  @override
  Stream<String> get messages =>
      socket.where((v) => v is String).cast<String>();
  @override
  Future<void> send(String value) async => socket.add(value);
  @override
  Future<void> close() async => socket.close();
}

class _ReplyWaiter {
  final bool Function(Map<String, dynamic>) matches;
  final result = Completer<Map<String, dynamic>>();
  _ReplyWaiter(this.matches) {
    // A synchronous fake transport (or a disconnect during send) may complete
    // before the caller awaits this future. Always install an error handler.
    unawaited(result.future.then<void>((_) {}, onError: (Object _) {}));
  }
}

/// Read-only discovery uses the existing data connection, never a private Mac
/// endpoint. Only an explicit, validated acquired reply permits coordinated BLE.
/// A durable uncertain handoff is never treated as standalone or auto-recovered.
class DeviceCoordination {
  static const pendingKey = 'coffeeCoordinationPendingV1';
  final Future<CoordinationTransport> Function(Uri) dial;
  final Duration offerTimeout;
  final Duration requestTimeout;
  final Duration connectionTimeout;
  final Duration heartbeatInterval;
  CoordinationTransport? _transport;
  StreamSubscription<String>? _subscription;
  Timer? _heartbeat;
  Completer<void>? _joining;
  final _waiters = <_ReplyWaiter>{};
  final _ioCancels = <void Function()>{};
  final _observedScopes = <String>{};
  final _standaloneScopes = <String>{};
  Future<void>? _acquiring;
  Future<void>? _releasing;
  bool _disposed = false, _connected = false, _pending = false, _owned = false;
  int _generation = 0, _ref = 0;
  String _clientId = '',
      _sessionId = '',
      _leaseId = '',
      _scope = '',
      _topic = '',
      _macId = '',
      _challenge = '',
      _originalAcquireRequestId = '';
  String _baseUrl = '', _key = '', _userId = '';
  Set<String> _resources = {};

  DeviceCoordination({
    Future<CoordinationTransport> Function(Uri)? dial,
    this.offerTimeout = const Duration(milliseconds: 1500),
    this.requestTimeout = const Duration(seconds: 20),
    this.connectionTimeout = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 10),
  }) : dial =
           dial ??
           ((uri) async =>
               _SocketTransport(await WebSocket.connect(uri.toString())));

  static String _id() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  static bool _validId(dynamic id) =>
      id is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(id);
  static bool _validResources(dynamic r) =>
      r is List &&
      r.isNotEmpty &&
      r.length <= 2 &&
      r.every((v) => v == 'scale' || v == 'grinder') &&
      r.toSet().length == r.length;
  bool get hasLease => _owned && !_disposed && _connected;
  int get _now => DateTime.now().millisecondsSinceEpoch;
  void _checkOpen() {
    if (_disposed) throw StateError('协调已关闭；如有未完成交接，请在 Mac 检查恢复');
  }

  StateError _recoveryError() =>
      StateError('设备交接尚未确认；请在 Mac 检查并显式恢复，再重试。未确认前不要连接蓝牙');

  Map<String, dynamic> _message(String type, String request) => {
    'schemaVersion': 1,
    'type': type,
    'clientId': _clientId,
    'sessionId': _sessionId,
    'requestId': request,
    'atMs': _now,
    'resources': _resources.toList()..sort(),
    if (type != 'hello') 'macId': _macId,
    if (type == 'acquire') 'challenge': _challenge,
    if (type == 'release' || type == 'pulse') 'leaseId': _leaseId,
  };

  /// Cancel timers immediately on disposal/disconnect, even when injected I/O
  /// never finishes. Late I/O failures are consumed, not unhandled futures.
  Future<T> _bounded<T>(Future<T> operation, Duration timeout) async {
    final result = Completer<T>();
    void cancel() {
      if (!result.isCompleted) result.completeError(_recoveryError());
    }

    _ioCancels.add(cancel);
    final timer = Timer(timeout, cancel);
    operation.then<void>(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(_recoveryError(), stack);
      },
    );
    try {
      return await result.future;
    } finally {
      timer.cancel();
      _ioCancels.remove(cancel);
    }
  }

  Future<void> _send(Map<String, dynamic> message) async {
    _checkOpen();
    final t = _transport;
    if (t == null || !_connected) throw _recoveryError();
    await _bounded(
      t.send(
        jsonEncode({
          'topic': _topic,
          'event': 'broadcast',
          'payload': {
            'type': 'broadcast',
            'event': 'coffee_coordination',
            'payload': message,
          },
          'ref': '${++_ref}',
          'join_ref': '1',
        }),
      ),
      requestTimeout,
    );
  }

  bool _matches(
    Map<String, dynamic> m,
    String request,
    Set<String> types, {
    required bool discovery,
  }) =>
      m['schemaVersion'] is int &&
      m['schemaVersion'] == 1 &&
      m['clientId'] == _clientId &&
      m['sessionId'] == _sessionId &&
      m['requestId'] == request &&
      types.contains(m['type']) &&
      m['atMs'] is int &&
      (_now - (m['atMs'] as int)).abs() <= 30000 &&
      _validId(m['macId']) &&
      (discovery || m['macId'] == _macId) &&
      _validResources(m['resources']) &&
      (m['resources'] as List).length == _resources.length &&
      _resources.containsAll((m['resources'] as List).cast<String>()) &&
      (m['type'] != 'released' || m['leaseId'] == _leaseId) &&
      (m['type'] != 'acquired' || _validId(m['leaseId']));

  Future<Map<String, dynamic>> _exchange(
    String type,
    String request,
    Set<String> types,
    Duration timeout, {
    bool discovery = false,
    void Function()? onObserved,
  }) async {
    _checkOpen();
    final waiter = _ReplyWaiter((m) {
      if (m['clientId'] == _clientId &&
          m['sessionId'] == _sessionId &&
          m['requestId'] == request &&
          types.contains(m['type'])) {
        onObserved?.call();
      }
      return _matches(m, request, types, discovery: discovery);
    });
    _waiters.add(waiter);
    final timer = Timer(timeout, () {
      if (!waiter.result.isCompleted) {
        waiter.result.completeError(TimeoutException('设备协调未确认，请在 Mac 检查'));
      }
    });
    try {
      final sending = _send(_message(type, request));
      final result = await Future.any([
        waiter.result.future,
        sending.then((_) => waiter.result.future),
      ]);
      _checkOpen();
      if (!discovery && !_connected) throw _recoveryError();
      return result;
    } finally {
      timer.cancel();
      _waiters.remove(waiter);
    }
  }

  void _connectionLost() {
    _generation++;
    _connected = false;
    _owned = false;
    for (final cancel in _ioCancels.toList()) {
      cancel();
    }
    _heartbeat?.cancel();
    _heartbeat = null;
    final joining = _joining;
    if (joining != null && !joining.isCompleted) {
      joining.completeError(_recoveryError());
    }
    for (final waiter in _waiters.toList()) {
      if (!waiter.result.isCompleted) {
        waiter.result.completeError(_recoveryError());
      }
    }
  }

  Future<void> _connect() async {
    _checkOpen();
    await _closeSocket();
    _checkOpen();
    final generation = _generation;
    final base = Uri.parse(_baseUrl);
    if (base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path != '' && base.path != '/')) {
      throw StateError('数据连接地址无效');
    }
    _topic =
        'realtime:bookoo-coordination-v1:${base64Url.encode(utf8.encode(_userId)).replaceAll('=', '')}';
    final uri = base.replace(
      scheme: 'wss',
      path: '/realtime/v1/websocket',
      queryParameters: {'apikey': _key, 'vsn': '1.0.0'},
    );
    bool accepting = true;
    try {
      final opening = dial(uri).then((t) async {
        if (!accepting || _disposed || generation != _generation) {
          try {
            await t.close();
          } catch (_) {}
          throw _recoveryError();
        }
        return t;
      });
      _transport = await _bounded(opening, connectionTimeout);
      _checkOpen();
      final joined = Completer<void>();
      unawaited(joined.future.then<void>((_) {}, onError: (Object _) {}));
      _joining = joined;
      _subscription = _transport!.messages.listen(
        (raw) {
          try {
            final doc = jsonDecode(raw);
            if (doc is! Map || doc['topic'] != _topic) return;
            if (doc['event'] == 'phx_close' || doc['event'] == 'phx_error') {
              _connectionLost();
            } else if (doc['event'] == 'phx_reply' &&
                doc['ref'] == '1' &&
                !joined.isCompleted) {
              if (doc['payload'] is Map && doc['payload']['status'] == 'ok') {
                joined.complete();
              } else {
                joined.completeError(_recoveryError());
              }
            } else if (doc['event'] == 'broadcast' &&
                doc['payload'] is Map &&
                doc['payload']['type'] == 'broadcast' &&
                doc['payload']['event'] == 'coffee_coordination' &&
                doc['payload']['payload'] is Map) {
              final m = Map<String, dynamic>.from(doc['payload']['payload']);
              for (final w in _waiters.toList()) {
                if (!w.result.isCompleted && w.matches(m)) w.result.complete(m);
              }
            }
          } catch (_) {
            /* Malformed/unrelated frames cannot grant ownership. */
          }
        },
        onError: (_) => _connectionLost(),
        onDone: _connectionLost,
      );
      _ref = 1;
      await _bounded(
        _transport!.send(
          jsonEncode({
            'topic': _topic,
            'event': 'phx_join',
            'ref': '1',
            'join_ref': '1',
            'payload': {
              'config': {
                'broadcast': {'ack': false, 'self': false},
                'presence': {'enabled': false},
                'private': false,
              },
            },
          }),
        ),
        connectionTimeout,
      );
      await _bounded(joined.future, connectionTimeout);
      _checkOpen();
      if (generation != _generation) throw _recoveryError();
      _connected = true;
      _joining = null;
      bool heartbeatBusy = false;
      _heartbeat = Timer.periodic(heartbeatInterval, (_) {
        final t = _transport;
        if (t == null || !_connected || heartbeatBusy) return;
        heartbeatBusy = true;
        unawaited(() async {
          try {
            await _bounded(
              t.send(
                jsonEncode({
                  'topic': 'phoenix',
                  'event': 'heartbeat',
                  'payload': {},
                  'ref': '${++_ref}',
                }),
              ),
              requestTimeout,
            );
            if (generation == _generation && _owned) {
              await _send(_message('pulse', _id()));
            }
          } catch (_) {
            if (generation == _generation) _connectionLost();
          } finally {
            heartbeatBusy = false;
          }
        }());
      });
    } catch (_) {
      accepting = false;
      await _closeSocket();
      throw _recoveryError(); // Never expose a credential-bearing socket error.
    }
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    if (!await p.setString(
      pendingKey,
      jsonEncode({
        'schemaVersion': 1,
        'scope': _scope,
        'clientId': _clientId,
        'sessionId': _sessionId,
        'leaseId': _leaseId,
        'resources': _resources.toList()..sort(),
        'macId': _macId,
        'challenge': _challenge,
        'originalAcquireRequestId': _originalAcquireRequestId,
      }),
    )) {
      throw _recoveryError();
    }
    _pending = true;
  }

  void _loadPending(String raw, String expectedScope) {
    try {
      final p = jsonDecode(raw);
      if (p is! Map ||
          p['schemaVersion'] is! int ||
          p['schemaVersion'] != 1 ||
          p['scope'] != expectedScope ||
          !_validResources(p['resources']) ||
          !['clientId', 'sessionId', 'macId'].every((k) => _validId(p[k])) ||
          !(p['leaseId'] == '' || _validId(p['leaseId'])) ||
          (p['leaseId'] == '' &&
              ![
                'challenge',
                'originalAcquireRequestId',
              ].every((k) => _validId(p[k]))) ||
          (p['challenge'] != null && !_validId(p['challenge'])) ||
          (p['originalAcquireRequestId'] != null &&
              !_validId(p['originalAcquireRequestId']))) {
        throw _recoveryError();
      }
      _clientId = p['clientId'];
      _sessionId = p['sessionId'];
      _resources = (p['resources'] as List).cast<String>().toSet();
      _macId = p['macId'];
      _challenge = p['challenge'] ?? '';
      _originalAcquireRequestId = p['originalAcquireRequestId'] ?? '';
      _leaseId = p['leaseId'];
      _pending = true;
    } catch (_) {
      // Legacy schema-1 states without macId cannot safely address a release.
      throw _recoveryError();
    }
  }

  Future<void> _repeatAcquire() async {
    final reply = await _exchange('acquire', _originalAcquireRequestId, {
      'acquired',
      'error',
    }, requestTimeout);
    if (reply['type'] != 'acquired') throw _recoveryError();
    _leaseId = reply['leaseId'];
    await _persist();
    _checkOpen();
  }

  Future<void> acquire({
    required String baseUrl,
    required String key,
    required String userId,
    required Set<String> resources,
  }) {
    _checkOpen();
    if (_acquiring != null || _releasing != null) {
      throw StateError('设备交接正在进行，请等待完成');
    }
    final operation = _acquire(baseUrl, key, userId, resources);
    _acquiring = operation;
    // Return the cleanup chain, not an ignored future that could leak errors.
    return operation.whenComplete(() {
      _acquiring = null;
    });
  }

  Future<void> _acquire(
    String baseUrl,
    String key,
    String userId,
    Set<String> resources,
  ) async {
    if (!_validResources(resources.toList())) {
      throw ArgumentError('Invalid resources');
    }
    final scope = jsonEncode([baseUrl, userId]);
    if (hasLease) {
      if (_scope == scope &&
          _resources.length == resources.length &&
          _resources.containsAll(resources)) {
        return;
      }
      throw StateError('请先结束当前设备使用');
    }
    final p = await SharedPreferences.getInstance();
    _checkOpen();
    final raw = p.getString(pendingKey);
    // Validate before changing the in-memory channel. An account switch must
    // never redirect an outstanding release into another user's topic.
    if (raw != null) _loadPending(raw, scope);
    _baseUrl = baseUrl;
    _key = key;
    _userId = userId;
    _scope = scope;
    if (raw != null) {
      try {
        await _connect();
        await _releasePending();
      } catch (_) {
        await _closeSocket();
        throw _recoveryError();
      }
    }
    _checkOpen();
    if (_standaloneScopes.contains(scope)) return;
    _clientId = p.getString('coffeeCoordinationClientId') ?? _id();
    if (!_validId(_clientId)) _clientId = _id();
    if (!await p.setString('coffeeCoordinationClientId', _clientId)) {
      throw _recoveryError();
    }
    _sessionId = _id();
    _resources = Set.of(resources);
    _leaseId = '';
    _macId = '';
    _challenge = '';
    _originalAcquireRequestId = '';
    try {
      await _connect();
    } catch (_) {
      _checkOpen();
      if (_observedScopes.contains(scope)) throw _recoveryError();
      _standaloneScopes.add(scope);
      return; // Read-only discovery unavailable: ordinary independent BLE.
    }
    bool observed = false;
    try {
      final offer = await _exchange(
        'hello',
        _id(),
        {'offer', 'error'},
        offerTimeout,
        discovery: true,
        onObserved: () {
          observed = true;
          _observedScopes.add(scope);
        },
      );
      observed = true;
      if (offer['type'] != 'offer' ||
          !_validId(offer['challenge']) ||
          offer['expiresAtMs'] is! int ||
          offer['expiresAtMs'] <= _now ||
          offer['expiresAtMs'] > _now + 30000) {
        throw _recoveryError();
      }
      _macId = offer['macId'];
      _challenge = offer['challenge'];
      _originalAcquireRequestId = _id();
      // These exact identifiers MUST be durable before acquire can have effects.
      await _persist();
      _checkOpen();
      await _repeatAcquire();
      _checkOpen();
      if (!_connected) throw _recoveryError();
      _owned = true;
    } on TimeoutException {
      await _closeSocket();
      _checkOpen();
      if (observed || _pending || _observedScopes.contains(scope)) {
        throw _recoveryError();
      }
      _standaloneScopes.add(scope);
    } catch (_) {
      await _closeSocket();
      _checkOpen();
      // A discovery disconnect before any offer is also standalone.
      if (!observed && !_pending && !_observedScopes.contains(scope)) {
        _standaloneScopes.add(scope);
        return;
      }
      throw _recoveryError();
    }
  }

  Future<void> _releasePending() async {
    _owned = false;
    if (_leaseId.isEmpty) await _repeatAcquire();
    final result = await _exchange('release', _id(), {
      'released',
      'error',
    }, requestTimeout);
    if (result['type'] != 'released') throw _recoveryError();
    final p = await SharedPreferences.getInstance();
    if (!await p.remove(pendingKey)) throw _recoveryError();
    _pending = false;
    _leaseId = '';
    await _closeSocket();
  }

  /// Caller must drain acquire, then disconnect BOTH BLE clients before release.
  /// An uncertain acquire is reconciled using its original request, not hello.
  Future<void> release() {
    final existing = _releasing;
    if (existing != null) return existing;
    final operation = _release();
    _releasing = operation.whenComplete(() {
      _releasing = null;
    });
    return _releasing!;
  }

  Future<void> _release() async {
    _checkOpen();
    if (_acquiring != null) throw StateError('请先等待设备交接完成，再断开蓝牙并释放');
    if (!_pending) {
      final p = await SharedPreferences.getInstance();
      _checkOpen();
      // An unparseable/legacy or not-yet-loaded intent is NOT a release.
      // Without a validated owner and backend context, only the Mac can recover.
      if (p.getString(pendingKey) != null) throw _recoveryError();
      await _closeSocket();
      return;
    }
    try {
      if (!_connected) await _connect();
      await _releasePending();
    } catch (_) {
      await _closeSocket();
      throw _recoveryError();
    }
  }

  Future<void> _closeSocket() async {
    _connectionLost();
    _joining = null;
    final sub = _subscription;
    _subscription = null;
    await sub?.cancel();
    final t = _transport;
    _transport = null;
    try {
      await t?.close();
    } catch (_) {}
  }

  /// Never releases ownership implicitly: disposal is not BLE-disconnect proof.
  Future<void> dispose() async {
    _disposed = true;
    await _closeSocket();
  }
}
