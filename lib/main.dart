import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'bookoo_ble.dart';
import 'brew_controller.dart';
import 'brewguide_api.dart';
import 'brewguide_webview.dart';
import 'models.dart';
import 'settings.dart';
import 'mt80.dart';
import 'mt80_panel.dart';
import 'mt80_ble.dart';
import 'mt80_phone_store.dart';
import 'mt80_snapshot.dart';

void main() => runApp(const BookooBrewApp());

/// 豆子展示名：有烘焙商时显示「烘焙商 豆名」，否则仅豆名。
String beanLabel(Bean b) => (b.roaster != null && b.roaster!.trim().isNotEmpty)
    ? '${b.roaster!.trim()} ${b.name}'
    : b.name;

const String _noBeanSelectionId = '__no_bean__';

class _BeanPickerResult {
  final Bean? bean;

  const _BeanPickerResult(this.bean);
}

class BookooBrewApp extends StatefulWidget {
  const BookooBrewApp({super.key});

  @override
  State<BookooBrewApp> createState() => _BookooBrewAppState();
}

class _BookooBrewAppState extends State<BookooBrewApp> {
  ThemeMode themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final settings = await Settings.load();
    if (!mounted) return;
    _setThemePreference(settings.themePreference);
  }

  void _setThemePreference(AppThemePreference preference) {
    setState(() {
      themeMode = switch (preference) {
        AppThemePreference.system => ThemeMode.system,
        AppThemePreference.light => ThemeMode.light,
        AppThemePreference.dark => ThemeMode.dark,
      };
    });
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF2B2B2B),
          brightness: brightness,
        ).copyWith(
          surface: dark ? const Color(0xFF121212) : Colors.white,
          onSurface: dark ? const Color(0xFFF2F2F2) : const Color(0xFF222222),
          surfaceContainer: dark ? const Color(0xFF1B1B1B) : Colors.white,
          surfaceContainerHighest: dark
              ? const Color(0xFF2A2A2A)
              : const Color(0xFFF2F2F2),
          primary: dark ? const Color(0xFFF0F0F0) : const Color(0xFF2B2B2B),
          onPrimary: dark ? const Color(0xFF202020) : Colors.white,
          secondaryContainer: dark
              ? const Color(0xFF383838)
              : const Color(0xFFEDEDED),
          onSecondaryContainer: dark
              ? const Color(0xFFF2F2F2)
              : const Color(0xFF2B2B2B),
          outline: dark ? const Color(0xFF666666) : const Color(0xFFB8B8B8),
          outlineVariant: dark
              ? const Color(0xFF2A2A2A)
              : const Color(0xFFECECEC),
        );
    final borderSide = BorderSide(color: scheme.outlineVariant);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surface,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        surfaceTintColor: scheme.surfaceContainer,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: borderSide,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: borderSide,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: borderSide,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: borderSide,
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: borderSide,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outline),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: scheme.surfaceContainer,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BOOKOO Brew',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: themeMode,
      home: HomeScreen(onThemePreferenceChanged: _setThemePreference),
    );
  }
}

/// 降低刻度尺的拖动响应和甩动惯性，让微调更稳定。
class DampedScaleScrollPhysics extends ClampingScrollPhysics {
  final double dragFactor;
  final double flingFactor;

  const DampedScaleScrollPhysics({
    super.parent,
    this.dragFactor = 0.62,
    this.flingFactor = 0.35,
  });

  @override
  DampedScaleScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      DampedScaleScrollPhysics(
        parent: buildParent(ancestor),
        dragFactor: dragFactor,
        flingFactor: flingFactor,
      );

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      super.applyPhysicsToUserOffset(position, offset * dragFactor);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => super.createBallisticSimulation(position, velocity * flingFactor);
}

String _grindValueText(num value, double step) =>
    step < 1 ? value.toStringAsFixed(1) : value.round().toString();

/// 固定中线的横向刻度尺；左右滑动，松手吸附到每个磨豆机的实际档位。
class GrindScalePicker extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final double step;
  final bool enabled;
  final bool enableHaptics;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback? onTap;

  const GrindScalePicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.onTap,
    this.min = 1.0,
    this.max = 120.0,
    this.step = 1.0,
    this.enabled = true,
    this.enableHaptics = true,
  }) : assert(max > min),
       assert(step > 0);

  @override
  State<GrindScalePicker> createState() => _GrindScalePickerState();
}

class _GrindScalePickerState extends State<GrindScalePicker> {
  static const double _itemExtent = 16;
  late final ScrollController _controller;
  late int _tick;
  bool _snapping = false;
  int _snapToken = 0;

  int get _maxTick => ((widget.max - widget.min) / widget.step).round();

  int _clampTick(int tick) => tick.clamp(0, _maxTick);

  int _tickForValue(double value) =>
      _clampTick(((value - widget.min) / widget.step).round());

  double _valueForTick(int tick) {
    final value = widget.min + _clampTick(tick) * widget.step;
    return double.parse(value.toStringAsFixed(widget.step < 1 ? 1 : 0));
  }

  String _tickText(int tick) =>
      _grindValueText(_valueForTick(tick), widget.step);

  bool _isValueMultiple(int tick, int stepCount) {
    final unit = widget.step * stepCount;
    final ratio = _valueForTick(tick) / unit;
    return (ratio - ratio.round()).abs() < 0.0001;
  }

  void _haptic() {
    if (widget.enableHaptics) HapticFeedback.selectionClick();
  }

