import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Reader used only by the tests, mirroring what the browser viewer does
/// (architecture.md, section 3.4).
class OpenedReport {
  OpenedReport(this.manifest, this.png);

  final Map<String, Object?> manifest;
  final Uint8List? png;
}

class OpenProblem implements Exception {
  OpenProblem(this.problem);

  /// `envelope`, `decrypt`, `payload` or `manifest`, as in the vectors file.
  final String problem;

  @override
  String toString() => 'OpenProblem($problem)';
}

Future<OpenedReport> openEnvelope(Uint8List bytes, Uint8List key) async {
  if (bytes.length < 18 + 16 ||
      bytes[0] != 0x4e ||
      bytes[1] != 0x42 ||
      bytes[2] != 0x52 ||
      bytes[3] != 0x31 ||
      bytes[4] != 0x01 ||
      bytes[5] & 0xfe != 0) {
    throw OpenProblem('envelope');
  }
  final flags = bytes[5];
  final Uint8List plain;
  try {
    final tagStart = bytes.length - 16;
    final box = SecretBox(
      bytes.sublist(18, tagStart),
      nonce: bytes.sublist(6, 18),
      mac: Mac(bytes.sublist(tagStart)),
    );
    plain = Uint8List.fromList(
      await AesGcm.with256bits().decrypt(
        box,
        secretKey: SecretKey(key),
        aad: bytes.sublist(0, 6),
      ),
    );
  } on SecretBoxAuthenticationError {
    throw OpenProblem('decrypt');
  }
  if (plain.length < 4) throw OpenProblem('payload');
  final jsonLength = ByteData.sublistView(plain).getUint32(0, Endian.big);
  if (4 + jsonLength > plain.length) throw OpenProblem('payload');
  var json = plain.sublist(4, 4 + jsonLength);
  if (flags & 1 == 1) json = Uint8List.fromList(gzip.decode(json));
  final manifest = jsonDecode(utf8.decode(json));
  if (manifest is! Map || manifest['schemaVersion'] != 1) {
    throw OpenProblem('manifest');
  }
  final rest = plain.sublist(4 + jsonLength);
  return OpenedReport(
    manifest.cast<String, Object?>(),
    rest.isEmpty ? null : rest,
  );
}
