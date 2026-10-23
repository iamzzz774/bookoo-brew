import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'bookoo_ble.dart';
import 'brewguide_api.dart';
import 'models.dart';
import 'mt80.dart';
import 'mt80_snapshot.dart';

const String kEquipment = 'BOOKOO Themis';
const String kMethod = '手冲 / Pour-over';
const double kEndFlowEps = 0.2; // 流速静止阈值
const double kFlowDeadband = 0.2; // 显示流速死区，|flow|<此值显示 0
const double kFlowSpike = 20.0; // |flow| 超此值判为开关阀/碰秤的冲击伪影（真实手冲通常 <~12 g/s）

/// 去掉浮点末尾 .0（与 Python _fmt 一致）。
String fmt(num x) {
  if (x is double && x == x.roundToDouble()) return x.toInt().toString();
  return x.toString();
}

/// 手冲采集控制器：手动开始/结束，收集采样，构建笔记并入库。
class BrewController extends ChangeNotifier {
  final BookooBle ble;
  StreamSubscription? _sub;

  final DateTime Function() _now;

  BrewController(this.ble, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _sub = ble.readings.listen(_onReading);
  }

  // 实时状态
  double weight = 0;
  double flow = 0;
  double scaleElapsed = 0;
  int battery = 0;
  bool capturing = false;
  String? lastResult;
  String? lastSavedNoteId;
  String? _sessionGrinder;

  final List<Sample> _samples = [];
  int _startEpoch = 0;
  late DateTime _startWall;
  double? _timerBase; // 会话开始时秤计时（若在跑）

  /// 实时曲线使用与入库一致的清洗结果，不修改原始采样。
  List<Sample> get liveSamples =>
      _despike(List<Sample>.from(_samples, growable: false));

  void _onReading(ScaleReading r) {
    weight = r.weightG;
    // 显示流速：原始值 + 死区归零，仅避免零点附近 -0.1 抖动（无平滑，样本仍存原始 r.flowGs）
    flow = r.flowGs.abs() < kFlowDeadband ? 0.0 : r.flowGs;
    scaleElapsed = r.elapsedS;
    battery = r.batteryPct;
    if (capturing) {
      double t;
      if (_timerBase != null && r.elapsedS > 0) {
        t = r.elapsedS - _timerBase!;
      } else {
        t = _now().difference(_startWall).inMilliseconds / 1000.0;
      }
      if (t < 0) {
        t = _now().difference(_startWall).inMilliseconds / 1000.0;
      }
      _samples.add(
        Sample(double.parse(t.toStringAsFixed(2)), r.weightG, r.flowGs),
      );
    }
    notifyListeners();
  }

  static const shortBrewThreshold = Duration(seconds: 30);

  /// Use wall-clock age, not the scale's possibly pre-existing timer value.
  bool get needsEarlyStopConfirmation =>
      capturing && _now().difference(_startWall) < shortBrewThreshold;

  /// Discard only the in-memory cup. Never contacts the note/inventory backend.
  Future<void> discard() async {
    await ble.stopTimer();
    capturing = false;
    _samples.clear();
    _timerBase = null;
    _sessionGrinder = null;
    lastSavedNoteId = null;
    lastResult = '本杯已放弃，未保存、未扣库存';
    notifyListeners();
  }

  /// 开始一杯：tare + 启动秤上计时器，开始采集。
  Future<void> start({String? grinder}) async {
    _sessionGrinder = grinder;
    lastSavedNoteId = null;
    _samples.clear();
    _startEpoch = _now().millisecondsSinceEpoch ~/ 1000;
    _startWall = _now();
    await ble.tareAndStartTimer();
    // 给秤一点时间清零再开采（避免把上一杯残留计入）
    await Future.delayed(const Duration(milliseconds: 300));
    _timerBase = scaleElapsed > 0 ? scaleElapsed : null;
    capturing = true;
    lastResult = null;
    notifyListeners();
  }

