import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'redaction.dart';
import 'runtime.dart';

/// Most bytes of a body read for its preview; the rest still streams to
/// the app, untouched.
const int _maxPreviewBytes = 64 * 1024;

/// Wraps a `package:http` client and records each call into the ring buffer.
///
/// By default it keeps only method, sanitized URL, status, duration and sizes.
/// With [captureBodies] it also keeps headers and a preview of text bodies
/// (JSON, forms, XML, plain text), after redacting `authorization`,
/// `cookie`, `token`, `password`, `secret` and `api_key` values. Binary
/// bodies (images, files) are never read as text, and the response still
/// streams to the app as it arrives. While the SDK is disabled it just
/// forwards the call.
class NabrilaHttpClient extends http.BaseClient {
  NabrilaHttpClient(this._inner, {this.captureBodies = false});

  final http.Client _inner;
  final bool captureBodies;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final runtime = NabrilaRuntime.current;
    if (runtime == null) return _inner.send(request);

    final watch = Stopwatch()..start();
    final session = runtime.session;
    final reqBody = captureBodies ? _requestPreview(request) : null;
    final reqHeaders = {
      for (final e in request.headers.entries) e.key: [e.value],
    };

    final http.StreamedResponse response;
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
        startedIn: session,
      );
      rethrow;
    }

    final event = runtime.recordHttp(
      method: request.method,
      url: request.url,
      statusCode: response.statusCode,
      duration: watch.elapsed,
      reqBytes: request.contentLength,
      resBytes: response.contentLength,
      captureBodies: captureBodies,
      reqHeaders: reqHeaders,
      resHeaders: {
        for (final e in response.headers.entries) e.key: [e.value],
      },
      reqBody: reqBody,
      startedIn: session,
    );
    if (!captureBodies ||
        event == null ||
        !isTextContentType(response.headers['content-type'])) {
      return response;
    }
    return _teed(response, (preview, total) {
      runtime.completeHttp(
        event,
        resBody: utf8.decode(preview, allowMalformed: true),
        resBytes: total,
      );
    });
  }

  @override
  void close() => _inner.close();
}

/// The start of a text request body, or null for a binary or unknown one.
/// The request itself is never changed.
String? _requestPreview(http.BaseRequest request) {
  try {
    if (request is! http.Request) return null;
    if (!isTextContentType(request.headers['content-type'])) return null;
    final bytes = request.bodyBytes;
    return utf8.decode(
      bytes.length > _maxPreviewBytes
          ? bytes.sublist(0, _maxPreviewBytes)
          : bytes,
      allowMalformed: true,
    );
  } on Object {
    return null;
  }
}

/// [response] with a stream that hands every chunk on as it arrives and
/// copies the first [_maxPreviewBytes] aside; [done] gets them when the
/// body ends.
http.StreamedResponse _teed(
  http.StreamedResponse response,
  void Function(Uint8List preview, int total) done,
) {
  final preview = BytesBuilder();
  var total = 0;
  final stream = response.stream.transform(
    StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        total += chunk.length;
        final room = _maxPreviewBytes - preview.length;
        if (room > 0) {
          preview.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
        }
        sink.add(chunk);
      },
      handleDone: (sink) {
        done(preview.takeBytes(), total);
        sink.close();
      },
    ),
  );
  return http.StreamedResponse(
    http.ByteStream(stream),
    response.statusCode,
    contentLength: response.contentLength,
    request: response.request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}
