import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'mt80.dart';

enum AppThemePreference { system, light, dark }

extension AppThemePreferenceLabel on AppThemePreference {
  String get label => switch (this) {
    AppThemePreference.system => '跟随系统',
    AppThemePreference.light => '浅色',
    AppThemePreference.dark => '深色',
  };
}

/// brew-guide Supabase 凭证，持久化在本地。
class Settings {
  String brewGuideUrl = const String.fromEnvironment('BREW_GUIDE_URL');
  String supabaseUrl = '';
  String supabaseKey = '';
  String userId = 'default_user';
  List<double> dosePresets = [15.0, 16.0, 18.0];
  List<String> dripperPresets = ['GX2', 'RF']; // 滤杯预设，可增减
  bool mt80Enabled = false;
  List<String> grinderPresets = []; // 磨豆机名称，在设置页管理
  Map<String, List<double>> grinderRanges = {}; // 磨豆机 → [最小刻度, 最大刻度]
  Map<String, double> grinderSteps = {}; // 磨豆机 → 每格步进（1 或 0.1）
  Map<String, double> grinderLastSettings = {}; // 磨豆机 → 上次使用的刻度
  Map<String, List<String>> dripperProcesses = {}; // 滤杯 → 勾选的处理法
  String? lastBeanId; // 上次用的豆子，重开自动选中
  double? lastDose; // 上次豆重
  int? lastTemp; // 上次水温
  String? lastDripper; // 上次滤杯
  String? lastGrinder; // 上次磨豆机
  double? lastGrindSetting; // 上次磨豆机刻度
  AppThemePreference themePreference = AppThemePreference.system;

  List<String> get grinderChoices => {
    ...grinderPresets.where((g) => g != kMt80Grinder),
    if (mt80Enabled) kMt80Grinder,
  }.toList();

  bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;

  double grinderMin(String? grinder) {
    final range = grinder == null ? null : grinderRanges[grinder];
    return range != null && range.length >= 2 ? range.first : 1.0;
  }

  double grinderMax(String? grinder) {
    final range = grinder == null ? null : grinderRanges[grinder];
    return range != null && range.length >= 2 ? range[1] : 120.0;
  }

  double grinderStep(String? grinder) =>
      grinder == null ? 1.0 : (grinderSteps[grinder] ?? 1.0);

  void setGrinderRange(String grinder, double min, double max, {double? step}) {
    grinderRanges[grinder] = [min, max];
    if (step != null) grinderSteps[grinder] = step;
  }

  double normalizeGrindSetting(String? grinder, num value) {
    final min = grinderMin(grinder);
    final max = grinderMax(grinder);
    final step = grinderStep(grinder);
    final clamped = value.toDouble().clamp(min, max);
    final tick = ((clamped - min) / step).round();
    final snapped = (min + tick * step).clamp(min, max);
    final decimals = step < 1 ? 1 : 0;
    return double.parse(snapped.toStringAsFixed(decimals));
  }

  double grindSettingFor(String? grinder) {
    if (grinder == null) return grinderMin(null);
    final stored =
        grinderLastSettings[grinder] ??
        (lastGrinder == grinder ? lastGrindSetting : null);
    return normalizeGrindSetting(grinder, stored ?? grinderMin(grinder));
  }