  /// 结束并入库。bean 为用户已选豆（可为空 → 不挂豆/不扣库存）。
  Future<String> stopAndSave(
    BrewGuideApi api,
    Bean? bean,
    double dose, {
    required int temp,
    required String dripper,
    required String grinder,
    required double grindSetting,
    Future<Map<String, dynamic>?> Function(String noteId, int brewAt)?
    localMt80Record,
  }) async {
    capturing = false;
    await ble.stopTimer();
    // 入库前清洗曲线：去掉手指按阀/碰秤的冲击伪影，并把负重量/负流速归零；
    // 实时显示用的原值不动。
    final cleaned = _despike(List<Sample>.from(_samples));
    final sessionGrinder = _sessionGrinder ?? grinder;
    final note = _buildNote(
      cleaned,
      dose,
      bean,
      temp,
      dripper,
      sessionGrinder,
      grindSetting,
    );

    // 曲线图：和 gaggiuino 脚本一样塞成 PNG data URL（brew-guide 无曲线字段，走 image）。
    final curve = await _curveImageDataUrl(cleaned, _startEpoch);
    if (curve != null) {
      note['image'] = curve;
      note['images'] = [curve];
    }

    // 关联豆 + 至多一次扣库存。先持久化“已尝试”标记，再调用库存接口；
    // 即使扣库存成功后网络中断，重试也不会重复扣减。
    final existing = (bean != null || isMt80(sessionGrinder))
        ? await api.getNoteData(note['id'] as String)
        : null;
    if (bean != null) {
      note['beanId'] = bean.id;
      final info = <String, dynamic>{
        'name': bean.name,
        'roastLevel': bean.roastLevel,
      };
      if (bean.roastDate != null) info['roastDate'] = bean.roastDate;
      if (bean.roaster != null) info['roaster'] = bean.roaster;
      note['coffeeBeanInfo'] = info;

      final alreadyAttempted =
          existing?['bookooDeductionAttempted'] == true ||
          existing?['bookooDeducted'] == true;
      if (alreadyAttempted) {
        note['bookooDeductionAttempted'] = true;
        if (existing?['bookooDeducted'] == true) {
          note['bookooDeducted'] = true;
        }
      } else {
        note['bookooDeductionAttempted'] = true;
        await api.pushNote(note);
        try {
          final (oldG, newG) = await api.deductBean(bean, dose);
          note['bookooDeducted'] = true;
          lastResult = '库存 ${fmt(oldG)}→${fmt(newG)}g';
        } catch (e) {
          note['bookooDeductionError'] = e.toString();
          lastResult = '扣库存失败：$e';
        }
      }
    }

    // Only publish the request on the final note write, after inventory handling.
    // The Mac must never enrich an intermediate deduction-intent record.
    if (isMt80(sessionGrinder)) {
      final preserveExisting =
          existing != null &&
          [
            'complete',
            'snapshot',
          ].contains(Mt80Result.fromNote(existing).status);
      final record = preserveExisting
          ? null
          : await localMt80Record?.call(
              note['id'] as String,
              _startEpoch * 1000,
            );
      note['mt80Request'] = {
        ...mt80Request(_startEpoch * 1000, _now().millisecondsSinceEpoch),
        'collector': 'phone',
        'status': record == null
            ? 'unavailable'
            : record['source'] == kMt80SnapshotSource
            ? 'snapshot'
            : 'complete',
      };
      if (record != null) {
        final verified = Mt80Result.fromNote({
          ...note,
          'grinderRecord': record,
        });
        if (!['complete', 'snapshot'].contains(verified.status)) {
          throw StateError('手机磨豆记录无法校验');
        }
        note['grinderRecord'] = record;
        (note['params'] as Map<String, dynamic>).addAll(<String, dynamic>{
          'grindSize': '${record['bladeGapUm']} μm',
          'feedingRpm': '${record['feedingRpm']} rpm',
          'grindRpm': '${record['grindRpm']} rpm',
        });
        note['notes'] =
            '${note['notes']}\nMOTTO80 磨豆（${verified.status == 'snapshot' ? '参数记录' : '手机采集'}）：研磨度 ${record['bladeGapUm']} μm；下豆速度 ${record['feedingRpm']} rpm；刀盘转速 ${record['grindRpm']} rpm';
      }
      if (preserveExisting) {
        note['grinderRecord'] = existing['grinderRecord'];
        note['mt80Request'] = existing['mt80Request'];
        final params = note['params'] as Map;
        final oldParams = existing['params'] as Map? ?? {};
        for (final field in [
          'grinder',
          'grindSize',
          'feedingRpm',
          'grindRpm',
        ]) {
          if (oldParams.containsKey(field)) params[field] = oldParams[field];
        }
        for (final line in (existing['notes'] as String? ?? '').split('\n')) {
          if (line.startsWith('MOTTO80 磨豆')) {
            note['notes'] = '${note['notes']}\n$line';
          }
        }
      }
    }
    await api.pushNote(note);
    lastSavedNoteId = note['id'] as String;
    final water = (note['params'] as Map)['water'] ?? '?';
    final tt = note['totalTime'];
    final ttStr = tt is int ? _mmss(tt) : '?';
    final summary = isMt80(sessionGrinder)
        ? '已保存 · ${Mt80Result.fromNote(note).saveFeedback}'
        : '已入库 ${note['id']} · 出液 $water · $ttStr';
    final res = '$summary${lastResult != null ? " · $lastResult" : ""}';
    lastResult = res;
    notifyListeners();
    return res;
  }

