import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bookoo_brew/device_coordination.dart';
import 'package:bookoo_brew/settings.dart';
import 'package:bookoo_brew/mt80.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const baseUrl = 'https://example.invalid';
const fast = Duration(milliseconds: 35);
const macId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const challenge = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const leaseId = 'cccccccccccccccccccccccccccccccc';
const baseFields = {
  'schemaVersion',
  'type',
  'clientId',
  'sessionId',
  'requestId',
  'atMs',
  'resources',
};

/// Models the Python contract, NOT an echo of Dart's outgoing extra fields.
class Broker {
  bool enabled = true, recovery = false;
  String? acquireError, releaseError;
  Map<String, dynamic>? active, completed;
  final requests = <Map<String, dynamic>>[];
  final violations = <String>[];
  Map<String, dynamic> response(
    Map<String, dynamic> m,
    String type, [
    Map<String, dynamic> extra = const {},
  ]) => {
    for (final k in baseFields.difference({'type', 'atMs'})) k: m[k],
    'type': type,
    'atMs': DateTime.now().millisecondsSinceEpoch,
    'macId': macId,
    ...extra,
  };
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> m) async {
    requests.add(m);
    final extras = switch (m['type']) {
      'hello' => <String>{},
      'acquire' => {'macId', 'challenge'},
      'release' || 'pulse' => {'macId', 'leaseId'},
      _ => {'INVALID'},
    };
    if (m.keys.toSet().difference({...baseFields, ...extras}).isNotEmpty ||
        {...baseFields, ...extras}.difference(m.keys.toSet()).isNotEmpty) {
      violations.add('Unexpected wire fields for ${m['type']}');
      return null;
    }
    if (m['type'] != 'hello' && m['macId'] != macId) {
      return response(m, 'error', {'code': 'wrong_mac'});
    }
    if (recovery) return response(m, 'error', {'code': 'recovery_required'});
    if (m['type'] == 'hello') {
      if (!enabled) return null;
      if (active != null) return response(m, 'error', {'code': 'lease_active'});
      return response(m, 'offer', {
        'challenge': challenge,
        'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 15000,
      });
    }
    if (m['type'] == 'acquire') {
      // Check the crash boundary: all original identifiers must already exist.
      final stored = await pending();
      for (final field in [
        'clientId',
        'sessionId',
        'resources',
        'macId',
        'challenge',
      ]) {
        if (jsonEncode(stored?[field]) != jsonEncode(m[field])) {
          violations.add('Not durable: $field');
        }
      }
      if (stored?['originalAcquireRequestId'] != m['requestId']) {
        violations.add('Not durable: requestId');
      }
      if (acquireError != null) {
        return response(m, 'error', {'code': acquireError});
      }
      if (active != null &&
          (active!['requestId'] != m['requestId'] ||
              active!['challenge'] != m['challenge'] ||
              active!['clientId'] != m['clientId'] ||
              active!['sessionId'] != m['sessionId'] ||
              jsonEncode(active!['resources']) != jsonEncode(m['resources']))) {
        return response(m, 'error', {'code': 'busy'});
      }
      active ??= Map.of(m);
      return response(m, 'acquired', {'leaseId': leaseId});
    }
    if (m['type'] == 'release') {
      if (releaseError != null) {
        return response(m, 'error', {'code': releaseError});
      }
      final owner = active ?? completed;
      if (owner == null) return response(m, 'error', {'code': 'no_lease'});
      if (m['leaseId'] != leaseId ||
          m['clientId'] != owner['clientId'] ||
          m['sessionId'] != owner['sessionId'] ||
          jsonEncode(m['resources']) != jsonEncode(owner['resources'])) {
        return response(m, 'error', {'code': 'wrong_owner'});
      }
      completed = owner;
      active = null;
      return response(m, 'released', {'leaseId': m['leaseId']});
    }
    return response(m, 'pulsed', {'leaseId': m['leaseId']});
  }
}

