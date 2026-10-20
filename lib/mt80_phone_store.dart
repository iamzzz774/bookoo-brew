import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'mt80.dart';
import 'mt80_snapshot.dart';

/// A single durable JSON transaction holds observations AND one-event/one-note
/// reservations. Cloud failures retain the original reservation for retry.
class Mt80PhoneStore {
  static const key = 'mt80PhoneEventsV1';
  final SharedPreferences _prefs;
  Map<String, dynamic> _data;
  Future<void> _tail = Future.value();
  Mt80PhoneStore._(this._prefs, this._data);

  static Future<Mt80PhoneStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    final data = raw == null
        ? <String, dynamic>{
            'events': <dynamic>[],
            'bindings': <String, dynamic>{},
          }
        : jsonDecode(raw);
    if (raw != null && raw.length > 2000000 ||
        data is! Map ||
        data['events'] is! List ||
        data['bindings'] is! Map ||
        (data['events'] as List).length > 500) {
      throw const FormatException('本地磨豆记录损坏，请保留应用数据');
    }
    for (final event in data['events']) {
      if (event is! Map || !_valid(event)) {
        throw const FormatException('本地磨豆记录无法校验');
      }
    }
    data.putIfAbsent('snapshotBindings', () => <String, dynamic>{});
    final confirmed = data['snapshotBindings'];
    if (confirmed is! Map || confirmed.length > 500) {
      throw const FormatException('参数快照记录损坏');
    }
    for (final entry in confirmed.entries) {
      final b = entry.value;
      if (b is! Map ||
          b['brewAt'] is! int ||
          b['beanId'] != null && b['beanId'] is! String ||
          !isValidMt80SnapshotRecord(b['record']) ||
          (data['bindings'] as Map).containsKey(entry.key)) {
        throw const FormatException('参数快照预留记录无法校验');
      }
    }
    final ids = (data['events'] as List).map((e) => e['eventId']).toSet();
    if (ids.length != (data['events'] as List).length) {
      throw const FormatException('磨豆事件标识重复');
    }
    final used = <String>{};
    for (final b in (data['bindings'] as Map).values) {
      if (b is! Map ||
          b['eventId'] is! String ||
          !ids.contains(b['eventId']) ||
          !used.add(b['eventId']) ||
          b['brewAt'] is! int ||
          b['manual'] is! bool ||
          b['beanId'] != null && b['beanId'] is! String) {
        throw const FormatException('磨豆预留记录无法校验');
      }
    }
    return Mt80PhoneStore._(prefs, Map<String, dynamic>.from(data));
  }

  static bool _valid(Map e) {
    final p = e['parameters'];
    if (e['eventId'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(e['eventId'] as String) ||
        p is! Map ||
        e['source'] != 'motto80-phone-ble' ||
        e['reason'] != 'observed_idle_grinding_idle') {
      return false;
    }
    if (e['schemaVersion'] != 1 ||
        e['schemaVersion'] is! int ||
        e['durationMs'] is! int ||
        e['endedAtMs'] is! int ||
        e['startedAtMs'] is! int ||
        e['durationMs'] != e['endedAtMs'] - e['startedAtMs']) {
      return false;
    }
    return Mt80Candidate.parse({
          ...e,
          'bladeGapUm': p['bladeGap'],
          'feedingRpm': p['feedingRpm'],
          'grindRpm': p['grindRpm'],
        }) !=
        null;
  }

  Future<T> _transaction<T>(Future<T> Function() work) async {
    final before = _tail, done = Completer<void>();
    _tail = done.future;
    await before;
    try {
      return await work();
    } finally {
      done.complete();
    }
  }

  Future<void> _commit(Map<String, dynamic> next) async {
    final encoded = jsonEncode(next);
    if (encoded.length > 2000000) throw StateError('本地磨豆记录较多，请先备份维护');
    if (!await _prefs.setString(key, encoded)) {
      throw StateError('磨豆记录未能持久保存');
    }
    _data = next;
  }

  Future<void> add(Map<String, dynamic> event, {String? beanId}) =>
      _transaction(() async {
        if (!_valid(event)) throw const FormatException('磨豆事件不完整');
        final next = Map<String, dynamic>.from(jsonDecode(jsonEncode(_data)));
        final events = next['events'] as List;
        if (events.any((e) => e['eventId'] == event['eventId'])) return;
        // Retain history instead of deleting old bindings and permitting reuse.
        if (events.length >= 500) throw StateError('本地磨豆记录已满，请备份后维护');
        events.add({...event, 'beanId': beanId});
        await _commit(next);
      });

  Future<List<Map<String, dynamic>>> candidates(int brewAt, {String? beanId}) =>
      _transaction(() async {
        final used = (_data['bindings'] as Map).values
            .map((b) => b['eventId'])
            .toSet();
        return (_data['events'] as List)
            .where(
              (e) =>
                  _eligible(e, brewAt, beanId) && !used.contains(e['eventId']),
            )
            .map((e) => Map<String, dynamic>.from(jsonDecode(jsonEncode(e))))
            .toList();
      });

  static bool _eligible(Map e, int start, String? bean) =>
      _valid(e) &&
      e['endedAtMs'] >= start - 600000 &&
      e['endedAtMs'] <= start + 3000 &&
      (e['beanId'] == null || e['beanId'] == bean);

  Future<Map<String, dynamic>?> reserve(
    String scope,
    String noteId,
    int brewAt, {
    String? beanId,
    String? chosenEventId,
  }) => _transaction(() async {
    final next = Map<String, dynamic>.from(jsonDecode(jsonEncode(_data)));
    final bindings = next['bindings'] as Map;
    final bindingKey = jsonEncode([scope, noteId]);
    final confirmed = (next['snapshotBindings'] as Map)[bindingKey];
    if (confirmed != null) {
      if (confirmed['brewAt'] != brewAt ||
          confirmed['beanId'] != beanId ||
          chosenEventId != null) {
        throw StateError('本杯磨豆关联已冻结');
      }
      return Map<String, dynamic>.from(confirmed['record'] as Map);
    }
    final previous = bindings[bindingKey];
    final events = next['events'] as List;
    if (previous != null) {
      if (previous['brewAt'] != brewAt ||
          previous['beanId'] != beanId ||
          chosenEventId != null && chosenEventId != previous['eventId']) {
        throw StateError('本杯磨豆关联已冻结');
      }
      return _record(
        events.singleWhere((e) => e['eventId'] == previous['eventId']),
        previous['manual'] == true,
      );
    }
    final used = bindings.values.map((b) => b['eventId']).toSet();
    final eligible = events
        .where(
          (e) => _eligible(e, brewAt, beanId) && !used.contains(e['eventId']),
        )
        .toList();
    Map? event;
    if (chosenEventId != null) {
      event = eligible
          .where((e) => e['eventId'] == chosenEventId)
          .cast<Map>()
          .singleOrNull;
      if (event == null) throw StateError('所选磨豆记录不可用');
    } else if (eligible.length == 1 &&
        eligible.single['endedAtMs'] <= brewAt - 3000 &&
        eligible.single['beanId'] == beanId) {
      event = eligible.single;
    }
    if (event == null) return null;
    bindings[bindingKey] = {
      'eventId': event['eventId'],
      'brewAt': brewAt,
      'beanId': beanId,
      'manual': chosenEventId != null,
    };
    await _commit(next);
    return _record(event, chosenEventId != null);
  });

  Future<Map<String, dynamic>> saveCurrentSnapshot(
    String scope,
    String noteId,
    int brewAt,
    Map<String, dynamic> record, {
    String? beanId,
  }) => _transaction(() async {
    if (!isValidMt80SnapshotRecord(record)) {
      throw const FormatException('参数快照无法校验');
    }
    final next = Map<String, dynamic>.from(jsonDecode(jsonEncode(_data)));
    final key = jsonEncode([scope, noteId]);
    if ((next['bindings'] as Map).containsKey(key)) {
      throw StateError('本杯已预留完整磨豆事件');
    }
    final confirmed = next['snapshotBindings'] as Map;
    final previous = confirmed[key];
    if (previous != null) {
      if (previous['brewAt'] != brewAt ||
          previous['beanId'] != beanId ||
          jsonEncode(previous['record']) != jsonEncode(record)) {
        throw StateError('本杯磨豆关联已冻结');
      }
      return Map<String, dynamic>.from(previous['record']);
    }
    if (confirmed.length >= 500) throw StateError('本地快照记录已满，请先备份维护');
    confirmed[key] = {
      'brewAt': brewAt,
      'beanId': beanId,
      'record': jsonDecode(jsonEncode(record)),
    };
    await _commit(next);
    return Map<String, dynamic>.from(jsonDecode(jsonEncode(record)));
  });

  static Map<String, dynamic> _record(Map event, bool manual) {
    final p = event['parameters'] as Map;
    return {
      'schemaVersion': 1,
      'model': 'BOOKOO MOTTO80',
      'source': 'motto80-phone-ble',
      'eventId': event['eventId'],
      'association': manual ? 'phone_user_confirmed' : 'phone_unique_complete',
      'bladeGapUm': p['bladeGap'],
      'feedingRpm': p['feedingRpm'],
      'grindRpm': p['grindRpm'],
      'startedAtMs': event['startedAtMs'],
      'endedAtMs': event['endedAtMs'],
      'durationMs': event['durationMs'],
      'deviceReportedParameters': p,
      'parameterChanges': event['parameterChanges'] ?? [],
      'units': {'bladeGap': 'μm', 'feedingRpm': 'rpm', 'grindRpm': 'rpm'},
    };
  }
}
