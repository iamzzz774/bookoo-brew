import 'dart:async';
import 'dart:io';
import 'package:bookoo_brew/shared_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const window = Duration(milliseconds: 60);
  late StreamController<List<String>> stream;
  late SharedScan<String> scanner;
  late int starts, stops;
  late Completer<void>? starting, stopping;
  late Object? startError, stopError;
  setUp(() {
    stream = StreamController<List<String>>.broadcast(sync: true);
    starts = stops = 0;
    starting = stopping = null;
    startError = stopError = null;
    scanner = SharedScan<String>(
      results: () => stream.stream,
      start: (_) async {
        starts++;
        if (startError != null) throw startError!;
        if (starting != null) await starting!.future;
      },
      stop: () async {
        stops++;
        if (stopError != null) throw stopError!;
        if (stopping != null) await stopping!.future;
      },
      keyOf: (value) => value,
    );
  });
  tearDown(() => stream.close());

  test('concurrent roles use one scan and preserve role filtering', () async {
    final scale = scanner.find((v) => v.startsWith('scale'), timeout: window);
    final grinder = scanner.find(
      (v) => v.startsWith('grinder'),
      timeout: window,
    );
    stream.add(['scale1', 'grinder1']);
    expect(await scale, ['scale1']);
    expect(await grinder, ['grinder1']);
    expect(starts, 1);
    expect(stops, 1);
  });
  test(
    'late discovery preserves ambiguity instead of selecting first',
    () async {
      final pending = scanner.find((_) => true, timeout: window);
      var completed = false;
      unawaited(pending.then((_) => completed = true));
      stream.add(['scale1']);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(completed, isFalse);
      stream.add(['scale2']);
      expect(await pending, ['scale1', 'scale2']);
    },
  );
  test('repeated advertisements deduplicate', () async {
    final pending = scanner.find((_) => true, timeout: window);
    stream.add(['scale1', 'scale1']);
    stream.add(['scale1']);
    expect(await pending, ['scale1']);
  });
  test('cancelled role cannot stop or discard another role', () async {
    var cancelled = false;
    final scale = scanner.find(
      (v) => v.startsWith('scale'),
      timeout: window,
      cancelled: () => cancelled,
    );
    final scaleError = expectLater(scale, throwsStateError);
    final grinder = scanner.find(
      (v) => v.startsWith('grinder'),
      timeout: window,
    );
    cancelled = true;
    stream.add(['grinder1']);
    expect(stops, 0);
    expect(await grinder, ['grinder1']);
    await scaleError;
    expect(starts, 1);
    expect(stops, 1);
  });
  test('already cancelled caller does not start scan', () async {
    await expectLater(
      scanner.find((_) => true, timeout: window, cancelled: () => true),
      throwsStateError,
    );
    expect(starts, 0);
    expect(stops, 0);
  });
  test('new session has no stale results', () async {
    final first = scanner.find((_) => true, timeout: window);
    stream.add(['scale1']);
    expect(await first, ['scale1']);
    expect(await scanner.find((_) => true, timeout: window), isEmpty);
    expect(starts, 2);
    expect(stops, 2);
  });
  test('join while native start pending shares scan', () async {
    starting = Completer<void>();
    final first = scanner.find((_) => true, timeout: window);
    final second = scanner.find((_) => true, timeout: window);
    expect(starts, 1);
    expect(stops, 0);
    starting!.complete();
    await Future.wait([first, second]);
    expect(starts, 1);
    expect(stops, 1);
  });
  test('native stop drains before new physical scan', () async {
    stopping = Completer<void>();
    final first = scanner.find((_) => true, timeout: window);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(stops, 1);
    final second = scanner.find((_) => true, timeout: window);
    expect(starts, 1);
    stopping!.complete();
    await Future.wait([first, second]);
    stopping = null;
    await scanner.find((_) => true, timeout: window);
    expect(starts, 2);
    expect(stops, 2);
  });
  test('start failure reaches both callers and later scan retries', () async {
    startError = StateError('mock start failure');
    final first = scanner.find((_) => true, timeout: window);
    final second = scanner.find((_) => true, timeout: window);
    await Future.wait([
      expectLater(first, throwsStateError),
      expectLater(second, throwsStateError),
    ]);
    expect(starts, 1);
    expect(stops, 1);
    startError = null;
    await scanner.find((_) => true, timeout: window);
    expect(starts, 2);
  });
  test('stream failure is not hidden as empty discovery', () async {
    final pending = scanner.find((_) => true, timeout: window);
    final check = expectLater(pending, throwsStateError);
    stream.addError(StateError('mock stream failure'));
    await check;
    expect(stops, 1);
  });
  test('stop failure is not reported as successful discovery', () async {
    stopError = StateError('mock stop failure');
    final pending = scanner.find((_) => true, timeout: window);
    stream.add(['scale1']);
    await expectLater(pending, throwsStateError);
  });
  test('production adapter avoids replayed previous scan results', () {
    final source = File('lib/bookoo_scan.dart').readAsStringSync();
    expect(source, contains('SharedScan<ScanResult>'));
    expect(source, contains('FlutterBluePlus.onScanResults'));
    expect(source, isNot(contains('FlutterBluePlus.scanResults.listen')));
    expect(source, isNot(contains('_tail')));
  });
}
