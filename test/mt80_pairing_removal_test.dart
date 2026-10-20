import 'dart:io';
import 'package:bookoo_brew/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('upgrade removes retired pairing preference only', () async {
    SharedPreferences.setMockInitialValues({
      'mt80PresetSecret': 'obsolete-private-value',
      'supabaseUrl': 'https://example.invalid',
      'supabaseKey': 'existing-key',
      'userId': 'existing-user',
      'lastBeanId': 'existing-bean',
      'grinderPresets': ['K-Ultra'],
    });
    final settings = await Settings.load();
    expect(settings.supabaseKey, 'existing-key');
    expect(settings.lastBeanId, 'existing-bean');
    expect(settings.grinderPresets, ['K-Ultra']);
    await settings.save();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('mt80PresetSecret'), isFalse);
    expect(prefs.getString('supabaseUrl'), 'https://example.invalid');
    expect(prefs.getString('supabaseKey'), 'existing-key');
    expect(prefs.getString('userId'), 'existing-user');
  });
  test(
    'record-only App has no recommendation, preset writes or pairing gates',
    () {
      final main = File('lib/main.dart').readAsStringSync();
      final api = File('lib/brewguide_api.dart').readAsStringSync();
      expect(main, isNot(contains('mt80-auth-field')));
      expect(main, isNot(contains('MT80 预设授权码')));
      expect(main, isNot(contains('Mt80PresetControl')));
      expect(main, isNot(contains('Mt80BrewContextSheet')));
      expect(api, isNot(contains('sendMt80Preset')));
      expect(api, isNot(contains('requestMt80Analysis')));
      expect(api, isNot(contains('presetSecret')));
      expect(main, contains('Mt80GrindPanel'));
      expect(api, contains('pendingMt80Note'));
      expect(api, contains('selectMt80Event'));
      expect(File('lib/mt80_preset_control.dart').existsSync(), isFalse);
      expect(File('lib/mt80_recommendation.dart').existsSync(), isFalse);
    },
  );
}
