import 'package:bookoo_brew/mt80.dart';
import 'package:bookoo_brew/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('built-in MT80 is offered without changing manual grinders', () {
    final settings = Settings()
      ..mt80Enabled = true
      ..grinderPresets = ['K-Ultra'];
    expect(settings.grinderChoices, ['K-Ultra', kMt80Grinder]);
    expect(settings.grinderPresets, ['K-Ultra']);
    settings.grinderPresets.add(kMt80Grinder);
    expect(
      settings.grinderChoices.where((g) => g == kMt80Grinder),
      hasLength(1),
    );
  });

  test('pending never displays an old/manual grind value', () {
    final result = Mt80Result.fromNote({
      'id': 'bookoo-1',
      'mt80Request': {'schemaVersion': 1, 'status': 'pending'},
      'params': {'grindSize': '6.5'},
    });
    expect(result.status, 'pending');
    expect(result.bladeGapUm, isNull);
    expect(result.title, contains('等待'));
  });

  test(
    'complete uses unit-bearing validated grinderRecord, not a scale mark',
    () {
      final result = Mt80Result.fromNote({
        'id': 'bookoo-1',
        'mt80Request': {'schemaVersion': 1, 'status': 'complete'},
        'grinderRecord': {
          'schemaVersion': 1,
          'model': 'BOOKOO MOTTO80',
          'source': 'motto80-ble',
          'eventId': 'event-1',
          'bladeGapUm': 650,
          'feedingRpm': 25,
          'grindRpm': 800,
        },
      });
      expect(result.title, '研磨度 650 μm');
      expect(result.subtitle, contains('25 rpm'));
      expect(result.subtitle, contains('800 rpm'));
    },
  );

  test('malformed complete payload cannot masquerade as a measurement', () {
    final result = Mt80Result.fromNote({
      'mt80Request': {'schemaVersion': 1, 'status': 'complete'},
      'grinderRecord': {'bladeGapUm': 650.5, 'feedingRpm': 25, 'grindRpm': 800},
    });
    expect(result.status, 'unavailable');
    expect(result.bladeGapUm, isNull);
  });

  test('confirmation choices require complete records with integer units', () {
    final result = Mt80Result.fromNote({
      'mt80Request': {
        'schemaVersion': 1,
        'status': 'needs_confirmation',
        'candidates': [
          {
            'eventId': 'good',
            'complete': true,
            'startedAtMs': 1792402479925,
            'endedAtMs': 1792402487248,
            'bladeGapUm': 650,
            'feedingRpm': 25,
            'grindRpm': 800,
          },
          {'eventId': 'bad', 'complete': false, 'bladeGapUm': 650},
        ],
      },
    });
    expect(result.candidates.map((c) => c.eventId), ['good']);
  });
}
