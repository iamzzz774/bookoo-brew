import 'dart:async';
import 'package:bookoo_brew/mt80_ble.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only the transport is delayed. Enable/disable/generation logic is production.
class _DelayedTransport extends Mt80Ble {
  final first = Completer<void>();
  Future<void>? pending;
  int attempts = 0;
  @override
  Future<void> connect() =>
      pending ??= _attempt().whenComplete(() => pending = null);
  Future<void> _attempt() async {
    attempts++;
    if (attempts == 1) await first.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rapid off/on drains stale attempt then starts a fresh one', () async {
    final ble = _DelayedTransport();
    final firstEnable = ble.setEnabled(true);
    expect(ble.attempts, 1);
    await ble.setEnabled(false);
    final secondEnable = ble.setEnabled(true);
    expect(ble.attempts, 1);
    ble.first.complete();
    await Future.wait([firstEnable, secondEnable]);
    expect(ble.attempts, 2);
    ble.dispose();
  });
}
