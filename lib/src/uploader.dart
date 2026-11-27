import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'envelope.dart';
import 'manifest.dart' show sdkVersion;
import 'report_status.dart';

/// Why an upload failed. The UI maps each one to a message for the tester.
enum UploadFailure {
  invalidKey,
  suspended,
  tooLarge,
  quota,
  planLimit,
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
    this.keyToken,
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

  /// The one-time permission the server gave this upload to store its key
  /// (`keyToken` of the `201`), kept for a later retry of the key.
  final String? keyToken;
}

/// Header that proves a key upload belongs to the report it names.
const String keyTokenHeader = 'X-Nabrila-Key-Token';

const Duration _timeout = Duration(seconds: 30);

/// Longest silence allowed while sending or receiving: a link that stops
/// moving is cut then, however long the whole upload may take.
const Duration idleTimeout = Duration(seconds: 30);

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
///
/// With [keepKeyOnDevice] the key is never sent, whatever the server says.
/// The key also stays when the server asks for it without a `keyToken`.
Future<UploadResult> uploadReport({
  required http.Client client,
  required String endpoint,
  required String appKey,
  required SealedReport sealed,
  bool keepKeyOnDevice = false,
  Duration idle = idleTimeout,
  @visibleForTesting Duration? total,
  @visibleForTesting Duration? ceiling,
}) async {
  final response = await _send(
    client,
    'POST',
    Uri.parse('$endpoint/api/v1/reports'),
    appKey,
    sealed.envelope,
    total ?? uploadTimeout(sealed.envelope.length),
    idle: idle,
    ceiling: ceiling,
    // Lets whoever holds the link tell the tester later what became of
    // the report, without the server ever seeing the key.
    headers: {
      statusHashHeader: await statusHashOf(sealed.key),
      // Only the phone can answer later whether the fix works (D34).
      if (sealed.verdictSecret != null)
        verdictHashHeader: await verdictHashOf(sealed.verdictSecret!),
    },
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
  final serverKeeps = json['keyCustody'] == 'server' && !keepKeyOnDevice;
  final token = json['keyToken'];
  final keyToken = token is String && token.isNotEmpty ? token : null;
  var stored = false;
  var failed = false;
  var refused = false;
  if (serverKeeps && json['keyStored'] == true) {
    stored = true;
  } else if (serverKeeps && keyToken == null) {
    debugPrint(
      'nabrila: the server asked for the key of $id without a keyToken; '
      'the key stays on the phone.',
    );
    failed = true;
  } else if (serverKeeps) {
    final outcome = await storeKey(
      client: client,
      endpoint: endpoint,
      appKey: appKey,
      id: id,
      key: sealed.key,
      keyToken: keyToken!,
    );
    stored = outcome == KeyUpload.stored;
    failed = !stored;
    // A refusal is final: the token is dropped so nobody retries it.
    if (outcome == KeyUpload.refused) refused = true;
  }
  return UploadResult(
    id: id,
    link: buildShareLink(id: id, key: sealed.key, origin: endpoint),
    expiresAt: expiresAt is String ? expiresAt : null,
    keyStoredOnServer: stored,
    keyCustodyFailed: failed,
    keyToken: failed && !refused ? keyToken : null,
  );
}

/// What became of a key upload.
enum KeyUpload {
  /// `204`: the server keeps the key.
  stored,

  /// `403`: the server will never take it (wrong or used token). Final.
  refused,

  /// A network failure, a `503` or anything else: tried again later.
  failed,
}

/// `PUT .../{id}/key`: gives the key to the plans that keep it, with the
/// [keyToken] the upload got. Also used later on its own when the first
/// try failed.
Future<KeyUpload> storeKey({
  required http.Client client,
  required String endpoint,
  required String appKey,
  required String id,
  required Uint8List key,
  required String keyToken,
}) async {
  try {
    final response = await _send(
      client,
      'PUT',
      Uri.parse('$endpoint/api/v1/reports/${Uri.encodeComponent(id)}/key'),
      appKey,
      key,
      _timeout,
      headers: {keyTokenHeader: keyToken},
    );
    return switch (response.statusCode) {
      204 => KeyUpload.stored,
      403 => KeyUpload.refused,
      _ => KeyUpload.failed,
    };
  } on UploadException {
    return KeyUpload.failed;
  }
}

/// Which SDK and platform is calling, so Nabrila can count live installs per
/// version (D31). Nothing about the device or the person.
@visibleForTesting
String get clientHeader {
  final platform = switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    _ => 'other',
  };
  return 'nabrila-flutter/$sdkVersion ($platform)';
}

