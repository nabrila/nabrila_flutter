import 'events.dart';
import 'redaction.dart';

const int maxNoteLength = 1000;

/// Version of this SDK, sent as `app.sdkVersion`.
const String sdkVersion = '0.2.0';

/// The git commit the build came from, set with
/// `--dart-define=NABRILA_COMMIT=$(git rev-parse HEAD)`; empty when unset.
const String buildCommit = String.fromEnvironment('NABRILA_COMMIT');

final RegExp _commitRx = RegExp(r'^[0-9a-f]{7,40}$');

/// [value] as a lowercase git commit id, or null when it is not one.
String? commitOf(String value) {
  final commit = value.trim().toLowerCase();
  return _commitRx.hasMatch(commit) ? commit : null;
}

class AppInfo {
  const AppInfo({
    required this.appName,
    required this.appVersion,
    required this.buildNumber,
    this.commit = '',
  });

  final String appName;
  final String appVersion;
  final String buildNumber;

  /// The commit the build came from ([buildCommit]); sent only when valid.
  final String commit;
}

class DeviceInfo {
  const DeviceInfo({
    required this.platform,
    required this.osVersion,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.pixelRatio,
    required this.textScaleFactor,
    required this.locale,
  });

  final String platform;
  final String osVersion;
  final double logicalWidth;
  final double logicalHeight;
  final double pixelRatio;
  final double textScaleFactor;
  final String? locale;
}

/// What the person tells about the report: the kind they picked, their note
/// and the element they pointed at, if any.
class ReportInput {
  const ReportInput({this.note = '', this.kind, this.element});

  final String note;

  /// One of [reportKinds], or null when the person did not pick one.
  final String? kind;

  /// `{xNorm, yNorm, widget?, label?, source?}`, see `element_locator.dart`.
  final Map<String, Object?>? element;
}

/// The kinds a person can pick: something fails, looks wrong, shows wrong
/// data, or is an idea. A person decides it; the SDK never guesses.
const List<String> reportKinds = ['bug', 'visual', 'data', 'suggestion'];

/// Most pairs of app context kept in a report.
const int maxContextEntries = 30;
const int _maxContextKey = 40;
const int _maxContextValue = 200;

/// Adds [key] = [value] to [context] the way a report carries it: text,
/// clipped, at most [maxContextEntries] pairs, and the value of a key that
/// sounds secret (`token`, `password`…) replaced by `[REDACTED]`. A null
/// [value] removes the key.
void putContext(Map<String, String> context, String key, Object? value) {
  final name = clip(key.trim(), _maxContextKey);
  if (name.isEmpty) return;
  if (value == null) {
    context.remove(name);
    return;
  }
  if (!context.containsKey(name) && context.length >= maxContextEntries) {
    return;
  }
  context[name] = isSensitiveName(name)
      ? redacted
      : clip('$value', _maxContextValue);
}

/// Builds `ReportManifestV1` (architecture.md, section 3.4).
Map<String, Object?> buildManifest({
  required DateTime capturedAt,
  required String note,
  required AppInfo app,
  required String? activeRoute,
  required DeviceInfo device,
  required EventBuffer events,
  String? kind,
  Map<String, Object?>? element,
  Map<String, String> context = const {},
}) {
  final trimmed = note.trim();
  return {
    'schemaVersion': 1,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    if (trimmed.isNotEmpty) 'note': clip(trimmed, maxNoteLength),
    if (kind != null && reportKinds.contains(kind)) 'kind': kind,
    'element': ?element,
    if (context.isNotEmpty) 'context': Map.of(context),
    'app': {
      'appName': clip(app.appName, 100),
      'appVersion': clip(app.appVersion, 40),
      'buildNumber': clip(app.buildNumber, 40),
      'sdkVersion': sdkVersion,
      if (activeRoute != null) 'activeRoute': clip(activeRoute, 300),
      'commit': ?commitOf(app.commit),
    },
    'device': {
      'platform': clip(device.platform, 40),
      'osVersion': clip(device.osVersion, 80),
      'logicalWidth': device.logicalWidth,
      'logicalHeight': device.logicalHeight,
      'pixelRatio': device.pixelRatio,
      'textScaleFactor': device.textScaleFactor,
      if (device.locale != null) 'locale': clip(device.locale!, 20),
    },
    'events': events.toJson(),
  };
}
