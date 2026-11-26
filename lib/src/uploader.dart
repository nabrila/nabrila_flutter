import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'envelope.dart';
import 'report_status.dart';

/// Why an upload failed. The UI maps each one to a message for the tester.
enum UploadFailure {
  invalidKey,
  suspended,
  tooLarge,
  quota,
  rateLimited,
  badEnvelope,
  network,
  server,
}

class UploadException implements Exception {
  UploadException(
    this.failure, [
    this.statusCode,
    this.retryAfter,
    this.permanent = false,
  ]);

  final UploadFailure failure;
  final int? statusCode;

  /// How long the server asked to wait (`Retry-After`), if it said.
  final Duration? retryAfter;

  /// True only when the Nabrila API itself refused the report (a JSON
  /// `{"error": …}` with a code that never changes on a retry). A bare 401,
  /// 403 or 400 from a hotel login page, a proxy or a firewall is not
  /// permanent: the report waits until it reaches the real server.
  final bool permanent;

  /// Whether the same bytes may succeed later.
  bool get retryable => !permanent;

  @override
  String toString() => 'UploadException($failure, $statusCode)';
}

class UploadResult {
  UploadResult({
    required this.id,
    required this.link,
    required this.expiresAt,
    required this.keyStoredOnServer,
    required this.keyCustodyFailed,
  });

  final String id;

  /// `https://nabrila.com/r/<id>#k=<key>`. The key never reaches the server
  /// on the free plan.
  final String link;
  final String? expiresAt;

  /// True when the plan keeps the key (`keyCustody: "server"`) and it was stored.
  final bool keyStoredOnServer;

  /// True when the plan keeps the key but the second step failed. The link
  /// still opens the report.
  final bool keyCustodyFailed;
}

const Duration _timeout = Duration(seconds: 30);

/// Time allowed to send [bytes]: 30 seconds plus one per 16 KB, so a 2 MB
/// report still goes out over a weak 2G link (about 130 kbps) instead of
/// being cut and sent again from the start.
Duration uploadTimeout(int bytes) =>
    _timeout + Duration(milliseconds: bytes * 1000 ~/ 16384);

/// `POST {endpoint}/api/v1/reports`, then `PUT .../{id}/key` if the server
/// asks for custody and does not have the key yet (architecture.md,
/// sections 3.3 and 3.6). The server answers a repeat of the same envelope
/// with the report it already made (200 instead of 201), so sending again
/// after a cut never makes a second report.
Future<UploadResult> uploadReport({
  required http.Client client,
  required String endpoint,
  required String appKey,
  required SealedReport sealed,
}) async {
  final response = await _send(
    client,
    'POST',
    Uri.parse('$endpoint/api/v1/reports'),
    appKey,
    sealed.envelope,
    uploadTimeout(sealed.envelope.length),
    // Lets whoever holds the link tell the tester later what became of
    // the report, without the server ever seeing the key.
    headers: {statusHashHeader: await statusHashOf(sealed.key)},
  );
  if (response.statusCode != 201 && response.statusCode != 200) {
    throw _failure(response);
  }

  // A 2xx that is not our JSON (a captive portal's login page, a proxy)
  // means the report never reached Nabrila: it is retried.
  final Map<String, Object?> json;
  try {
    json = (jsonDecode(utf8.decode(response.bodyBytes)) as Map)
        .cast<String, Object?>();
  } on Object {
    throw UploadException(UploadFailure.server, response.statusCode);
  }
  final id = json['id'];
  if (id is! String || id.isEmpty) {
    throw UploadException(UploadFailure.server, response.statusCode);
  }
  final expiresAt = json['expiresAt'];
  final serverKeeps = json['keyCustody'] == 'server';
  var stored = false;
  var failed = false;
  if (serverKeeps && json['keyStored'] == true) {
    stored = true;
  } else if (serverKeeps) {
    stored = await storeKey(
      client: client,
      endpoint: endpoint,
      appKey: appKey,
      id: id,
      key: sealed.key,
    );
    failed = !stored;
  }
  return UploadResult(
    id: id,
    link: buildShareLink(id: id, key: sealed.key, origin: endpoint),
    expiresAt: expiresAt is String ? expiresAt : null,
    keyStoredOnServer: stored,
    keyCustodyFailed: failed,
  );
}

/// `PUT .../{id}/key`: gives the key to the plans that keep it. Also used
/// later on its own when the first try failed.
Future<bool> storeKey({
  required http.Client client,
  required String endpoint,
  required String appKey,
  required String id,
  required Uint8List key,
}) async {
  try {
    final response = await _send(
      client,
      'PUT',
      Uri.parse('$endpoint/api/v1/reports/${Uri.encodeComponent(id)}/key'),
      appKey,
      key,
      _timeout,
    );
    return response.statusCode == 204;
  } on UploadException {
    return false;
  }
}

/// One request that is really cancelled when it runs out of time: a plain
/// `.timeout` would leave the old upload running and the retry would share
/// the weak link with it.
Future<http.Response> _send(
  http.Client client,
  String method,
  Uri url,
  String appKey,
  List<int> body,
  Duration timeout, {
  Map<String, String> headers = const {},
  String contentType = 'application/octet-stream',
}) async {
  final abort = Completer<void>();
  final timer = Timer(timeout, () {
    if (!abort.isCompleted) abort.complete();
  });
  final request = http.AbortableRequest(method, url, abortTrigger: abort.future)
    ..headers['Authorization'] = 'Bearer $appKey'
    ..headers['Content-Type'] = contentType
    ..headers.addAll(headers)
    ..bodyBytes = body;
  try {
    final streamed = await client.send(request).timeout(timeout);
    return await http.Response.fromStream(streamed).timeout(timeout);
  } on Exception {
    throw UploadException(UploadFailure.network);
  } finally {
    timer.cancel();
    if (!abort.isCompleted) abort.complete();
  }
}

/// Codes of the Nabrila API that a retry never changes.
const Map<String, UploadFailure> _permanent = {
  'invalid_key': UploadFailure.invalidKey,
  'suspended': UploadFailure.suspended,
  'too_large': UploadFailure.tooLarge,
  'bad_envelope': UploadFailure.badEnvelope,
  'quota': UploadFailure.quota,
};

UploadException _failure(http.Response response) {
  // The contract says `{"error": "<code>"}`; `reason` is accepted too.
  String? code;
  try {
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is Map) {
      final value = body['error'] ?? body['reason'];
      if (value is String) code = value;
    }
  } on Object {
    code = null;
  }
  final status = response.statusCode;
  final seconds = int.tryParse(response.headers['retry-after']?.trim() ?? '');
  final retryAfter = seconds == null || seconds < 0
      ? null
      : Duration(seconds: seconds.clamp(0, 3600));
  final permanent = _permanent[code];
  if (permanent != null) {
    return UploadException(permanent, status, retryAfter, true);
  }
  // Anything else did not come from the API's own refusals: it is told as
  // a server problem and retried.
  final failure = status == 429 || code == 'rate_limited'
      ? UploadFailure.rateLimited
      : UploadFailure.server;
  return UploadException(failure, status, retryAfter);
}

/// Sends [body] as JSON with the app key and returns the response, or
/// throws [UploadException] on a network failure or timeout.
Future<http.Response> sendJson(
  http.Client client,
  String method,
  Uri url,
  String appKey, [
  Object? body,
]) => _send(
  client,
  method,
  url,
  appKey,
  body == null ? const [] : utf8.encode(jsonEncode(body)),
  const Duration(seconds: 20),
  contentType: 'application/json',
);
