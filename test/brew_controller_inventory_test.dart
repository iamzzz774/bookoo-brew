import 'package:bookoo_brew/bookoo_ble.dart';
import 'package:bookoo_brew/brew_controller.dart';
import 'package:bookoo_brew/brewguide_api.dart';
import 'package:bookoo_brew/models.dart';
import 'package:bookoo_brew/mt80.dart';
import 'package:bookoo_brew/mt80_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBle extends BookooBle {
  @override
  Future<void> stopTimer() async {}
  @override
  Future<void> tareAndStartTimer() async {}
}

class _FakeApi extends BrewGuideApi {
  _FakeApi({this.existing, this.deductError})
    : super(baseUrl: 'https://example.invalid', key: 'key', userId: 'user');

  final Map<String, dynamic>? existing;
  final Object? deductError;
  final List<Map<String, dynamic>> pushedNotes = [];
  int getNoteCalls = 0;
  int deductCalls = 0;

  @override
  Future<Map<String, dynamic>?> getNoteData(String noteId) async {
    getNoteCalls += 1;
    return existing;
  }

  @override
  Future<void> pushNote(Map<String, dynamic> note) async {
    pushedNotes.add(Map<String, dynamic>.from(note));
  }

  @override
  Future<(double, double)> deductBean(Bean bean, double dose) async {
    deductCalls += 1;
    if (deductError != null) throw deductError!;
    return (100.0, 100.0 - dose);
  }
}

Bean _bean() => Bean(
  id: 'bean-1',
  name: '测试豆',
  roastLevel: 'light',
  remaining: 100,
  raw: const {'remaining': '100'},
);

