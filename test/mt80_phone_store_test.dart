import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:bookoo_brew/mt80_phone_store.dart';
import 'package:bookoo_brew/bookoo_scan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const start = 1792453000000;
Map<String, dynamic> event(String id, {int end = start - 5000}) => {
  'schemaVersion': 1,
  'eventId': id,
  'complete': true,
  'reason': 'observed_idle_grinding_idle',
  'source': 'motto80-phone-ble',
  'startedAtMs': end - 10000,
  'endedAtMs': end,
  'durationMs': 10000,
  'parameters': {'bladeGap': 650, 'feedingRpm': 25, 'grindRpm': 800},
  'parameterChanges': [],
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('Android 12+ never requests location for BLE scanning', () {
    expect(BookooScan.permissionsForAndroidSdk(31), [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ]);
    expect(BookooScan.permissionsForAndroidSdk(37), [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ]);
    expect(BookooScan.permissionsForAndroidSdk(30), [
      Permission.locationWhenInUse,
    ]);
  });
  test('scale and MT80 discovery never cross roles', () {
    for (final name in [
      'BOOKOO MT80',
      'BOOKOO MT80 9fccdc30',
      'bookoo mt80 abcdef12',
    ]) {
      expect(BookooScan.isGrinderName(name), isTrue);
      expect(BookooScan.isScaleName(name), isFalse);
    }
    for (final name in ['BOOKOO Themis Ultra', 'BOOKOO Mini']) {
      expect(BookooScan.isScaleName(name), isTrue);
      expect(BookooScan.isGrinderName(name), isFalse);
    }
    expect(BookooScan.isScaleName('BOOKOO MOTTO80'), isFalse);
    expect(BookooScan.isGrinderName('BOOKOO MT80 fake-device'), isFalse);
  });
  test(
    'complete event persists and one-note reservation survives restart',
    () async {
      var store = await Mt80PhoneStore.load();
      await store.add(event('a' * 32), beanId: 'bean');
      final record = await store.reserve(
        'scope',
        'note',
        start,
        beanId: 'bean',
      );
      expect(record!['source'], 'motto80-phone-ble');
      expect(record['bladeGapUm'], 650);
      store = await Mt80PhoneStore.load();
      expect(
        await store.reserve('scope', 'note', start, beanId: 'bean'),
        record,
      );
      expect(
        await store.reserve('scope', 'different', start, beanId: 'bean'),
        isNull,
      );
      expect(
        await store.reserve('other-user', 'note', start, beanId: 'bean'),
        isNull,
      );
    },
  );
  test(
    'multiple events require explicit choice and cannot be rebound',
    () async {
      final store = await Mt80PhoneStore.load();
      await store.add(event('a' * 32), beanId: 'bean');
      await store.add(event('b' * 32), beanId: 'bean');
      expect(
        await store.reserve('scope', 'note', start, beanId: 'bean'),
        isNull,
      );
      final chosen = await store.reserve(
        'scope',
        'note',
        start,
        beanId: 'bean',
        chosenEventId: 'b' * 32,
      );
      expect(chosen!['eventId'], 'b' * 32);
      expect(chosen['association'], 'phone_user_confirmed');
      await expectLater(
        store.reserve(
          'scope',
          'note',
          start,
          beanId: 'bean',
          chosenEventId: 'a' * 32,
        ),
        throwsStateError,
      );
    },
  );
  test('clock boundary and unknown bean require confirmation', () async {
    final store = await Mt80PhoneStore.load();
    await store.add(event('a' * 32, end: start + 1000), beanId: 'bean');
    expect(await store.reserve('scope', 'n', start, beanId: 'bean'), isNull);
    expect(
      await store.reserve(
        'scope',
        'n',
        start,
        beanId: 'bean',
        chosenEventId: 'a' * 32,
      ),
      isNotNull,
    );
    await store.add(event('b' * 32));
    expect(await store.reserve('scope', 'n2', start, beanId: 'bean'), isNull);
    expect(
      await store.reserve(
        'scope',
        'n2',
        start,
        beanId: 'bean',
        chosenEventId: 'b' * 32,
      ),
      isNotNull,
    );
  });
  test('stale/future/wrong bean never selected as latest', () async {
    final store = await Mt80PhoneStore.load();
    await store.add(event('a' * 32, end: start - 600001), beanId: 'bean');
    await store.add(event('b' * 32, end: start + 3001), beanId: 'bean');
    await store.add(event('c' * 32), beanId: 'different');
    expect(await store.candidates(start, beanId: 'bean'), isEmpty);
    expect(await store.reserve('scope', 'note', start, beanId: 'bean'), isNull);
  });
  test('two concurrent notes cannot reserve one event twice', () async {
    final store = await Mt80PhoneStore.load();
    await store.add(event('a' * 32), beanId: 'bean');
    final both = await Future.wait([
      store.reserve('scope', 'n1', start, beanId: 'bean'),
      store.reserve('scope', 'n2', start, beanId: 'bean'),
    ]);
    expect(both.whereType<Map>().length, 1);
  });
  test('incomplete and idle snapshots cannot become actual events', () async {
    final store = await Mt80PhoneStore.load();
    await expectLater(
      store.add({...event('a' * 32), 'complete': false}),
      throwsFormatException,
    );
    await expectLater(
      store.add({
        'parameters': {'bladeGap': 650, 'feedingRpm': 25, 'grindRpm': 800},
      }),
      throwsFormatException,
    );
  });
  test('oversized persistence never replaces earlier valid history', () async {
    final store = await Mt80PhoneStore.load();
    await store.add(event('a' * 32), beanId: 'bean');
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(Mt80PhoneStore.key);
    await expectLater(
      store.add({...event('b' * 32), 'extra': 'x' * 2000000}),
      throwsStateError,
    );
    expect(prefs.getString(Mt80PhoneStore.key), before);
    expect((await store.candidates(start, beanId: 'bean')).length, 1);
  });
  test('corrupt persisted history fails without erasing it', () async {
    SharedPreferences.setMockInitialValues({
      Mt80PhoneStore.key: jsonEncode({
        'events': [{}],
        'bindings': {},
      }),
    });
    await expectLater(Mt80PhoneStore.load(), throwsFormatException);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(Mt80PhoneStore.key), isTrue);
  });
}
