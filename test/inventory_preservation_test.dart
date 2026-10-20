import 'dart:convert';
import 'package:bookoo_brew/brewguide_api.dart';
import 'package:bookoo_brew/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'record-only inventory uses fresh CAS and preserves retired/custom fields',
    () async {
      final row = <String, dynamic>{
        'id': 'bean/a+b',
        'user_id': 'test-user',
        'updated_at': '2026-10-19T00:00:00Z',
        'data': {
          'remaining': '180',
          'custom': {'preserve': true},
          'mt80PresetRequest': {
            'requestId': 'old-command',
            'status': 'pending',
          },
          'mt80AnalysisRequest': {
            'requestId': 'old-analysis',
            'status': 'pending',
          },
        },
      };
      final client = MockClient((req) async {
        expect(req.url.queryParameters['user_id'], 'eq.test-user');
        expect(req.url.queryParameters['deleted_at'], 'is.null');
        expect(req.url.queryParameters['id'], 'eq.bean/a+b');
        if (req.method == 'GET') return http.Response(jsonEncode([row]), 200);
        expect(req.method, 'PATCH');
        expect(
          req.url.queryParameters['updated_at'],
          'eq.${row['updated_at']}',
        );
        final body = jsonDecode(req.body) as Map;
        expect(body['data']['remaining'], '165');
        expect(
          body['data']['mt80PresetRequest'],
          (row['data'] as Map)['mt80PresetRequest'],
        );
        expect(
          body['data']['mt80AnalysisRequest'],
          (row['data'] as Map)['mt80AnalysisRequest'],
        );
        expect(body['data']['custom'], {'preserve': true});
        return http.Response(
          jsonEncode([
            {...row, ...body},
          ]),
          200,
        );
      });
      final api = BrewGuideApi(
        baseUrl: 'https://example.invalid',
        key: 'test-key',
        userId: 'test-user',
        client: client,
      );
      final stale = Bean(
        id: 'bean/a+b',
        name: 'old',
        roastLevel: '',
        remaining: 200,
        raw: {'remaining': '200'},
      );
      expect(await api.deductBean(stale, 15), (180.0, 165.0));
    },
  );
}
