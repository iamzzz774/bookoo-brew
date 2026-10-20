import 'dart:convert';

import 'package:bookoo_brew/mt80_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const _capturedAtMs = 1792402479925;

Map<String, dynamic> _make({
  int bladeGapUm = 650,
  int feedingRpm = 25,
  int grindRpm = 800,
  int capturedAtMs = _capturedAtMs,
  int recordedAtMs = _capturedAtMs + 1000,
}) => makeMt80SnapshotRecord(
  bladeGapUm: bladeGapUm,
  feedingRpm: feedingRpm,
  grindRpm: grindRpm,
  capturedAtMs: capturedAtMs,
  recordedAtMs: recordedAtMs,
);

void main() {
  test('snapshot identifies current settings, not a complete event', () {
    final record = _make();
    expect(isValidMt80SnapshotRecord(record), isTrue);
    expect(record['schemaVersion'], 1);
    expect(record['model'], 'BOOKOO MOTTO80');
    expect(record['source'], kMt80SnapshotSource);
    expect(kMt80SnapshotSource, 'motto80-phone-settings-snapshot');
    expect(record['association'], 'current_parameters_snapshot');
    expect(record['complete'], isFalse);
    expect(record['capturedAtMs'], _capturedAtMs);
    expect(record['recordedAtMs'], _capturedAtMs + 1000);
    expect(record['bladeGapUm'], 650);
    expect(record['feedingRpm'], 25);
    expect(record['grindRpm'], 800);
    expect(record['units'], {
      'bladeGap': 'μm',
      'feedingRpm': 'rpm',
      'grindRpm': 'rpm',
    });
    expect(record['note'], contains('未采集完整磨豆过程'));
    expect(isValidMt80SnapshotRecord(jsonDecode(jsonEncode(record))), isTrue);
  });

  test('accepts inclusive parameter and timestamp boundaries', () {
    expect(
      isValidMt80SnapshotRecord(
        _make(
          bladeGapUm: 0,
          feedingRpm: 10,
          grindRpm: 500,
          capturedAtMs: 946684800000,
          recordedAtMs: 946684800000,
        ),
      ),
      isTrue,
    );
    expect(
      isValidMt80SnapshotRecord(
        _make(
          bladeGapUm: 999,
          feedingRpm: 65,
          grindRpm: 1500,
          recordedAtMs: _capturedAtMs + 3600000,
        ),
      ),
      isTrue,
    );
  });

  test('rejects non-map values', () {
    for (final value in [null, true, 1, 'record', <dynamic>[]]) {
      expect(isValidMt80SnapshotRecord(value), isFalse);
    }
  });

  for (final key in [
    'schemaVersion',
    'bladeGapUm',
    'feedingRpm',
    'grindRpm',
    'capturedAtMs',
    'recordedAtMs',
  ]) {
    test('$key rejects missing values and non-integer types', () {
      final record = _make();
      expect(isValidMt80SnapshotRecord({...record}..remove(key)), isFalse);
      for (final invalid in [
        null,
        true,
        false,
        '${record[key]}',
        (record[key] as int).toDouble(),
      ]) {
        expect(
          isValidMt80SnapshotRecord({...record, key: invalid}),
          isFalse,
          reason: '$key=$invalid (${invalid.runtimeType})',
        );
      }
    });
  }

  for (final entry in <String, List<int>>{
    'schemaVersion': [0, 2],
    'bladeGapUm': [-1, 1000],
    'feedingRpm': [9, 66],
    'grindRpm': [499, 1501],
    'capturedAtMs': [946684799999, _capturedAtMs + 1001],
    'recordedAtMs': [946684799999, _capturedAtMs - 1, _capturedAtMs + 3600001],
  }.entries) {
    test('${entry.key} rejects out-of-range values', () {
      for (final invalid in entry.value) {
        expect(
          isValidMt80SnapshotRecord({..._make(), entry.key: invalid}),
          isFalse,
          reason: '${entry.key}=$invalid',
        );
      }
    });
  }

  for (final key in [
    'startedAtMs',
    'endedAtMs',
    'durationMs',
    'eventId',
    'parameterChanges',
    'confirmationId',
    'confirmedAtMs',
  ]) {
    test('$key is never generated and its presence invalidates a snapshot', () {
      final record = _make();
      expect(record.containsKey(key), isFalse);
      for (final value in [null, 0, '', <dynamic>[]]) {
        expect(isValidMt80SnapshotRecord({...record, key: value}), isFalse);
      }
    });
  }

  test('rejects altered identity, association, and completeness fields', () {
    for (final entry in <String, List<dynamic>>{
      'model': [null, 'BOOKOO MT80'],
      'source': [null, 'motto80-phone-ble', 'motto80-ble'],
      'association': [null, 'automatic'],
      'complete': [null, true, 0, 'false'],
    }.entries) {
      expect(
        isValidMt80SnapshotRecord({..._make()}..remove(entry.key)),
        isFalse,
      );
      for (final value in entry.value) {
        expect(
          isValidMt80SnapshotRecord({..._make(), entry.key: value}),
          isFalse,
        );
      }
    }
  });

  test('snapshot IDs must be exactly 32 lowercase hexadecimal digits', () {
    const validId = '0123456789abcdef0123456789abcdef';
    expect(
      isValidMt80SnapshotRecord({..._make(), 'snapshotId': validId}),
      isTrue,
    );
    for (final id in [
      null,
      1,
      '',
      validId.substring(1),
      '${validId}0',
      validId.toUpperCase(),
      '${validId.substring(1)}g',
      '$validId\n',
    ]) {
      expect(
        isValidMt80SnapshotRecord({..._make(), 'snapshotId': id}),
        isFalse,
      );
    }
    expect(
      isValidMt80SnapshotRecord({..._make()}..remove('snapshotId')),
      isFalse,
    );
  });

  test('units are required and note is optional but must be a string', () {
    final record = _make();
    expect(isValidMt80SnapshotRecord({...record}..remove('note')), isTrue);
    for (final note in [null, 1, false]) {
      expect(isValidMt80SnapshotRecord({...record, 'note': note}), isFalse);
    }
    for (final units in [null, 'μm', <String, String>{}]) {
      expect(isValidMt80SnapshotRecord({...record, 'units': units}), isFalse);
    }
    expect(isValidMt80SnapshotRecord({...record}..remove('units')), isFalse);
    final units = Map<String, dynamic>.from(record['units'] as Map);
    for (final key in units.keys) {
      expect(
        isValidMt80SnapshotRecord({
          ...record,
          'units': {...units}..remove(key),
        }),
        isFalse,
      );
      expect(
        isValidMt80SnapshotRecord({
          ...record,
          'units': {...units, key: 'bad'},
        }),
        isFalse,
      );
    }
  });

  test(
    'factory rejects invalid inputs rather than returning invalid records',
    () {
      for (final make in <Map<String, dynamic> Function()>[
        () => _make(bladeGapUm: -1),
        () => _make(bladeGapUm: 1000),
        () => _make(feedingRpm: 9),
        () => _make(feedingRpm: 66),
        () => _make(grindRpm: 499),
        () => _make(grindRpm: 1501),
        () => _make(capturedAtMs: 946684799999),
        () => _make(recordedAtMs: 946684799999),
        () => _make(recordedAtMs: _capturedAtMs - 1),
        () => _make(recordedAtMs: _capturedAtMs + 3600001),
      ]) {
        expect(make, throwsArgumentError);
      }
    },
  );

  test('identical parameters still receive distinct random snapshot IDs', () {
    final ids = <String>{};
    for (var i = 0; i < 100; i++) {
      final record = _make();
      expect(isValidMt80SnapshotRecord(record), isTrue);
      expect(ids.add(record['snapshotId'] as String), isTrue);
    }
  });

  test('parameters and nested units are frozen after recording', () {
    final record = _make();
    for (final key in record.keys) {
      expect(() => record[key] = null, throwsUnsupportedError);
    }
    expect(() => record['eventId'] = 'fake', throwsUnsupportedError);
    expect(() => record.remove('complete'), throwsUnsupportedError);
    expect(() => record.clear(), throwsUnsupportedError);
    final units = record['units'] as Map;
    expect(() => units['bladeGap'] = 'mm', throwsUnsupportedError);
    expect(() => units.clear(), throwsUnsupportedError);
    final nextRecord = _make(bladeGapUm: 800, feedingRpm: 30, grindRpm: 900);
    expect(nextRecord['bladeGapUm'], 800);
    expect(record['bladeGapUm'], 650);
    expect(record['feedingRpm'], 25);
    expect(record['grindRpm'], 800);
    expect(isValidMt80SnapshotRecord(record), isTrue);
  });
}
