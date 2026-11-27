import 'dart:convert';

import 'events.dart' show clip;

/// Placeholder that replaces anything sensitive before it leaves memory.
const String redacted = '[REDACTED]';

const int _maxBodyPreview = 8000;
const int _maxParsedBody = 200000;
const int _maxHeaders = 50;
const int _maxHeaderValue = 1000;

/// A name that contains any of these is sensitive.
const List<String> _sensitiveParts = [
  'authorization',
  'cookie',
  'token',
  'password',
  'passwd',
  'passcode',
  'secret',
  'api_key',
  'api-key',
  'apikey',
  'private_key',
  'private-key',
  'privatekey',
  'access_key',
  'access-key',
  'accesskey',
  'session',
  'credential',
  'signature',
  'jwt',
  'bearer',
  'csrf',
  'xsrf',
  'x-auth',
];

/// Short names that are sensitive only as a whole word of the name, so
/// `pin_code` is redacted and `shipping` is not: one-time codes, card
/// codes and national IDs (Brazil, Argentina, Peru, Mexico, the US).
final RegExp _sensitiveWord = RegExp(
  r'^(otp|cvv|cvc|cpf|dni|curp|pin|ssn|sig)\d*$',
);

/// Query names that carry a credential only in a URL: the OAuth `code` of
/// a callback and the `key` of APIs that take it there.
const Set<String> _sensitiveQueryNames = {'code', 'key'};

/// Headers whose value is a URL: they are cleaned like one, not dropped.
const Set<String> _urlHeaders = {'location', 'content-location', 'referer'};

/// True for names like `Authorization`, `access_token`, `x-api-key`,
/// `JSESSIONID`, `cvv` or the `X-Amz-Signature` of a presigned URL.
bool isSensitiveName(String name) {
  final lower = name.toLowerCase();
  if (_sensitiveParts.any(lower.contains)) return true;
  final words = name
      .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .toLowerCase()
      .split(RegExp('[^a-z0-9]+'));
  return words.any(_sensitiveWord.hasMatch);
}

/// Drops user info and fragment, and redacts sensitive query values.
String sanitizeUrl(Uri uri) {
  final query = uri.hasQuery
      ? uri.query.split('&').map((p) => _redactPair(p, query: true)).join('&')
      : null;
  final origin = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  ).toString();
  // Built by hand: `Uri(path:)` would escape the brackets of the marker.
  final base = '$origin${uri.path.split('/').map(_redactSegment).join('/')}';
  return query == null ? base : '$base?$query';
}

final RegExp _longToken = RegExp(r'^[A-Za-z0-9_-]{24,}$');

/// A canonical UUID: a record id, what makes a request reproducible.
final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// A path segment that is a credential or a person, not a route: a JWT
/// (`/reset/eyJ…`), a long mixed token (reset links, API keys) or an email.
/// `/api/v1/users/42/orders` and `/orders/<uuid>` stay as they are (SOL #3).
String _redactSegment(String segment) {
  String text;
  try {
    text = Uri.decodeComponent(segment);
  } on Object {
    text = segment;
  }
  final token =
      _longToken.hasMatch(text) &&
      !_uuid.hasMatch(text) &&
      text.contains(RegExp('[0-9]')) &&
      text.contains(RegExp('[A-Za-z]'));
  return token ||
          text.startsWith('eyJ') && text.contains('.') ||
          _email.hasMatch(text)
      ? redacted
      : segment;
}

/// `name=value` with the value redacted when the name is sensitive. A name
/// that is not valid percent-encoding is judged as written.
String _redactPair(String pair, {bool query = false}) {
  final eq = pair.indexOf('=');
  if (eq < 0) return pair;
  final raw = pair.substring(0, eq);
  String name;
  try {
    name = Uri.decodeQueryComponent(raw);
  } on Object {
    name = raw;
  }
  final sensitive =
      isSensitiveName(name) ||
      (query && _sensitiveQueryNames.contains(name.toLowerCase()));
  return sensitive ? '$raw=$redacted' : pair;
}

