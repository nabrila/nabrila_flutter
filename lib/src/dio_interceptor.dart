import 'dart:convert';

import 'package:dio/dio.dart';

import 'redaction.dart';
import 'runtime.dart';

const String _watchKey = 'nabrila_stopwatch';
const String _sessionKey = 'nabrila_session';

/// Records each Dio call into the ring buffer.
///
/// By default it keeps only method, sanitized URL, status, duration and sizes.
/// With [captureBodies] it also keeps headers and body previews, after
/// redacting `authorization`, `cookie`, `token`, `password`, `secret` and
/// `api_key` values. Bytes, files and non-text bodies are left out. While
/// the SDK is disabled it does nothing.
class NabrilaDioInterceptor extends Interceptor {
  NabrilaDioInterceptor({this.captureBodies = false});

  final bool captureBodies;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_watchKey] = Stopwatch()..start();
    options.extra[_sessionKey] = NabrilaRuntime.current?.session;
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _record(response.requestOptions, response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(err.requestOptions, err.response);
    handler.next(err);
  }

  void _record(RequestOptions options, Response<dynamic>? response) {
    final runtime = NabrilaRuntime.current;
    final watch = options.extra[_watchKey];
    if (runtime == null || watch is! Stopwatch) return;
    final length = int.tryParse(
      response?.headers.value(Headers.contentLengthHeader) ?? '',
    );
    runtime.recordHttp(
      method: options.method,
      url: options.uri,
      statusCode: response?.statusCode,
      duration: watch.elapsed,
      reqBytes: int.tryParse(
        options.headers[Headers.contentLengthHeader]?.toString() ?? '',
      ),
      resBytes: length,
      captureBodies: captureBodies,
      startedIn: options.extra[_sessionKey] as int?,
      reqHeaders: options.headers.map((k, v) => MapEntry(k, ['$v'])),
      resHeaders: response?.headers.map,
      reqBody: captureBodies ? _text(options.data, options.contentType) : null,
      resBody: captureBodies
          ? _text(
              response?.data,
              response?.headers.value(Headers.contentTypeHeader),
            )
          : null,
    );
  }

  /// A text preview of [data], or null for bytes, files, streams and any
  /// body whose [contentType] is not text: a photo is never serialized,
  /// and its first bytes (EXIF, location) never reach the report.
  String? _text(Object? data, String? contentType) {
    if (data == null) return null;
    if (contentType != null && !isTextContentType(contentType)) return null;
    if (data is String) return data;
    if (data is! Map && data is! List) return null;
    if (data is List<int>) return null;
    try {
      return jsonEncode(data);
    } on Object {
      return null;
    }
  }
}
