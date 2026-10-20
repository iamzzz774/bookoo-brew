import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// The adapter's scan is global; device connections are independent.
/// Only the current scan lease may start/stop scanning. Disposing one device
/// cannot stop another device's scan or disconnect its GATT connection.
class BookooScan {
  static Future<void> _tail = Future.value();
  static Future<bool>? _permissions;

  static Future<bool> permissions() => _permissions ??= _requestPermissions();
  static List<Permission> permissionsForAndroidSdk(int sdk) => sdk >= 31
      ? [Permission.bluetoothScan, Permission.bluetoothConnect]
      : [Permission.locationWhenInUse];

  static Future<bool> _requestPermissions() async {
    try {
      if (!Platform.isAndroid) return false;
      final sdk = await const MethodChannel(
        'coffee.bookoo.bookoo_brew/bluetooth_host',
      ).invokeMethod<int>('sdkInt').timeout(const Duration(seconds: 2));
      if (sdk == null) return false;
      final required = permissionsForAndroidSdk(sdk);
      final statuses = await required.request();
      return required.every((p) => statuses[p]?.isGranted == true);
    } finally {
      _permissions = null;
    }
  }

  static bool isGrinderName(String name) => RegExp(
    r'^BOOKOO\s+MT80(?:\s+[0-9a-f]{8})?$',
    caseSensitive: false,
  ).hasMatch(name.trim());
  static bool isScaleName(String name) {
    final n = name.trim().toUpperCase();
    return n.startsWith('BOOKOO') &&
        !n.contains('MT80') &&
        !n.contains('MOTTO');
  }

  static Future<List<BluetoothDevice>> find(
    bool Function(String) accepts, {
    Duration timeout = const Duration(seconds: 10),
    bool Function()? cancelled,
  }) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    StreamSubscription<List<ScanResult>>? subscription;
    try {
      if (cancelled?.call() == true) throw StateError('连接已取消');
      final found = <String, BluetoothDevice>{};
      subscription = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          // advName is available even before platformName's cache is populated.
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          if (accepts(name)) found[r.device.remoteId.str] = r.device;
        }
      });
      await FlutterBluePlus.startScan(timeout: timeout);
      await Future<void>.delayed(timeout);
      if (cancelled?.call() == true) throw StateError('连接已取消');
      return found.values.toList();
    } finally {
      await subscription?.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      release.complete();
    }
  }
}
