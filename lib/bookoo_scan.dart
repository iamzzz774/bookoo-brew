import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'shared_scan.dart';

/// The adapter's scan is global; device connections are independent.
/// Concurrent roles share one full discovery window. Disposing one device
/// cannot stop another device's scan or disconnect its GATT connection.
class BookooScan {
  static final _shared = SharedScan<ScanResult>(
    // onScanResults deliberately excludes results replayed from an older scan.
    results: () => FlutterBluePlus.onScanResults,
    start: (timeout) => FlutterBluePlus.startScan(timeout: timeout),
    stop: () => FlutterBluePlus.stopScan(),
    keyOf: (result) => '${result.device.remoteId.str}|${_name(result)}',
  );

  static String _name(ScanResult result) =>
      result.advertisementData.advName.isNotEmpty
      ? result.advertisementData.advName
      : result.device.platformName;
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
    final results = await _shared.find(
      (result) => accepts(_name(result)),
      timeout: timeout,
      cancelled: cancelled,
    );
    // A device may advertise with an initially empty name then a real name;
    // preserve the named observation without duplicating the same device.
    return {
      for (final result in results) result.device.remoteId.str: result.device,
    }.values.toList();
  }
}
