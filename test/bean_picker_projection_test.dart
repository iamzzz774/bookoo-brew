import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bookoo_brew/brewguide_api.dart';

void main() {
  Map<String, Object?> row(int i) => {
    'id': 'bean-$i',
    'name': 'bean $i',
    'remaining': '100g',
    'roastDate': '2026-10-01',
    'roastLevel': 'light',
    'roaster': 'fixture',
    'process': 'washed',
    'componentProcess': null,
  };
  BrewGuideApi api(MockClient c) => BrewGuideApi(
    baseUrl: 'https://example.invalid',
    key: 'test-key',
    userId: 'test-user',
    client: c,
  );
  test(
    'picker projects fields, scopes user/type and reads beyond 80 rows',
    () async {
      final offsets = <int>[];
      final result = await api(
        MockClient((req) async {
          expect(req.method, 'GET');
          final q = req.url.queryParameters;
          expect(q['user_id'], 'eq.test-user');
          expect(q['deleted_at'], 'is.null');
          expect(q['data->>beanType'], 'eq.filter');
          expect(q['order'], 'updated_at.desc,id.asc');
          expect(
            q['select'],
            contains('componentProcess:data->blendComponents->0->>process'),
          );
          expect(q['select']!.split(','), isNot(contains('data')));
          expect(q['select'], isNot(contains('image')));
          final offset = int.parse(q['offset']!);
          offsets.add(offset);
          final rows = offset == 0
              ? List.generate(80, row)
              : offset == 80
              ? [row(80)]
              : [];
          return http.Response(jsonEncode(rows), 200);
        }),
      ).listFilterBeans();
      expect(result, hasLength(81));
      expect(offsets, [0, 80, 81]);
    },
  );
  test(
    'short server-capped pages continue, grams and process semantics preserved',
    () async {
      final result = await api(
        MockClient((req) async {
          final offset = req.url.queryParameters['offset'];
          final rows = offset == '0'
              ? [
                  {
                    ...row(0),
                    'componentProcess': ' natural ',
                    'remaining': 12.5,
                  },
                  {...row(1), 'remaining': '0'},
                ]
              : offset == '2'
              ? [
                  {...row(2), 'componentProcess': ' ', 'remaining': '18g'},
                  {...row(3), 'remaining': '-1'},
                ]
              : [];
          return http.Response(jsonEncode(rows), 200);
        }),
      ).listFilterBeans();
      expect(result.map((b) => b.id), ['bean-0', 'bean-2']);
      expect(result.map((b) => b.remaining), [12.5, 18]);
      expect(result.map((b) => b.process), ['natural', 'washed']);
    },
  );
  test('repeated page fails boundedly instead of hanging', () async {
    var calls = 0;
    await expectLater(
      api(
        MockClient((_) async {
          calls++;
          return http.Response(jsonEncode([row(0)]), 200);
        }),
      ).listFilterBeans(),
      throwsFormatException,
    );
    expect(calls, 2);
  });
  test('error never exposes server response body', () async {
    try {
      await api(
        MockClient((_) async => http.Response('PRIVATE_SERVER_BODY', 401)),
      ).listFilterBeans();
      fail('must throw');
    } catch (e) {
      expect(e.toString(), contains('401'));
      expect(e.toString(), isNot(contains('PRIVATE_SERVER_BODY')));
    }
  });
  test('invalid payload and missing identity are rejected', () async {
    for (final payload in ['{}', '[null]', '[{"name":"missing id"}]']) {
      await expectLater(
        api(
          MockClient((_) async => http.Response(payload, 200)),
        ).listFilterBeans(),
        throwsFormatException,
      );
    }
  });
}