void main() {
  test(
    'automatic snapshot is final-only, has no fake process and no confirmation label',
    () async {
      final api = _FakeApi();
      final controller = BrewController(_FakeBle());
      final record = makeMt80SnapshotRecord(
        bladeGapUm: 600,
        feedingRpm: 25,
        grindRpm: 800,
        capturedAtMs: 1792474987112,
        recordedAtMs: 1792474987113,
      );
      await controller.start(grinder: kMt80Grinder);
      await controller.stopAndSave(
        api,
        _bean(),
        15,
        temp: 94,
        dripper: 'V60',
        grinder: kMt80Grinder,
        grindSetting: 6.5,
        localMt80Record: (_, __) async => record,
      );
      expect(api.deductCalls, 1);
      expect(api.pushedNotes.first['grinderRecord'], isNull);
      final saved = api.pushedNotes.last;
      expect(saved['mt80Request']['status'], 'snapshot');
      expect(saved['grinderRecord']['complete'], isFalse);
      expect(saved['grinderRecord'].containsKey('startedAtMs'), isFalse);
      expect(saved['params']['grindSize'], '600 μm');
      expect(saved['notes'], isNot(contains('用户确认')));
      expect(saved['notes'], contains('研磨度 600 μm；下豆速度 25 rpm；刀盘转速 800 rpm'));
      expect(controller.lastResult, contains('已记录磨豆参数'));
      controller.dispose();
    },
  );
  test(
    'MT80 phone association is final-only and never falls back to Mac or a fake dial value',
    () async {
      final api = _FakeApi();
      final controller = BrewController(_FakeBle());
      await controller.start(grinder: kMt80Grinder);
      await controller.stopAndSave(
        api,
        _bean(),
        15,
        temp: 92,
        dripper: 'V60',
        grinder: 'K-Ultra',
        grindSetting: 6.5,
      );
      expect(api.deductCalls, 1);
      expect(api.pushedNotes, hasLength(2));
      expect(api.pushedNotes.first['mt80Request'], isNull);
      final saved = api.pushedNotes.last;
      expect(saved['bookooDeducted'], isTrue);
      expect((saved['params'] as Map)['grinder'], kMt80Grinder);
      expect((saved['params'] as Map).containsKey('grindSize'), isFalse);
      expect(saved['notes'], isNot(contains('刻度 6.5')));
      expect(
        (saved['mt80Request'] as Map)['brewStartedAtMs'],
        saved['timestamp'],
      );
      expect((saved['mt80Request'] as Map)['status'], 'unavailable');
      expect(controller.lastResult, contains('未记录磨豆参数'));
      expect((saved['mt80Request'] as Map)['collector'], 'phone');
      expect(controller.lastSavedNoteId, saved['id']);
      controller.dispose();
    },
  );

  test(
    'phone complete record is frozen into final note without a Mac request',
    () async {
      final api = _FakeApi();
      final controller = BrewController(_FakeBle());
      await controller.start(grinder: kMt80Grinder);
      final record = <String, dynamic>{
        'schemaVersion': 1,
        'model': 'BOOKOO MOTTO80',
        'source': 'motto80-phone-ble',
        'eventId': 'a' * 32,
        'startedAtMs': 1792453000000,
        'endedAtMs': 1792453010000,
        'durationMs': 10000,
        'bladeGapUm': 640,
        'feedingRpm': 27,
        'grindRpm': 850,
      };
      await controller.stopAndSave(
        api,
        _bean(),
        15,
        temp: 92,
        dripper: 'GX2',
        grinder: kMt80Grinder,
        grindSetting: 6.5,
        localMt80Record: (noteId, at) async {
          expect(controller.capturing, isFalse);
          expect(noteId, startsWith('bookoo-'));
          return record;
        },
      );
      expect(api.pushedNotes.first['grinderRecord'], isNull);
      final saved = api.pushedNotes.last;
      expect(saved['grinderRecord'], record);
      expect(saved['mt80Request']['status'], 'complete');
      expect(controller.lastResult, contains('已关联磨豆参数'));
      expect(saved['mt80Request']['collector'], 'phone');
      expect(saved['params']['grindSize'], '640 μm');
      expect(saved['params']['feedingRpm'], '27 rpm');
      expect(saved['bookooDeducted'], isTrue);
      expect(Mt80Result.fromNote(saved).status, 'complete');
      controller.dispose();
    },
  );

  test('MT80 without a bean never touches inventory', () async {
    final api = _FakeApi();
    final controller = BrewController(_FakeBle());
    await controller.start(grinder: kMt80Grinder);
    await controller.stopAndSave(
      api,
      null,
      15,
      temp: 92,
      dripper: 'V60',
      grinder: kMt80Grinder,
      grindSetting: 120,
    );
    expect(api.deductCalls, 0);
    expect(api.pushedNotes, hasLength(1));
    expect(api.pushedNotes.single['beanId'], isNull);
    expect((api.pushedNotes.single['params'] as Map)['grindSize'], isNull);
    expect(api.pushedNotes.single['mt80Request'], isNotNull);
    controller.dispose();
  });

  test('manual grinder does not opt in to Mac enrichment', () async {
    final api = _FakeApi();
    final controller = BrewController(_FakeBle());
    await controller.start(grinder: 'K-Ultra');
    await controller.stopAndSave(
      api,
      null,
      15,
      temp: 92,
      dripper: 'V60',
      grinder: 'K-Ultra',
      grindSetting: 6.5,
    );
    expect(api.pushedNotes.single['mt80Request'], isNull);
    expect((api.pushedNotes.single['params'] as Map)['grindSize'], '6.5');
    controller.dispose();
  });

  test('不使用咖啡豆时只写笔记，不关联豆子或扣库存', () async {
    final api = _FakeApi();
    final controller = BrewController(_FakeBle());

    await controller.stopAndSave(
      api,
      null,
      15,
      temp: 92,
      dripper: 'V60',
      grinder: 'K-Ultra',
      grindSetting: 6.5,
    );

    expect(api.getNoteCalls, 0);
    expect(api.deductCalls, 0);
    expect(api.pushedNotes, hasLength(1));
    expect(api.pushedNotes.single['beanId'], isNull);
    expect(api.pushedNotes.single['coffeeBeanInfo'], isNull);
    expect(api.pushedNotes.single['bookooDeductionAttempted'], isNull);
    expect((api.pushedNotes.single['params'] as Map)['coffee'], '15 g');
    controller.dispose();
  });

  test('扣库存前先写入至多一次标记，成功后再写完成状态', () async {
    final api = _FakeApi();
    final controller = BrewController(_FakeBle());

    await controller.stopAndSave(
      api,
      _bean(),
      15,
      temp: 92,
      dripper: 'V60',
      grinder: 'K-Ultra',
      grindSetting: 6.5,
    );

    expect(api.deductCalls, 1);
    expect(api.pushedNotes, hasLength(2));
    expect(api.pushedNotes.first['bookooDeductionAttempted'], isTrue);
    expect(api.pushedNotes.first['bookooDeducted'], isNull);
    expect(api.pushedNotes.last['bookooDeducted'], isTrue);
    controller.dispose();
  });

  test('已有尝试标记时不会重复扣库存', () async {
    final api = _FakeApi(existing: const {'bookooDeductionAttempted': true});
    final controller = BrewController(_FakeBle());

    await controller.stopAndSave(
      api,
      _bean(),
      15,
      temp: 92,
      dripper: 'V60',
      grinder: 'K-Ultra',
      grindSetting: 6.5,
    );

    expect(api.deductCalls, 0);
    expect(api.pushedNotes, hasLength(1));
    expect(api.pushedNotes.single['bookooDeductionAttempted'], isTrue);
    controller.dispose();
  });

  test('扣库存失败时保留尝试标记和错误信息', () async {
    final api = _FakeApi(deductError: StateError('network failed'));
    final controller = BrewController(_FakeBle());

    await controller.stopAndSave(
      api,
      _bean(),
      15,
      temp: 92,
      dripper: 'V60',
      grinder: 'K-Ultra',
      grindSetting: 6.5,
    );

    expect(api.deductCalls, 1);
    expect(api.pushedNotes, hasLength(2));
    expect(api.pushedNotes.last['bookooDeductionAttempted'], isTrue);
    expect(api.pushedNotes.last['bookooDeducted'], isNull);
    expect(
      api.pushedNotes.last['bookooDeductionError'],
      contains('network failed'),
    );
    controller.dispose();
  });
}