  Map<String, dynamic> _buildNote(
    List<Sample> samples,
    double dose,
    Bean? bean,
    int temp,
    String dripper,
    String grinder,
    double grindSetting,
  ) {
    final xs = samples.map((s) => s.t).toList();
    final flows = samples.map((s) => s.flow).toList();

    // 出液量以结束时的液重为准；中途按压/碰秤只影响曲线局部，不参与最终出液量。
    final double? yieldG = _yieldFromEnd(samples);
    final int? totalTime = xs.isNotEmpty ? xs.last.round() : null;
    final flowPos = flows.where((f) => f > 0.05).toList();
    final double? avgFlow = flowPos.isNotEmpty
        ? _round1(flowPos.reduce((a, b) => a + b) / flowPos.length)
        : null;
    final double? ratio = (yieldG != null && dose > 0)
        ? _round1(yieldG / dose)
        : null;
    final tsMs = _startEpoch * 1000;

    final params = <String, dynamic>{};
    if (dose > 0) params['coffee'] = '${fmt(dose)} g';
    if (yieldG != null) params['water'] = '${fmt(yieldG)} g';
    if (ratio != null) params['ratio'] = '1:${fmt(ratio)}';
    params['temp'] = '$temp℃';
    final grinderName = grinder.trim();
    if (grinderName.isNotEmpty) {
      params['grinder'] = grinderName;
      if (!isMt80(grinderName)) params['grindSize'] = fmt(grindSetting);
    }

    final lines = <String>['BOOKOO 手冲'];
    final brew = <String>['水温 $temp℃'];
    if (dripper.trim().isNotEmpty) brew.add('滤杯 ${dripper.trim()}');
    lines.add(brew.join(' · '));
    if (grinderName.isNotEmpty && !isMt80(grinderName)) {
      lines.add('磨豆机 $grinderName · 刻度 ${fmt(grindSetting)}');
    }
    if (avgFlow != null) lines.add('平均流速 ${fmt(avgFlow)} g/s');
    final tail = <String>[];
    if (yieldG != null) tail.add('出液 ${fmt(yieldG)} g');
    if (totalTime != null) tail.add(_mmss(totalTime));
    if (ratio != null) tail.add('1:${fmt(ratio)}');
    if (tail.isNotEmpty) lines.add(tail.join(' / '));

    final note = <String, dynamic>{
      'id': 'bookoo-$_startEpoch',
      'timestamp': tsMs,
      'updatedAt': tsMs,
      // Brew Guide 把 source 保留给库存变动记录；第三方来源放独立命名空间，
      // 才会被当作普通冲煮笔记计入常用器具/方案统计。
      'bookoo': <String, dynamic>{
        'source': 'bookoo-app',
        'scale': kEquipment,
        'schemaVersion': 1,
      },
      'equipment': kEquipment,
      'method': kMethod,
      'params': params,
      'rating': 0,
      'taste': <String, dynamic>{},
      'notes': lines.join('\n'),
    };
    if (totalTime != null) note['totalTime'] = totalTime;
    return note;
  }

