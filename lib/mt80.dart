import 'mt80_snapshot.dart';

/// Built-in, opt-in grinder. This is never a manual dial/scale setting.
const kMt80Grinder = 'BOOKOO MT80';

bool isMt80(String? grinder) => grinder == kMt80Grinder;

Map<String, dynamic> mt80Request(int brewStartedAtMs, int requestedAtMs) => {
  'schemaVersion': 1,
  'status': 'pending',
  'brewStartedAtMs': brewStartedAtMs,
  'requestedAtMs': requestedAtMs,
};

bool _parametersValid(Map record) =>
    record['bladeGapUm'] is int &&
    record['bladeGapUm'] >= 0 &&
    record['bladeGapUm'] <= 999 &&
    record['feedingRpm'] is int &&
    record['feedingRpm'] >= 10 &&
    record['feedingRpm'] <= 65 &&
    record['grindRpm'] is int &&
    record['grindRpm'] >= 500 &&
    record['grindRpm'] <= 1500;

class Mt80Candidate {
  final String eventId;
  final int startedAtMs, endedAtMs, bladeGapUm, feedingRpm, grindRpm;
  const Mt80Candidate(
    this.eventId,
    this.startedAtMs,
    this.endedAtMs,
    this.bladeGapUm,
    this.feedingRpm,
    this.grindRpm,
  );

  static Mt80Candidate? parse(dynamic value) {
    if (value is! Map ||
        value['complete'] != true ||
        !_parametersValid(value) ||
        value['eventId'] is! String ||
        (value['eventId'] as String).isEmpty ||
        value['startedAtMs'] is! int ||
        value['endedAtMs'] is! int ||
        value['startedAtMs'] < 946684800000 ||
        value['endedAtMs'] < value['startedAtMs'] ||
        value['endedAtMs'] - value['startedAtMs'] > 300000) {
      return null;
    }
    return Mt80Candidate(
      value['eventId'],
      value['startedAtMs'],
      value['endedAtMs'],
      value['bladeGapUm'],
      value['feedingRpm'],
      value['grindRpm'],
    );
  }

  String get label {
    final t = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
    String two(int v) => '$v'.padLeft(2, '0');
    return '${t.month}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} · 研磨度 $bladeGapUm μm';
  }

  String get detail => '下豆速度 $feedingRpm rpm · 刀盘转速 $grindRpm rpm';
}

class Mt80Result {
  final String? noteId;
  final String status;
  final int? bladeGapUm, feedingRpm, grindRpm;
  final List<Mt80Candidate> candidates;
  const Mt80Result({
    this.noteId,
    this.status = 'idle',
    this.bladeGapUm,
    this.feedingRpm,
    this.grindRpm,
    this.candidates = const [],
  });

  factory Mt80Result.fromNote(Map<String, dynamic> note) {
    final id = note['id'] is String ? note['id'] as String : null;
    final request = note['mt80Request'];
    if (request is! Map || request['schemaVersion'] != 1) {
      return Mt80Result(noteId: id, status: 'unavailable');
    }
    final status = request['status'];
    if (status == 'snapshot' &&
        isValidMt80SnapshotRecord(note['grinderRecord'])) {
      final record = note['grinderRecord'] as Map;
      return Mt80Result(
        noteId: id,
        status: 'snapshot',
        bladeGapUm: record['bladeGapUm'],
        feedingRpm: record['feedingRpm'],
        grindRpm: record['grindRpm'],
      );
    }
    if (status == 'complete') {
      final record = note['grinderRecord'];
      if (record is Map &&
          record['schemaVersion'] == 1 &&
          record['model'] == 'BOOKOO MOTTO80' &&
          ['motto80-ble', 'motto80-phone-ble'].contains(record['source']) &&
          record['eventId'] is String &&
          (record['eventId'] as String).isNotEmpty &&
          _parametersValid(record) &&
          (record['source'] != 'motto80-phone-ble' ||
              (RegExp(
                    r'^[a-f0-9]{32}$',
                  ).hasMatch(record['eventId'] as String) &&
                  record['startedAtMs'] is int &&
                  record['endedAtMs'] is int &&
                  record['durationMs'] is int &&
                  record['startedAtMs'] >= 946684800000 &&
                  record['endedAtMs'] > record['startedAtMs'] &&
                  record['durationMs'] ==
                      record['endedAtMs'] - record['startedAtMs'] &&
                  record['durationMs'] <= 300000))) {
        return Mt80Result(
          noteId: id,
          status: 'complete',
          bladeGapUm: record['bladeGapUm'],
          feedingRpm: record['feedingRpm'],
          grindRpm: record['grindRpm'],
        );
      }
      return Mt80Result(noteId: id, status: 'unavailable');
    }
    final raw = request['candidates'];
    final candidates = raw is List
        ? raw
              .take(20)
              .map(Mt80Candidate.parse)
              .whereType<Mt80Candidate>()
              .toList()
        : <Mt80Candidate>[];
    return Mt80Result(
      noteId: id,
      status: ['pending', 'needs_confirmation'].contains(status)
          ? status as String
          : 'unavailable',
      candidates: candidates,
    );
  }

  String get saveFeedback => switch (status) {
    'complete' => '已关联磨豆参数',
    'snapshot' => '已记录磨豆参数',
    _ => '未记录磨豆参数',
  };

  String get title => switch (status) {
    'complete' || 'snapshot' => '研磨度 $bladeGapUm μm',
    'pending' => '等待 Mac 记录本次研磨',
    'needs_confirmation' => '请选择本次磨豆记录',
    'unavailable' => '未匹配到完整磨豆记录',
    _ => '手机蓝牙采集',
  };
  String get subtitle => switch (status) {
    'snapshot' => ' 下豆速度 $feedingRpm rpm · 刀盘转速 $grindRpm rpm',
    'complete' => '下豆速度 $feedingRpm rpm · 刀盘转速 $grindRpm rpm',
    'pending' => '笔记已保存，Mac 在线后自动补入',
    'needs_confirmation' => '请确认这杯对应的磨豆记录',
    'unavailable' => '本杯未填研磨参数，不使用旧值',
    _ => '保存后关联本次磨豆的参数',
  };
}
