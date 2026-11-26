import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Opens the report when the phone is shaken. The native side listens only
/// while the app is in the foreground (`android/` reads the accelerometer,
/// `ios/` the system shake gesture); neither needs a permission.
class ShakeTrigger {
  ShakeTrigger(this.onShake, {Stream<Object?>? shakes})
    : _shakes =
          shakes ??
          debugShakes ??
          (_supported ? _channel.receiveBroadcastStream() : null);

  /// Shakes for tests, in place of the native sensor.
  @visibleForTesting
  static Stream<Object?>? debugShakes;

  final VoidCallback onShake;
  final Stream<Object?>? _shakes;
  StreamSubscription<Object?>? _subscription;
  AppLifecycleListener? _lifecycle;

  static const EventChannel _channel = EventChannel('nabrila/shake');

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  void start() {
    if (_shakes == null) return;
    _lifecycle ??= AppLifecycleListener(
      onResume: _listen,
      onHide: _stop,
      onPause: _stop,
    );
    _listen();
  }

  void _listen() {
    _subscription ??= _shakes?.listen((_) => onShake(), onError: (_) {});
  }

  void _stop() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void dispose() {
    _stop();
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