/// One request that is really cancelled when it runs out of time: a plain
/// `.timeout` would leave the old upload running and the retry would share
/// the weak link with it. It is cut after [idle] without a byte going out
/// or coming in. [timeout] only cuts a link that is also quiet: while bytes
/// keep moving a slow upload is never cut for being slow (CL-06), up to a
/// very generous [ceiling] so nothing runs forever.
Future<http.Response> _send(
  http.Client client,
  String method,
  Uri url,
  String? appKey,
  List<int> body,
  Duration timeout, {
  Duration idle = idleTimeout,
  Duration? ceiling,
  Map<String, String> headers = const {},
  String contentType = 'application/octet-stream',
}) async {
  final abort = Completer<void>();
  void cut() {
    if (!abort.isCompleted) abort.complete();
  }

  final sinceMove = Stopwatch()..start();
  final life = Stopwatch()..start();
  final hardCap = ceiling ?? const Duration(minutes: 15);
  late Timer total;
  void check() {
    if (life.elapsed >= hardCap || sinceMove.elapsed >= idle) return cut();
    // Moving: look again later instead of cutting a slow link.
    total = Timer(timeout < idle ? timeout : idle, check);
  }

  total = Timer(timeout, check);
  var quiet = Timer(idle, cut);
  void moved() {
    sinceMove
      ..reset()
      ..start();
    quiet.cancel();
    quiet = Timer(idle, cut);
  }

  final request =
      http.AbortableStreamedRequest(method, url, abortTrigger: abort.future)
        ..headers['Content-Type'] = contentType
        ..headers['X-Nabrila-Client'] = clientHeader
        ..headers.addAll(headers)
        ..contentLength = body.length;
  if (appKey != null) request.headers['Authorization'] = 'Bearer $appKey';
  final aborted = abort.future.then<Never>(
    (_) => throw TimeoutException('nabrila upload', timeout),
  );
  // Never reported as unhandled when the request ends first.
  aborted.ignore();
  try {
    unawaited(
      request.sink
          .addStream(_chunks(body, moved))
          .whenComplete(request.sink.close)
          .catchError((Object _) {}),
    );
    final streamed = await Future.any([client.send(request), aborted]);
    final bytes = BytesBuilder(copy: false);
    final reading = streamed.stream.forEach((chunk) {
      moved();
      bytes.add(chunk);
    });
    await Future.any([reading, aborted]);
    return http.Response.bytes(
      bytes.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      request: streamed.request,
      reasonPhrase: streamed.reasonPhrase,
    );
  } on Exception {
    throw UploadException(UploadFailure.network);
  } finally {
    total.cancel();
    quiet.cancel();
    cut();
  }
}

/// [body] in 16 KB pieces, handed out as the connection takes them; each
/// one counts as progress.
Stream<List<int>> _chunks(List<int> body, void Function() moved) async* {
  const size = 16 * 1024;
  for (var start = 0; start < body.length; start += size) {
    moved();
    yield body.sublist(start, math.min(start + size, body.length));
  }
  moved();
}

/// Codes of the Nabrila API that a retry never changes.
const Map<String, UploadFailure> _permanent = {
  'invalid_key': UploadFailure.invalidKey,
  'suspended': UploadFailure.suspended,
  'too_large': UploadFailure.tooLarge,
  'bad_envelope': UploadFailure.badEnvelope,
  'quota': UploadFailure.quota,
  // 403 after a downgrade left the app over its plan's app quota (AUD-15).
  'plan_limit': UploadFailure.planLimit,
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

/// Sends [body] as JSON with the app key (none when [appKey] is null, as in
/// the tester's answer, which proves itself with its own secret) and returns
/// the response, or throws [UploadException] on a network failure or timeout.
Future<http.Response> sendJson(
  http.Client client,
  String method,
  Uri url,
  String? appKey, [
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
