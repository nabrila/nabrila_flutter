import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'delivery.dart';
import 'navigation.dart';
import 'replay/replay_options.dart';
import 'replay/replay_recorder.dart';
import 'runtime.dart';

/// Entry point of the SDK.
///
/// ```dart
/// void main() {
///   Nabrila.run(
///     appKey: 'nbr_...',
///     enabled: const bool.fromEnvironment('NABRILA_ENABLED'),
///     app: () => runApp(const NabrilaScope(child: MyApp())),
///   );
/// }
/// ```
class Nabrila {
  Nabrila._();

  static final NabrilaNavigatorObserver _observer = NabrilaNavigatorObserver();

  /// The handlers the SDK installed, to tell whether the app replaced them.
  static FlutterExceptionHandler? _flutterHook;
  static ErrorCallback? _platformHook;

  /// The platform handler that was there before the SDK's.
  static ErrorCallback? _platformPrevious;

  /// True while a hook records an error, so a chain of hooks (the app's
  /// handler calling the SDK's older one) records it once.
  static bool _inHook = false;

  /// Pass it to `MaterialApp.navigatorObservers` (or `GoRouter.observers`).
  /// It does nothing while the SDK is disabled.
  static NavigatorObserver get navigatorObserver => _observer;

  /// Whether `Nabrila.run` started the SDK with `enabled: true`.
  static bool get isEnabled => NabrilaRuntime.current != null;

