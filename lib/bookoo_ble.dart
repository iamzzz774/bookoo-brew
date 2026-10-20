import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'bookoo_scan.dart';
import 'models.dart';

/// BOOKOO 秤 BLE 服务（协议来源：解包官方 App + OpenSource/bookoo_ultra_scale）。
/// service 0x0FFE / notify 0xFF11(重量帧) / write 0xFF12(指令)。
class BookooBle {
  static final Guid serviceUuid = Guid('0000ffe0-0000-1000-8000-00805f9b34fb');
  // 注意：广播/服务短码是 0x0FFE，完整 128-bit 见下；不同固件可能用 ffe0/0ffe，连上后按特征 UUID 找。
  static final Guid altServiceUuid = Guid(
    '00000ffe-0000-1000-8000-00805f9b34fb',
  );
  static final Guid notifyUuid = Guid('0000ff11-0000-1000-8000-00805f9b34fb');
  static final Guid cmdUuid = Guid('0000ff12-0000-1000-8000-00805f9b34fb');

  static const String namePrefix = 'BOOKOO';

  // 指令字节（官方 Ultra 协议原值，非简单 XOR，照抄）。
  static const List<int> cmdTare = [0x03, 0x0A, 0x01, 0x00, 0x00, 0x08];
  static const List<int> cmdStartTimer = [0x03, 0x0A, 0x04, 0x00, 0x00, 0x0A];
  static const List<int> cmdStopTimer = [0x03, 0x0A, 0x05, 0x00, 0x00, 0x0D];
  static const List<int> cmdResetTimer = [0x03, 0x0A, 0x06, 0x00, 0x00, 0x0C];
  static const List<int> cmdTareAndStart = [0x03, 0x0A, 0x07, 0x00, 0x00, 0x00];

  BluetoothDevice? _device;
  final _ownedDevices = <BluetoothDevice>{};
  final _pendingWrites = <Future<void>>{};
  bool _commandsAllowed = false;
  BluetoothCharacteristic? _notifyChar;
  BluetoothCharacteristic? _cmdChar;
  StreamSubscription? _valueSub;
  StreamSubscription? _connectionSub;

  final _readings = StreamController<ScaleReading>.broadcast();
  final _conn = StreamController<bool>.broadcast();
  Stream<ScaleReading> get readings => _readings.stream;
  Stream<bool> get connection => _conn.stream;
  bool get isConnected => _device?.isConnected ?? false;
  String? get deviceName => _device?.platformName;

  bool _disposed = false;
  int _generation = 0;
  Future<void>? _connecting;
  Future<bool> ensurePermissions() => BookooScan.permissions();

  Future<void> scanAndConnect({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final pending = _connecting;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
      if (_disposed || isConnected) return;
      return scanAndConnect(timeout: timeout);
    }
    return _connecting = _scanAndConnect(
      timeout,
    ).whenComplete(() => _connecting = null);
  }

  Future<void> _scanAndConnect(Duration timeout) async {
    if (_disposed) return;
    final discoveryGeneration = _generation;
    if (!await ensurePermissions()) throw Exception('蓝牙权限被拒绝');
    if (_disposed || discoveryGeneration != _generation) return;
    if (!await FlutterBluePlus.isSupported) throw Exception('此设备不支持蓝牙');
    final devices = await BookooScan.find(
      BookooScan.isScaleName,
      timeout: timeout,
      cancelled: () => _disposed || discoveryGeneration != _generation,
    );
    if (_disposed || discoveryGeneration != _generation) return;
    if (devices.isEmpty) throw Exception('没找到 BOOKOO 秤');
    if (devices.length != 1) throw Exception('发现多台 BOOKOO 秤，请仅开启目标秤后重试');
    await connectTo(devices.single);
  }