  void rememberGrindSetting(String grinder, num value) {
    final normalized = normalizeGrindSetting(grinder, value);
    grinderLastSettings[grinder] = normalized;
    lastGrinder = grinder;
    lastGrindSetting = normalized;
  }

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    final s = Settings();
    s.brewGuideUrl =
        p.getString('brewGuideUrl') ??
        const String.fromEnvironment('BREW_GUIDE_URL');
    s.supabaseUrl = p.getString('supabaseUrl') ?? '';
    s.supabaseKey = p.getString('supabaseKey') ?? '';
    s.userId = p.getString('userId') ?? 'default_user';
    await p.remove(
      'mt80PresetSecret',
    ); // Retired pairing code; keep all other settings.
    final presets = p.getStringList('dosePresets');
    if (presets != null && presets.isNotEmpty) {
      final parsed = presets
          .map(double.tryParse)
          .whereType<double>()
          .where((value) => value > 0)
          .toList();
      if (parsed.isNotEmpty) s.dosePresets = parsed;
    }
    final dps = p.getStringList('dripperPresets');
    if (dps != null && dps.isNotEmpty) s.dripperPresets = dps;
    final gps = p.getStringList('grinderPresets');
    if (gps != null) s.grinderPresets = gps;
    final ranges = p.getString('grinderRanges');
    if (ranges != null) {
      try {
        final decoded = jsonDecode(ranges) as Map;
        for (final entry in decoded.entries) {
          final values = entry.value as List;
          if (values.length < 2) continue;
          final min = (values[0] as num).toDouble();
          final max = (values[1] as num).toDouble();
          if (min >= 0 && max > min && max <= 999) {
            s.grinderRanges[entry.key as String] = [min, max];
          }
        }
      } catch (_) {}
    }
    final steps = p.getString('grinderSteps');
    if (steps != null) {
      try {
        final decoded = jsonDecode(steps) as Map;
        for (final entry in decoded.entries) {
          final step = (entry.value as num).toDouble();
          if (step == 1.0 || step == 0.1) {
            s.grinderSteps[entry.key as String] = step;
          }
        }
      } catch (_) {}
    }
    final lastSettings = p.getString('grinderLastSettings');
    if (lastSettings != null) {
      try {
        final decoded = jsonDecode(lastSettings) as Map;
        for (final entry in decoded.entries) {
          final value = (entry.value as num).toDouble();
          s.grinderLastSettings[entry.key as String] = value;
        }
      } catch (_) {}
    }
    final dp = p.getString('dripperProcesses');
    if (dp != null) {
      try {
        s.dripperProcesses = (jsonDecode(dp) as Map).map(
          (k, v) => MapEntry(k as String, (v as List).cast<String>()),
        );
      } catch (_) {}
    } else {
      // 迁移旧格式：处理法 → 滤杯，反转成 滤杯 → [处理法]。
      final old = p.getString('processDripper');
      if (old != null) {
        try {
          (jsonDecode(old) as Map).cast<String, String>().forEach((proc, drip) {
            s.dripperProcesses.putIfAbsent(drip, () => []).add(proc);
          });
        } catch (_) {}
      }
    }
    s.lastBeanId = p.getString('lastBeanId');
    s.lastDose = p.getDouble('lastDose');
    s.lastTemp = p.getInt('lastTemp');
    s.lastDripper = p.getString('lastDripper');
    s.lastGrinder = p.getString('lastGrinder');
    s.mt80Enabled = p.getBool('mt80Enabled') ?? (s.lastGrinder == kMt80Grinder);
    s.lastGrindSetting = p.getDouble('lastGrindSetting');
    final themeName = p.getString('themePreference');
    s.themePreference = AppThemePreference.values.firstWhere(
      (preference) => preference.name == themeName,
      orElse: () => AppThemePreference.system,
    );
    if (s.lastGrinder != null && s.lastGrindSetting != null) {
      s.grinderLastSettings.putIfAbsent(
        s.lastGrinder!,
        () => s.normalizeGrindSetting(s.lastGrinder, s.lastGrindSetting!),
      );
    }
    return s;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('brewGuideUrl', brewGuideUrl);
    await p.setString('supabaseUrl', supabaseUrl);
    await p.setString('supabaseKey', supabaseKey);
    await p.remove('mt80PresetSecret');
    await p.setString('userId', userId);
    await p.setBool('mt80Enabled', mt80Enabled);
    await p.setStringList(
      'dosePresets',
      dosePresets.map((d) => d.toString()).toList(),
    );
    await p.setStringList('dripperPresets', dripperPresets);
    await p.setStringList('grinderPresets', grinderPresets);
    await p.setString('grinderRanges', jsonEncode(grinderRanges));
    await p.setString('grinderSteps', jsonEncode(grinderSteps));
    await p.setString('grinderLastSettings', jsonEncode(grinderLastSettings));
    await p.setString('dripperProcesses', jsonEncode(dripperProcesses));
    await p.setString('themePreference', themePreference.name);
    if (lastBeanId != null) {
      await p.setString('lastBeanId', lastBeanId!);
    } else {
      await p.remove('lastBeanId');
    }
    if (lastDose != null) {
      await p.setDouble('lastDose', lastDose!);
    } else {
      await p.remove('lastDose');
    }
    if (lastTemp != null) {
      await p.setInt('lastTemp', lastTemp!);
    } else {
      await p.remove('lastTemp');
    }
    if (lastDripper != null) {
      await p.setString('lastDripper', lastDripper!);
    } else {
      await p.remove('lastDripper');
    }
    if (lastGrinder != null) {
      await p.setString('lastGrinder', lastGrinder!);
    } else {
      await p.remove('lastGrinder');
    }
    if (lastGrindSetting != null) {
      await p.setDouble('lastGrindSetting', lastGrindSetting!);
    } else {
      await p.remove('lastGrindSetting');
    }
  }
}