  /// Starts the app. With [enabled] false it only calls [app]: no button, no
  /// recording, no uploads. With [enabled] true it owns the app's `Zone` (to
  /// capture `print`) and chains the existing `FlutterError.onError` and
  /// `PlatformDispatcher.instance.onError`, also when [app] sets its own.
  /// An uncaught error is recorded and then handed, once, to whoever would
  /// have got it without the SDK. [replay] sets how the moments before a
  /// report are recorded; `NabrilaReplay.off` turns it off. [context]
  /// starts the pairs every report carries (see [setContext]). With
  /// [shake] true, shaking the phone opens the report too; it reads the
  /// motion sensor, which needs no permission.
  ///
  /// [endpoint] must be `https://` (a plain `http://` server on this
  /// machine is allowed in debug builds); otherwise the SDK stays off.
  /// With [keepKeyOnDevice] true the report key never leaves the phone,
  /// even when the plan keeps keys on the server: the team then opens a
  /// report only from its link.
  ///
  /// A build with [enabled] false also deletes the reports an earlier build
  /// left on the phone, unsent: a release build never keeps a tester's
  /// report or its key.
  static void run({
    required String appKey,
    required bool enabled,
    required void Function() app,
    String endpoint = defaultEndpoint,
    NabrilaReplay replay = const NabrilaReplay(),
    Map<String, Object?> context = const {},
    bool shake = true,
    bool keepKeyOnDevice = false,
  }) {
    if (!enabled) {
      app();
      unawaited(_discardQuietly());
      return;
    }
    assert(appKey.startsWith('nbr_'), 'Nabrila appKey must start with nbr_');
    if (!isAllowedEndpoint(endpoint)) {
      debugPrint(
        'nabrila: the endpoint must use https:// ($endpoint); the SDK stays off.',
      );
      app();
      return;
    }
    final runtime = NabrilaRuntime(
      appKey: appKey,
      endpoint: endpoint,
      keepKeyOnDevice: keepKeyOnDevice,
    )..shake = shake;
    runtime.replay = replay.enabled
        ? ReplayRecorder(options: replay, clock: runtime.now)
        : null;
    context.forEach(runtime.setContext);
    NabrilaRuntime.current = runtime;
    final outer = Zone.current;
    runZonedGuarded(
      () {
        WidgetsFlutterBinding.ensureInitialized();
        _installErrorHooks();
        app();
        // An app that sets its own handlers inside `app` (or in its first
        // frame) would silently drop the SDK's: they are chained again.
        _installErrorHooks();
        _watchErrorHooks(WidgetsBinding.instance);
      },
      (error, stack) {
        NabrilaRuntime.current?.recordLog('error', '$error', '$stack');
        // Without the SDK the error would reach the zone around `run`.
        if (!identical(outer, Zone.root)) {
          outer.handleUncaughtError(error, stack);
          return;
        }
        final handled = _platformPrevious?.call(error, stack) ?? false;
        if (!handled) Zone.root.print('Uncaught error: $error\n$stack');
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          NabrilaRuntime.current?.recordPrint(line);
          parent.print(zone, line);
        },
      ),
    );
  }

  static WidgetsBinding? _watched;

  /// Checks on every frame that the SDK's handlers are still installed: an
  /// app that assigns `FlutterError.onError` after an `await` would leave
  /// the SDK blind (CL-23). The check is an identity comparison; a
  /// persistent callback cannot be removed, so it is added once per binding.
  static void _watchErrorHooks(WidgetsBinding binding) {
    if (identical(_watched, binding)) return;
    _watched = binding;
    binding.addPersistentFrameCallback((_) => _installErrorHooks());
  }

  /// Puts the SDK's handlers in front of whatever is installed, unless they
  /// already are. Each one records into the runtime of the moment.
  static void _installErrorHooks() {
    final flutter = FlutterError.onError;
    if (flutter == null || !identical(flutter, _flutterHook)) {
      void hook(FlutterErrorDetails details) {
        if (_inHook) return flutter?.call(details);
        _inHook = true;
        try {
          NabrilaRuntime.current?.recordLog(
            'error',
            details.exceptionAsString(),
            details.stack?.toString(),
          );
          flutter?.call(details);
        } finally {
          _inHook = false;
        }
      }

      FlutterError.onError = _flutterHook = hook;
    }

    final dispatcher = PlatformDispatcher.instance;
    final platform = dispatcher.onError;
    if (platform == null || !identical(platform, _platformHook)) {
      _platformPrevious = platform;
      bool hook(Object error, StackTrace stack) {
        if (_inHook) return platform?.call(error, stack) ?? false;
        _inHook = true;
        try {
          NabrilaRuntime.current?.recordLog('error', '$error', '$stack');
          return platform?.call(error, stack) ?? false;
        } finally {
          _inHook = false;
        }
      }

      dispatcher.onError = _platformHook = hook;
    }
  }

  /// Forgets the taps, screens, logs, calls and replay recorded so far.
  /// Call it when the person signed in to your app changes (sign-out,
  /// account switch), before the next screen shows, so a report never
  /// carries what the previous person did. Pairs set with [setContext]
  /// stay; remove them with [clearContext] if they are about the person.
  /// Does nothing while the SDK is disabled.
  static void clearSession() => NabrilaRuntime.current?.clearSession();

  /// Adds a pair that every report from now on carries, such as the
  /// environment, the signed-in test account or a feature flag:
  /// `Nabrila.setContext('plan', 'pro')`. A null [value] removes it. Values
  /// are sent as text, up to 200 characters, and at most 30 pairs are kept;
  /// a key that sounds secret (`token`, `password`…) is sent as
  /// `[REDACTED]`. Does nothing while the SDK is disabled.
  static void setContext(String key, Object? value) =>
      NabrilaRuntime.current?.setContext(key, value);

  /// Removes every pair added with [setContext].
  static void clearContext() => NabrilaRuntime.current?.context.clear();

  /// Deletes every report saved on this phone that was not sent yet, and
  /// the links not seen yet: for an app that lets testers opt out.
  static Future<void> discardSavedReports() async {
    final runtime = NabrilaRuntime.current;
    if (runtime != null) {
      await runtime.delivery.discardAll();
      await runtime.loop.clear();
      return;
    }
    await _discardQuietly();
  }

  static Future<void> _discardQuietly() async {
    try {
      final dir = await defaultStorageDir();
      if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    } on Object {
      // No binding yet, or nothing to delete.
    }
  }

  /// Turns the SDK on or off without a zone, for tests.
  @visibleForTesting
  static void debugSetRuntime(NabrilaRuntime? runtime) {
    NabrilaRuntime.current = runtime;
  }
}
