import 'dart:convert';
import 'dart:math';

/// Read-only MT80 GATT v1 framing. Only appHello can be encoded here.
/// Reference: BooKooCode/OpenSource bookoo_motto80 README and Python client.
class Mt80Protocol {
  static const serviceUuid = '4d543830-0001-4b80-8f00-424f4f4b4f4f';
  static const rxUuid = '4d543830-0002-4b80-8f00-424f4f4b4f4f';
  static const txUuid = '4d543830-0003-4b80-8f00-424f4f4b4f4f';
  static const minimumReleaseVer = 102190820;

  int? _sequence;
  int _length = 0;
  int? _lastAtMs;
  final List<int> _payload = [];

  static List<List<int>> handshakeFrames({int sequence = 0}) {
    if (sequence < 0 || sequence > 0xffff) {
      throw RangeError.range(sequence, 0, 0xffff, 'sequence');
    }
    final bytes = utf8.encode('{"request":{"appHello":{"op":"handshake"}}}');
    return [
      for (var offset = 0; offset < bytes.length; offset += 12)
        [
          0xa5,
          1,
          sequence & 255,
          sequence >> 8,
          bytes.length & 255,
          bytes.length >> 8,
          offset & 255,
          offset >> 8,
          ...bytes.sublist(offset, min(offset + 12, bytes.length)),
        ],
    ];
  }

  void reset() {
    _sequence = null;
    _length = 0;
    _lastAtMs = null;
    _payload.clear();
  }

  /// A notification can use an ATT MTU larger than the safe outgoing 20 bytes.
  /// Invalid input always discards the entire pending logical message.
  Map<String, dynamic>? addFragment(List<int> fragment, int atMs) {
    try {
      if (_lastAtMs != null &&
          (atMs < _lastAtMs! || atMs - _lastAtMs! > 2000)) {
        reset();
      }
      if (fragment.length <= 8 ||
          fragment.length > 512 ||
          fragment.any((byte) => byte < 0 || byte > 255)) {
        throw const FormatException('Invalid frame size or byte');
      }
      if (fragment[0] != 0xa5 || fragment[1] != 1) {
        throw const FormatException('Unsupported MT80 frame');
      }
      int u16(int index) => fragment[index] | (fragment[index + 1] << 8);
      final sequence = u16(2);
      final length = u16(4);
      final offset = u16(6);
      final count = fragment.length - 8;
      if (length < 1 ||
          length > 4096 ||
          offset >= length ||
          count > length - offset) {
        throw const FormatException('Invalid logical message bounds');
      }
      if (offset == 0) {
        reset();
        _sequence = sequence;
        _length = length;
      } else if (_sequence != sequence ||
          _length != length ||
          offset != _payload.length) {
        throw const FormatException('Noncontiguous or mismatched fragment');
      }
      _payload.addAll(fragment.skip(8));
      _lastAtMs = atMs;
      if (_payload.length != _length) return null;
      final document = jsonDecode(utf8.decode(_payload, allowMalformed: false));
      if (document is! Map<String, dynamic>) {
        throw const FormatException('MT80 JSON must be an object');
      }
      reset();
      return document;
    } on FormatException {
      reset();
      rethrow;
    }
  }
}

class Mt80Sample {
  final int atMs;
  final int bladeGap;
  final int feedingRpm;
  final int grindRpm;
  final String devState;

  const Mt80Sample({
    required this.atMs,
    required this.bladeGap,
    required this.feedingRpm,
    required this.grindRpm,
    required this.devState,
  });

  bool get _validParameters =>
      bladeGap >= 0 &&
      bladeGap <= 999 &&
      feedingRpm >= 10 &&
      feedingRpm <= 65 &&
      grindRpm >= 500 &&
      grindRpm <= 1500;

  Map<String, int> get _parameters => {
    'bladeGap': bladeGap,
    'feedingRpm': feedingRpm,
    'grindRpm': grindRpm,
  };

  /// periodInfo is directly under broadcast (not wrapped in data).
  /// releaseVer belongs to broadcast.baseInfo and is checked by the caller.
  /// Per the guide, future nonempty state strings remain readable as unknown;
  /// only exact IDLE/GRINDING values can contribute to a complete event.
  static Mt80Sample? parse(Map<String, dynamic> message, int atMs) {
    final broadcast = message['broadcast'];
    if (broadcast is! Map) return null;
    final period = broadcast['periodInfo'];
    if (period is! Map) return null;
    final gap = period['bladeGap'];
    final feeding = period['feedingRpm'];
    final grind = period['grindRpm'];
    final state = period['devState'];
    if (gap is! int ||
        feeding is! int ||
        grind is! int ||
        state is! String ||
        state.isEmpty) {
      return null;
    }
    final sample = Mt80Sample(
      atMs: atMs,
      bladeGap: gap,
      feedingRpm: feeding,
      grindRpm: grind,
      devState: state,
    );
    return sample._validParameters ? sample : null;
  }
}

/// Produces only fully observed IDLE -> GRINDING -> IDLE episodes, not snapshots.
class Mt80EventDetector {
  Mt80Sample? latest;
  Mt80Sample? _previous;
  Mt80Sample? _start;
  Mt80Sample? _lastGrinding;
  int _grindingCount = 0;
  final List<Map<String, dynamic>> _changes = [];
  final Random _random = Random.secure();

  void interrupt() {
    latest = null;
    _previous = null;
    _clearEpisode();
  }

  void _clearEpisode() {
    _start = null;
    _lastGrinding = null;
    _grindingCount = 0;
    _changes.clear();
  }

  Map<String, dynamic>? add(Mt80Sample sample) {
    final previous = _previous;
    if (previous != null &&
        (sample.atMs <= previous.atMs || sample.atMs - previous.atMs > 1500)) {
      interrupt();
    }
    latest = sample;
    if (!sample._validParameters ||
        (sample.devState != 'IDLE' && sample.devState != 'GRINDING')) {
      interrupt();
      latest = sample;
      return null;
    }
    Map<String, dynamic>? event;
    if (sample.devState == 'GRINDING') {
      if (_start == null && _previous?.devState == 'IDLE') {
        _start = sample;
      }
      if (_start != null) {
        if (sample.atMs - _start!.atMs > 300000) {
          _clearEpisode();
        } else {
          final last = _lastGrinding;
          if (last != null &&
              (last.bladeGap != sample.bladeGap ||
                  last.feedingRpm != sample.feedingRpm ||
                  last.grindRpm != sample.grindRpm)) {
            _changes.add({
              'observedAtMs': sample.atMs,
              'parameters': sample._parameters,
            });
          }
          _lastGrinding = sample;
          _grindingCount++;
        }
      }
    } else {
      final start = _start;
      if (start != null &&
          _grindingCount >= 2 &&
          sample.atMs - start.atMs <= 300000) {
        event = {
          'schemaVersion': 1,
          'eventId': List.generate(
            16,
            (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join(),
          'complete': true,
          'reason': 'observed_idle_grinding_idle',
          'startedAtMs': start.atMs,
          'endedAtMs': sample.atMs,
          'durationMs': sample.atMs - start.atMs,
          'parameters': start._parameters,
          'parameterChanges': List<Map<String, dynamic>>.of(_changes),
          'source': 'motto80-phone-ble',
        };
      }
      _clearEpisode();
    }
    _previous = sample;
    return event;
  }
}
