import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:bookoo_brew/bookoo_ble.dart';
import 'package:bookoo_brew/brew_controller.dart';
import 'package:bookoo_brew/models.dart';

class _Scale extends BookooBle {
  final frames = StreamController<ScaleReading>.broadcast();
  final commands = <String>[];
  @override
  Stream<ScaleReading> get readings => frames.stream;
  @override
  Future<void> tareAndStartTimer() async {
    commands.add('start');
  }

  @override
  Future<void> stopTimer() async {
    commands.add('stop');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real controller uses strict under-30s boundary, not existing scale timer',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      final scale = _Scale();
      final ctrl = BrewController(scale, now: () => now);
      expect(ctrl.needsEarlyStopConfirmation, isFalse);
      ctrl.scaleElapsed = 999;
      await ctrl.start();
      expect(ctrl.needsEarlyStopConfirmation, isTrue);
      now = now.add(const Duration(milliseconds: 29999));
      expect(ctrl.needsEarlyStopConfirmation, isTrue);
      now = now.add(const Duration(milliseconds: 1));
      expect(ctrl.needsEarlyStopConfirmation, isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(ctrl.needsEarlyStopConfirmation, isFalse);
      ctrl.dispose();
      await scale.frames.close();
      await scale.dispose();
    },
  );
  test(
    'discard clears captured draft, sends only stop, next cup starts clean',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      final scale = _Scale();
      final ctrl = BrewController(scale, now: () => now);
      await ctrl.start(grinder: 'BOOKOO MT80');
      now = now.add(const Duration(seconds: 1));
      scale.frames.add(ScaleReading(1, 20, 1, 80));
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.liveSamples, isNotEmpty);
      await ctrl.discard();
      expect(ctrl.capturing, isFalse);
      expect(ctrl.liveSamples, isEmpty);
      expect(ctrl.lastSavedNoteId, isNull);
      expect(ctrl.needsEarlyStopConfirmation, isFalse);
      expect(scale.commands, ['start', 'stop']);
      expect(ctrl.lastResult, contains('未扣库存'));
      await ctrl.start();
      expect(ctrl.capturing, isTrue);
      expect(ctrl.liveSamples, isEmpty);
      expect(ctrl.lastResult, isNull);
      expect(scale.commands, ['start', 'stop', 'start']);
      ctrl.dispose();
      await scale.frames.close();
      await scale.dispose();
    },
  );
}