/// Sensitive headers become [redacted]; at most 50 are kept. A redirect's
/// `location` keeps its URL without the secrets in it.
Map<String, String> sanitizeHeaders(Map<String, Iterable<String>> headers) {
  final out = <String, String>{};
  for (final entry in headers.entries) {
    if (out.length >= _maxHeaders) break;
    final name = entry.key.toLowerCase();
    final joined = entry.value.join(', ');
    final value = isSensitiveName(name)
        ? redacted
        : _urlHeaders.contains(name)
        ? _sanitizeUrlText(joined)
        : redactText(joined);
    out[name] = clip(value, _maxHeaderValue);
  }
  return out;
}

String _sanitizeUrlText(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return redactText(value);
  try {
    return sanitizeUrl(uri);
  } on Object {
    return redactText(value);
  }
}

/// Preview of a body with sensitive JSON keys and form fields redacted.
/// Opt-in only: the integrations never call this unless `captureBodies`.
/// A body that is not JSON or a form (or JSON cut short because it is too
/// large) is still cleaned with [redactText].
String? sanitizeBody(String? body) {
  if (body == null || body.isEmpty) return null;
  final text = clip(body, _maxParsedBody);
  String result;
  try {
    result = jsonEncode(_redactJson(jsonDecode(text)));
  } on Object {
    result = _looksLikeForm(text)
        ? text.split('&').map(_redactPair).join('&')
        : redactText(text);
  }
  return clip(result, _maxBodyPreview);
}

bool _looksLikeForm(String text) =>
    text.contains('=') && !text.contains(RegExp(r'\s'));

Object? _redactJson(Object? value) {
  if (value is Map) {
    return {
      for (final e in value.entries)
        '${e.key}': isSensitiveName('${e.key}')
            ? redacted
            : _redactJson(e.value),
    };
  }
  if (value is List) return value.map(_redactJson).toList();
  if (value is String) return redactText(value);
  return value;
}

final RegExp _authScheme = RegExp(
  r'\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+/]{8,}=*',
  caseSensitive: false,
);

final RegExp _jwt = RegExp(
  r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*',
);

final RegExp _email = RegExp(
  r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}',
);

/// `name: value`, `name=value` and `"name": "value"`, quoted or not.
final RegExp _pair = RegExp(
  r'''(["']?)([A-Za-z0-9_.\-]{2,64})\1(\s*[:=]\s*)("(?:[^"\\]|\\.)*"|'[^']*'|[^\s&,;"'}\]]+)''',
);

/// Redacts what looks like a secret in free text (a log line, a body that
/// is not JSON): `Bearer …` and `Basic …` credentials, JWTs, emails, and the value
/// of any `name=value` or `name: value` whose name is sensitive.
String redactText(String text) {
  if (text.isEmpty) return text;
  return text
      .replaceAllMapped(_authScheme, (m) => '${m[1]} $redacted')
      .replaceAll(_jwt, redacted)
      .replaceAllMapped(_pair, (m) {
        if (!isSensitiveName(m[2]!)) return m[0]!;
        final value = m[4]!;
        final quote = value.startsWith('"')
            ? '"'
            : value.startsWith("'")
            ? "'"
            : '';
        return '${m[1]}${m[2]}${m[1]}${m[3]}$quote$redacted$quote';
      })
      .replaceAll(_email, redacted);
}

/// Whether a `Content-Type` is text worth previewing (JSON, forms, XML,
/// GraphQL, plain text). Images, video, PDFs and other binaries are not.
bool isTextContentType(String? value) {
  if (value == null) return false;
  final type = value.toLowerCase();
  return type.startsWith('text/') ||
      type.contains('json') ||
      type.contains('x-www-form-urlencoded') ||
      type.contains('xml') ||
      type.contains('graphql') ||
      type.contains('javascript');
}
