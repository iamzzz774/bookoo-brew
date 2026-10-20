import 'dart:convert';
import 'package:bookoo_brew/brewguide_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> row() => {
  'id': 'bookoo-1',
  'updated_at': '2026-10-19T10:00:00+00:00',
  'data': {
    'id': 'bookoo-1',
    'image': 'unchanged-image',
    'bookooDeducted': true,
    'params': {'coffee': '15 g', 'grinder': 'BOOKOO MT80'},
    'mt80Request': {
      'schemaVersion': 1,
      'status': 'needs_confirmation',
      'candidates': [
        {
          'eventId': 'event-1',
          'complete': true,
          'startedAtMs': 1792402479925,
          'endedAtMs': 1792402487248,
          'bladeGapUm': 650,
          'feedingRpm': 25,
          'grindRpm': 800,
        },
      ],
    },
  },
};
BrewGuideApi api(http.Client client) => BrewGuideApi(
  baseUrl: 'https://example.invalid',
  key: 'test-key',
  userId: 'test-user',
  client: client,
);

void main() {
  test('pending lookup is user scoped and excludes deleted notes', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.queryParameters['user_id'], 'eq.test-user');
      expect(request.url.queryParameters['deleted_at'], 'is.null');
      expect(
        request.url.queryParameters['data->mt80Request->>status'],
        'in.(pending,needs_confirmation)',
      );
      return http.Response('[]', 200);
    });
    expect(await api(client).pendingMt80Note(), isNull);
  });

  test(
    'confirmation uses CAS, preserves inventory/curve and reads back exact note',
    () async {
      var current = row();
      var gets = 0;
      var patches = 0;
      final client = MockClient((request) async {
        expect(request.url.path, '/rest/v1/brewing_notes');
        expect(request.url.queryParameters['user_id'], 'eq.test-user');
        expect(request.url.queryParameters['deleted_at'], 'is.null');
        expect(request.url.queryParameters['id'], 'eq.bookoo-1');
        if (request.method == 'GET') {
          gets++;
          return http.Response(jsonEncode([current]), 200);
        }
        patches++;
        expect(request.method, 'PATCH');
        expect(
          request.url.queryParameters['updated_at'],
          'eq.2026-10-19T10:00:00+00:00',
        );
        final body = jsonDecode(request.body) as Map;
        expect(body.keys.toSet(), {'data', 'updated_at'});
        expect(body['data']['bookooDeducted'], isTrue);
        expect(body['data']['image'], 'unchanged-image');
        expect(body['data']['params']['coffee'], '15 g');
        expect(body['data']['mt80Request']['selectedEventId'], 'event-1');
        current = {...current, ...body};
        return http.Response(jsonEncode([current]), 200);
      });
      await api(client).selectMt80Event('bookoo-1', 'event-1');
      expect(gets, 2);
      expect(patches, 1);
    },
  );

  test('CAS conflict is reported rather than overwriting newer note', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        request.method == 'GET' ? jsonEncode([row()]) : '[]',
        200,
      );
    });
    await expectLater(
      api(client).selectMt80Event('bookoo-1', 'event-1'),
      throwsException,
    );
    expect(calls, 2);
  });

  test('unknown/incomplete candidate is never submitted', () async {
    var writes = 0;
    final client = MockClient((request) async {
      if (request.method != 'GET') writes++;
      return http.Response(jsonEncode([row()]), 200);
    });
    await expectLater(
      api(client).selectMt80Event('bookoo-1', 'not-a-candidate'),
      throwsException,
    );
    expect(writes, 0);
  });
}
