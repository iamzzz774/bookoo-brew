import 'dart:convert';

import 'package:bookoo_brew/mt80_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

List<List<int>> frames(
  List<int> bytes, {
  int sequence = 0x1234,
  int chunk = 12,
}) => [
  for (var offset = 0; offset < bytes.length; offset += chunk)
    [
      0xa5,
      1,
      sequence & 255,
      sequence >> 8,
      bytes.length & 255,
      bytes.length >> 8,
      offset & 255,
      offset >> 8,
      ...bytes.skip(offset).take(chunk),
    ],
];

Map<String, dynamic> envelope({
  Object? gap = 150,
  Object? feeding = 50,
  Object? grind = 800,
  Object? state = 'IDLE',
}) => {
  'broadcast': {
    'periodInfo': {
      'bladeGap': gap,
      'feedingRpm': feeding,
      'grindRpm': grind,
      'devState': state,
    },
  },
};

Mt80Sample sample(
  int at,
  String state, {
  int gap = 150,
  int feeding = 50,
  int grind = 800,
}) => Mt80Sample(
  atMs: at,
  bladeGap: gap,
  feedingRpm: feeding,
  grindRpm: grind,
  devState: state,
);

void main() {
  group('official framing', () {
    test('handshake exact compact bytes, uint16LE, default sequence zero', () {
      final encoded = Mt80Protocol.handshakeFrames(sequence: 0xabcd);
      final bytes = utf8.encode('{"request":{"appHello":{"op":"handshake"}}}');
      expect(encoded, frames(bytes, sequence: 0xabcd));
      expect(encoded.every((f) => f.length <= 20 && f.length > 8), isTrue);
      expect(Mt80Protocol.handshakeFrames().first.sublist(2, 4), [0, 0]);
      for (final sequence in [-1, 65536]) {
        expect(
          () => Mt80Protocol.handshakeFrames(sequence: sequence),
          throwsRangeError,
        );
      }
      final receiver = Mt80Protocol();
      Map<String, dynamic>? result;
      for (final frame in encoded) {
        result = receiver.addFragment(frame, 0);
      }
      expect(result, {
        'request': {
          'appHello': {'op': 'handshake'},
        },
      });
    });

    test('Unicode splits use UTF8 byte length; sequence reuse is legal', () {
      final document = {'hello': '咖啡☕中文'};
      final packets = frames(utf8.encode(jsonEncode(document)), chunk: 1);
      final receiver = Mt80Protocol();
      for (var cycle = 0; cycle < 2; cycle++) {
        for (var i = 0; i < packets.length; i++) {
          expect(
            receiver.addFragment(packets[i], cycle * 100 + i),
            i == packets.length - 1 ? document : isNull,
          );
        }
      }
    });

    test(
      'offset zero supersedes partial message and reset clears assembly',
      () {
        final receiver = Mt80Protocol();
        final packets = Mt80Protocol.handshakeFrames();
        receiver.addFragment(packets.first, 0);
        expect(receiver.addFragment(frames(utf8.encode('{}')).single, 1), {});
        expect(
          () => receiver.addFragment(packets[1], 2),
          throwsFormatException,
        );
        receiver.addFragment(packets.first, 3);
        receiver.reset();
        expect(
          () => receiver.addFragment(packets[1], 4),
          throwsFormatException,
        );
      },
    );

    for (final gap in [2000, 2001, -1]) {
      test('adjacent fragment gap $gap ms', () {
        final receiver = Mt80Protocol();
        final packets = Mt80Protocol.handshakeFrames();
        receiver.addFragment(packets[0], 100);
        if (gap == 2000) {
          expect(receiver.addFragment(packets[1], 100 + gap), isNull);
          expect(receiver.addFragment(packets[2], 100 + gap * 2), isNull);
          expect(receiver.addFragment(packets[3], 100 + gap * 3), isA<Map>());
        } else {
          expect(
            () => receiver.addFragment(packets[1], 100 + gap),
            throwsFormatException,
          );
          expect(
            receiver.addFragment(frames(utf8.encode('{}')).single, 10000),
            {},
          );
        }
      });
    }

    test('every truncated header is invalid and resets pending assembly', () {
      final packets = Mt80Protocol.handshakeFrames();
      for (var length = 0; length <= 8; length++) {
        final receiver = Mt80Protocol();
        receiver.addFragment(packets.first, 0);
        expect(
          () => receiver.addFragment(packets[1].sublist(0, length), 1),
          throwsFormatException,
          reason: 'truncated length $length',
        );
        expect(
          () => receiver.addFragment(packets[1], 2),
          throwsFormatException,
        );
      }
    });

    test('every payload truncation cannot silently finish a message', () {
      final packets = Mt80Protocol.handshakeFrames();
      for (var i = 0; i < packets.length; i++) {
        for (var length = 9; length < packets[i].length; length++) {
          final receiver = Mt80Protocol();
          for (var j = 0; j < i; j++) {
            receiver.addFragment(packets[j], 0);
          }
          expect(
            receiver.addFragment(packets[i].sublist(0, length), 1),
            isNull,
          );
          if (i + 1 < packets.length) {
            expect(
              () => receiver.addFragment(packets[i + 1], 2),
              throwsFormatException,
            );
          }
        }
      }
    });

    test('magic version lengths bounds and invalid bytes reset assembly', () {
      final first = Mt80Protocol.handshakeFrames().first;
      final invalid = <List<int>>[
        [...first]..[0] = 0,
        [...first]..[1] = 2,
        [...first]
          ..[4] = 0
          ..[5] = 0,
        [...first]
          ..[4] = 1
          ..[5] = 16,
        [...first]..[6] = first[4],
        [...first]
          ..[4] = 1
          ..[5] = 0,
        [...first]..[8] = -1,
        [...first]..[8] = 256,
        List<int>.filled(513, 0),
      ];
      for (final frame in invalid) {
        final receiver = Mt80Protocol();
        receiver.addFragment(first, 0);
        expect(() => receiver.addFragment(frame, 1), throwsFormatException);
        expect(receiver.addFragment(frames(utf8.encode('{}')).single, 2), {});
      }
    });

    test('sequence length and all incorrect continuation offsets rejected', () {
      final packets = Mt80Protocol.handshakeFrames();
      for (var offset = 1; offset < 40; offset++) {
        if (offset == 12) continue;
        final receiver = Mt80Protocol();
        receiver.addFragment(packets.first, 0);
        final bad = [...packets[1]]..[6] = offset;
        expect(() => receiver.addFragment(bad, 1), throwsFormatException);
      }
      for (final index in [2, 3, 4, 5]) {
        final receiver = Mt80Protocol();
        receiver.addFragment(packets.first, 0);
        final bad = [...packets[1]]..[index] ^= 1;
        expect(() => receiver.addFragment(bad, 1), throwsFormatException);
        expect(
          () => receiver.addFragment(packets[1], 2),
          throwsFormatException,
        );
      }
    });

    test('malformed UTF8 JSON and nonobject JSON reject then recover', () {
      for (final bytes in [
        [0xc0, 0xaf],
        [0xed, 0xa0, 0x80],
        [0xe4, 0xb8],
        utf8.encode('{'),
        utf8.encode('null'),
        utf8.encode('[]'),
        utf8.encode('true'),
        utf8.encode('{"x":NaN}'),
      ]) {
        final receiver = Mt80Protocol();
        expect(() {
          for (final frame in frames(bytes)) {
            receiver.addFragment(frame, 0);
          }
        }, throwsFormatException);
        expect(receiver.addFragment(frames(utf8.encode('{}')).single, 1), {});
      }
    });

    test('4096 bytes accepted with large ATT frames and 4097 rejected', () {
      final bytes = utf8.encode('{"x":"${'a' * 4088}"}');
      expect(bytes.length, 4096);
      final receiver = Mt80Protocol();
      Map<String, dynamic>? result;
      for (final frame in frames(bytes, chunk: 504)) {
        result = receiver.addFragment(frame, 0);
      }
      expect((result!['x'] as String).length, 4088);
      expect(
        () => receiver.addFragment(frames([...bytes, 32]).first, 0),
        throwsFormatException,
      );
      expect(
        () => receiver.addFragment([0xa5, 1, 0, 0, 1, 0, 0, 0, 48], 0),
        throwsFormatException,
      ); // Length one is framed legally, but not an object.
    });
  });

  group('periodInfo parsing', () {
    test('exact nesting, firmware separate, zero is a valid gap', () {
      final message = envelope(gap: 0);
      final broadcast = message['broadcast'] as Map;
      broadcast['baseInfo'] = {'releaseVer': 102190820};
      final value = Mt80Sample.parse(message, 123)!;
      expect(value.atMs, 123);
      expect(value.bladeGap, 0);
      expect(value.feedingRpm, 50);
      expect(value.grindRpm, 800);
      expect(value.devState, 'IDLE');
      expect(Mt80Protocol.minimumReleaseVer, 102190820);
      expect(Mt80Sample.parse(envelope(), 1), isNotNull);
      expect(
        Mt80Sample.parse({
          'broadcast': {'baseInfo': broadcast['baseInfo']},
        }, 1),
        isNull,
      );
      expect(
        Mt80Sample.parse({
          'broadcast': {
            'periodInfo': {'data': broadcast['periodInfo']},
          },
        }, 1),
        isNull,
      );
      expect(
        Mt80Sample.parse({'periodInfo': broadcast['periodInfo']}, 1),
        isNull,
      );
      expect(Mt80Sample.parse({'broadcast': []}, 1), isNull);
    });

    test('strict integer types including bool float null strings', () {
      for (final bad in [true, false, 150.0, '150', null]) {
        expect(Mt80Sample.parse(envelope(gap: bad), 0), isNull);
        expect(Mt80Sample.parse(envelope(feeding: bad), 0), isNull);
        expect(Mt80Sample.parse(envelope(grind: bad), 0), isNull);
      }
      for (final key in ['bladeGap', 'feedingRpm', 'grindRpm', 'devState']) {
        final message = envelope();
        ((message['broadcast'] as Map)['periodInfo'] as Map).remove(key);
        expect(Mt80Sample.parse(message, 0), isNull);
      }
    });

    test('inclusive ranges with out of bounds rejected', () {
      for (final gap in [0, 999]) {
        expect(Mt80Sample.parse(envelope(gap: gap), 0), isNotNull);
      }
      for (final rpm in [10, 65]) {
        expect(Mt80Sample.parse(envelope(feeding: rpm), 0), isNotNull);
      }
      for (final rpm in [500, 1500]) {
        expect(Mt80Sample.parse(envelope(grind: rpm), 0), isNotNull);
      }
      for (final gap in [-1, 1000]) {
        expect(Mt80Sample.parse(envelope(gap: gap), 0), isNull);
      }
      for (final rpm in [9, 66]) {
        expect(Mt80Sample.parse(envelope(feeding: rpm), 0), isNull);
      }
      for (final rpm in [499, 1501]) {
        expect(Mt80Sample.parse(envelope(grind: rpm), 0), isNull);
      }
    });

    test(
      'official state strings and future unknown strings preserved verbatim',
      () {
        for (final state in [
          'IDLE',
          'GRINDING',
          'SETTING',
          'UPDATING',
          'WARNING',
          'HighSpeedClean',
          'BootGuide',
          'UNKNOWN',
          'FUTURE_STATE',
          ' ',
          'grinding',
        ]) {
          expect(Mt80Sample.parse(envelope(state: state), 0)!.devState, state);
        }
        for (final state in ['', 0, 1, true, null]) {
          expect(Mt80Sample.parse(envelope(state: state), 0), isNull);
        }
      },
    );
  });

  group('complete observed events only', () {
    test('schema timing random ID frozen first params and changed samples', () {
      final detector = Mt80EventDetector();
      expect(detector.add(sample(0, 'IDLE', gap: 300)), isNull);
      expect(detector.add(sample(200, 'GRINDING')), isNull);
      expect(detector.add(sample(400, 'GRINDING')), isNull);
      expect(detector.add(sample(600, 'GRINDING', gap: 160)), isNull);
      expect(detector.add(sample(800, 'GRINDING', gap: 160)), isNull);
      expect(detector.add(sample(1000, 'GRINDING', grind: 900)), isNull);
      final event = detector.add(sample(1200, 'IDLE', gap: 999))!;
      expect(event['schemaVersion'], 1);
      expect(event['complete'], isTrue);
      expect(event['reason'], 'observed_idle_grinding_idle');
      expect(event['eventId'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(event['source'], 'motto80-phone-ble');
      expect(event['startedAtMs'], 200);
      expect(event['endedAtMs'], 1200);
      expect(event['durationMs'], 1000);
      expect(event['parameters'], {
        'bladeGap': 150,
        'feedingRpm': 50,
        'grindRpm': 800,
      });
      expect(event['parameterChanges'], [
        {
          'observedAtMs': 600,
          'parameters': {'bladeGap': 160, 'feedingRpm': 50, 'grindRpm': 800},
        },
        {
          'observedAtMs': 1000,
          'parameters': {'bladeGap': 150, 'feedingRpm': 50, 'grindRpm': 900},
        },
      ]);
      expect(detector.latest!.bladeGap, 999);
      expect(detector.add(sample(1400, 'IDLE')), isNull);
      detector.add(sample(1600, 'GRINDING'));
      detector.add(sample(1800, 'GRINDING'));
      final second = detector.add(sample(2000, 'IDLE'))!;
      expect(second['eventId'], isNot(event['eventId']));
      expect(second['parameterChanges'], isEmpty);
      expect(event['parameterChanges'], hasLength(2));
      expect(jsonDecode(jsonEncode(event)), event);
    });

    test(
      'connect grinding incomplete until idle then next full episode succeeds',
      () {
        final detector = Mt80EventDetector();
        for (final s in [
          sample(0, 'GRINDING'),
          sample(200, 'GRINDING'),
          sample(400, 'IDLE'),
        ]) {
          expect(detector.add(s), isNull);
        }
        detector.add(sample(600, 'GRINDING'));
        detector.add(sample(800, 'GRINDING'));
        expect(detector.add(sample(1000, 'IDLE')), isNotNull);
      },
    );

    test('explicit interrupt/reconnect discards episode and latest', () {
      final detector = Mt80EventDetector();
      detector.add(sample(0, 'IDLE'));
      detector.add(sample(200, 'GRINDING'));
      detector.add(sample(400, 'GRINDING'));
      detector.interrupt();
      expect(detector.latest, isNull);
      expect(detector.add(sample(600, 'GRINDING')), isNull);
      expect(detector.add(sample(800, 'IDLE')), isNull);
    });

    test('one grinding observation never enough', () {
      final detector = Mt80EventDetector();
      detector.add(sample(0, 'IDLE'));
      detector.add(sample(200, 'GRINDING'));
      expect(detector.add(sample(400, 'IDLE')), isNull);
    });

    for (final badState in [
      'SETTING',
      'UPDATING',
      'WARNING',
      'HighSpeedClean',
      'BootGuide',
      'UNKNOWN',
      'FUTURE',
      'grinding',
      '0',
    ]) {
      test('$badState interrupts; no invented clean-state bridge', () {
        final detector = Mt80EventDetector();
        detector.add(sample(0, 'IDLE'));
        detector.add(sample(200, 'GRINDING'));
        detector.add(sample(400, 'GRINDING'));
        expect(detector.add(sample(600, badState)), isNull);
        expect(detector.add(sample(800, 'GRINDING')), isNull);
        expect(detector.add(sample(1000, 'IDLE')), isNull);
      });
    }

    for (final position in [1, 2, 3]) {
      test('gap at position $position interrupts entire episode', () {
        final detector = Mt80EventDetector();
        var at = 0;
        final states = ['IDLE', 'GRINDING', 'GRINDING', 'IDLE'];
        for (var i = 0; i < states.length; i++) {
          at += i == position ? 1501 : 200;
          expect(detector.add(sample(at, states[i])), isNull);
        }
      });
    }

    test('1500 ms adjacency accepted', () {
      final detector = Mt80EventDetector();
      detector.add(sample(0, 'IDLE'));
      detector.add(sample(1500, 'GRINDING'));
      detector.add(sample(3000, 'GRINDING'));
      expect(detector.add(sample(4500, 'IDLE')), isNotNull);
    });

    for (final at in [100, 200]) {
      test('out of order or duplicate time $at interrupts', () {
        final detector = Mt80EventDetector();
        detector.add(sample(0, 'IDLE'));
        detector.add(sample(200, 'GRINDING'));
        detector.add(sample(at, 'GRINDING'));
        expect(detector.add(sample(400, 'IDLE')), isNull);
      });
    }

    for (final duration in [300000, 300001]) {
      test('maximum duration $duration inclusive with continuous samples', () {
        final detector = Mt80EventDetector();
        detector.add(sample(0, 'IDLE'));
        detector.add(sample(200, 'GRINDING'));
        for (var at = 1200; at < 200 + duration; at += 1000) {
          detector.add(sample(at, 'GRINDING'));
        }
        expect(
          detector.add(sample(200 + duration, 'IDLE')),
          duration == 300000 ? isNotNull : isNull,
        );
      });
    }

    test('duration expiry while still grinding never restarts mid-grind', () {
      final detector = Mt80EventDetector();
      detector.add(sample(0, 'IDLE'));
      detector.add(sample(200, 'GRINDING'));
      for (var at = 1200; at <= 302200; at += 1000) {
        expect(detector.add(sample(at, 'GRINDING')), isNull);
      }
      expect(detector.add(sample(302400, 'IDLE')), isNull);
      detector.add(sample(302600, 'GRINDING'));
      detector.add(sample(302800, 'GRINDING'));
      expect(detector.add(sample(303000, 'IDLE')), isNotNull);
    });

    test('invalid directly constructed parameters interrupt', () {
      final detector = Mt80EventDetector();
      detector.add(sample(0, 'IDLE'));
      detector.add(sample(200, 'GRINDING'));
      detector.add(sample(400, 'GRINDING', gap: 1000));
      expect(detector.add(sample(600, 'IDLE')), isNull);
    });
  });
}
