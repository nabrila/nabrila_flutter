import 'dart:convert';

import 'package:dio/dio.dart';

import 'runtime.dart';

const String _watchKey = 'nabrila_stopwatch';

/// Records each Dio call into the ring buffer.
///
/// By default it keeps only method, sanitized URL, status, duration and sizes.
/// With [captureBodies] it also keeps headers and body previews, after
/// redacting `authorization`, `cookie`, `token`, `password`, `secret` and
/// `api_key` values. While the SDK is disabled it does nothing.
class NabrilaDioInterceptor extends Interceptor {
  NabrilaDioInterceptor({this.captureBodies = false});

  final bool captureBodies;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_watchKey] = Stopwatch()..start();
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
      reqHeaders: options.headers.map((k, v) => MapEntry(k, ['$v'])),
      resHeaders: response?.headers.map,
      reqBody: captureBodies ? _text(options.data) : null,
      resBody: captureBodies ? _text(response?.data) : null,
    );
  }

  String? _text(Object? data) {
    if (data == null) return null;
    if (data is String) return data;
    try {
      return jsonEncode(data);
    } catch (_) {
      return null;
    }
  }
}
