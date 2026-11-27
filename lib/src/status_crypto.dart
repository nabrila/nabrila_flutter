import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Header of the upload that carries [statusHashOf] the report key.
const String statusHashHeader = 'X-Nabrila-Status';

const String _info = 'nabrila-status-v1';

/// `HKDF-SHA256(key, salt: empty, info: "nabrila-status-v1")`: whoever
/// holds the link can derive it and prove it to the server to set the
/// report's status; the server only keeps its hash.
Future<Uint8List> statusSecretOf(List<int> key) async {
  final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(key),
    nonce: const [],
    info: utf8.encode(_info),
  );
  return Uint8List.fromList(await derived.extractBytes());
}

/// `base64url(SHA-256(statusSecret))`, sent with the upload.
Future<String> statusHashOf(List<int> key) async {
  final hash = await Sha256().hash(await statusSecretOf(key));
  return base64UrlNoPad(hash.bytes);
}

/// Header of the upload that carries [verdictHashOf] the verdict secret.
const String verdictHashHeader = 'X-Nabrila-Verdict';

/// `base64url(SHA-256(verdictSecret))`, sent with the upload (D34).
Future<String> verdictHashOf(List<int> verdictSecret) async =>
    base64UrlNoPad((await Sha256().hash(verdictSecret)).bytes);

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _fromBase64Url(String value) =>
    base64Url.decode(base64Url.normalize(value));

/// Opens the team's note to the tester: `iv(12) || ciphertext || tag(16)`,
/// AES-256-GCM with the report key and `"nabrila-status-v1:" + id` as AAD.
/// Null when it does not open.
Future<String?> openStatusNote(List<int> key, String id, String sealed) async {
  try {
    final bytes = _fromBase64Url(sealed);
    if (bytes.length < 12 + 16 + 1) return null;
    final box = SecretBox(
      bytes.sublist(12, bytes.length - 16),
      nonce: bytes.sublist(0, 12),
      mac: Mac(bytes.sublist(bytes.length - 16)),
    );
    final clear = await AesGcm.with256bits().decrypt(
      box,
      secretKey: SecretKey(key),
      aad: utf8.encode('$_info:$id'),
    );
    return utf8.decode(clear);
  } on Object {
    return null;
  }
}
