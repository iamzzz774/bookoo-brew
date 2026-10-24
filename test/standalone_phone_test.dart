import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Architecture regression checks, not a claim of real BLE/hardware coverage.
void main() {
  test('phone entrypoint contains no Mac discovery or handoff lifecycle', () {
    final source = File('lib/main.dart').readAsStringSync();
    for (final removed in [
      'device_coordination.dart',
      'DeviceCoordination',
      'coordination.acquire',
      'coordination.release',
      'coordination.dispose',
      '请在 Mac 检查设备交接状态',
    ]) {
      expect(source, isNot(contains(removed)), reason: removed);
    }
    expect(File('lib/device_coordination.dart').existsSync(), isFalse);
  });

  test('opening BLE devices is not gated on backend or Mac availability', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _openDevices()');
    final end = source.indexOf('BrewGuideApi? get _api', start);
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final connect = source.substring(start, end);
    expect(connect, contains('ble.scanAndConnect()'));
    expect(connect, contains('phoneGrinder.setEnabled(wantedGrinder)'));
    expect(connect, isNot(contains('settings.isConfigured')));
    expect(connect, isNot(contains('supabase')));
    expect(connect, isNot(contains('coordination')));
  });

  test('scale header restores tap retry without extra grinder controls', () {
    final main = File('lib/main.dart').readAsStringSync();
    final panel = File('lib/mt80_panel.dart').readAsStringSync();
    expect(main, isNot(contains('点击重连')));
    expect(main, contains("ValueKey('scale-connection-header')"));
    expect(main, contains('Future<void> _reconnectScale()'));
    expect(main, contains('_reconnectScale,'));
    expect(panel, isNot(contains('重连磨豆机')));
    expect(panel, isNot(contains('刷新本杯研磨参数')));
    expect(panel, isNot(contains('IconButton(')));
  });
}