  /// 仅供测试：暴露去毛刺与出图，方便在无硬件时验证。
  @visibleForTesting
  static List<Sample> despikeForTest(List<Sample> raw) => _despike(raw);
  @visibleForTesting
  static double? yieldForTest(List<Sample> samples) => _yieldFromEnd(samples);
  @visibleForTesting
  static Future<String?> curveForTest(List<Sample> samples, int startEpoch) =>
      _curveImageDataUrl(samples, startEpoch);

  /// 画「重量 / 流速 vs 时间」两块面板 → PNG data URL（移植自 bookoo_to_brewguide.py）。
  /// 样本不足或渲染失败返回 null。
  static Future<String?> _curveImageDataUrl(
    List<Sample> samples,
    int startEpoch,
  ) async {
    if (samples.length < 2) return null;
    final xs = samples.map((s) => s.t).toList();
    final weights = samples.map((s) => s.w).toList();
    final flows = samples.map((s) => s.flow).toList();
    final minX = xs.reduce((a, b) => a < b ? a : b);
    var maxX = xs.reduce((a, b) => a > b ? a : b);
    if (maxX <= minX) maxX = minX + 1;

    const w = 1200.0, h = 620.0, marginL = 80.0, marginR = 40.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, w, h),
      Paint()..color = Colors.white,
    );

    void text(
      String s,
      Offset o,
      double size,
      Color color, {
      bool bold = false,
    }) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            color: color,
            fontSize: size,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o);
    }

    String two(int n) => n.toString().padLeft(2, '0');
    final dt = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000);
    final when =
        '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
    text(
      'BOOKOO Pour-over · $when',
      const Offset(marginL, 22),
      28,
      const Color(0xFF141414),
      bold: true,
    );

    double px(double t) =>
        marginL + (t - minX) / (maxX - minX) * (w - marginR - marginL);

    void drawPanel(
      String label,
      double y0,
      double y1,
      List<double> vals,
      Color color,
    ) {
      const x0 = marginL, x1 = w - marginR;
      text(label, Offset(x0, y0 - 30), 22, const Color(0xFF282828));
      canvas.drawRect(
        Rect.fromLTRB(x0, y0, x1, y1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFFD2D2D2),
      );
      var lo = vals.reduce((a, b) => a < b ? a : b);
      if (lo > 0) lo = 0;
      var hi = vals.reduce((a, b) => a > b ? a : b);
      if (hi <= lo) hi = lo + 1;
      hi += (hi - lo) * 0.08;
      double py(double v) => y1 - (v - lo) / (hi - lo) * (y1 - y0);

      for (var i = 0; i < 5; i++) {
        final yy = y0 + (y1 - y0) * i / 4;
        canvas.drawLine(
          Offset(x0, yy),
          Offset(x1, yy),
          Paint()
            ..color = const Color(0xFFEEEEEE)
            ..strokeWidth = 1,
        );
        text(
          (hi - (hi - lo) * i / 4).toStringAsFixed(1),
          Offset(8, yy - 8),
          16,
          const Color(0xFF646464),
        );
      }
      final startSec = (minX ~/ 10) * 10;
      for (var sec = startSec; sec <= maxX.toInt(); sec += 10) {
        final xx = px(sec.toDouble());
        if (xx >= x0 && xx <= x1) {
          canvas.drawLine(
            Offset(xx, y0),
            Offset(xx, y1),
            Paint()
              ..color = const Color(0xFFF4F4F4)
              ..strokeWidth = 1,
          );
          text('$sec', Offset(xx - 10, y1 + 4), 16, const Color(0xFF787878));
        }
      }
      final path = Path();
      for (var j = 0; j < vals.length && j < xs.length; j++) {
        final p = Offset(px(xs[j]), py(vals[j]));
        if (j == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round,
      );
      text('sec', Offset(x1 - 80, y1 + 4), 16, const Color(0xFF787878));
    }

    drawPanel('Weight g', 110, 350, weights, const Color(0xFF4C9AFF));
    drawPanel('Flow g/s', 400, 560, flows, const Color(0xFFF5A623));

    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    return 'data:image/png;base64,${base64Encode(bytes.buffer.asUint8List())}';
  }

  /// 清洗写入笔记/曲线图的样本：
  /// - 去掉手指按阀/碰秤造成的瞬间冲击伪影；
  /// - 把负重量、负流速归零，避免清零抖动或回流假象写进曲线。
  /// 探测器：秤上报的 |flow| 异常大（>kFlowSpike）即该采样受冲击 —— 这种点的重量
  /// 也是单点毛刺。坏点重量用左右最近的好点线性插值，流速按插值后重量的中心差分重算；
  /// 好点的重量/流速保留秤原值。
  static List<Sample> _despike(List<Sample> raw) {
    final n = raw.length;
    if (n == 0) return raw;
    final bad = n >= 3
        ? [for (final s in raw) s.flow.abs() > kFlowSpike]
        : List<bool>.filled(n, false);

    // 1) 重量：坏点线性插值
    final w = [for (final s in raw) s.w];
    if (bad.contains(true)) {
      for (var i = 0; i < n; i++) {
        if (!bad[i]) continue;
        var l = i - 1;
        while (l >= 0 && bad[l]) {
          l--;
        }
        var r = i + 1;
        while (r < n && bad[r]) {
          r++;
        }
        if (l < 0 && r >= n) continue; // 全是坏点，放弃
        if (l < 0) {
          w[i] = raw[r].w;
        } else if (r >= n) {
          w[i] = raw[l].w;
        } else {
          final span = raw[r].t - raw[l].t;
          final k = span > 0 ? (raw[i].t - raw[l].t) / span : 0.0;
          w[i] = raw[l].w + (raw[r].w - raw[l].w) * k;
        }
      }
    }

    // 2) 流速：坏点用清洗后重量的中心差分重算，好点保留秤原值；
    // 最后负重量/负流速统一归零。
    return [
      for (var i = 0; i < n; i++)
        () {
          var f = raw[i].flow;
          if (bad[i]) {
            final l = i > 0 ? i - 1 : i;
            final r = i < n - 1 ? i + 1 : i;
            final dt = raw[r].t - raw[l].t;
            f = dt > 0 ? (w[r] - w[l]) / dt : 0.0;
          }
          return Sample(
            raw[i].t,
            _roundNonNegative2(w[i]),
            _roundNonNegative2(f),
          );
        }(),
    ];
  }

  static double _round1(double x) => double.parse(x.toStringAsFixed(1));

  static double? _yieldFromEnd(List<Sample> samples) {
    if (samples.isEmpty) return null;
    return _round1(samples.last.w);
  }

  static double _roundNonNegative2(double x) {
    final rounded = double.parse((x < 0 ? 0.0 : x).toStringAsFixed(2));
    return rounded == 0 ? 0.0 : rounded;
  }

  static String _mmss(int s) =>
      '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
