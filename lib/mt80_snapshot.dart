import 'dart:math';

const kMt80SnapshotSource = 'motto80-phone-settings-snapshot';

const _earliestTimestampMs = 946684800000;
const _maximumRecordingDelayMs = 3600000;
const _units = <String, String>{
  'bladeGap': 'μm',
  'feedingRpm': 'rpm',
  'grindRpm': 'rpm',
};
const _eventFields = <String>[
  'startedAtMs',
  'endedAtMs',
  'durationMs',
  'eventId',
  'parameterChanges',
  'confirmationId',
  'confirmedAtMs',
];
final _snapshotIdPattern = RegExp(r'^[0-9a-f]{32}$');

bool _integerInRange(dynamic value, int minimum, int maximum) =>
    value is int && value >= minimum && value <= maximum;

/// Validates a current-settings snapshot, never evidence of a grinding event.
bool isValidMt80SnapshotRecord(dynamic value) {
  if (value is! Map ||
      _eventFields.any(value.containsKey) ||
      value['schemaVersion'] is! int ||
      value['schemaVersion'] != 1 ||
      value['model'] != 'BOOKOO MOTTO80' ||
      value['source'] != kMt80SnapshotSource ||
      value['association'] != 'current_parameters_snapshot' ||
      value['complete'] is! bool ||
      value['complete'] != false ||
      !_integerInRange(value['bladeGapUm'], 0, 999) ||
      !_integerInRange(value['feedingRpm'], 10, 65) ||
      !_integerInRange(value['grindRpm'], 500, 1500)) {
    return false;
  }
  final id = value['snapshotId'];
  final capturedAtMs = value['capturedAtMs'];
  final recordedAtMs = value['recordedAtMs'];
  final units = value['units'];
  return id is String &&
      id.length == 32 &&
      _snapshotIdPattern.hasMatch(id) &&
      capturedAtMs is int &&
      recordedAtMs is int &&
      capturedAtMs >= _earliestTimestampMs &&
      recordedAtMs >= capturedAtMs &&
      recordedAtMs - capturedAtMs <= _maximumRecordingDelayMs &&
      units is Map &&
      _units.entries.every((entry) => units[entry.key] == entry.value) &&
      (!value.containsKey('note') || value['note'] is String);
}

/// Freezes current parameters without inventing a completed grinding episode.
///
/// Called when saving, using the capture time of the current device
/// parameters. No event timing, duration, or completeness is inferred.
/// Throws [ArgumentError] if parameters or recording timestamps are invalid.
Map<String, dynamic> makeMt80SnapshotRecord({
  required int bladeGapUm,
  required int feedingRpm,
  required int grindRpm,
  required int capturedAtMs,
  required int recordedAtMs,
}) {
  final random = Random.secure();
  final snapshotId = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final record = <String, dynamic>{
    'schemaVersion': 1,
    'model': 'BOOKOO MOTTO80',
    'source': kMt80SnapshotSource,
    'association': 'current_parameters_snapshot',
    'complete': false,
    'snapshotId': snapshotId,
    'capturedAtMs': capturedAtMs,
    'recordedAtMs': recordedAtMs,
    'bladeGapUm': bladeGapUm,
    'feedingRpm': feedingRpm,
    'grindRpm': grindRpm,
    'units': _units,
    'note': '设备连接后读取的当前参数；未采集完整磨豆过程。',
  };
  if (!isValidMt80SnapshotRecord(record)) {
    throw ArgumentError('Invalid MT80 snapshot parameters or timestamps');
  }
  return Map<String, dynamic>.unmodifiable(record);
}
