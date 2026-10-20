import 'package:flutter/material.dart';
import 'mt80.dart';

class Mt80GrindPanel extends StatelessWidget {
  final Mt80Result result;
  final bool loading;
  final bool connected;
  final VoidCallback? onRefresh, onChoose, onConnect;
  final String? connectionStatus, currentParameters;
  const Mt80GrindPanel({
    super.key,
    this.result = const Mt80Result(),
    this.loading = false,
    this.connected = false,
    this.onRefresh,
    this.onChoose,
    this.onConnect,
    this.connectionStatus,
    this.currentParameters,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'MT80 手机采集的研磨参数',
      child: Container(
        key: const ValueKey('mt80-grind-panel'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(Icons.bluetooth, size: 21, color: colors.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connectionStatus ?? 'MT80 未连接',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (connected && currentParameters != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      currentParameters!.replaceFirst(' · ', '\n'),
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (result.status == 'needs_confirmation')
                    const Text('请选择本次磨豆记录', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
            if (loading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (result.status == 'needs_confirmation' && onChoose != null)
              TextButton(onPressed: onChoose, child: const Text('选择'))
            else if (onConnect != null)
              IconButton(
                onPressed: onConnect,
                tooltip: '重连磨豆机',
                icon: const Icon(Icons.bluetooth_searching, size: 21),
              )
            else if (onRefresh != null)
              IconButton(
                onPressed: onRefresh,
                tooltip: '刷新本杯研磨参数',
                icon: const Icon(Icons.refresh, size: 21),
              ),
          ],
        ),
      ),
    );
  }
}
