import 'package:bookoo_brew/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'Brew Guide URL is private user configuration, separate from Supabase',
    () async {
      SharedPreferences.setMockInitialValues({});
      final s = await Settings.load();
      expect(s.brewGuideUrl, isEmpty);
      s.brewGuideUrl = 'https://brew.example.test/';
      await s.save();
      final again = await Settings.load();
      expect(again.brewGuideUrl, s.brewGuideUrl);
      expect(again.supabaseUrl, isEmpty);
    },
  );
  test('磨豆机和刻度设置可以持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings()
      ..grinderPresets = ['K-Ultra', 'EK43']
      ..grinderRanges = {
        'K-Ultra': [1.0, 12.0],
        'EK43': [1.0, 16.0],
      }
      ..grinderSteps = {'K-Ultra': 0.1, 'EK43': 1.0}
      ..grinderLastSettings = {'K-Ultra': 6.5, 'EK43': 11.0}
      ..lastDose = 15.0
      ..lastGrinder = 'K-Ultra'
      ..lastGrindSetting = 6.5
      ..themePreference = AppThemePreference.dark;

    await settings.save();
    final loaded = await Settings.load();

    expect(loaded.grinderPresets, ['K-Ultra', 'EK43']);
    expect(loaded.grinderMin('K-Ultra'), 1);
    expect(loaded.grinderMax('K-Ultra'), 12);
    expect(loaded.grinderStep('K-Ultra'), 0.1);
    expect(loaded.grinderMax('EK43'), 16);
    expect(loaded.lastDose, 15.0);
    expect(loaded.lastGrinder, 'K-Ultra');
    expect(loaded.lastGrindSetting, 6.5);
    expect(loaded.themePreference, AppThemePreference.dark);
    expect(loaded.grindSettingFor('K-Ultra'), 6.5);
    expect(loaded.grindSettingFor('EK43'), 11);
    expect(loaded.normalizeGrindSetting('K-Ultra', 6.54), 6.5);
  });

  test('每台磨豆机分别记忆上次刻度', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings()
      ..grinderPresets = ['K-Ultra', 'EK43']
      ..grinderRanges = {
        'K-Ultra': [1.0, 12.0],
        'EK43': [1.0, 16.0],
      }
      ..grinderSteps = {'K-Ultra': 0.1, 'EK43': 1.0};

    settings.rememberGrindSetting('K-Ultra', 6.54);
    settings.rememberGrindSetting('EK43', 11.4);

    expect(settings.grindSettingFor('K-Ultra'), 6.5);
    expect(settings.grindSettingFor('EK43'), 11);
    expect(settings.lastGrinder, 'EK43');
    expect(settings.lastGrindSetting, 11);

    await settings.save();
    final loaded = await Settings.load();
    expect(loaded.grindSettingFor('K-Ultra'), 6.5);
    expect(loaded.grindSettingFor('EK43'), 11);
  });

  test('旧版全局刻度会迁移到对应磨豆机', () async {
    SharedPreferences.setMockInitialValues({
      'grinderPresets': ['K-Ultra'],
      'grinderRanges': '{"K-Ultra":[1.0,12.0]}',
      'grinderSteps': '{"K-Ultra":0.1}',
      'lastGrinder': 'K-Ultra',
      'lastGrindSetting': 6.54,
    });

    final settings = await Settings.load();

    expect(settings.grinderLastSettings['K-Ultra'], 6.5);
    expect(settings.grindSettingFor('K-Ultra'), 6.5);
  });

  test('删除最后一台磨豆机时清除上次选择', () async {
    SharedPreferences.setMockInitialValues({
      'grinderPresets': ['K-Ultra'],
      'lastGrinder': 'K-Ultra',
    });
    final settings = await Settings.load()
      ..grinderPresets = []
      ..lastGrinder = null;

    await settings.save();
    final loaded = await Settings.load();

    expect(loaded.grinderPresets, isEmpty);
    expect(loaded.lastGrinder, isNull);
  });

  test('损坏的豆重预设不会阻止应用启动', () async {
    SharedPreferences.setMockInitialValues({
      'dosePresets': ['15', '坏数据', '-2'],
    });

    final settings = await Settings.load();

    expect(settings.dosePresets, [15]);
  });

  test('可空的上次选择会从持久化设置中清除', () async {
    SharedPreferences.setMockInitialValues({
      'lastBeanId': 'old-bean',
      'lastDose': 16.0,
      'lastTemp': 92,
      'lastDripper': 'old-dripper',
    });
    final settings = await Settings.load()
      ..lastBeanId = null
      ..lastDose = null
      ..lastTemp = null
      ..lastDripper = null;

    await settings.save();
    final loaded = await Settings.load();

    expect(loaded.lastBeanId, isNull);
    expect(loaded.lastDose, isNull);
    expect(loaded.lastTemp, isNull);
    expect(loaded.lastDripper, isNull);
  });
}
