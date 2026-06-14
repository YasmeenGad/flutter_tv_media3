import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'lifecycle_types.dart';

/// Coordinates the lifecycle of a native player surface and gates every
/// outgoing [MethodChannel] invocation behind a state machine + command queue.
///
/// One coordinator is owned per [MethodChannel] (= per Flutter engine ↔ native
/// channel pair).
///
/// ### Design goals
///  * Eliminate `MissingPluginException` storms during activity recreate /
///    background / dispose transitions.
///  * Make UI lifecycle observable so widgets can disable controls while the
///    native side is not ready.
///  * Preserve user intent: commands like `play`, `pause`, `selectTrack` are
///    queued and replayed after re-attach instead of being lost.
///  * Coalesce high-frequency commands (`seekTo`, `setVolume`) so only the
///    latest value is applied after re-attach.
///  * Surface real `PlatformException`s to the caller; never swallow them.
///
/// ### Wiring
/// 1. Construct one [PlayerLifecycleCoordinator] per channel.
/// 2. Call [bindNativeSignals] passing the inbound `MethodCall` stream — when
///    the native side emits one of [LifecycleEvent]'s method names, the
///    coordinator updates state.
/// 3. Call [beginAttach] just before launching the native activity so that
///    early calls during the gap are queued (not lost).
/// 4. Replace direct `channel.invokeMethod(...)` calls with [invoke].
class PlayerLifecycleCoordinator {
  PlayerLifecycleCoordinator({
    required MethodChannel channel,
    String debugLabel = 'PlayerLifecycle',
    Duration attachTimeout = const Duration(seconds: 8),
    int maxQueueLength = 64,
  })  : _channel = channel,
        _debugLabel = debugLabel,
        _attachTimeoutDuration = attachTimeout,
        _maxQueueLength = maxQueueLength;

  final MethodChannel _channel;
  final String _debugLabel;
  final Duration _attachTimeoutDuration;
  final int _maxQueueLength;

  final ValueNotifier<PlayerLifecycleState> _state =
      ValueNotifier<PlayerLifecycleState>(PlayerLifecycleState.detached);

  final List<_QueuedCommand> _queue = <_QueuedCommand>[];
  Timer? _attachTimeoutTimer;
  bool _disposed = false;

  // ── Public surface ──────────────────────────────────────────────────────

  /// Observable lifecycle state. Bind UI to this to enable/disable controls.
  ValueListenable<PlayerLifecycleState> get state => _state;

  /// Snapshot of the current state.
  PlayerLifecycleState get currentState => _state.value;

  /// True when [invoke] would execute synchronously without queueing.
  bool get isLive =>
      _state.value == PlayerLifecycleState.ready ||
      _state.value == PlayerLifecycleState.background;

  /// Number of commands currently buffered awaiting re-attach.
  @visibleForTesting
  int get pendingCommandCount => _queue.length;

  /// Invoke a MethodChannel method, gated by lifecycle state and [policy].
  ///
  /// Throws [PlatformException] for real native errors. Returns `null` for
  /// dropped / disposing calls. May queue and resolve later for
  /// [InvokePolicy.queueUntilReady] / [InvokePolicy.coalesce].
  Future<T?> invoke<T>(
    String method, {
    Object? arguments,
    InvokePolicy policy = InvokePolicy.dropIfNotReady,
  }) async {
    if (_disposed) return null;

    final s = _state.value;

    if (s == PlayerLifecycleState.ready ||
        s == PlayerLifecycleState.background) {
      return _rawInvoke<T>(method, arguments);
    }

    if (s == PlayerLifecycleState.disposing) {
      if (policy == InvokePolicy.rejectIfNotReady) {
        throw StateError(
          '[$_debugLabel] Cannot invoke "$method" — player is disposing.',
        );
      }
      return null;
    }

    // detached or attaching
    switch (policy) {
      case InvokePolicy.dropIfNotReady:
        return null;
      case InvokePolicy.rejectIfNotReady:
        throw StateError(
          '[$_debugLabel] Cannot invoke "$method" — player not ready '
          '(state=${s.name}).',
        );
      case InvokePolicy.queueUntilReady:
      case InvokePolicy.coalesce:
        return _enqueue<T>(method, arguments, policy);
    }
  }

  /// Mark that an attach is expected. If the attach event doesn't arrive
  /// within [_attachTimeoutDuration], the coordinator falls back to
  /// [PlayerLifecycleState.detached] and drains the queue.
  ///
  /// Idempotent: calling while already in [PlayerLifecycleState.ready] /
  /// [PlayerLifecycleState.attaching] is a no-op.
  void beginAttach() {
    if (_disposed) return;
    final s = _state.value;
    if (s == PlayerLifecycleState.ready ||
        s == PlayerLifecycleState.background ||
        s == PlayerLifecycleState.attaching) {
      return;
    }
    _transition(PlayerLifecycleState.attaching);
    _armAttachTimeout();
  }

