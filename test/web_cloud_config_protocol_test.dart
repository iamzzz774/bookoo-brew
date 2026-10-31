// Standalone pure-Dart tests: dart test/web_cloud_config_protocol_test.dart
// ignore_for_file: avoid_relative_lib_imports, avoid_print
import 'dart:convert';
import '../lib/web_cloud_config.dart';

const origin = 'https://coffee.chu3.top';
const token = 'document_nonce_123';
const request = 'request_456';
int checks = 0;
void check(bool condition, String name) {
  if (!condition) throw StateError('FAIL: $name');
  checks++;
}

Map<String, dynamic> message() => {
  'type': 'bookoo.webCloudConfig.v1',
  'origin': origin,
  'token': token,
  'requestId': request,
  'status': 'ready',
  'config': <String, dynamic>{
    'url': 'https://fixture.invalid/project',
    'key': 'FAKE_SECRET',
    'userId': '  Exact_Case 身份  ',
  },
};
WebCloudConfigResult? parse(Object? m) => parseWebCloudConfigMessage(
  jsonEncode(m),
  origin: origin,
  token: token,
  requestId: request,
);
void main() {
  final result = parse(message())!;
  check(result.status == WebCloudConfigStatus.ready, 'ready');
  check(
    result.config!.userId == '  Exact_Case 身份  ',
    'exact identity preserved',
  );
  check(
    result.config!.url == 'https://fixture.invalid/project',
    'endpoint preserved',
  );
  check(result.config!.key == 'FAKE_SECRET', 'key preserved');
  check(
    !result.toString().contains('FAKE_SECRET') &&
        !result.toString().contains('fixture.invalid'),
    'result redaction',
  );
  check(
    !result.config.toString().contains('FAKE_SECRET') &&
        !result.config.toString().contains('fixture.invalid'),
    'config redaction',
  );
  for (final status in ['missing', 'disabled', 'unsupported']) {
    final m = message()..remove('config');
    m['status'] = status;
    final r = parse(m);
    check(r != null && r.status.name == status && r.config == null, status);
    m['config'] = message()['config'];
    check(parse(m) == null, 'nonready may not carry config');
  }
  for (final field in ['type', 'origin', 'token', 'requestId', 'status']) {
    for (final value in [null, 42, [], 'wrong', '']) {
      final m = message();
      m[field] = value;
      check(parse(m) == null, 'envelope validation $field');
    }
  }
  for (final field in ['url', 'key', 'userId']) {
    for (final value in [null, 42, [], '', 'x\n']) {
      final m = message();
      (m['config'] as Map)[field] = value;
      check(parse(m) == null, 'config type/required $field');
    }
  }
  for (final url in [
    'http://fixture.invalid',
    'https://user:pass@fixture.invalid',
    'https://@fixture.invalid',
    'https://fixture.invalid?q=secret',
    'https://fixture.invalid#secret',
    ' https://fixture.invalid',
    'https://fixture.invalid\\x',
    'https://',
    'https://fixture.invalid:0',
    'https://fixture.invalid:99999',
  ]) {
    final m = message();
    (m['config'] as Map)['url'] = url;
    check(parse(m) == null, 'invalid endpoint');
  }
  for (final pair in [
    ('url', 'x' * 2049),
    ('key', 'x' * 8193),
    ('userId', 'x' * 257),
    ('userId', '   '),
    ('key', ' padded '),
  ]) {
    final m = message();
    (m['config'] as Map)[pair.$1] = pair.$2;
    check(parse(m) == null, 'bounded values');
  }
  final extraEnvelope = message()..['error'] = 'FAKE_SECRET';
  check(parse(extraEnvelope) == null, 'extra envelope field');
  final extraConfig = message();
  (extraConfig['config'] as Map)['extra'] = 1;
  check(parse(extraConfig) == null, 'extra config field');
  for (final raw in ['{FAKE_SECRET', 'null', '[]', 'x' * 24577]) {
    check(
      parseWebCloudConfigMessage(
            raw,
            origin: origin,
            token: token,
            requestId: request,
          ) ==
          null,
      'invalid JSON/oversize never throws',
    );
  }
  for (final badOrigin in [
    'http://coffee.chu3.top',
    '$origin/',
    '$origin/path',
    'https://user@coffee.chu3.top',
  ]) {
    check(
      parseWebCloudConfigMessage(
            jsonEncode(message()),
            origin: badOrigin,
            token: token,
            requestId: request,
          ) ==
          null,
      'scope origin',
    );
  }
  for (final bad in ['', 'bad token', 'x' * 129, 'bad\n']) {
    check(
      parseWebCloudConfigMessage(
            jsonEncode(message()),
            origin: origin,
            token: bad,
            requestId: request,
          ) ==
          null,
      'scope nonce',
    );
    try {
      webCloudConfigReadScript(origin: origin, token: bad, requestId: request);
      throw StateError('must reject request');
    } on FormatException catch (e) {
      check(
        e.toString() == 'FormatException: Invalid cloud config request scope',
        'static error',
      );
    }
  }
  final script = webCloudConfigReadScript(
    origin: origin,
    token: token,
    requestId: request,
  );
  check(
    script.contains('readonly') && script.contains("get('main')"),
    'narrow read',
  );
  check(
    !script.contains('fetch(') && !script.contains('localStorage'),
    'no network/stale fallback',
  );
  print('PASS: $checks pure-Dart protocol checks');
}
