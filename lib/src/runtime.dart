import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'delivery.dart';
import 'events.dart';
import 'manifest.dart';
import 'redaction.dart';
import 'remote_config.dart';
import 'report_status.dart';
import 'replay/replay_recorder.dart';

const String defaultEndpoint = 'https://nabrila.com';

/// Whether reports may go to [endpoint]: only over `https://`, except a
/// server on this machine (or the Android emulator's view of it) in a
/// [debug] build. The key of a paid plan travels in the clear otherwise.
bool isAllowedEndpoint(String endpoint, {bool debug = kDebugMode}) {
  final uri = Uri.tryParse(endpoint);
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme == 'https') return true;
  const local = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
  return debug && uri.scheme == 'http' && local.contains(uri.host);
}

/// The SDK's own HTTP client. It ignores `HttpOverrides.global`: a QA build
/// that trusts any certificate or routes through an intercepting proxy for
/// its own calls never sends the report key that way.
@visibleForTesting
http.Client sdkHttpClient() => IOClient(
  HttpOverrides.runWithHttpOverrides(HttpClient.new, _NoOverrides()),
);

class _NoOverrides extends HttpOverrides {}

/// Live state of an enabled SDK: credentials, ring buffer and active route.
/// It exists only when `Nabrila.run` was called with `enabled: true`.
class NabrilaRuntime {
  NabrilaRuntime({
    required this.appKey,
    String endpoint = defaultEndpoint,
    http.Client? client,
    DateTime Function()? clock,
    this._storageDir,
    this.keepKeyOnDevice = false,
  }) : endpoint = _trimSlash(endpoint),
       client = client ?? sdkHttpClient(),
       _clock = clock ?? _MonotonicClock().now,
       _wallClock = clock ?? DateTime.now;

  /// The enabled runtime, or null while the SDK is off. Not exported.
  static NabrilaRuntime? current;

  final String appKey;
  final String endpoint;
  final http.Client client;

  /// When true, the report key never leaves the phone, even if the server
  /// says the plan keeps it (`Nabrila.run(keepKeyOnDevice: true)`).
  final bool keepKeyOnDevice;

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
    keepKeyOnDevice: keepKeyOnDevice,
    onSent: (result, key, endpoint, appKey, verdictSecret) => unawaited(
      loop.remember(
        id: result.id,
        key: key,
        verdictSecret: verdictSecret,
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
    appVersion: _installedVersion,
  );

  /// The version of the app installed now: when it reaches the one a fix
  /// shipped in, the tester is asked whether it works.
  static Future<AppVersion?> _installedVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return (version: info.version, build: info.buildNumber);
    } on Object {
      return null;
    }
  }

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

  /// Bumped by [clearSession]. A call that started in an earlier session
  /// is dropped when it answers, so it never lands in the next person's
  /// report (SOL #4).
  int session = 0;

  /// Route name set by the navigator observer, if the app uses it.
  String? activeRoute;

  DateTime now() => _clock();

  void setContext(String key, Object? value) => putContext(context, key, value);

  /// Forgets what was recorded so far (events, the active route and the
  /// replay), for when the signed-in person changes.
  void clearSession() {
    session++;
    buffer.clear();
    activeRoute = null;
    replay?.clear();
    _console.reset();
  }

  /// Null coordinates for a tap inside a `NabrilaMask`.
  void recordTap({
    required double? xNorm,
    required double? yNorm,
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
    final to = routeName(toRoute);
    activeRoute = to;
    buffer.add(
      RecordedEvent.navigation(
        at: now(),
        action: action,
        fromRoute: fromRoute == null ? null : routeName(fromRoute),
        toRoute: to,
      ),
    );
  }

  /// Keeps a log line with what looks like a secret redacted.
  void recordLog(String level, String message, [String? stackTrace]) =>
      buffer.add(
        RecordedEvent.log(
          at: now(),
          level: level,
          message: redactText(clip(message, 4000)),
          stackTrace: stackTrace == null
              ? null
              : redactText(clip(stackTrace, 16000)),
        ),
      );

  final ConsoleFilter _console = ConsoleFilter();

  /// A line the app printed. The console dump of a Flutter error is left
  /// out: the error itself is already kept, and its dozens of lines would
  /// push the earlier events out of the buffer.
  void recordPrint(String line) {
    if (_console.keep(line)) recordLog('info', line);
  }

  /// Method, sanitized URL, status, duration and sizes. Headers and body
  /// previews are included only when [captureBodies] is true, and always
  /// redacted first. Never throws: a URL it cannot read must not break the
  /// app's own call. [startedIn] is the [session] when the call began. Returns the event, to add the response body once it
  /// has streamed (see [completeHttp]).
  RecordedEvent? recordHttp({
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
    int? startedIn,
  }) {
    if (startedIn != null && startedIn != session) return null;
    try {
      final event = RecordedEvent.http(
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
      );
      buffer.add(event);
      return event;
    } on Object catch (e) {
      debugPrint('nabrila: could not record an HTTP call: $e');
      return null;
    }
  }

  /// Adds the response body to [event] once the app has read it.
  void completeHttp(RecordedEvent event, {String? resBody, int? resBytes}) {
    try {
      final preview = sanitizeBody(resBody);
      if (preview != null) event.fields['resBodyPreview'] = preview;
      if (resBytes != null) event.fields['resBytes'] = resBytes;
    } on Object {
      // The call itself is already recorded.
    }
  }

  static String _trimSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}

/// The route name without its query or fragment: an OAuth callback's
/// `#access_token=` must never reach a report.
String routeName(String route) {
  final cut = route.indexOf(RegExp('[?#]'));
  return cut < 0 ? route : route.substring(0, cut);
}

/// Tells apart the lines a program prints from the console dump of a
/// Flutter error: in debug, `══╡ EXCEPTION CAUGHT BY … ╞══` up to its
/// closing rule and the one-line `Another exception was thrown:` after it;
/// in release, the stack frames `debugPrintStack` prints one per line.
class ConsoleFilter {
  bool _inDump = false;

  static final RegExp _frame = RegExp(r'^(#\d+\s|<asynchronous suspension>)');

  bool keep(String line) {
    if (_inDump) {
      if (_closesDump(line)) _inDump = false;
      return false;
    }
    if (line.startsWith('══╡ EXCEPTION CAUGHT BY')) {
      _inDump = true;
      return false;
    }
    return !line.startsWith('Another exception was thrown:') &&
        !_frame.hasMatch(line);
  }

  void reset() => _inDump = false;

  static bool _closesDump(String line) {
    final trimmed = line.trim();
    return trimmed.length >= 10 && trimmed.replaceAll('═', '').isEmpty;
  }
}

/// The wall time when it was made plus a stopwatch: steady even when the
/// phone's clock is moved.
class _MonotonicClock {
  final DateTime _base = DateTime.now();
  final Stopwatch _watch = Stopwatch()..start();

  DateTime now() => _base.add(_watch.elapsed);
}