  /// Mark that Flutter has initiated a tear-down. Drains the queue.
  /// Subsequent [invoke]s with [InvokePolicy.rejectIfNotReady] will throw.
  void beginDispose() {
    if (_disposed) return;
    _transition(PlayerLifecycleState.disposing);
    _drainQueueAsDropped('disposing');
  }

  /// Called from the channel's inbound `MethodCall` handler. Returns `true`
  /// if the call was a lifecycle signal and was consumed.
  bool handleNativeMethodCall(MethodCall call) {
    final event = LifecycleEvent.tryParse(call.method);
    if (event == null) return false;
    _onLifecycleEvent(event);
    return true;
  }

  /// Explicit lifecycle event injector. Useful when the channel already has a
  /// custom inbound handler and you only want to forward specific signals.
  void notify(LifecycleEvent event) => _onLifecycleEvent(event);

  /// Release resources. After this, [invoke] returns `null` and lifecycle
  /// signals are ignored.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _attachTimeoutTimer?.cancel();
    _attachTimeoutTimer = null;
    _drainQueueAsDropped('coordinator disposed');
    _state.dispose();
  }

  // ── Internal ───────────────────────────────────────────────────────────

  void _onLifecycleEvent(LifecycleEvent event) {
    if (_disposed) return;
    switch (event) {
      case LifecycleEvent.attached:
        _transition(PlayerLifecycleState.ready);
        _flushQueue();
        break;
      case LifecycleEvent.paused:
        if (_state.value == PlayerLifecycleState.ready) {
          _transition(PlayerLifecycleState.background);
        }
        break;
      case LifecycleEvent.resumed:
        if (_state.value == PlayerLifecycleState.background ||
            _state.value == PlayerLifecycleState.attaching ||
            _state.value == PlayerLifecycleState.detached) {
          _transition(PlayerLifecycleState.ready);
          _flushQueue();
        }
        break;
      case LifecycleEvent.detached:
        _transition(PlayerLifecycleState.detached);
        _drainQueueAsDropped('native detached');
        break;
    }
  }

  Future<T?> _rawInvoke<T>(String method, Object? arguments) async {
    if (_disposed) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      // Channel torn down mid-flight. Mark detached so subsequent calls queue
      // instead of repeatedly failing. Do NOT surface to caller.
      _transition(PlayerLifecycleState.detached);
      return null;
    }
    // PlatformException intentionally propagates to caller.
  }

  Future<T?> _enqueue<T>(
    String method,
    Object? arguments,
    InvokePolicy policy,
  ) {
    if (policy == InvokePolicy.coalesce) {
      // Drop any prior queued call for the same method (older value loses).
      for (int i = _queue.length - 1; i >= 0; i--) {
        if (_queue[i].method == method) {
          _queue[i].completer.complete(null);
          _queue.removeAt(i);
        }
      }
    }

    if (_queue.length >= _maxQueueLength) {
      // Backpressure: drop the oldest non-rejecting command.
      final dropped = _queue.removeAt(0);
      dropped.completer.complete(null);
    }

    final completer = Completer<dynamic>();
    _queue.add(_QueuedCommand(method, arguments, policy, completer));
    return completer.future.then((dynamic v) => v as T?);
  }

  void _flushQueue() {
    if (_queue.isEmpty) return;
    final pending = List<_QueuedCommand>.from(_queue);
    _queue.clear();
    for (final cmd in pending) {
      _rawInvoke<dynamic>(cmd.method, cmd.arguments).then(
        cmd.completer.complete,
        onError: (Object err, StackTrace st) =>
            cmd.completer.completeError(err, st),
      );
    }
  }

  void _drainQueueAsDropped(String reason) {
    if (_queue.isEmpty) return;
    for (final cmd in _queue) {
      if (!cmd.completer.isCompleted) {
        cmd.completer.complete(null);
      }
    }
    _queue.clear();
  }

  void _transition(PlayerLifecycleState next) {
    if (_disposed) return;
    if (_state.value == next) return;
    _attachTimeoutTimer?.cancel();
    _attachTimeoutTimer = null;
    _state.value = next;
  }

  void _armAttachTimeout() {
    _attachTimeoutTimer?.cancel();
    _attachTimeoutTimer = Timer(_attachTimeoutDuration, () {
      if (_disposed) return;
      if (_state.value != PlayerLifecycleState.attaching) return;
      _transition(PlayerLifecycleState.detached);
      _drainQueueAsDropped('attach timeout');
    });
  }
}

class _QueuedCommand {
  _QueuedCommand(
    this.method,
    this.arguments,
    this.policy,
    this.completer,
  );

  final String method;
  final Object? arguments;
  final InvokePolicy policy;
  final Completer<dynamic> completer;
}
