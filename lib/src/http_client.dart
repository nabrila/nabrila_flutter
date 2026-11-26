import 'dart:convert';

import 'package:http/http.dart' as http;

import 'runtime.dart';

/// Wraps a `package:http` client and records each call into the ring buffer.
///
/// By default it keeps only method, sanitized URL, status, duration and sizes.
/// With [captureBodies] it also keeps headers and body previews, after
/// redacting `authorization`, `cookie`, `token`, `password`, `secret` and
/// `api_key` values. While the SDK is disabled it just forwards the call.
class NabrilaHttpClient extends http.BaseClient {
  NabrilaHttpClient(this._inner, {this.captureBodies = false});

  final http.Client _inner;
  final bool captureBodies;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final runtime = NabrilaRuntime.current;
    if (runtime == null) return _inner.send(request);

    final watch = Stopwatch()..start();
    final reqBody = captureBodies && request is http.Request
        ? request.body
        : null;
    final reqHeaders = {
      for (final e in request.headers.entries) e.key: [e.value],
    };

    http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (_) {
      runtime.recordHttp(
        method: request.method,
        url: request.url,
        statusCode: null,
        duration: watch.elapsed,
        reqBytes: request.contentLength,
        captureBodies: captureBodies,
        reqHeaders: reqHeaders,
        reqBody: reqBody,
      );
      rethrow;
    }

    String? resBody;
    var resBytes = response.contentLength;
    if (captureBodies) {
      final bytes = await response.stream.toBytes();
      resBody = utf8.decode(bytes, allowMalformed: true);
      resBytes = bytes.length;
      response = http.StreamedResponse(
        http.ByteStream.fromBytes(bytes),
        response.statusCode,
        contentLength: bytes.length,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    }
    runtime.recordHttp(
      method: request.method,
      url: request.url,
      statusCode: response.statusCode,
      duration: watch.elapsed,
      reqBytes: request.contentLength,
      resBytes: resBytes,
      captureBodies: captureBodies,
      reqHeaders: reqHeaders,
      resHeaders: {
        for (final e in response.headers.entries) e.key: [e.value],
      },
      reqBody: reqBody,
      resBody: resBody,
    );
    return response;
  }

  @override
  void close() => _inner.close();
}