  Future<void> connectTo(BluetoothDevice device) async {
    if (_disposed) return;
    if (!BookooScan.isScaleName(device.platformName)) {
      throw StateError('不是受支持的 BOOKOO 秤');
    }
    final previousDevice = _device;
    final generation = ++_generation;
    _commandsAllowed = false;
    Future<void> guard() async {
      if (_disposed || generation != _generation) {
        await device.disconnect();
        throw StateError('秤连接已取消');
      }
    }

    await _valueSub?.cancel();
    _valueSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    _notifyChar = null;
    _cmdChar = null;
    if (previousDevice != null && previousDevice != device) {
      await previousDevice.disconnect();
    }
    if (_disposed || generation != _generation) return;
    _device = device;
    _ownedDevices.add(device);
    _connectionSub = device.connectionState.listen((s) {
      if (!_conn.isClosed && generation == _generation) {
        if (s != BluetoothConnectionState.connected) _conn.add(false);
      }
    });
    try {
      await device.connect(timeout: const Duration(seconds: 15));
      await guard();
      final services = await device.discoverServices();
      await guard();
      for (final svc in services) {
        if (svc.uuid != Guid('0ffe')) continue;
        for (final c in svc.characteristics) {
          if (c.uuid == notifyUuid) _notifyChar = c;
          if (c.uuid == cmdUuid) _cmdChar = c;
        }
      }
      if (_notifyChar == null ||
          _cmdChar == null ||
          !_notifyChar!.properties.notify ||
          !(_cmdChar!.properties.write ||
              _cmdChar!.properties.writeWithoutResponse)) {
        throw Exception('未找到重量数据特征 0xFF11（确认是 BOOKOO 秤）');
      }
      await _notifyChar!.setNotifyValue(true);
      await guard();
      final firstSample = Completer<void>();
      _valueSub = _notifyChar!.onValueReceived.listen((data) {
        if (_disposed || generation != _generation) return;
        final r = decodeFrame(data);
        if (r != null && !_readings.isClosed) {
          if (!firstSample.isCompleted) {
            firstSample.complete();
            _commandsAllowed = true;
            if (!_conn.isClosed) _conn.add(true);
            debugPrint('BOOKOO_BLE: scale live weight stream verified');
          }
          _readings.add(r);
        }
      });
      await firstSample.future.timeout(const Duration(seconds: 5));
      await guard();
    } catch (_) {
      _commandsAllowed = false;
      await _connectionSub?.cancel();
      _connectionSub = null;
      try {
        await device.disconnect();
      } catch (_) {}
      _device = null;
      _notifyChar = null;
      _cmdChar = null;
      rethrow;
    }
  }

  Future<void> sendCommand(List<int> cmd) {
    final c = _cmdChar;
    if (c == null || !_commandsAllowed) return Future.value();
    final write = c.write(
      cmd,
      withoutResponse: c.properties.writeWithoutResponse,
    );
    _pendingWrites.add(write);
    unawaited(
      write.then<void>(
        (_) {
          _pendingWrites.remove(write);
        },
        onError: (Object _) {
          _pendingWrites.remove(write);
        },
      ),
    );
    return write;
  }

  Future<void> tare() => sendCommand(cmdTare);
  Future<void> tareAndStartTimer() => sendCommand(cmdTareAndStart);
  Future<void> stopTimer() => sendCommand(cmdStopTimer);
  Future<void> resetTimer() => sendCommand(cmdResetTimer);

  Future<void> disconnect() async {
    _generation++;
    _commandsAllowed = false;
    await _valueSub?.cancel();
    _valueSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {
      // 设备可能已经超距或由系统断开，本地状态仍需完整清理。
    }
    _device = null;
    _notifyChar = null;
    _cmdChar = null;
    if (!_conn.isClosed) _conn.add(false);
  }

  Future<void> releaseConnection() async {
    final pending = _connecting;
    final device = _device;
    await disconnect();
    if (pending != null) {
      try {
        await pending.timeout(const Duration(seconds: 35));
      } on TimeoutException {
        throw StateError('秤连接仍在退出');
      } catch (_) {}
    }
    final owned = {..._ownedDevices, if (device != null) device};
    for (final peripheral in owned) {
      try {
        await peripheral.disconnect().timeout(const Duration(seconds: 5));
      } catch (_) {
        if (peripheral.isConnected) throw StateError('秤连接尚未释放');
      }
      if (peripheral.isConnected) throw StateError('秤连接尚未释放');
      _ownedDevices.remove(peripheral);
    }
    await Future.wait(
      _pendingWrites.map((future) => future.catchError((_) {})).toList(),
    ).timeout(const Duration(seconds: 8));
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _readings.close();
    await _conn.close();
  }

  /// 解码 20 字节重量帧（type 0x0B）。非重量帧（状态/auto-mode）返回 null。
  /// 布局：0-1 头 03 0B；2-4 ms(BE)；6 重量符号；7-9 克*100(BE)；
  /// 10 流速符号；11-12 流速*100(BE)；13 电量；19 校验。
  static ScaleReading? decodeFrame(List<int> d) {
    if (d.length < 14 || d[0] != 0x03 || d[1] != 0x0B) return null;
    final ms = (d[2] << 16) | (d[3] << 8) | d[4];
    var weight = ((d[7] << 16) | (d[8] << 8) | d[9]) / 100.0;
    if (d[6] == 0x2D || d[6] == 1) weight = -weight;
    var flow = ((d[11] << 8) | d[12]) / 100.0;
    if (d[10] == 0x2D || d[10] == 1) flow = -flow;
    final battery = d[13];
    return ScaleReading(
      ms / 1000.0,
      double.parse(weight.toStringAsFixed(2)),
      double.parse(flow.toStringAsFixed(2)),
      battery,
    );
  }
}
