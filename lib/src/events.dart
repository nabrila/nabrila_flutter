/// Event kinds of `ReportManifestV1` (architecture.md, section 3.4).
library;

/// Ring buffer capacity: the viewer keeps the last 150 events too.
const int maxEvents = 150;

const int _maxLogMessage = 4000;
const int _maxStackTrace = 16000;
const int _maxRoute = 300;
const int _maxUrl = 2000;
const int _maxHint = 80;

/// [value] cut to at most [max] UTF-16 units, never in the middle of a
/// character: half an emoji is not valid Unicode and breaks the viewer.
String clip(String value, int max) {
  if (value.length <= max) return value;
  var end = max;
  if (end > 0 && _isHighSurrogate(value.codeUnitAt(end - 1))) end--;
  return value.substring(0, end);
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// A recorded event. [fields] already hold plain JSON values; [toJson] adds
/// `kind` and `tMs` (milliseconds since [origin], never negative).
class RecordedEvent {
  RecordedEvent._(this.at, this.kind, this.fields);

  final DateTime at;
  final String kind;
  final Map<String, Object?> fields;

  /// [xNorm] and [yNorm] are relative to the screen, `0..1`. Both are null
  /// for a tap inside a `NabrilaMask`: where a finger lands on a masked PIN
  /// pad tells the PIN.
  factory RecordedEvent.tap({
    required DateTime at,
    required double? xNorm,
    required double? yNorm,
    required String? targetHint,
  }) => RecordedEvent._(at, 'tap', {
    'xNorm': xNorm?.clamp(0.0, 1.0),
    'yNorm': yNorm?.clamp(0.0, 1.0),
    'targetHint': targetHint == null ? null : clip(targetHint, _maxHint),
  });

  factory RecordedEvent.navigation({
    required DateTime at,
    required String action,
    required String? fromRoute,
    required String toRoute,
  }) => RecordedEvent._(at, 'navigation', {
    'action': action,
    if (fromRoute != null) 'fromRoute': clip(fromRoute, _maxRoute),
    'toRoute': clip(toRoute, _maxRoute),
  });

  /// [level] is one of `debug`, `info`, `warn`, `error`.
  factory RecordedEvent.log({
    required DateTime at,
    required String level,
    required String message,
    String? stackTrace,
  }) => RecordedEvent._(at, 'log', {
    'level': level,
    'message': clip(message, _maxLogMessage),
    if (stackTrace != null) 'stackTrace': clip(stackTrace, _maxStackTrace),
  });

  /// Everything in [fields] must already be sanitized (see `redaction.dart`).
  factory RecordedEvent.http({
    required DateTime at,
    required String method,
    required String sanitizedUrl,
    required int? statusCode,
    required int durationMs,
    int? reqBytes,
    int? resBytes,
    Map<String, String>? reqHeaders,
    Map<String, String>? resHeaders,
    String? reqBodyPreview,
    String? resBodyPreview,
  }) => RecordedEvent._(at, 'http', {
    'method': clip(method, 16),
    'sanitizedUrl': clip(sanitizedUrl, _maxUrl),
    'statusCode': ?statusCode,
    'durationMs': durationMs < 0 ? 0 : durationMs,
    'reqBytes': ?reqBytes,
    'resBytes': ?resBytes,
    if (reqHeaders != null && reqHeaders.isNotEmpty) 'reqHeaders': reqHeaders,
    if (resHeaders != null && resHeaders.isNotEmpty) 'resHeaders': resHeaders,
    'reqBodyPreview': ?reqBodyPreview,
    'resBodyPreview': ?resBodyPreview,
  });

  Map<String, Object?> toJson(DateTime origin) {
    final ms = at.difference(origin).inMilliseconds;
    return {'kind': kind, 'tMs': ms < 0 ? 0 : ms, ...fields};
  }
}

/// In-memory ring buffer. Nothing is ever written to disk.
class EventBuffer {
  EventBuffer({this.capacity = maxEvents});

  final int capacity;
  final List<RecordedEvent> _events = [];

  int get length => _events.length;

  void add(RecordedEvent event) {
    _events.add(event);
    if (_events.length > capacity) {
      _events.removeRange(0, _events.length - capacity);
    }
  }

  List<RecordedEvent> snapshot() => List.unmodifiable(_events);

  void clear() => _events.clear();

  /// The instant `tMs` counts from, or null while empty.
  DateTime? get origin => _events.isEmpty ? null : _events.first.at;

  /// Chronological JSON; `tMs` counts from the oldest kept event.
  List<Map<String, Object?>> toJson() {
    if (_events.isEmpty) return const [];
    final origin = _events.first.at;
    return [for (final e in _events) e.toJson(origin)];
  }
}
