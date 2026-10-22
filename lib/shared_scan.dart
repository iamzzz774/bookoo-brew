import 'dart:async';

/// Coalesces concurrent discovery requests into one complete scan window.
/// Each caller filters the same observed set and owns only its cancellation.
/// No cached results survive a completed scan, and no first-match shortcut
/// bypasses the caller's multiple-device ambiguity check.
class SharedScan<T> {
  SharedScan({
    required this.results,
    required this.start,
    required this.stop,
    required this.keyOf,
  });

  final Stream<List<T>> Function() results;
  final Future<void> Function(Duration timeout) start;
  final Future<void> Function() stop;
  final String Function(T value) keyOf;
  Future<List<T>>? _active;

  Future<List<T>> find(
    bool Function(T value) accepts, {
    required Duration timeout,
    bool Function()? cancelled,
  }) async {
    if (cancelled?.call() == true) throw StateError('连接已取消');
    // Assign before yielding: the second role joins even while native start
    // is pending. The future remains active through native stop completion.
    final batch = _active ??= _scan(timeout).whenComplete(() => _active = null);
    final observed = await batch;
    if (cancelled?.call() == true) throw StateError('连接已取消');
    return observed.where(accepts).toList();
  }

  Future<List<T>> _scan(Duration timeout) async {
    final found = <String, T>{};
    final streamFailure = Completer<void>();
    // Register the error listener before starting native scanning. Discovery
    // errors must not silently turn into "no devices" or unhandled errors.
    final subscription = results().listen(
      (batch) {
        for (final value in batch) {
          found[keyOf(value)] = value;
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!streamFailure.isCompleted) {
          streamFailure.completeError(error, stack);
        }
      },
    );
    // Attach an error consumer immediately even if start is still pending.
    unawaited(streamFailure.future.then<void>((_) {}, onError: (Object _) {}));
    try {
      await start(timeout);
      await Future.any<void>([
        Future<void>.delayed(timeout),
        streamFailure.future,
      ]);
      return found.values.toList();
    } finally {
      await subscription.cancel();
      await stop();
    }
  }
}
