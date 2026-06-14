// Public lifecycle types for the Media3 player.
//
// These types describe where the player's native side is in its lifecycle and
// how the Dart side should treat outgoing MethodChannel invocations while the
// native side is not in the `PlayerLifecycleState.ready` state.

/// The lifecycle state of the native player surface (the Android Activity that
/// hosts the FlutterEngines and registers the MethodChannel handlers).
///
/// The state machine is driven by:
///  * Native signals delivered through the MethodChannel
///    (`lifecycle.attached`, `lifecycle.paused`, `lifecycle.resumed`,
///    `lifecycle.detached`).
///  * Flutter-side intent (open / dispose) emitted by the controllers.
///
/// Transition diagram:
///
/// ```
///   detached ──beginAttach──> attaching ──native.attached──> ready
///                                  │                          │
///                                  │                          │ native.paused
///                                  │                          ▼
///                                  │                       background
///                                  │                          │
///                                  │   native.resumed         │
///                                  └──────────────────────────┘
///                                  │
///                                  ▼ (timeout / native.detached)
///                              detached
///
///   any state ──beginDispose / native.detached──> disposing ──finalize──> detached
/// ```
enum PlayerLifecycleState {
  /// No native activity attached. Channels are not callable.
  detached,

  /// Native attach in progress (we expect `lifecycle.attached` soon).
  /// Calls are buffered if their [InvokePolicy] allows queueing.
  attaching,

  /// Native is up. MethodChannel invocations execute directly.
  ready,

  /// Activity is backgrounded but channels are still live. Calls still execute
  /// (some platforms keep audio playing in the background) — UI may choose to
  /// freeze interactive controls.
  background,

  /// Tear-down in progress. New calls are rejected or dropped. Queue is
  /// drained.
  disposing,
}

/// Policy that controls how the lifecycle coordinator handles a method call
/// when the native side is not in [PlayerLifecycleState.ready] /
/// [PlayerLifecycleState.background].
enum InvokePolicy {
  /// Execute only when the channels are live. If not, silently return `null`.
  ///
  /// Use for read-only / poll-style methods where a missed call is harmless
  /// (e.g. `getPosition`, `getDuration`).
  dropIfNotReady,

  /// Buffer the call until the coordinator reaches [PlayerLifecycleState.ready]
  /// and then flush. Order is preserved.
  ///
  /// Use for user-intent commands that must eventually run (e.g. `playPause`,
  /// `play`, `pause`, `selectTrack`).
  queueUntilReady,

  /// Like [queueUntilReady] but newer invocations of the same method replace
  /// older queued ones.
  ///
  /// Use for commands where only the latest value matters (e.g. `seekTo`,
  /// `setVolume`, `setSpeed`).
  coalesce,

  /// If channels are not live, throw a [StateError]. Caller must handle it.
  ///
  /// Use for destructive / unambiguous one-shots where queueing would hide a
  /// real problem (e.g. `stop`, `findSubtitles` — the user must retry
  /// explicitly).
  rejectIfNotReady,
}

/// Logical lifecycle events the native side can emit through the MethodChannel
/// (or that Flutter can emit synthetically).
///
/// The string values are the exact method names expected over the channel.
enum LifecycleEvent {
  attached('lifecycle.attached'),
  paused('lifecycle.paused'),
  resumed('lifecycle.resumed'),
  detached('lifecycle.detached');

  const LifecycleEvent(this.methodName);
  final String methodName;

  static LifecycleEvent? tryParse(String methodName) {
    for (final e in LifecycleEvent.values) {
      if (e.methodName == methodName) return e;
    }
    return null;
  }
}
