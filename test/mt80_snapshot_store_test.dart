import 'dart:convert';
import 'package:bookoo_brew/mt80.dart';
import 'package:bookoo_brew/mt80_phone_store.dart';
import 'package:bookoo_brew/mt80_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const at = 1792474987112;
Map<String, dynamic> snapshot({int gap = 600}) => makeMt80SnapshotRecord(
  bladeGapUm: gap,
  feedingRpm: 25,
  grindRpm: 800,
  capturedAtMs: at,
  recordedAtMs: at + 1,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'snapshot reservation survives restart without an event or confirmation',
    () async {
      final store = await Mt80PhoneStore.load();
      final record = snapshot();
      await store.saveCurrentSnapshot(
        'scope',
        'note',
        at,
        record,
        beanId: 'bean',
      );
      final restored = await Mt80PhoneStore.load();
      expect(
        await restored.reserve('scope', 'note', at, beanId: 'bean'),
        record,
      );
      expect(await restored.candidates(at, beanId: 'bean'), isEmpty);
      final result = Mt80Result.fromNote({
        'mt80Request': {'schemaVersion': 1, 'status': 'snapshot'},
        'grinderRecord': record,
      });
      expect(result.status, 'snapshot');
      expect(result.saveFeedback, '已记录磨豆参数');
      expect(
        Mt80Result.fromNote({
          'mt80Request': {'schemaVersion': 1, 'status': 'complete'},
          'grinderRecord': record,
        }).status,
        'unavailable',
      );
    },
  );
  test(
    'retry cannot silently replace frozen parameters or bean identity',
    () async {
      final store = await Mt80PhoneStore.load();
      final record = snapshot();
      await store.saveCurrentSnapshot(
        'scope',
        'note',
        at,
        record,
        beanId: 'bean',
      );
      await expectLater(
        store.saveCurrentSnapshot(
          'scope',
          'note',
          at,
          snapshot(gap: 700),
          beanId: 'bean',
        ),
        throwsStateError,
      );
      await expectLater(
        store.reserve('scope', 'note', at, beanId: 'other'),
        throwsStateError,
      );
      expect(await store.reserve('scope', 'note', at, beanId: 'bean'), record);
    },
  );
  test('legacy history migrates without deleting event/binding keys', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      Mt80PhoneStore.key,
      jsonEncode({'events': [], 'bindings': {}}),
    );
    final store = await Mt80PhoneStore.load();
    await store.saveCurrentSnapshot('scope', 'note', at, snapshot());
    final raw = jsonDecode(prefs.getString(Mt80PhoneStore.key)!);
    expect(raw['events'], isEmpty);
    expect(raw['bindings'], isEmpty);
    expect(raw['snapshotBindings'], hasLength(1));
  });
  test('corrupt snapshot history is refused, not reset', () async {
    final raw = jsonEncode({
      'events': [],
      'bindings': {},
      'snapshotBindings': {
        'bad': {'brewAt': at, 'record': {}},
      },
    });
    SharedPreferences.setMockInitialValues({Mt80PhoneStore.key: raw});
    await expectLater(Mt80PhoneStore.load(), throwsFormatException);
    expect(
      (await SharedPreferences.getInstance()).getString(Mt80PhoneStore.key),
      raw,
    );
  });
}