class FakePeer implements CoordinationTransport {
  final Broker broker;
  final events = StreamController<String>.broadcast(sync: true);
  bool closed = false;
  bool Function(Map<String, dynamic>)? drop;
  void Function(Map<String, dynamic>)? mutate;
  void Function(Map<String, dynamic>)? afterReply;
  Future<void> Function(Map<String, dynamic>)? beforeReply;
  FakePeer(this.broker);
  @override
  Stream<String> get messages => events.stream;
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> m) =>
      broker.handle(m);
  @override
  Future<void> send(String raw) async {
    final d = jsonDecode(raw) as Map<String, dynamic>;
    if (d['event'] == 'phx_join') {
      events.add(
        jsonEncode({
          'topic': d['topic'],
          'event': 'phx_reply',
          'ref': '1',
          'payload': {'status': 'ok'},
        }),
      );
      return;
    }
    if (d['event'] != 'broadcast') return;
    final request = Map<String, dynamic>.from(d['payload']['payload']);
    final reply = await handle(request);
    if (reply == null) return;
    await beforeReply?.call(reply);
    if ((drop?.call(reply) ?? false) || closed) return;
    mutate?.call(reply);
    events.add(
      jsonEncode({
        'topic': d['topic'],
        'event': 'broadcast',
        'payload': {
          'type': 'broadcast',
          'event': 'coffee_coordination',
          'payload': reply,
        },
      }),
    );
    afterReply?.call(reply);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!events.isClosed) await events.close();
  }
}

/// Only the pure Coordinator + temporary JsonStore + inert adapter are used.
/// This never starts run_broker, reads credentials, or touches a real device.
const pythonFixture = r'''
import importlib.util, json, os, sys, tempfile
spec = importlib.util.spec_from_file_location('offline_coordination', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class Adapter:
    def snapshot(self, resources): return {'grinderPaused': False}
    def hold(self, *args): pass
    def restore(self, *args): pass
with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as root:
    store = module.JsonStore(root)
    coordinator = module.Coordinator(store, Adapter())
    coordinator.startup()
    for line in sys.stdin:
        message = json.loads(line)
        if message.get('restart'):
            coordinator = module.Coordinator(store, Adapter())
            coordinator.startup()
            result = {'restarted': True}
        else:
            result = coordinator.handle(message, {'schemaVersion': 1, 'enabled': True})
        print(json.dumps(result), flush=True)
''';

class PythonPeer extends FakePeer {
  final Process process;
  final StreamIterator<String> lines;
  PythonPeer(super.broker, this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
  Future<void> _serial = Future.value();
  Future<Map<String, dynamic>?> command(Map<String, dynamic> m) {
    final result = _serial.then((_) => _command(m));
    _serial = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, dynamic>?> _command(Map<String, dynamic> m) async {
    process.stdin.writeln(jsonEncode(m));
    if (!await lines.moveNext().timeout(const Duration(seconds: 3))) {
      throw StateError('Offline Python ended');
    }
    final reply = jsonDecode(lines.current);
    return reply == null ? null : Map<String, dynamic>.from(reply);
  }

  @override
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> m) async {
    broker.requests.add(m);
    return command(m);
  }

  Future<void> shutdown() async {
    await super.close();
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 3)), 0);
    await lines.cancel();
  }

  // Closing/reopening the socket must not restart the broker process.
  @override
  Future<void> close() async {
    closed = true;
  }

  void reopen() {
    closed = false;
  }
}

Future<Map<String, dynamic>?> pending() async {
  final raw = (await SharedPreferences.getInstance()).getString(
    DeviceCoordination.pendingKey,
  );
  return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw));
}