  @override
  void initState() {
    super.initState();
    _tick = _tickForValue(widget.value);
    _controller = ScrollController(
      initialScrollOffset: (_maxTick - _tick) * _itemExtent,
    )..addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant GrindScalePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _tickForValue(widget.value);
    final rangeChanged =
        oldWidget.min != widget.min ||
        oldWidget.max != widget.max ||
        oldWidget.step != widget.step;
    if (next == _tick && !rangeChanged) return;
    _tick = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpTo((_maxTick - _tick) * _itemExtent);
    });
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_controller.hasClients) return;
    final next = _clampTick(
      _maxTick - (_controller.offset / _itemExtent).round(),
    );
    if (next == _tick) return;
    setState(() => _tick = next);
    _haptic();
    widget.onChanged(_valueForTick(next));
  }

  Future<void> _snapToTick(int tick, {bool notifyEnd = true}) async {
    if (!_controller.hasClients) return;
    final next = _clampTick(tick);
    final target = (_maxTick - next) * _itemExtent;
    final token = ++_snapToken;
    _snapping = true;
    try {
      await _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {
      if (token == _snapToken) _snapping = false;
      return;
    }
    if (!mounted || token != _snapToken || !_controller.hasClients) {
      if (token == _snapToken) _snapping = false;
      return;
    }
    _controller.jumpTo(target); // 消除子像素误差，保证指针落在刻度上
    _snapping = false;
    if (notifyEnd) widget.onChangeEnd(_valueForTick(next));
  }

  void _adjust(int delta) {
    if (!widget.enabled) return;
    final next = _clampTick(_tick + delta);
    if (next == _tick) return;
    setState(() => _tick = next);
    _haptic();
    widget.onChanged(_valueForTick(next));
    _snapToTick(next);
  }

  @override
  Widget build(BuildContext context) {
    final currentText = _tickText(_tick);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '研磨刻度',
      value: currentText,
      enabled: widget.enabled,
      increasedValue: widget.enabled && _tick < _maxTick
          ? _tickText(_tick + 1)
          : null,
      decreasedValue: widget.enabled && _tick > 0 ? _tickText(_tick - 1) : null,
      onIncrease: widget.enabled && _tick < _maxTick ? () => _adjust(1) : null,
      onDecrease: widget.enabled && _tick > 0 ? () => _adjust(-1) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: SizedBox(
          height: 56,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final sidePadding = (constraints.maxWidth - _itemExtent) / 2;
              return ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: ColoredBox(
                  color: colors.surfaceContainerHighest,
                  child: Stack(
                    children: [
                      NotificationListener<ScrollEndNotification>(
                        onNotification: (_) {
                          if (!_snapping) _snapToTick(_tick);
                          return false;
                        },
                        child: ListView.builder(
                          key: const ValueKey('grind-scale-scroll'),
                          controller: _controller,
                          scrollDirection: Axis.horizontal,
                          physics: widget.enabled
                              ? const DampedScaleScrollPhysics()
                              : const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.symmetric(
                            horizontal: sidePadding,
                          ),
                          itemExtent: _itemExtent,
                          itemCount: _maxTick + 1,
                          itemBuilder: (context, index) {
                            final tick = _maxTick - index;
                            final major = _isValueMultiple(tick, 10);
                            final medium = _isValueMultiple(tick, 5);
                            final selected = tick == _tick;
                            return Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (medium && !selected)
                                  SizedBox(
                                    height: 11,
                                    child: OverflowBox(
                                      maxWidth: 48,
                                      child: Text(
                                        _tickText(tick),
                                        maxLines: 1,
                                        softWrap: false,
                                        style: TextStyle(
                                          fontSize: 9,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  const SizedBox(height: 11),
                                const SizedBox(height: 3),
                                Container(
                                  width: major ? 2 : 1.5,
                                  height: major
                                      ? 20
                                      : medium
                                      ? 14
                                      : 7,
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? Colors.transparent
                                        : colors.outline,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(height: 9),
                              ],
                            );
                          },
                        ),
                      ),
                      IgnorePointer(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.enabled ? currentText : '—',
                                key: const ValueKey('grind-scale-value'),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: widget.enabled
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Container(
                                width: 2,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: widget.enabled
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant,
                                  borderRadius: BorderRadius.circular(1),
                                ),
                              ),
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: widget.enabled
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class LiveBrewChart extends StatelessWidget {
  final List<Sample> samples;

  const LiveBrewChart({super.key, required this.samples});

  String _elapsedText() {
    final seconds = samples.isEmpty ? 0 : samples.last.t.floor();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                const Text(
                  '实时曲线',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  _elapsedText(),
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 210,
              width: double.infinity,
              child: CustomPaint(
                key: const ValueKey('live-brew-chart'),
                painter: _LiveBrewChartPainter(
                  samples,
                  panelColor: colors.surfaceContainerHighest,
                  gridColor: colors.outlineVariant,
                  textColor: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveBrewChartPainter extends CustomPainter {
  static const weightColor = Color(0xFF3B82F6);
  static const flowColor = Color(0xFFE59B2F);
  final List<Sample> samples;
  final Color panelColor;
  final Color gridColor;
  final Color textColor;

  _LiveBrewChartPainter(
    this.samples, {
    required this.panelColor,
    required this.gridColor,
    required this.textColor,
  });

  void _text(
    Canvas canvas,
    String text,
    Offset offset, {
    double size = 10,
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: color ?? textColor,
          fontWeight: weight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  double _axisMax(double value, double step, double minimum) {
    if (value <= minimum) return minimum;
    return (value / step).ceil() * step;
  }

  void _panel(Canvas canvas, Rect rect, double maxY) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()..color = panelColor,
    );
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = rect.top + rect.height * i / 4;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
      final x = rect.left + rect.width * i / 4;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
    }
    _text(canvas, fmt(maxY), Offset(2, rect.top - 6));
    _text(canvas, '0', Offset(20, rect.bottom - 7));
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = gridColor,
    );
  }

  void _series(
    Canvas canvas,
    Rect rect,
    double timeMax,
    double valueMax,
    double Function(Sample sample) read,
    Color color,
  ) {
    if (samples.isEmpty) return;
    final path = Path();
    var started = false;
    Offset? lastPoint;
    for (final sample in samples) {
      final value = read(sample);
      if (!sample.t.isFinite || !value.isFinite) continue;
      final xRatio = (sample.t / timeMax).clamp(0.0, 1.0).toDouble();
      final yRatio = (value / valueMax).clamp(0.0, 1.0).toDouble();
      final x = rect.left + xRatio * rect.width;
      final y = rect.bottom - yRatio * rect.height;
      final point = Offset(x, y);
      if (started) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        started = true;
      }
      lastPoint = point;
    }
    if (!started) return;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (lastPoint != null) {
      canvas.drawCircle(lastPoint, 3, Paint()..color = color);
    }
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 38.0;
    final right = size.width - 8;
    final weightRect = Rect.fromLTRB(left, 20, right, size.height * 0.55);
    final flowRect = Rect.fromLTRB(
      left,
      size.height * 0.68,
      right,
      size.height - 20,
    );

    var maxTime = 0.0;
    var maxWeight = 0.0;
    var maxFlow = 0.0;
    for (final sample in samples) {
      if (sample.t.isFinite && sample.t > maxTime) maxTime = sample.t;
      if (sample.w.isFinite && sample.w > maxWeight) maxWeight = sample.w;
      if (sample.flow.isFinite && sample.flow > maxFlow) maxFlow = sample.flow;
    }
    final timeMax = _axisMax(maxTime, 30, 30);
    final weightMax = _axisMax(maxWeight, 50, 50);
    final flowMax = _axisMax(maxFlow.clamp(0.0, 20.0).toDouble(), 5, 5);

    _text(
      canvas,
      '重量 g',
      const Offset(left, 0),
      color: weightColor,
      weight: FontWeight.w600,
    );
    _text(
      canvas,
      '流速 g/s',
      Offset(left, flowRect.top - 20),
      color: flowColor,
      weight: FontWeight.w600,
    );
    _panel(canvas, weightRect, weightMax);
    _panel(canvas, flowRect, flowMax);
    _series(
      canvas,
      weightRect,
      timeMax,
      weightMax,
      (sample) => sample.w,
      weightColor,
    );
    _series(
      canvas,
      flowRect,
      timeMax,
      flowMax,
      (sample) => sample.flow,
      flowColor,
    );

    for (var i = 0; i <= 2; i++) {
      final seconds = (timeMax * i / 2).round();
      final x = flowRect.left + flowRect.width * i / 2;
      _text(
        canvas,
        '${seconds}s',
        Offset(x - (i == 0 ? 0 : 8), size.height - 15),
      );
    }
    if (samples.isEmpty) {
      _text(
        canvas,
        '等待秤数据',
        Offset(size.width / 2 - 24, weightRect.center.dy - 6),
        size: 12,
        color: textColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LiveBrewChartPainter oldDelegate) => true;
}

class HomeScreen extends StatefulWidget {
  final ValueChanged<AppThemePreference>? onThemePreferenceChanged;

  // Optional dependencies let lifecycle regressions run without hardware/cloud.
  final BookooBle? scale;
  final Mt80Ble? grinder;
  final BrewController? controller;
  final BrewGuideApi? api;

  const HomeScreen({
    super.key,
    this.onThemePreferenceChanged,
    this.scale,
    this.grinder,
    this.controller,
    this.api,
  });
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _foreground = true, _starting = false;
  bool _deviceSessionRequested = false, _scaleReconnecting = false;
  bool _disconnectIncomplete = false;
  int _deviceEpoch = 0;
  Future<void>? _openingDevices, _closingDevices;
  Future<void> _deviceLane = Future.value();
  late final ble = widget.scale ?? BookooBle();
  late final BrewController ctrl = widget.controller ?? BrewController(ble);
  late final StreamSubscription<bool> connectionSubscription;
  final brewGuideWebKey = GlobalKey<BrewGuideWebPaneState>();
  Settings settings = Settings();
  int selectedSection = 0;
  bool connected = false;
  String status = '未连接';
  String? statusHint; // 次要说明，小字显示

  List<Bean> beans = [];
  Bean? selectedBean;
  bool loadingBeans = false;
  final doseCtrl = TextEditingController(text: '15');
  int waterTemp = 92;
  String? selectedDripper;
  String? selectedGrinder;
  double grindSetting = 5.0;
  Mt80Result mt80 = const Mt80Result();
  bool mt80Loading = false;
  late final Mt80Ble phoneGrinder =
      widget.grinder ?? Mt80Ble(currentBeanId: () => selectedBean?.id);
  Mt80PhoneStore? phoneGrinds;
  StreamSubscription? _phoneGrindEvents;
  String? _phoneStoreError;
  bool _saving = false, _reviewingStop = false;
  int _mt80Generation = 0;
  Timer? _mt80Poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    connectionSubscription = ble.connection.listen((c) {
      if (!mounted) return;
      setState(() {
        connected = c;
        status = c ? '已连接' : '未连接';
        statusHint = c ? (ble.deviceName) : null;
      });
    });
    _phoneGrindEvents = phoneGrinder.events.listen((event) async {
      try {
        final store = phoneGrinds;
        if (store == null) throw StateError('本地磨豆记录尚未就绪');
        await store.add(event, beanId: event['beanId'] as String?);
      } catch (_) {
        if (mounted) {
          setState(() => _phoneStoreError = '磨豆记录未能保存在手机，请保留应用数据后重试');
        }
      }
    });
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      _closeDevices().whenComplete(() async {
        phoneGrinder.dispose();
        await ble.dispose();
      }),
    );
    unawaited(WakelockPlus.disable());
    unawaited(connectionSubscription.cancel());
    _mt80Poll?.cancel();
    _mt80Generation++;
    unawaited(_phoneGrindEvents?.cancel());
    ctrl.dispose();
    doseCtrl.dispose();
    super.dispose();
  }

  /// 启动：加载设置后自动连秤 + 自动拉取豆子库存。
  Future<void> _boot() async {
    final s = await Settings.load();
    try {
      phoneGrinds = await Mt80PhoneStore.load();
    } catch (_) {
      _phoneStoreError = '本地磨豆记录无法读取，请保留应用数据';
    }
    if (!mounted) return;
    setState(() {
      settings = s;
      if (s.dosePresets.isNotEmpty) {
        doseCtrl.text = fmt(s.lastDose ?? s.dosePresets.first);
      }
      waterTemp = s.lastTemp ?? 92;
      selectedDripper =
          s.lastDripper ??
          (s.dripperPresets.isNotEmpty ? s.dripperPresets.first : null);
      selectedGrinder =
          s.lastGrinder != null && s.grinderChoices.contains(s.lastGrinder)
          ? s.lastGrinder
          : (s.grinderPresets.isNotEmpty ? s.grinderPresets.first : null);
      grindSetting = s.grindSettingFor(selectedGrinder);
    });
    if (s.isConfigured) {
      unawaited(_loadBeans());
      // Historical Mac records remain readable; new cups use phone capture.
    }
    if (selectedSection == 1 && _foreground) unawaited(_connect());
  }

  bool get _keepDeviceSession =>
      ctrl.capturing ||
      _saving ||
      _starting ||
      _reviewingStop ||
      _scaleReconnecting;
  bool get _wantDevices => _keepDeviceSession || _deviceSessionRequested;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) return;
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.detached) {
      _deviceSessionRequested = false;
      unawaited(_closeDevices());
      return;
    }
    if (_foreground && selectedSection == 1) _deviceSessionRequested = true;
    // Keep established sessions while the app process is alive, including
    // backgrounding. Do not start new connection attempts in the background.
    if (_foreground && !_keepDeviceSession && _wantDevices) {
      unawaited(_connect());
    }
  }

  Future<void> _closeDevices() {
    _deviceEpoch++;
    final closing = _closingDevices;
    if (closing != null) return closing;
    final opening = _openingDevices;
    final done = _deviceLane.then((_) async {
      _disconnectIncomplete = true;
      try {
        await phoneGrinder.releaseConnection();
        await ble.releaseConnection();
        if (opening != null) {
          try {
            await opening.timeout(const Duration(seconds: 45));
          } on TimeoutException {
            throw StateError("设备连接尚未退出");
          } catch (_) {}
        }
        _disconnectIncomplete = false;
      } catch (_) {
        if (mounted) _snack('蓝牙连接尚未完全释放');
      }
      if (mounted) {
        setState(() {
          connected = false;
          status = _disconnectIncomplete ? '蓝牙连接待释放' : '未连接';
          statusHint = _disconnectIncomplete ? '请等待设备连接退出后重新进入萃取页' : null;
        });
      }
    });
    _deviceLane = done.catchError((_) {});
    return _closingDevices = done.whenComplete(() => _closingDevices = null);
  }

  Future<void> _reconnectScale() async {
    if (_scaleReconnecting || connected || !mounted || !_foreground) return;
    setState(() => _scaleReconnecting = true);
    try {
      final pending = _openingDevices;
      if (pending != null) await pending;
      if (!mounted || !_foreground || connected) return;
      // Reset only our scale client, never the grinder or global scan state.
      await ble.releaseConnection();
      if (mounted && _foreground) await _connect();
    } catch (e) {
      if (mounted) {
        setState(() {
          status = '秤暂不可用';
          statusHint = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _scaleReconnecting = false);
    }
  }

  Future<void> _connect() async {
    if (!mounted || !_foreground) return;
    if (selectedSection == 1) _deviceSessionRequested = true;
    if (!_wantDevices) return;
    final pending = _openingDevices;
    if (pending != null) {
      await pending;
      await _deviceLane;
      if (mounted && _wantDevices && !connected) await _connect();
      return;
    }
    if (_disconnectIncomplete) {
      await _closeDevices();
      if (_disconnectIncomplete || !mounted || !_wantDevices) return;
    }
    return _openingDevices = _openDevices().whenComplete(
      () => _openingDevices = null,
    );
  }

  Future<void> _openDevices() async {
    // Reserve before yielding: a background release invalidates even an open
    // attempt still waiting for the previous native disconnect to drain.
    final epoch = ++_deviceEpoch;
    await _deviceLane;
    if (!mounted || !_foreground || !_wantDevices || epoch != _deviceEpoch) {
      return;
    }
    if (!connected) {
      setState(() {
        status = '连接设备中…';
        statusHint = null;
      });
    }
    try {
      if (!mounted || !_foreground || !_wantDevices || epoch != _deviceEpoch) {
        return;
      }
      final wantedGrinder = settings.mt80Enabled && isMt80(selectedGrinder);
      final grinder = () async {
        await phoneGrinder.setEnabled(wantedGrinder);
        if (wantedGrinder && !phoneGrinder.ready) await phoneGrinder.connect();
      }();
      await Future.wait([
        if (!ble.isConnected) ble.scanAndConnect(),
        grinder,
      ], eagerError: false);
      if (!mounted || !_foreground || !_wantDevices || epoch != _deviceEpoch) {
        return;
      }
    } catch (e) {
      if (!mounted || epoch != _deviceEpoch) return;
      setState(() {
        status = '设备暂不可用';
        statusHint = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      });
    }
  }

  BrewGuideApi? get _api =>
      widget.api ??
      (settings.isConfigured
          ? BrewGuideApi(
              baseUrl: settings.supabaseUrl,
              key: settings.supabaseKey,
              userId: settings.userId,
            )
          : null);

  Future<void> _loadBeans() async {
    final api = _api;
    if (api == null) {
      _snack('先在设置里填 Supabase 凭证');
      return;
    }
    if (!mounted) return;
    setState(() => loadingBeans = true);
    try {
      final list = await api.listFilterBeans();
      if (!mounted) return;
      setState(() {
        beans = list;
        if (list.isNotEmpty &&
            selectedBean == null &&
            settings.lastBeanId != _noBeanSelectionId) {
          selectedBean = list.firstWhere(
            (b) => b.id == settings.lastBeanId,
            orElse: () => list.first,
          );
          _applyDripperForBean(selectedBean);
        }
      });
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => loadingBeans = false);
    }
  }

  void _scheduleMt80Poll() {
    _mt80Poll?.cancel();
    if (mt80.status != 'pending') return;
    var attempts = 0;
    _mt80Poll = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted ||
          !isMt80(selectedGrinder) ||
          ctrl.capturing ||
          mt80.status != 'pending' ||
          ++attempts > 12) {
        timer.cancel();
        return;
      }
      unawaited(_refreshMt80());
    });
  }

  Future<void> _refreshMt80({bool reportErrors = false}) async {
    final id = mt80.noteId;
    final api = _api;
    if (mt80Loading || id == null || api == null || ctrl.capturing) return;
    final generation = _mt80Generation;
    setState(() => mt80Loading = true);
    try {
      final note = await api.getNoteData(id);
      if (!mounted || generation != _mt80Generation) return;
      setState(
        () => mt80 = note == null
            ? Mt80Result(noteId: id, status: 'unavailable')
            : Mt80Result.fromNote(note),
      );
      if (mt80.status != 'pending') _mt80Poll?.cancel();
    } catch (_) {
      if (mounted && generation == _mt80Generation && reportErrors) {
        _snack('暂时无法读取本杯记录，请稍后刷新');
      }
    } finally {
      if (mounted && generation == _mt80Generation) {
        setState(() => mt80Loading = false);
      }
    }
  }

  Future<void> _chooseMt80() async {
    if (mt80Loading || mt80.noteId == null || mt80.candidates.isEmpty) return;
    final noteId = mt80.noteId!;
    final generation = _mt80Generation;
    final candidate = await showModalBottomSheet<Mt80Candidate>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.65,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHeader(context, '选择本杯的磨豆记录'),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in mt80.candidates)
                      ListTile(
                        title: Text(c.label),
                        subtitle: Text(c.detail),
                        onTap: () => Navigator.pop(context, c),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (candidate == null || !mounted || generation != _mt80Generation) return;
    setState(() => mt80Loading = true);
    try {
      final api = _api;
      if (api == null) throw StateError('请先配置数据连接');
      await api.selectMt80Event(noteId, candidate.eventId);
      if (!mounted || generation != _mt80Generation) return;
      setState(() => mt80 = Mt80Result(noteId: noteId, status: 'pending'));
      _scheduleMt80Poll();
    } catch (_) {
      if (mounted && generation == _mt80Generation) _snack('确认未完成，请刷新后重试');
    } finally {
      if (mounted && generation == _mt80Generation) {
        setState(() => mt80Loading = false);
      }
    }
    if (mounted && generation == _mt80Generation) await _refreshMt80();
  }

  Future<Map<String, dynamic>?> _phoneRecord(
    BrewGuideApi api,
    String? beanId,
    String noteId,
    int at,
  ) async {
    final store = phoneGrinds;
    if (store == null || _phoneStoreError != null) return null;
    final scope = jsonEncode([api.baseUrl, api.userId]);
    final direct = await store.reserve(scope, noteId, at, beanId: beanId);
    if (direct != null) return direct;
    if (!phoneGrinder.ready) {
      try {
        await phoneGrinder.connect().timeout(const Duration(seconds: 12));
      } catch (_) {}
    }
    final current = phoneGrinder.sample;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!phoneGrinder.ready ||
        current == null ||
        now < current.atMs ||
        now - current.atMs > 3000) {
      return null;
    }
    final snapshot = makeMt80SnapshotRecord(
      bladeGapUm: current.bladeGap,
      feedingRpm: current.feedingRpm,
      grindRpm: current.grindRpm,
      capturedAtMs: current.atMs,
      recordedAtMs: now,
    );
    return store.saveCurrentSnapshot(
      scope,
      noteId,
      at,
      snapshot,
      beanId: beanId,
    );
  }

  Future<void> _start() async {
    if (_saving ||
        _reviewingStop ||
        _starting ||
        _scaleReconnecting ||
        ctrl.capturing) {
      return;
    }
    _starting = true;
    try {
      if (!connected) await _connect();
      if (!mounted || !connected || !_wantDevices) {
        if (mounted) _snack('设备尚未就绪');
        return;
      }
      _mt80Poll?.cancel();
      _mt80Generation++;
      setState(() {
        mt80 = const Mt80Result();
        mt80Loading = false;
      });
      await ctrl.start(grinder: selectedGrinder);
      await WakelockPlus.enable(); // 萃取中保持屏幕常亮
    } catch (e) {
      if (mounted) _snack('启动萃取失败：$e');
    } finally {
      _starting = false;
      if (mounted && !_wantDevices) unawaited(_closeDevices());
    }
  }

  Future<void> _resolveShortStop(String choice) async {
    if (!_reviewingStop || _saving) return;
    if (choice == 'continue') {
      setState(() => _reviewingStop = false);
      return;
    }
    if (choice == 'save') {
      setState(() => _reviewingStop = false);
      await _stop(shortCupConfirmed: true);
      return;
    }
    if (choice != 'discard') return;
    setState(() => _saving = true);
    try {
      await ctrl.discard();
      await WakelockPlus.disable();
      if (mounted) setState(() => _reviewingStop = false);
    } catch (e) {
      if (mounted) _snack('结束未完成：$e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (!_wantDevices) unawaited(_closeDevices());
      }
    }
  }

  Future<void> _stop({bool shortCupConfirmed = false}) async {
    if (_saving || _reviewingStop || !ctrl.capturing) return;
    if (!shortCupConfirmed && ctrl.needsEarlyStopConfirmation) {
      setState(() => _reviewingStop = true);
      return;
    }
    final api = _api;
    if (api == null) {
      _snack('先在设置里填 Supabase 凭证');
      return;
    }
    final dose =
        double.tryParse(doseCtrl.text) ??
        (settings.dosePresets.isNotEmpty ? settings.dosePresets.first : 15.0);
    final dripper = selectedDripper ?? '';
    final grinder = selectedGrinder ?? '';
    final brewBean = selectedBean;
    unawaited(WakelockPlus.disable()); // 结束萃取，恢复自动熄屏
    setState(() => _saving = true);
    try {
      final res = await ctrl.stopAndSave(
        api,
        brewBean,
        dose,
        temp: waterTemp,
        dripper: dripper,
        grinder: grinder,
        grindSetting: grindSetting,
        localMt80Record: (id, at) => _phoneRecord(api, brewBean?.id, id, at),
      );
      if (!mounted) return;
      settings.lastTemp = waterTemp;
      settings.lastDose = dose;
      settings.lastDripper = dripper;
      if (selectedGrinder != null && !isMt80(selectedGrinder)) {
        settings.rememberGrindSetting(selectedGrinder!, grindSetting);
      }
      await settings.save();
      if (!mounted) return;
      _snack(res);
      // A saved cup ends recording, not the app-owned device session.
      // Keep both live streams across tabs/background for the next cup.
      if (isMt80(selectedGrinder) && ctrl.lastSavedNoteId != null) {
        setState(
          () => mt80 = Mt80Result(noteId: ctrl.lastSavedNoteId, status: 'idle'),
        );
        unawaited(_refreshMt80());
      }
      unawaited(_loadBeans()); // 刷新余量
    } catch (e) {
      if (mounted) _snack('入库失败：$e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (!_wantDevices) unawaited(_closeDevices());
      }
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), duration: const Duration(seconds: 4)),
  );

  Future<void> _handlePop(bool didPop, Object? result) async {
    if (didPop) return;
    if (selectedSection == 2) {
      _selectSection(1);
      return;
    }
    if (selectedSection != 0) return;
    final wentBack =
        await brewGuideWebKey.currentState?.goBackIfPossible() ?? false;
    if (!wentBack && mounted) await SystemNavigator.pop();
  }

  void _reconcileBrewSelections() {
    if (!settings.dripperPresets.contains(selectedDripper)) {
      selectedDripper =
          settings.lastDripper != null &&
              settings.dripperPresets.contains(settings.lastDripper)
          ? settings.lastDripper
          : (settings.dripperPresets.isNotEmpty
                ? settings.dripperPresets.first
                : null);
    }
    if (!settings.grinderChoices.contains(selectedGrinder)) {
      selectedGrinder =
          settings.lastGrinder != null &&
              settings.grinderChoices.contains(settings.lastGrinder)
          ? settings.lastGrinder
          : (settings.grinderPresets.isNotEmpty
                ? settings.grinderPresets.first
                : null);
    }
    grindSetting = settings.grindSettingFor(selectedGrinder);
  }

  void _selectSection(int index) {
    if (index == selectedSection) return;
    setState(() {
      if (selectedSection == 2 && index != 2) _reconcileBrewSelections();
      selectedSection = index;
    });
    if (selectedSection == 1) _deviceSessionRequested = true;
    if (_keepDeviceSession) return;
    if (_wantDevices) {
      // Switching foreground tabs must not tear down a working GATT session.
      unawaited(_connect());
    } else if (!_foreground) {
      unawaited(_closeDevices());
    }
  }

  void _settingsSaved() {
    if (!mounted) return;
    setState(() {
      _reconcileBrewSelections();
      if (settings.mt80Enabled && settings.lastGrinder == kMt80Grinder) {
        selectedGrinder = kMt80Grinder;
      }
    });
    if (selectedSection == 1) _deviceSessionRequested = true;
    if (_keepDeviceSession) return;
    if (_wantDevices) {
      // Switching foreground tabs must not tear down a working GATT session.
      unawaited(_connect());
    } else if (!_foreground) {
      unawaited(_closeDevices());
    }
  }

  Widget _compactNativeTypography(Widget child) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(fontSizeFactor: .92),
        primaryTextTheme: theme.primaryTextTheme.apply(fontSizeFactor: .92),
      ),
      child: child,
    );
  }

  List<String> get _beanProcesses =>
      beans.map((bean) => bean.process).whereType<String>().toSet().toList()
        ..sort();

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: selectedSection == 1,
      onPopInvokedWithResult: _handlePop,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: selectedSection,
            children: [
              BrewGuideWebPane(
                key: brewGuideWebKey,
                url: settings.brewGuideUrl,
              ),
              _compactNativeTypography(_brewPane()),
              _compactNativeTypography(
                SettingsScreen(
                  key: ValueKey(settings),
                  settings: settings,
                  processes: _beanProcesses,
                  onThemePreferenceChanged: widget.onThemePreferenceChanged,
                  onSaved: _settingsSaved,
                  embedded: true,
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          height: 60,
          selectedIndex: selectedSection,
          onDestinationSelected: _selectSection,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.inventory_2_outlined),
              selectedIcon: Icon(Icons.inventory_2),
              label: '豆仓',
            ),
            NavigationDestination(
              icon: Icon(Icons.local_cafe_outlined),
              selectedIcon: Icon(Icons.local_cafe),
              label: '萃取',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }

  Widget _brewPane() => LayoutBuilder(
    builder: (context, constraints) {
      // 其余参数卡和操作区约占 389px；顶部标题栏移除后，新增空间
      // 由 LayoutBuilder 自动分配给秤数据区。
      final scaleHeight = (constraints.maxHeight - 389)
          .clamp(190.0, 400.0)
          .toDouble();
      return ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          children: [
            _scaleCard(height: scaleHeight),
            const SizedBox(height: 4),
            ctrl.capturing
                ? LiveBrewChart(samples: ctrl.liveSamples)
                : _beanCard(),
            const SizedBox(height: 4),
            _controlButtons(),
            if (ctrl.lastResult != null) ...[
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    ctrl.lastResult!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );

  /// 秤卡片：顶部连接状态行 + 实时读数（合并）。
  Widget _scaleCard({required double height}) {
    final sub = connected ? '电量 ${ctrl.battery}%' : statusHint;
    return SizedBox(
      height: height,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            children: [
              InkWell(
                key: const ValueKey('scale-connection-header'),
                onTap: connected || _scaleReconnecting ? null : _reconnectScale,
                onLongPress: connected ? () => ble.disconnect() : null,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        connected ? Icons.bluetooth_connected : Icons.bluetooth,
                        size: 20,
                        color: connected
                            ? Theme.of(context).colorScheme.onSurface
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${ble.deviceName ?? 'BOOKOO 秤'} · $status',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (sub != null && sub.isNotEmpty)
                              Text(
                                sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Semantics(
                    label: '当前重量 ${ctrl.weight.toStringAsFixed(1)} 克',
                    child: Text(
                      '${ctrl.weight.toStringAsFixed(1)} g',
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -1,
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _stat('粉水比', _ratioText()),
                  _stat('流速', _flowText()),
                  _stat('时间', _timeText(ctrl.scaleElapsed)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _beanCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _pickBean,
            borderRadius: BorderRadius.circular(6),
            child: _controlFrame(
              label: '咖啡豆',
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      selectedBean != null
                          ? '${beanLabel(selectedBean!)}（余 ${fmt(selectedBean!.remaining)}g）'
                          : settings.lastBeanId == _noBeanSelectionId
                          ? '不使用咖啡豆'
                          : beans.isEmpty
                          ? '暂无咖啡豆'
                          : '选择咖啡豆',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selectedBean == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : null,
                      ),
                    ),
                  ),
                  if (loadingBeans)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      Icons.unfold_more,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          _parameterGrid(),
          const SizedBox(height: 4),
          if (isMt80(selectedGrinder)) ...[
            AnimatedBuilder(
              animation: phoneGrinder,
              builder: (_, __) => Mt80GrindPanel(
                result: mt80,
                loading: mt80Loading,
                connected: phoneGrinder.ready && _phoneStoreError == null,
                connectionStatus: _phoneStoreError ?? phoneGrinder.status,
                currentParameters:
                    !phoneGrinder.ready || phoneGrinder.sample == null
                    ? null
                    : '研磨度 ${phoneGrinder.sample!.bladeGap} μm · 下豆速度 ${phoneGrinder.sample!.feedingRpm} rpm · 刀盘转速 ${phoneGrinder.sample!.grindRpm} rpm',
                onChoose: mt80.candidates.isEmpty ? null : _chooseMt80,
              ),
            ),
          ] else ...[
            Text(
              '研磨刻度',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 2),
            GrindScalePicker(
              value: grindSetting,
              min: settings.grinderMin(selectedGrinder),
              max: settings.grinderMax(selectedGrinder),
              step: settings.grinderStep(selectedGrinder),
              enabled: selectedGrinder != null,
              onTap: _showGrindQuickPicker,
              onChanged: (value) => setState(() => grindSetting = value),
              onChangeEnd: _saveGrindSetting,
            ),
          ],
        ],
      ),
    ),
  );

  Widget _parameterGrid() {
    final dose = double.tryParse(doseCtrl.text);
    const gap = 4.0;
    return Column(
      children: [
        SizedBox(
          height: 56,
          child: Row(
            children: [
              Expanded(child: _doseField(dose)),
              const SizedBox(width: gap),
              Expanded(child: _temperatureField()),
            ],
          ),
        ),
        const SizedBox(height: gap),
        SizedBox(
          height: 56,
          child: Row(
            children: [
              Expanded(
                child: _compactSelector<String>(
                  label: '磨豆机',
                  value: settings.grinderChoices.contains(selectedGrinder)
                      ? selectedGrinder
                      : null,
                  options: settings.grinderChoices,
                  itemText: (value) => value,
                  onChanged: _selectGrinder,
                ),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: _compactSelector<String>(
                  label: '滤杯',
                  value: settings.dripperPresets.contains(selectedDripper)
                      ? selectedDripper
                      : null,
                  options: settings.dripperPresets,
                  itemText: (value) => value,
                  onChanged: _selectDripper,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _controlFrame({
    required String label,
    required Widget child,
    bool enabled = true,
    EdgeInsets contentPadding = const EdgeInsets.fromLTRB(12, 5, 12, 0),
  }) {
    final colors = Theme.of(context).colorScheme;
    final color = enabled ? colors.onSurfaceVariant : colors.outline;
    return SizedBox(
      height: 56,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            top: 6,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(padding: contentPadding, child: child),
            ),
          ),
          Positioned(
            left: 10,
            top: 0,
            child: ColoredBox(
              color: colors.surfaceContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12, color: color, height: 1),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactSelector<T>({
    required String label,
    required T? value,
    required List<T> options,
    required String Function(T value) itemText,
    required ValueChanged<T> onChanged,
    String emptyText = '未设置',
  }) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: options.isEmpty
          ? null
          : () => _showOptionSheet<T>(
              title: '选择$label',
              options: options,
              selected: value,
              itemText: itemText,
              onSelected: onChanged,
            ),
      child: _controlFrame(
        label: label,
        enabled: options.isNotEmpty,
        child: Row(
          children: [
            Expanded(
              child: Text(
                value == null ? emptyText : itemText(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: value == null ? colors.onSurfaceVariant : null,
                ),
              ),
            ),
            Icon(
              Icons.expand_more,
              size: 20,
              color: options.isEmpty ? colors.outline : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showOptionSheet<T>({
    required String title,
    required List<T> options,
    required T? selected,
    required String Function(T value) itemText,
    required ValueChanged<T> onSelected,
  }) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.62,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHeader(sheetContext, title),
              const Divider(height: 1),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  itemCount: options.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, index) {
                    final option = options[index];
                    final isSelected = option == selected;
                    return Semantics(
                      selected: isSelected,
                      child: ListTile(
                        minTileHeight: 52,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        tileColor: isSelected
                            ? Theme.of(
                                sheetContext,
                              ).colorScheme.secondaryContainer
                            : Colors.transparent,
                        title: Text(
                          itemText(option),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check_circle, size: 21)
                            : const SizedBox(width: 21),
                        onTap: () => Navigator.pop(sheetContext, option),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onSelected(picked);
  }

  Future<void> _showGrindQuickPicker() async {
    if (selectedGrinder == null) return;
    final min = settings.grinderMin(selectedGrinder);
    final max = settings.grinderMax(selectedGrinder);
    final step = settings.grinderStep(selectedGrinder);
    final span = step * 10;
    double clean(double value) =>
        double.parse(value.toStringAsFixed(step < 1 ? 1 : 0));
    final optionSet = <double>{clean(min), clean(max)};
    for (
      var value = (max / span).floor() * span;
      value >= min - 0.0001;
      value -= span
    ) {
      if (value <= max + 0.0001) optionSet.add(clean(value));
    }
    final options = optionSet.toList()..sort((a, b) => b.compareTo(a));
    final selected = settings.normalizeGrindSetting(
      selectedGrinder,
      grindSetting,
    );
    final picked = await showModalBottomSheet<double>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sheetHeader(sheetContext, '快速选择刻度'),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          selectedGrinder!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        '范围 ${_grindValueText(min, step)}–${_grindValueText(max, step)} · 当前 ${_grindValueText(selected, step)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final value in options)
                        ChoiceChip(
                          label: SizedBox(
                            width: 48,
                            child: Center(
                              child: Text(_grindValueText(value, step)),
                            ),
                          ),
                          selected: value == selected,
                          showCheckmark: false,
                          side: BorderSide.none,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          selectedColor: Theme.of(context).colorScheme.primary,
                          labelStyle: TextStyle(
                            color: value == selected
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context).colorScheme.onSurface,
                            fontWeight: value == selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          onSelected: (_) => Navigator.pop(sheetContext, value),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() => grindSetting = picked);
    await _saveGrindSetting(picked);
  }

  Widget _sheetHeader(
    BuildContext sheetContext,
    String title, {
    Widget? action,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 2, 12, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        if (action != null) action,
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(sheetContext),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );

  Widget _stepperField({
    required String label,
    required String value,
    required String decreaseTooltip,
    required String increaseTooltip,
    required VoidCallback? onDecrease,
    required VoidCallback? onIncrease,
    VoidCallback? onValueTap,
    String? valueTooltip,
  }) {
    Widget valueControl = Center(
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.fade,
        softWrap: false,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
    if (onValueTap != null) {
      valueControl = Tooltip(
        message: valueTooltip ?? label,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onValueTap,
          child: valueControl,
        ),
      );
    }
    return _controlFrame(
      label: label,
      contentPadding: const EdgeInsets.fromLTRB(2, 5, 2, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: decreaseTooltip,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            icon: const Icon(Icons.remove, size: 20),
            onPressed: onDecrease,
          ),
          Expanded(child: SizedBox(height: 44, child: valueControl)),
          IconButton(
            tooltip: increaseTooltip,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            icon: const Icon(Icons.add, size: 20),
            onPressed: onIncrease,
          ),
        ],
      ),
    );
  }

  Widget _doseField(double? dose) => _stepperField(
    label: '豆重',
    value: dose == null ? '—' : '${fmt(dose)}g',
    decreaseTooltip: '减少豆重',
    increaseTooltip: '增加豆重',
    onDecrease: dose == null || dose <= 1 ? null : () => _setDose(dose - 1),
    onIncrease: () => _setDose((dose ?? 0) + 1),
    valueTooltip: '快捷切换豆重',
    onValueTap: settings.dosePresets.isEmpty
        ? null
        : () => _showOptionSheet<double>(
            title: '选择豆重',
            options: settings.dosePresets,
            selected: settings.dosePresets.contains(dose) ? dose : null,
            itemText: (value) => '${fmt(value)} g',
            onSelected: _setDose,
          ),
  );

  Future<void> _setDose(double value) async {
    final dose = double.parse(value.clamp(1.0, 200.0).toStringAsFixed(1));
    setState(() => doseCtrl.text = fmt(dose));
    settings.lastDose = dose;
    await settings.save();
  }

  Widget _temperatureField() => _stepperField(
    label: '水温',
    value: '$waterTemp℃',
    decreaseTooltip: '降低水温',
    increaseTooltip: '提高水温',
    onDecrease: () => _setTemp(waterTemp - 1),
    onIncrease: () => _setTemp(waterTemp + 1),
  );

  void _setTemp(int v) => setState(() => waterTemp = v.clamp(1, 100));

  Future<void> _selectDripper(String dripper) async {
    setState(() => selectedDripper = dripper);
    settings.lastDripper = dripper;
    await settings.save();
  }

  Future<void> _selectGrinder(String grinder) async {
    if (ctrl.capturing || _saving) return;
    _mt80Poll?.cancel();
    _mt80Generation++;
    if (selectedGrinder != null && !isMt80(selectedGrinder)) {
      settings.rememberGrindSetting(selectedGrinder!, grindSetting);
    }
    setState(() {
      selectedGrinder = grinder;
      grindSetting = settings.grindSettingFor(grinder);
      mt80 = const Mt80Result();
      mt80Loading = false;
    });
    if (isMt80(grinder)) {
      settings.lastGrinder = grinder;
      settings.lastGrindSetting = null;
    } else {
      settings.rememberGrindSetting(grinder, grindSetting);
    }
    await settings.save();
    if (mounted && !_keepDeviceSession && _wantDevices) {
      // Reconcile only the selected grinder; never disconnect the scale here.
      await _connect();
    }
  }

  Future<void> _saveGrindSetting(double value) async {
    if (selectedGrinder == null) return;
    final setting = settings.normalizeGrindSetting(selectedGrinder, value);
    settings.rememberGrindSetting(selectedGrinder!, setting);
    await settings.save();
  }

  /// 可搜索的咖啡豆选择器（底部弹窗）。
  Future<void> _pickBean() async {
    final picked = await showModalBottomSheet<_BeanPickerResult>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) {
        var query = '';
        var refreshing = false;
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final q = query.trim().toLowerCase();
            final list = q.isEmpty
                ? beans
                : beans
                      .where((b) => beanLabel(b).toLowerCase().contains(q))
                      .toList();
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.72,
                child: Column(
                  children: [
                    _sheetHeader(
                      ctx,
                      '选择咖啡豆',
                      action: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: const ValueKey('no-bean-button'),
                            tooltip: '不使用咖啡豆',
                            onPressed: () => Navigator.pop(
                              ctx,
                              const _BeanPickerResult(null),
                            ),
                            icon: const Icon(Icons.no_drinks_outlined),
                          ),
                          IconButton(
                            tooltip: '刷新咖啡豆',
                            onPressed: refreshing
                                ? null
                                : () async {
                                    setSheet(() => refreshing = true);
                                    await _loadBeans();
                                    if (!ctx.mounted) return;
                                    setSheet(() => refreshing = false);
                                  },
                            icon: refreshing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: TextField(
                        autofocus: false,
                        decoration: const InputDecoration(
                          hintText: '搜索咖啡豆…',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onChanged: (v) => setSheet(() => query = v),
                      ),
                    ),
                    Expanded(
                      child: list.isEmpty
                          ? Center(
                              child: Text(
                                q.isEmpty ? '暂无咖啡豆' : '无匹配',
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                              itemCount: list.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 4),
                              itemBuilder: (_, i) {
                                final b = list[i];
                                final sel = b.id == selectedBean?.id;
                                return Semantics(
                                  selected: sel,
                                  child: ListTile(
                                    minTileHeight: 56,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    tileColor: sel
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.secondaryContainer
                                        : Colors.transparent,
                                    title: Text(
                                      beanLabel(b),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      '余 ${fmt(b.remaining)} g',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    trailing: sel
                                        ? const Icon(
                                            Icons.check_circle,
                                            size: 21,
                                          )
                                        : const SizedBox(width: 21),
                                    onTap: () => Navigator.pop(
                                      ctx,
                                      _BeanPickerResult(b),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (picked != null) {
      final bean = picked.bean;
      setState(() {
        selectedBean = bean;
        if (bean != null) _applyDripperForBean(bean);
      });
      settings.lastBeanId = bean?.id ?? _noBeanSelectionId;
      await settings.save();
    }
  }

  /// 按豆子的处理法偏好自动勾选滤杯（调用方负责 setState）。
  void _applyDripperForBean(Bean? b) {
    final proc = b?.process;
    if (proc == null) return;
    // 取第一个勾选了该处理法的滤杯（按预设顺序）。
    for (final d in settings.dripperPresets) {
      if (settings.dripperProcesses[d]?.contains(proc) ?? false) {
        selectedDripper = d;
        settings.lastDripper = d;
        return;
      }
    }
  }

  String _flowText() {
    if (ctrl.flow.abs() > 99) return '—'; // 超 99 多为噪声尖峰，不显示
    return '${ctrl.flow.toStringAsFixed(1)} g/s';
  }

  String _timeText(double seconds) {
    final s = seconds.floor();
    final m = s ~/ 60;
    return '$m:${(s % 60).toString().padLeft(2, '0')}';
  }

  String _ratioText() {
    final dose = double.tryParse(doseCtrl.text) ?? 0;
    if (dose <= 0 || ctrl.weight <= 0) return '—';
    return '1:${(ctrl.weight / dose).toStringAsFixed(1)}';
  }

  Widget _stat(String label, String value) => Column(
    children: [
      Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ],
  );

  Widget _controlButtons() => Column(
    children: [
      SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: connected ? () => ble.tare() : null,
                child: const Text('去皮'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton(
                onPressed: connected ? () => ble.resetTimer() : null,
                child: const Text('重置时间'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton(
                onPressed: connected ? _setDoseFromScale : null,
                child: const Text('设置豆重'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 44,
        width: double.infinity,
        child: _reviewingStop
            ? Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _saving
                          ? null
                          : () => _resolveShortStop('continue'),
                      child: const Text('继续'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _saving
                          ? null
                          : () => _resolveShortStop('discard'),
                      child: const Text('放弃'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => _resolveShortStop('save'),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              )
            : ctrl.capturing
            ? FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: _stop,
                icon: const Icon(Icons.stop),
                label: const Text('结束并入库'),
              )
            : FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始'),
              ),
      ),
    ],
  );

  /// 把秤上当前重量设为豆重（直接称豆）。
  void _setDoseFromScale() {
    final w = ctrl.weight.abs();
    if (w <= 0) {
      _snack('秤上没有读数');
      return;
    }
    _setDose(double.parse(w.toStringAsFixed(1)));
  }
}

class _GrinderRangeSheet extends StatefulWidget {
  final String grinder;
  final double min;
  final double max;
  final double step;

  const _GrinderRangeSheet({
    required this.grinder,
    required this.min,
    required this.max,
    required this.step,
  });

  @override
  State<_GrinderRangeSheet> createState() => _GrinderRangeSheetState();
}

class _GrinderRangeSheetState extends State<_GrinderRangeSheet> {
  late final minCtrl = TextEditingController(
    text: _grindValueText(widget.min, widget.step),
  );
  late final maxCtrl = TextEditingController(
    text: _grindValueText(widget.max, widget.step),
  );
  late double step = widget.step;
  String? error;

  @override
  void dispose() {
    minCtrl.dispose();
    maxCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final min = double.tryParse(minCtrl.text.trim());
    final max = double.tryParse(maxCtrl.text.trim());
    if (min == null || max == null || min < 0 || max > 999) {
      setState(() => error = '请输入 0–999 的刻度');
      return;
    }
    if (max <= min) {
      setState(() => error = '最大刻度必须大于最小刻度');
      return;
    }
    if (step == 1 &&
        (min != min.roundToDouble() || max != max.roundToDouble())) {
      setState(() => error = '整数刻度的范围不能带小数');
      return;
    }
    final ticks = (max - min) / step;
    if ((ticks - ticks.round()).abs() > 0.0001) {
      setState(() => error = '范围需要与每格步进对齐');
      return;
    }
    if (ticks > 2000) {
      setState(() => error = '刻度格数不能超过 2000');
      return;
    }
    Navigator.pop(context, [min, max, step]);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 12, 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '设置研磨刻度',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.grinder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '每格步进',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SegmentedButton<double>(
                      expandedInsets: EdgeInsets.zero,
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 1.0, label: Text('整数  1')),
                        ButtonSegment(value: 0.1, label: Text('小数  0.1')),
                      ],
                      selected: {step},
                      onSelectionChanged: (value) {
                        setState(() {
                          step = value.first;
                          error = null;
                        });
                      },
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: minCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textAlign: TextAlign.center,
                            selectAllOnFocus: true,
                            decoration: const InputDecoration(
                              labelText: '最小刻度',
                            ),
                            onSubmitted: (_) => _submit(),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            '至',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: maxCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textAlign: TextAlign.center,
                            selectAllOnFocus: true,
                            decoration: const InputDecoration(
                              labelText: '最大刻度',
                            ),
                            onSubmitted: (_) => _submit(),
                          ),
                        ),
                      ],
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        style: const TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _submit,
                        child: const Text('保存刻度'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final Settings settings;
  final List<String> processes; // 当前豆子里出现的处理法
  final ValueChanged<AppThemePreference>? onThemePreferenceChanged;
  final VoidCallback? onSaved;
  final bool embedded;

  const SettingsScreen({
    super.key,
    required this.settings,
    this.processes = const [],
    this.onThemePreferenceChanged,
    this.onSaved,
    this.embedded = false,
  });
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final brewGuideUrlCtrl = TextEditingController(
    text: widget.settings.brewGuideUrl,
  );
  late final urlCtrl = TextEditingController(text: widget.settings.supabaseUrl);
  late final keyCtrl = TextEditingController(text: widget.settings.supabaseKey);
  late final uidCtrl = TextEditingController(text: widget.settings.userId);
  final dosePresetCtrl = TextEditingController();
  final dripperPresetCtrl = TextEditingController();
  final grinderPresetCtrl = TextEditingController();
  bool _obscureSupabaseKey = true;

  void _applyConnectionFields() {
    widget.settings
      ..brewGuideUrl = brewGuideUrlCtrl.text.trim()
      ..supabaseUrl = urlCtrl.text.trim()
      ..supabaseKey = keyCtrl.text.trim()
      ..userId = uidCtrl.text.trim().isEmpty
          ? 'default_user'
          : uidCtrl.text.trim();
  }

  Future<void> _saveConnectionSettings() async {
    _applyConnectionFields();
    await widget.settings.save();
    if (mounted) widget.onSaved?.call();
  }

  @override
  void dispose() {
    brewGuideUrlCtrl.dispose();
    urlCtrl.dispose();
    keyCtrl.dispose();
    uidCtrl.dispose();
    dosePresetCtrl.dispose();
    dripperPresetCtrl.dispose();
    grinderPresetCtrl.dispose();
    super.dispose();
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _setThemePreference(AppThemePreference preference) async {
    setState(() => widget.settings.themePreference = preference);
    widget.onThemePreferenceChanged?.call(preference);
    await widget.settings.save();
  }

  Future<void> _addDosePreset() async {
    final value = double.tryParse(dosePresetCtrl.text.trim());
    if (value == null || value <= 0) {
      _snack('请输入正确的豆重');
      return;
    }
    setState(() {
      if (!widget.settings.dosePresets.contains(value)) {
        widget.settings.dosePresets = [...widget.settings.dosePresets, value]
          ..sort();
      }
      dosePresetCtrl.clear();
    });
    await widget.settings.save();
  }

  Future<void> _removeDosePreset(double value) async {
    if (widget.settings.dosePresets.length <= 1) return;
    setState(
      () => widget.settings.dosePresets = widget.settings.dosePresets
          .where((preset) => preset != value)
          .toList(),
    );
    await widget.settings.save();
  }

  Future<void> _addDripperPreset() async {
    final name = dripperPresetCtrl.text.trim();
    if (name.isEmpty || widget.settings.dripperPresets.contains(name)) return;
    setState(() {
      widget.settings.dripperPresets = [
        ...widget.settings.dripperPresets,
        name,
      ];
      widget.settings.lastDripper ??= name;
      dripperPresetCtrl.clear();
    });
    await widget.settings.save();
  }

  Future<void> _removeDripperPreset(String name) async {
    if (widget.settings.dripperPresets.length <= 1) return;
    setState(() {
      widget.settings.dripperPresets = widget.settings.dripperPresets
          .where((preset) => preset != name)
          .toList();
      widget.settings.dripperProcesses.remove(name);
      if (widget.settings.lastDripper == name) {
        widget.settings.lastDripper = widget.settings.dripperPresets.first;
      }
    });
    await widget.settings.save();
  }

  Future<void> _addGrinderPreset() async {
    final name = grinderPresetCtrl.text.trim();
    if (name.isEmpty || widget.settings.grinderPresets.contains(name)) return;
    setState(() {
      widget.settings.grinderPresets = [
        ...widget.settings.grinderPresets,
        name,
      ];
      widget.settings.setGrinderRange(name, 1, 120, step: 1);
      widget.settings.lastGrinder ??= name;
      grinderPresetCtrl.clear();
    });
    await widget.settings.save();
  }

  Future<void> _removeGrinderPreset(String name) async {
    setState(() {
      widget.settings.grinderPresets = widget.settings.grinderPresets
          .where((preset) => preset != name)
          .toList();
      widget.settings.grinderRanges.remove(name);
      widget.settings.grinderSteps.remove(name);
      widget.settings.grinderLastSettings.remove(name);
      if (widget.settings.lastGrinder == name) {
        widget.settings.lastGrinder = widget.settings.grinderPresets.isEmpty
            ? null
            : widget.settings.grinderPresets.first;
        final next = widget.settings.lastGrinder;
        if (next == null) {
          widget.settings.lastGrindSetting = null;
        } else {
          widget.settings.rememberGrindSetting(
            next,
            widget.settings.grindSettingFor(next),
          );
        }
      }
    });
    await widget.settings.save();
  }

  Future<void> _editGrinderRange(String grinder) async {
    final range = await showModalBottomSheet<List<double>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _GrinderRangeSheet(
        grinder: grinder,
        min: widget.settings.grinderMin(grinder),
        max: widget.settings.grinderMax(grinder),
        step: widget.settings.grinderStep(grinder),
      ),
    );
    if (range == null || !mounted) return;
    setState(() {
      widget.settings.setGrinderRange(
        grinder,
        range[0],
        range[1],
        step: range[2],
      );
      final previous = widget.settings.grinderLastSettings[grinder];
      if (previous != null) {
        final normalized = widget.settings.normalizeGrindSetting(
          grinder,
          previous,
        );
        widget.settings.grinderLastSettings[grinder] = normalized;
        if (widget.settings.lastGrinder == grinder) {
          widget.settings.lastGrindSetting = normalized;
        }
      }
    });
    await widget.settings.save();
  }

  Color _settingsPageColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF171717)
      : const Color(0xFFFAFAFA);

  Color _settingsGroupColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF262626)
      : const Color(0xFFF5F5F5);

  InputDecoration _settingsInputDecoration({
    String? hintText,
    Widget? suffixIcon,
  }) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = dark
        ? const Color(0xFF404040)
        : const Color(0xFFE5E5E5);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: borderColor),
    );
    return InputDecoration(
      hintText: hintText,
      isDense: true,
      filled: true,
      fillColor: dark ? const Color(0xFF262626) : const Color(0xFFFAFAFA),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      suffixIcon: suffixIcon,
      suffixIconColor: colors.onSurfaceVariant,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: colors.outline),
      ),
    );
  }

  Widget _settingsItemTitle(IconData icon, String title) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, size: 20, color: colors.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _settingsSection({
    Key? key,
    required String title,
    required Widget child,
    double radius = 12,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsSectionLabel(title, colors),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _settingsGroupColor(context),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: child,
        ),
      ],
    );
  }

  Widget _settingsSectionLabel(String title, ColorScheme colors) => Text(
    title,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: .7,
      color: colors.onSurfaceVariant,
    ),
  );

  Widget _settingsDivider() => Divider(
    height: 25,
    thickness: 1,
    color: Theme.of(context).colorScheme.outlineVariant,
  );

  Widget _settingsAddButton({
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      icon: const Icon(Icons.add),
    );
  }

  Widget _grinderEditor() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _settingsItemTitle(Icons.tune, '磨豆机'),
      Material(
        color: Colors.transparent,
        child: SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('使用 BOOKOO MT80'),
          value: widget.settings.mt80Enabled,
          onChanged: (value) async {
            setState(() {
              widget.settings.mt80Enabled = value;
              if (value) {
                widget.settings.lastGrinder = kMt80Grinder;
              } else if (widget.settings.lastGrinder == kMt80Grinder) {
                final manual = widget.settings.grinderPresets
                    .where((g) => g != kMt80Grinder)
                    .toList();
                widget.settings.lastGrinder = manual.isEmpty
                    ? null
                    : manual.first;
              }
            });
            await widget.settings.save();
            widget.onSaved?.call();
          },
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: grinderPresetCtrl,
              style: const TextStyle(fontSize: 13),
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              decoration: _settingsInputDecoration(hintText: '名称，如 K-Ultra'),
              onSubmitted: (_) => _addGrinderPreset(),
            ),
          ),
          const SizedBox(width: 8),
          _settingsAddButton(tooltip: '添加磨豆机', onPressed: _addGrinderPreset),
        ],
      ),
      const SizedBox(height: 8),
      if (widget.settings.grinderPresets.isEmpty)
        Text(
          '暂无',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        )
      else
        ...widget.settings.grinderPresets.map(
          (grinder) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            grinder,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '刻度 ${_grindValueText(widget.settings.grinderMin(grinder), widget.settings.grinderStep(grinder))}–${_grindValueText(widget.settings.grinderMax(grinder), widget.settings.grinderStep(grinder))} · 每格 ${_grindValueText(widget.settings.grinderStep(grinder), widget.settings.grinderStep(grinder))}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '设置 $grinder 刻度范围',
                      onPressed: () => _editGrinderRange(grinder),
                      icon: const Icon(Icons.tune, size: 20),
                    ),
                    IconButton(
                      tooltip: '删除$grinder',
                      onPressed: () => _removeGrinderPreset(grinder),
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _presetEditor<T>({
    required IconData icon,
    required String title,
    required String hint,
    required TextEditingController controller,
    required TextInputType keyboardType,
    required List<T> values,
    required String Function(T value) itemText,
    required VoidCallback onAdd,
    required ValueChanged<T> onDelete,
    int minimumItems = 0,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsItemTitle(icon, title),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                style: const TextStyle(fontSize: 13),
                keyboardType: keyboardType,
                textInputAction: TextInputAction.done,
                decoration: _settingsInputDecoration(hintText: hint),
                onSubmitted: (_) => onAdd(),
              ),
            ),
            const SizedBox(width: 8),
            _settingsAddButton(tooltip: '添加$title', onPressed: onAdd),
          ],
        ),
        const SizedBox(height: 8),
        if (values.isEmpty)
          Text(
            '暂无',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final value in values)
                InputChip(
                  label: Text(itemText(value)),
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  deleteButtonTooltipMessage: '删除${itemText(value)}',
                  onDeleted: values.length <= minimumItems
                      ? null
                      : () => onDelete(value),
                ),
            ],
          ),
      ],
    );
  }

  Widget _dripperRow(String dripper) {
    final selected = widget.settings.dripperProcesses[dripper] ?? const [];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _settingsItemTitle(Icons.filter_alt_outlined, dripper),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final proc in widget.processes)
                FilterChip(
                  label: Text(proc),
                  selected: selected.contains(proc),
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  onSelected: (on) {
                    setState(() {
                      final list = widget.settings.dripperProcesses.putIfAbsent(
                        dripper,
                        () => [],
                      );
                      if (on) {
                        if (!list.contains(proc)) list.add(proc);
                      } else {
                        list.remove(proc);
                      }
                      if (list.isEmpty) {
                        widget.settings.dripperProcesses.remove(dripper);
                      }
                    });
                    widget.settings.save();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _connectionField({
    required Key key,
    required String label,
    required TextEditingController controller,
    String? hintText,
    bool obscureText = false,
    Widget? suffixIcon,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 5),
        TextField(
          key: key,
          controller: controller,
          style: const TextStyle(fontSize: 13),
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          obscureText: obscureText,
          onSubmitted: (_) => _saveConnectionSettings(),
          decoration: _settingsInputDecoration(
            hintText: hintText,
            suffixIcon: suffixIcon,
          ),
        ),
      ],
    );
  }

  Widget _connectionSettingsSection() {
    final colors = Theme.of(context).colorScheme;
    final configured = widget.settings.isConfigured;
    final groupDecoration = BoxDecoration(
      color: _settingsGroupColor(context),
      borderRadius: BorderRadius.circular(4),
    );
    return Column(
      key: const ValueKey('settings-group-connection'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsSectionLabel('数据连接', colors),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: groupDecoration,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: configured ? const Color(0xFF22C55E) : colors.outline,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Supabase 数据连接',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                configured ? '已配置' : '未配置',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: groupDecoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _connectionField(
                key: const ValueKey('brew-guide-url-field'),
                label: 'Brew Guide 网址',
                controller: brewGuideUrlCtrl,
                hintText: 'https://your-brew-guide.example/',
              ),
              const SizedBox(height: 12),
              _connectionField(
                key: const ValueKey('supabase-url-field'),
                label: 'Supabase URL',
                controller: urlCtrl,
                hintText: 'https://xxx.supabase.co',
              ),
              const SizedBox(height: 12),
              _connectionField(
                key: const ValueKey('supabase-key-field'),
                label: 'Supabase Key (anon/publishable)',
                controller: keyCtrl,
                obscureText: _obscureSupabaseKey,
                suffixIcon: IconButton(
                  tooltip: _obscureSupabaseKey
                      ? '显示 Supabase Key'
                      : '隐藏 Supabase Key',
                  onPressed: () => setState(
                    () => _obscureSupabaseKey = !_obscureSupabaseKey,
                  ),
                  icon: Icon(
                    _obscureSupabaseKey
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _connectionField(
                key: const ValueKey('supabase-user-id-field'),
                label: 'User ID',
                controller: uidCtrl,
                hintText: 'default_user',
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = ListView(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
      children: [
        if (widget.embedded) ...[
          const Text(
            '设置',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 24),
        ],
        _settingsSection(
          key: const ValueKey('settings-group-appearance'),
          title: '外观',
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: _settingsItemTitle(Icons.monitor_outlined, '外观模式'),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: SegmentedButton<AppThemePreference>(
                      expandedInsets: EdgeInsets.zero,
                      showSelectedIcon: false,
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 5),
                        ),
                        side: const WidgetStatePropertyAll(BorderSide.none),
                        shape: WidgetStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        backgroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? colors.surface
                              : Colors.transparent,
                        ),
                      ),
                      segments: const [
                        ButtonSegment(
                          value: AppThemePreference.light,
                          label: Text('浅色'),
                        ),
                        ButtonSegment(
                          value: AppThemePreference.dark,
                          label: Text('深色'),
                        ),
                        ButtonSegment(
                          value: AppThemePreference.system,
                          label: Text('系统'),
                        ),
                      ],
                      selected: {widget.settings.themePreference},
                      onSelectionChanged: (selection) =>
                          _setThemePreference(selection.first),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _settingsSection(
          key: const ValueKey('settings-group-presets'),
          title: '冲煮预设',
          child: Column(
            children: [
              _presetEditor<double>(
                icon: Icons.scale_outlined,
                title: '豆重',
                hint: '克数，如 17',
                controller: dosePresetCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                values: widget.settings.dosePresets,
                itemText: (value) => '${fmt(value)}g',
                onAdd: _addDosePreset,
                onDelete: _removeDosePreset,
                minimumItems: 1,
              ),
              _settingsDivider(),
              _presetEditor<String>(
                icon: Icons.coffee_maker_outlined,
                title: '滤杯',
                hint: '名称，如 V60',
                controller: dripperPresetCtrl,
                keyboardType: TextInputType.text,
                values: widget.settings.dripperPresets,
                itemText: (value) => value,
                onAdd: _addDripperPreset,
                onDelete: _removeDripperPreset,
                minimumItems: 1,
              ),
              _settingsDivider(),
              _grinderEditor(),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _settingsSection(
          key: const ValueKey('settings-group-processes'),
          title: '滤杯处理法偏好',
          child: widget.processes.isEmpty
              ? Text(
                  '暂无可选处理法',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              : Column(
                  children: [
                    for (
                      var index = 0;
                      index < widget.settings.dripperPresets.length;
                      index++
                    ) ...[
                      _dripperRow(widget.settings.dripperPresets[index]),
                      if (index < widget.settings.dripperPresets.length - 1)
                        _settingsDivider(),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 20),
        _connectionSettingsSection(),
      ],
    );
    if (widget.embedded) {
      return ColoredBox(color: _settingsPageColor(context), child: content);
    }
    return Scaffold(
      backgroundColor: _settingsPageColor(context),
      appBar: AppBar(title: const Text('设置')),
      body: content,
    );
  }
}
