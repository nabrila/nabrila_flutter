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
  static bool _hooksInstalled = false;

  /// Pass it to `MaterialApp.navigatorObservers` (or `GoRouter.observers`).
  /// It does nothing while the SDK is disabled.
  static NavigatorObserver get navigatorObserver => _observer;

  /// Whether `Nabrila.run` started the SDK with `enabled: true`.
  static bool get isEnabled => NabrilaRuntime.current != null;

  /// Starts the app. With [enabled] false it only calls [app]: no button, no
  /// recording, no uploads. With [enabled] true it owns the app's `Zone` (to
  /// capture `print`) and chains the existing `FlutterError.onError` and
  /// `PlatformDispatcher.instance.onError`. [replay] sets how the moments
  /// before a report are recorded; `NabrilaReplay.off` turns it off.
  /// [context] starts the pairs every report carries (see [setContext]).
  /// With [shake] true, shaking the phone opens the report too; it reads
  /// the motion sensor, which needs no permission.
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
  }) {
    if (!enabled) {
      app();
      unawaited(_discardQuietly());
      return;
    }
    assert(appKey.startsWith('nbr_'), 'Nabrila appKey must start with nbr_');
    final runtime = NabrilaRuntime(appKey: appKey, endpoint: endpoint)
      ..shake = shake;
    runtime.replay = replay.enabled
        ? ReplayRecorder(options: replay, clock: runtime.now)
        : null;
    context.forEach(runtime.setContext);
    NabrilaRuntime.current = runtime;
    ErrorCallback? previousPlatform;
    runZonedGuarded(
      () {
        WidgetsFlutterBinding.ensureInitialized();
        previousPlatform = _installErrorHooks(runtime);
        app();
      },
      (error, stack) {
        runtime.recordLog('error', '$error', '$stack');
        final previous = previousPlatform;
        if (previous != null) {
          previous(error, stack);
        } else {
          Zone.root.print('Uncaught error: $error\n$stack');
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          runtime.recordLog('info', line);
          parent.print(zone, line);
        },
      ),
    );
  }

  static ErrorCallback? _installErrorHooks(NabrilaRuntime runtime) {
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    if (_hooksInstalled) return previousPlatform;
    _hooksInstalled = true;

    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      runtime.recordLog(
        'error',
        details.exceptionAsString(),
        details.stack?.toString(),
      );
      previousFlutter?.call(details);
    };
    dispatcher.onError = (error, stack) {
      runtime.recordLog('error', '$error', '$stack');
      return previousPlatform?.call(error, stack) ?? false;
    };
    return previousPlatform;
  }

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
