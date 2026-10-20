import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'bookoo_scan.dart';
import 'mt80_protocol.dart';

/// Independent, read-only MT80 GATT client. The ONLY RX write is appHello.
/// No setting, preset, start, stop, or cleaning command API is exposed.
class Mt80Ble extends ChangeNotifier {
  static final serviceUuid = Guid('4d543830-0001-4b80-8f00-424f4f4b4f4f');
  static final rxUuid = Guid('4d543830-0002-4b80-8f00-424f4f4b4f4f');
  static final txUuid = Guid('4d543830-0003-4b80-8f00-424f4f4b4f4f');
  final String? Function()? currentBeanId;
  Mt80Ble({this.currentBeanId});
  String? _beanAtGrindStart;
  final _protocol = Mt80Protocol();
  final _detector = Mt80EventDetector();
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;
  BluetoothDevice? _device;
  final _ownedDevices = <BluetoothDevice>{};
  StreamSubscription? _notifications, _connection;
  Timer? _watchdog, _retry;
  Future<void>? _connecting;
  int _generation = 0, _retries = 0;
  bool _enabled = false, _disposed = false, _ready = false;
  String status = 'MT80 未连接';
  Mt80Sample? sample;
  int? releaseVer;
  bool get ready => _ready;
  bool _current(int g) => !_disposed && _enabled && _generation == g;

  void _status(String value) {
    status = value;
    if (!_disposed) notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (enabled) {
      _retries = 0;
      final before = _generation;
      await connect();
      // A rapid off/on can await the cancelled old attempt. Once it has
      // drained, start a fresh attempt instead of staying enabled but idle.
      if (_enabled &&
          !_disposed &&
          !_ready &&
          _generation != before &&
          _connecting == null &&
          _retry?.isActive != true &&
          _retries < 3) {
        await connect();
      }
    } else {
      await _disconnect();
      _status('MT80 未连接');
    }
  }

