// 数据模型：秤读数、咖啡豆、采样点。

/// 一帧解码后的秤读数。
class ScaleReading {
  final double elapsedS; // 秤上计时器（秒）；未启动时为 0
  final double weightG;
  final double flowGs;
  final int batteryPct;
  ScaleReading(this.elapsedS, this.weightG, this.flowGs, this.batteryPct);
}

/// brew-guide 里的一颗咖啡豆。
class Bean {
  final String id;
  final String name;
  final String roastLevel;
  final String? roaster;
  final String? roastDate;
  final String? process; // 处理法（blendComponents[0].process 或顶层 process）
  final double remaining; // 克
  final Map<String, dynamic> raw; // 完整 data，扣库存时整条回写
  Bean({
    required this.id,
    required this.name,
    required this.roastLevel,
    required this.remaining,
    required this.raw,
    this.roaster,
    this.roastDate,
    this.process,
  });
}

/// 采样点 (相对时间 s, 重量 g, 流速 g/s)。
class Sample {
  final double t;
  final double w;
  final double flow;
  Sample(this.t, this.w, this.flow);
}
