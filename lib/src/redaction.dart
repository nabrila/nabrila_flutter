import 'dart:convert';

/// Placeholder that replaces anything sensitive before it leaves memory.
const String redacted = '[REDACTED]';

const int _maxBodyPreview = 8000;
const int _maxHeaders = 50;
const int _maxHeaderValue = 1000;

const List<String> _sensitiveParts = [
  'authorization',
  'cookie',
  'token',
  'password',
  'passwd',
  'secret',
  'api_key',
  'api-key',
  'apikey',
  'session',
  'credential',
  'signature',
  'jwt',
  'x-auth',
];

/// True for names like `Authorization`, `access_token`, `x-api-key`, `JSESSIONID` or the
/// `X-Amz-Signature` of a presigned URL.
bool isSensitiveName(String name) {
  final lower = name.toLowerCase();
  return _sensitiveParts.any(lower.contains);
}

/// Drops user info and fragment, and redacts sensitive query values.
String sanitizeUrl(Uri uri) {
  final query = uri.hasQuery
      ? uri.query.split('&').map(_redactPair).join('&')
      : null;
  final clean = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  );
  final base = clean.toString();
  return query == null ? base : '$base?$query';
}

String _redactPair(String pair) {
  final eq = pair.indexOf('=');
  if (eq < 0) return pair;
  final name = Uri.decodeQueryComponent(pair.substring(0, eq));
  return isSensitiveName(name) ? '${pair.substring(0, eq)}=$redacted' : pair;
}

/// Sensitive headers become [redacted]; at most 50 are kept.
Map<String, String> sanitizeHeaders(Map<String, Iterable<String>> headers) {
  final out = <String, String>{};
  for (final entry in headers.entries) {
    if (out.length >= _maxHeaders) break;
    final value = isSensitiveName(entry.key)
        ? redacted
        : _clipValue(entry.value.join(', '));
    out[entry.key.toLowerCase()] = value;
  }
  return out;
}

String _clipValue(String value) => value.length > _maxHeaderValue
    ? value.substring(0, _maxHeaderValue)
    : value;

/// Preview of a body with sensitive JSON keys and form fields redacted.
/// Opt-in only: the integrations never call this unless `captureBodies`.
String? sanitizeBody(String? body) {
  if (body == null || body.isEmpty) return null;
  final text = body.length > 200000 ? body.substring(0, 200000) : body;
  String result;
  try {
    result = jsonEncode(_redactJson(jsonDecode(text)));
  } on FormatException {
    result = _looksLikeForm(text)
        ? text.split('&').map(_redactPair).join('&')
        : text;
  }
  return result.length > _maxBodyPreview
      ? result.substring(0, _maxBodyPreview)
      : result;
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
  return value;
}