  Future<void> connect() {
    if (_disposed || !_enabled) return Future.value();
    _retry?.cancel();
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    await _disconnect();
    if (_disposed || !_enabled) return;
    final g = _generation;
    _status('MT80 连接中…');
    BluetoothDevice? attemptDevice;
    try {
      if (!await BookooScan.permissions()) throw StateError('蓝牙权限被拒绝');
      if (!_current(g)) return;
      final devices = await BookooScan.find(
        BookooScan.isGrinderName,
        cancelled: () => !_current(g),
      );
      if (!_current(g)) return;
      if (devices.isEmpty) throw StateError('MT80 未连接 · 点击重连');
      if (devices.length != 1) throw StateError('发现多台 MT80，请仅开启目标磨豆机后重试');
      final device = devices.single;
      attemptDevice = device;
      _device = device;
      _ownedDevices.add(device);
      _connection = device.connectionState.listen((state) {
        if (_current(g) &&
            state == BluetoothConnectionState.disconnected &&
            _ready) {
          unawaited(_failed('MT80 未连接 · 点击重连', g));
        }
      });
      await device.connect(timeout: const Duration(seconds: 12));
      if (!_current(g)) return;
      final services = await device.discoverServices().timeout(
        const Duration(seconds: 8),
      );
      if (!_current(g)) return;
      BluetoothCharacteristic? rx, tx;
      for (final svc in services.where((s) => s.uuid == serviceUuid)) {
        for (final c in svc.characteristics) {
          if (c.uuid == rxUuid) rx = c;
          if (c.uuid == txUuid) tx = c;
        }
      }
      if (rx == null ||
          tx == null ||
          (!tx.properties.notify && !tx.properties.indicate) ||
          (!rx.properties.write && !rx.properties.writeWithoutResponse)) {
        throw StateError('MT80 固件未提供所需蓝牙协议');
      }
      final firstPeriod = Completer<void>();
      unawaited(firstPeriod.future.then<void>((_) {}, onError: (Object _) {}));
      _notifications = tx.onValueReceived.listen(
        (bytes) {
          if (!_current(g)) return;
          try {
            final now = DateTime.now().millisecondsSinceEpoch;
            final doc = _protocol.addFragment(bytes, now);
            if (doc == null) return;
            final broadcast = doc['broadcast'];
            if (broadcast is Map && broadcast['baseInfo'] is Map) {
              final v = broadcast['baseInfo']['releaseVer'];
              if (v is int) {
                releaseVer = v;
                if (v < 102190820) {
                  if (!firstPeriod.isCompleted) {
                    firstPeriod.completeError(
                      StateError('MT80 固件需 v1.2.19.0820 或以上'),
                    );
                  }
                  unawaited(_failed('MT80 固件版本过旧', g));
                  return;
                }
              }
            }
            final current = Mt80Sample.parse(doc, now);
            if (current == null) {
              if (broadcast is Map && broadcast.containsKey('periodInfo')) {
                _detector.interrupt();
              }
              return;
            }
            if (sample?.devState != 'GRINDING' &&
                current.devState == 'GRINDING') {
              _beanAtGrindStart = currentBeanId?.call();
            }
            sample = current;
            final event = _detector.add(current);
            if (event != null && !_events.isClosed) {
              _events.add({...event, 'beanId': _beanAtGrindStart});
            }
            if (!firstPeriod.isCompleted) firstPeriod.complete();
            if (!_ready) {
              debugPrint('BOOKOO_BLE: MT80 live periodInfo stream verified');
            }
            _ready = true;
            _retries = 0;
            _status(
              current.devState == 'GRINDING' ? 'MT80 正在磨豆 · 手机采集' : 'MT80 已连接',
            );
          } on FormatException {
            _protocol.reset();
            _detector.interrupt();
          }
        },
        onError: (_) {
          if (_current(g)) unawaited(_failed('MT80 数据接收中断', g));
        },
      );
      await tx.setNotifyValue(true).timeout(const Duration(seconds: 5));
      if (!_current(g)) return;
      // Install a failure listener before notification callbacks can signal it.
      final verified = firstPeriod.future.timeout(const Duration(seconds: 5));
      // Observe handshake failures immediately, even if a fragmented write fails.
      unawaited(verified.then<void>((_) {}, onError: (Object _) {}));
      for (final frame in Mt80Protocol.handshakeFrames()) {
        if (!_current(g)) return;
        await rx
            .write(
              frame,
              withoutResponse:
                  !rx.properties.write && rx.properties.writeWithoutResponse,
            )
            .timeout(const Duration(seconds: 3));
      }
      await verified;
      if (!_current(g)) return;
      _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        final at = sample?.atMs;
        if (_current(g) &&
            (at == null || DateTime.now().millisecondsSinceEpoch - at > 3000)) {
          unawaited(_failed('MT80 数据已中断，等待重连', g));
        }
      });
    } on Object catch (e) {
      if (_current(g)) {
        await _failed(
          e is StateError ? e.message.toString() : 'MT80 连接未完成，请重试',
          g,
        );
      }
    } finally {
      if (!_current(g)) {
        try {
          await attemptDevice?.disconnect().timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    }
  }

  Future<void> _failed(String reason, int g) async {
    if (!_current(g)) return;
    await _disconnect();
    _status(reason);
    if (_enabled && !_disposed && _retries < 3) {
      _retries++;
      _retry = Timer(
        Duration(seconds: 5 * _retries),
        () => unawaited(connect()),
      );
    }
  }

  Future<void> _disconnect() async {
    _generation++;
    _watchdog?.cancel();
    _retry?.cancel();
    _ready = false;
    sample = null;
    releaseVer = null;
    _protocol.reset();
    _detector.interrupt();
    await _notifications?.cancel();
    _notifications = null;
    await _connection?.cancel();
    _connection = null;
    final device = _device;
    _device = null;
    try {
      await device?.disconnect().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> releaseConnection() async {
    final device = _device;
    final pending = _connecting;
    await setEnabled(false);
    if (pending != null) {
      try {
        await pending.timeout(const Duration(seconds: 40));
      } on TimeoutException {
        throw StateError('磨豆机连接仍在退出');
      } catch (_) {}
    }
    final owned = {..._ownedDevices, if (device != null) device};
    for (final peripheral in owned) {
      try {
        await peripheral.disconnect().timeout(const Duration(seconds: 5));
      } catch (_) {
        if (peripheral.isConnected) throw StateError('磨豆机尚未释放');
      }
      if (peripheral.isConnected) throw StateError('磨豆机尚未释放');
      _ownedDevices.remove(peripheral);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _enabled = false;
    unawaited(_disconnect());
    unawaited(_events.close());
    super.dispose();
  }
}
