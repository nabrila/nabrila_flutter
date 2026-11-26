import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'delivery.dart';
import 'events.dart';
import 'manifest.dart';
import 'redaction.dart';
import 'remote_config.dart';
import 'report_status.dart';
import 'replay/replay_recorder.dart';

const String defaultEndpoint = 'https://nabrila.com';

/// Live state of an enabled SDK: credentials, ring buffer and active route.
/// It exists only when `Nabrila.run` was called with `enabled: true`.
class NabrilaRuntime {
  NabrilaRuntime({
    required this.appKey,
    String endpoint = defaultEndpoint,
    http.Client? client,
    DateTime Function()? clock,
    Future<Directory?> Function()? storageDir,
  }) : endpoint = _trimSlash(endpoint),
       client = client ?? http.Client(),
       _clock = clock ?? _MonotonicClock().now,
       _wallClock = clock ?? DateTime.now,
       _storageDir = storageDir;

  /// The enabled runtime, or null while the SDK is off. Not exported.
  static NabrilaRuntime? current;

  final String appKey;
  final String endpoint;
  final http.Client client;

  /// Time of events and replay frames. It never jumps when the phone's
  /// clock is changed, so a tap and the frame that shows it stay in order.
  final DateTime Function() _clock;

  /// Time of retries, which outlive the app and are kept on disk.
  final DateTime Function() _wallClock;
  final Future<Directory?> Function()? _storageDir;
  final EventBuffer buffer = EventBuffer();

  /// Pairs the app adds with `Nabrila.setContext`, sent with every report.
  final Map<String, String> context = {};

  /// Whether shaking the phone opens the capture flow.
  bool shake = true;

  /// Sends reports and keeps the ones that could not go out yet.
  late final ReportDelivery delivery = ReportDelivery(
    client: client,
    endpoint: endpoint,
    appKey: appKey,
    clock: _wallClock,
    storageDir: _storageDir,
    onSent: (result, key, endpoint, appKey) => unawaited(
      loop.remember(
        id: result.id,
        key: key,
        endpoint: endpoint,
        appKey: appKey,
        expiresAt: result.expiresAt,
      ),
    ),
  );

  /// What the team said about the reports this phone sent.
  late final ReportLoop loop = ReportLoop(
    client: client,
    storageDir: _storageDir ?? defaultStorageDir,
    clock: _wallClock,
  );

  /// The remote replay switch.
  late final RemoteConfig config = RemoteConfig(
    client: client,
    endpoint: endpoint,
    appKey: appKey,
    storageDir: _storageDir ?? defaultStorageDir,
    clock: _wallClock,
  );

  /// Keeps the last moments as masked pictures; null when replay is off.
  ReplayRecorder? replay;

  /// Route name set by the navigator observer, if the app uses it.
  String? activeRoute;

  DateTime now() => _clock();

  void setContext(String key, Object? value) => putContext(context, key, value);

  void recordTap({
    required double xNorm,
    required double yNorm,
    required String? targetHint,
  }) => buffer.add(
    RecordedEvent.tap(
      at: now(),
      xNorm: xNorm,
      yNorm: yNorm,
      targetHint: targetHint,
    ),
  );

  void recordNavigation({
    required String action,
    required String? fromRoute,
    required String toRoute,
  }) {
    activeRoute = toRoute;
    buffer.add(
      RecordedEvent.navigation(
        at: now(),
        action: action,
        fromRoute: fromRoute,
        toRoute: toRoute,
      ),
    );
  }

  void recordLog(String level, String message, [String? stackTrace]) =>
      buffer.add(
        RecordedEvent.log(
          at: now(),
          level: level,
          message: message,
          stackTrace: stackTrace,
        ),
      );

  /// Method, sanitized URL, status, duration and sizes. Headers and body
  /// previews are included only when [captureBodies] is true, and always
  /// redacted first.
  void recordHttp({
    required String method,
    required Uri url,
    required int? statusCode,
    required Duration duration,
    int? reqBytes,
    int? resBytes,
    bool captureBodies = false,
    Map<String, Iterable<String>>? reqHeaders,
    Map<String, Iterable<String>>? resHeaders,
    String? reqBody,
    String? resBody,
  }) {
    buffer.add(
      RecordedEvent.http(
        at: now(),
        method: method.toUpperCase(),
        sanitizedUrl: sanitizeUrl(url),
        statusCode: statusCode,
        durationMs: duration.inMilliseconds,
        reqBytes: reqBytes,
        resBytes: resBytes,
        reqHeaders: captureBodies && reqHeaders != null
            ? sanitizeHeaders(reqHeaders)
            : null,
        resHeaders: captureBodies && resHeaders != null
            ? sanitizeHeaders(resHeaders)
            : null,
        reqBodyPreview: captureBodies ? sanitizeBody(reqBody) : null,
        resBodyPreview: captureBodies ? sanitizeBody(resBody) : null,
      ),
    );
  }

  static String _trimSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}

/// The wall time when it was made plus a stopwatch: steady even when the
/// phone's clock is moved.
class _MonotonicClock {
  final DateTime _base = DateTime.now();
  final Stopwatch _watch = Stopwatch()..start();

  DateTime now() => _base.add(_watch.elapsed);
}