Future<void> acquire(
  DeviceCoordination c, {
  String user = 'user',
  Set<String> resources = const {'scale', 'grinder'},
}) => c.acquire(
  baseUrl: baseUrl,
  key: 'test-key-never-log',
  userId: user,
  resources: resources,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clients = <DeviceCoordination>[];
  final brokers = <Broker>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clients.clear();
    brokers.clear();
  });
  tearDown(() async {
    for (final c in clients) {
      await c.dispose();
    }
    for (final b in brokers) {
      expect(b.violations, isEmpty);
    }
  });
  Broker broker() {
    final b = Broker();
    brokers.add(b);
    return b;
  }

  DeviceCoordination client(
    Future<CoordinationTransport> Function(Uri) dial, {
    Duration heartbeat = const Duration(seconds: 10),
    Duration timeout = fast,
  }) {
    final c = DeviceCoordination(
      dial: dial,
      offerTimeout: timeout,
      requestTimeout: timeout,
      connectionTimeout: timeout,
      heartbeatInterval: heartbeat,
    );
    clients.add(c);
    return c;
  }

  test('new install and MT80 selection remain independent of Mac', () async {
    final s = await Settings.load();
    expect(s.mt80Enabled, isFalse);
    expect(s.grinderChoices, isNot(contains(kMt80Grinder)));
    s.grinderPresets = ['Manual'];
    s.mt80Enabled = true;
    await s.save();
    expect(
      (await Settings.load()).grinderChoices,
      containsAll(['Manual', kMt80Grinder]),
    );
    s.mt80Enabled = false;
    await s.save();
    expect((await Settings.load()).grinderChoices, ['Manual']);
  });
  test('legacy selected MT80 is preserved', () async {
    SharedPreferences.setMockInitialValues({'lastGrinder': kMt80Grinder});
    expect((await Settings.load()).mt80Enabled, isTrue);
  });
  test(
    'disabled/no Mac is standalone without polling; new user independently discovers',
    () async {
      final b = broker()..enabled = false;
      var calls = 0;
      final c = client((_) async {
        calls++;
        return FakePeer(b);
      });
      await acquire(c);
      await acquire(c);
      await c.release();
      await acquire(c);
      expect(calls, 1);
      expect(b.requests.map((m) => m['type']), ['hello']);
      expect(c.hasLease, isFalse);
      expect(await pending(), isNull);
      await acquire(c, user: 'new-user');
      expect(calls, 2);
      expect(
        b.requests.last['sessionId'],
        isNot(b.requests.first['sessionId']),
      );
    },
  );
  test(
    'unavailable discovery is standalone once and does not reveal key/URL',
    () async {
      var calls = 0;
      final c = client((uri) async {
        calls++;
        throw StateError('private $uri');
      });
      await acquire(c);
      await acquire(c);
      expect(calls, 1);
      expect(await pending(), isNull);
      expect(c.hasLease, isFalse);
    },
  );
  test(
    'acquired, exact durable fields, release and pulse obey Python wire fields',
    () async {
      final b = broker();
      final c = client(
        (_) async => FakePeer(b),
        heartbeat: const Duration(milliseconds: 4),
      );
      await acquire(c);
      expect(c.hasLease, isTrue);
      expect((await pending())!['leaseId'], leaseId);
      await Future<void>.delayed(const Duration(milliseconds: 12));
      expect(b.requests.any((m) => m['type'] == 'pulse'), isTrue);
      await c.release();
      expect(c.hasLease, isFalse);
      expect(await pending(), isNull);
      expect(b.requests.first.keys.toSet(), baseFields);
    },
  );
  test('busy discovery fails closed without acquire', () async {
    final b = broker()..active = {};
    final c = client((_) async => FakePeer(b));
    await expectLater(acquire(c), throwsStateError);
    expect(c.hasLease, isFalse);
    expect(b.requests.length, 1);
  });
  for (final code in [
    'hold_failed',
    'disabled',
    'recovery_required',
    'invalid_offer',
  ]) {
    test('offer then $code never permits standalone BLE', () async {
      final b = broker()..acquireError = code;
      final c = client((_) async => FakePeer(b));
      await expectLater(acquire(c), throwsStateError);
      expect(c.hasLease, isFalse);
      expect(await pending(), isNotNull);
    });
  }
  test(
    'lost acquired retries original request/challenge after reconnect then releases',
    () async {
      final b = broker();
      var dropped = false;
      final c = client(
        (_) async => FakePeer(b)
          ..drop = (m) {
            if (m['type'] == 'acquired' && !dropped) {
              dropped = true;
              return true;
            }
            return false;
          },
      );
      await expectLater(acquire(c), throwsStateError);
      final original = await pending();
      expect(original!['leaseId'], '');
      expect(b.active, isNotNull);
      await c.release();
      final attempts = b.requests.where((m) => m['type'] == 'acquire').toList();
      expect(attempts.length, 2);
      expect(attempts[1]['requestId'], attempts[0]['requestId']);
      expect(attempts[1]['challenge'], attempts[0]['challenge']);
      expect(b.requests.map((m) => m['type']), [
        'hello',
        'acquire',
        'acquire',
        'release',
      ]);
      expect(await pending(), isNull);
    },
  );
  test(
    'cold start retries persisted acquire; learned lease releases before fresh session',
    () async {
      final b = broker();
      final first = client(
        (_) async => FakePeer(b)..drop = (m) => m['type'] == 'acquired',
      );
      await expectLater(acquire(first), throwsStateError);
      await first.dispose();
      final second = client((_) async => FakePeer(b));
      await acquire(second);
      expect(b.requests.map((m) => m['type']), [
        'hello',
        'acquire',
        'acquire',
        'release',
        'hello',
        'acquire',
      ]);
      expect(second.hasLease, isTrue);
      await second.release();
    },
  );
  test(
    'persisted known lease reconnects with release directly, never hello first',
    () async {
      final b = broker();
      final first = client((_) async => FakePeer(b));
      await acquire(first);
      await first.dispose();
      // A known lease needs its owner/macId, not an acquire challenge.
      final stored = (await pending())!;
      stored.remove('challenge');
      stored.remove('originalAcquireRequestId');
      await (await SharedPreferences.getInstance()).setString(
        DeviceCoordination.pendingKey,
        jsonEncode(stored),
      );
      final second = client((_) async => FakePeer(b));
      await acquire(second);
      expect(b.requests[2]['type'], 'release');
      expect(b.requests[2]['macId'], macId);
      expect(b.requests[2]['leaseId'], leaseId);
      await second.release();
    },
  );
  for (final knownLease in [false, true]) {
    test(
      'broker restart quarantines ${knownLease ? 'known' : 'unknown'} lease, no fallback/force recovery',
      () async {
        final b = broker();
        final first = client(
          (_) async =>
              FakePeer(b)..drop = (m) => !knownLease && m['type'] == 'acquired',
        );
        if (knownLease) {
          await acquire(first);
        } else {
          await expectLater(acquire(first), throwsStateError);
        }
        await first.dispose();
        b.recovery = true;
        final before = await pending();
        final second = client((_) async => FakePeer(b));
        await expectLater(
          acquire(second),
          throwsA(
            predicate((e) => e is StateError && e.toString().contains('Mac')),
          ),
        );
        expect(second.hasLease, isFalse);
        expect(await pending(), before);
        expect(b.requests.last['type'], knownLease ? 'release' : 'acquire');
      },
    );
  }
  for (final wrong in [
    'mac',
    'resource',
    'duplicate-resource',
    'lease',
    'request',
    'session',
    'client',
    'stale',
    'future',
  ]) {
    test(
      'wrong $wrong released reply cannot clear durable ownership',
      () async {
        final b = broker();
        final c = client(
          (_) async => FakePeer(b)
            ..mutate = (m) {
              if (m['type'] != 'released') return;
              switch (wrong) {
                case 'mac':
                  m['macId'] = 'd' * 32;
                case 'resource':
                  m['resources'] = ['scale'];
                case 'duplicate-resource':
                  m['resources'] = ['scale', 'scale'];
                case 'lease':
                  m['leaseId'] = 'd' * 32;
                case 'request':
                  m['requestId'] = 'd' * 32;
                case 'session':
                  m['sessionId'] = 'd' * 32;
                case 'client':
                  m['clientId'] = 'd' * 32;
                case 'stale':
                  m['atMs'] = DateTime.now().millisecondsSinceEpoch - 31000;
                case 'future':
                  m['atMs'] = DateTime.now().millisecondsSinceEpoch + 31000;
              }
            },
        );
        await acquire(c);
        final before = await pending();
        await expectLater(c.release(), throwsStateError);
        expect(await pending(), before);
        expect(c.hasLease, isFalse);
      },
    );
  }
  for (final wrong in ['mac', 'resource', 'stale', 'lease']) {
    test(
      'invalid acquired $wrong fails closed and preserves original acquire',
      () async {
        final b = broker();
        final c = client(
          (_) async => FakePeer(b)
            ..mutate = (m) {
              if (m['type'] != 'acquired') return;
              switch (wrong) {
                case 'mac':
                  m['macId'] = 'd' * 32;
                case 'resource':
                  m['resources'] = ['scale'];
                case 'stale':
                  m['atMs'] = DateTime.now().millisecondsSinceEpoch - 31000;
                case 'lease':
                  m['leaseId'] = 'invalid';
              }
            },
        );
        await expectLater(acquire(c), throwsStateError);
        expect(c.hasLease, isFalse);
        expect((await pending())!['leaseId'], '');
      },
    );
  }
  test(
    'invalid observed offer is fail closed, not discovery absence',
    () async {
      final b = broker();
      final c = client(
        (_) async => FakePeer(b)
          ..mutate = (m) {
            m['resources'] = ['scale'];
          },
      );
      await expectLater(acquire(c), throwsStateError);
      expect(c.hasLease, isFalse);
      expect(b.requests.length, 1);
    },
  );
  test(
    'connection lost immediately after offer leaves durable original intent',
    () async {
      final b = broker();
      late FakePeer peer;
      final second = client((_) async {
        peer = FakePeer(b)
          ..afterReply = (m) {
            if (m['type'] == 'offer') unawaited(peer.close());
          };
        return peer;
      });
      await expectLater(acquire(second), throwsStateError);
      expect(await pending(), isNotNull);
      expect(second.hasLease, isFalse);
    },
  );
  for (final code in ['restore_failed', 'recovery_required', 'no_lease']) {
    test('release $code is actionable and leaves pending unchanged', () async {
      final b = broker();
      final c = client((_) async => FakePeer(b));
      await acquire(c);
      final before = await pending();
      b.releaseError = code;
      await expectLater(
        c.release(),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('Mac') &&
                !e.toString().contains('test-key') &&
                !e.toString().contains(baseUrl),
          ),
        ),
      );
      expect(await pending(), before);
      expect(c.hasLease, isFalse);
    });
  }
  test('lost released retries idempotent release without reacquire', () async {
    final b = broker();
    var drop = true;
    final c = client(
      (_) async => FakePeer(b)..drop = (m) => m['type'] == 'released' && drop,
    );
    await acquire(c);
    await expectLater(c.release(), throwsStateError);
    expect(b.active, isNull);
    expect(await pending(), isNotNull);
    drop = false;
    await c.release();
    expect(b.requests.map((m) => m['type']), [
      'hello',
      'acquire',
      'release',
      'release',
    ]);
    expect(await pending(), isNull);
  });
  test(
    'schema 1 missing macId fails closed, remains stored, never dials',
    () async {
      final p = await SharedPreferences.getInstance();
      final old = jsonEncode({
        'schemaVersion': 1,
        'scope': jsonEncode([baseUrl, 'user']),
        'clientId': '1' * 32,
        'sessionId': '2' * 32,
        'leaseId': leaseId,
        'resources': ['scale'],
      });
      await p.setString(DeviceCoordination.pendingKey, old);
      final c = client((_) async => throw StateError('must not dial'));
      await expectLater(acquire(c), throwsStateError);
      await expectLater(c.release(), throwsStateError);
      expect(p.getString(DeviceCoordination.pendingKey), old);
      expect(c.hasLease, isFalse);
    },
  );
  test(
    'different user cannot overwrite another scope pending handoff',
    () async {
      final b = broker();
      final first = client((_) async => FakePeer(b));
      await acquire(first);
      await first.dispose();
      final before = await pending();
      final second = client((_) async => FakePeer(b));
      await expectLater(acquire(second, user: 'other-user'), throwsStateError);
      expect(await pending(), before);
      expect(b.requests.length, 2);
    },
  );
  test(
    'dispose pending acquire cancels waiters/timers without granting or releasing',
    () async {
      final b = broker();
      final seen = Completer<void>();
      final c = client(
        (_) async => FakePeer(b)
          ..drop = (m) {
            if (m['type'] == 'acquired') {
              seen.complete();
              return true;
            }
            return false;
          },
      );
      final operation = acquire(c);
      final failed = expectLater(operation, throwsStateError);
      await seen.future;
      await c.dispose();
      await failed;
      expect(c.hasLease, isFalse);
      expect(await pending(), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(b.requests.map((m) => m['type']), ['hello', 'acquire']);
    },
  );
  test(
    'release cannot race pending acquisition; caller drains before disconnect/release',
    () async {
      final b = broker();
      final seen = Completer<void>();
      final c = client(
        (_) async => FakePeer(b)
          ..drop = (m) {
            if (m['type'] == 'acquired' && !seen.isCompleted) {
              seen.complete();
              return true;
            }
            return false;
          },
      );
      final operation = acquire(c);
      final failed = expectLater(operation, throwsStateError);
      await seen.future;
      await expectLater(c.release(), throwsStateError);
      await failed;
      expect(b.active, isNotNull);
      await c.release();
      expect(await pending(), isNull);
    },
  );

  test(
    'observed Mac failure cannot later silently become standalone',
    () async {
      final b = broker()..active = {};
      var calls = 0;
      final c = client((_) async {
        calls++;
        if (calls > 1) throw StateError('offline');
        return FakePeer(b);
      });
      await expectLater(acquire(c), throwsStateError);
      await expectLater(acquire(c), throwsStateError);
      expect(c.hasLease, isFalse);
    },
  );
  test(
    'dispose hung dial cancels long timeout and closes late transport',
    () async {
      final b = broker();
      final opening = Completer<CoordinationTransport>();
      final started = Completer<void>();
      final c = client((_) {
        started.complete();
        return opening.future;
      }, timeout: const Duration(minutes: 1));
      final operation = acquire(c);
      final failed = expectLater(
        operation.timeout(const Duration(seconds: 1)),
        throwsStateError,
      );
      await started.future;
      await c.dispose();
      await failed;
      final latePeer = FakePeer(b);
      opening.complete(latePeer);
      await Future<void>.delayed(fast);
      expect(latePeer.closed, isTrue);
      expect(latePeer.events.hasListener, isFalse);
      expect(c.hasLease, isFalse);
      expect(await pending(), isNull);
    },
  );
  test(
    'dispose hung acquire send immediately cancels timers and listener',
    () async {
      final b = broker();
      final seen = Completer<void>();
      final blocked = Completer<void>();
      late FakePeer peer;
      final c = client((_) async {
        peer = FakePeer(b)
          ..beforeReply = (m) async {
            if (m['type'] == 'acquired') {
              seen.complete();
              await blocked.future;
            }
          };
        return peer;
      }, timeout: const Duration(minutes: 1));
      final failed = expectLater(
        acquire(c).timeout(const Duration(seconds: 1)),
        throwsStateError,
      );
      await seen.future;
      await c.dispose();
      await failed;
      expect(peer.events.hasListener, isFalse);
      expect(peer.closed, isTrue);
      expect(c.hasLease, isFalse);
      expect(await pending(), isNotNull);
      blocked.complete();
      await Future<void>.delayed(fast);
      expect(b.requests.map((m) => m['type']), ['hello', 'acquire']);
    },
  );

  test('duplicate release calls share one safe release exchange', () async {
    final b = broker();
    final c = client((_) async => FakePeer(b));
    await acquire(c);
    await Future.wait([c.release(), c.release()]);
    expect(b.requests.where((m) => m['type'] == 'release').length, 1);
    expect(await pending(), isNull);
  });

  final pythonPath =
      '${Directory.current.parent.path}/gaggiuino-motto80/coffee_coordination.py';
  test(
    'offline real Python Coordinator: acquired, lost ACK retry, pulse, released retry, restart',
    () async {
      final proc = await Process.start(
        'python3',
        ['-u', '-c', pythonFixture, pythonPath],
        environment: {'PYTHONDONTWRITEBYTECODE': '1'},
      );
      final stderr = proc.stderr.transform(utf8.decoder).join();
      final b = broker();
      final peer = PythonPeer(b, proc);
      final c = client(
        (_) async {
          peer.reopen();
          return peer;
        },
        heartbeat: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 500),
      );
      try {
        // Exclude interpreter/import startup from protocol timeout assertions.
        await peer.command({'ready': true});
        var dropAcquired = true;
        peer.drop = (m) => m['type'] == 'acquired' && dropAcquired;
        await expectLater(acquire(c), throwsStateError);
        expect((await pending())!['leaseId'], '');
        dropAcquired = false;
        await c.release();
        expect(await pending(), isNull);
        await acquire(c);
        expect(c.hasLease, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(b.requests.any((m) => m['type'] == 'pulse'), isTrue);
        peer.drop = (m) => m['type'] == 'released';
        await expectLater(c.release(), throwsStateError);
        expect(await pending(), isNotNull);
        peer.drop = null;
        await c.release();
        expect(await pending(), isNull);
        await acquire(c);
        await peer.command({'restart': true});
        await expectLater(c.release(), throwsStateError);
        expect(await pending(), isNotNull);
        expect(c.hasLease, isFalse);
        expect(
          b.requests
              .where((m) => m['type'] == 'acquire')
              .take(2)
              .map((m) => m['requestId'])
              .toSet()
              .length,
          1,
        );
      } finally {
        await c.dispose();
        await peer.shutdown();
        expect(await stderr, isEmpty);
      }
    },
    skip: !File(pythonPath).existsSync()
        ? 'Sibling Python broker not present; fake contract tests still run'
        : false,
  );
}
