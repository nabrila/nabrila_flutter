import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nabrila/src/envelope.dart';

import 'support/open_envelope.dart';

void main() {
  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'capturedAt': '2026-11-26T14:03:07.120Z',
    'app': {'appName': 'Demo'},
    'device': {'platform': 'android'},
    'events': <Object?>[],
  };
  final png = Uint8List.fromList(List<int>.generate(300, (i) => i & 0xff));

  test('sealReport round-trips with gzip on the JSON only', () async {
    final sealed = await sealReport(manifest: manifest, png: png);
    final e = sealed.envelope;
    expect(utf8.decode(e.sublist(0, 4)), 'NBR1');
    expect(e[4], 1);
    expect(e[5], 1);
    expect(sealed.key.length, 32);
    final opened = await openEnvelope(e, sealed.key);
    expect(opened.manifest, manifest);
    expect(opened.png, png);
  });

  test('every report gets a fresh key and IV', () async {
    final a = await sealReport(manifest: manifest, png: png);
    final b = await sealReport(manifest: manifest, png: png);
    expect(a.key, isNot(b.key));
    expect(a.envelope.sublist(6, 18), isNot(b.envelope.sublist(6, 18)));
  });

  test('a report without a picture still opens', () async {
    final sealed = await sealReport(manifest: manifest, png: null);
    final opened = await openEnvelope(sealed.envelope, sealed.key);
    expect(opened.png, isNull);
  });

  test('over 2,097,152 bytes it refuses to build the envelope', () async {
    final random = Random(7);
    final big = Uint8List.fromList(
      List<int>.generate(maxEnvelopeBytes, (_) => random.nextInt(256)),
    );
    await expectLater(
      sealReport(manifest: manifest, png: big),
      throwsA(isA<EnvelopeTooLargeException>()),
    );
  });

  test('a payload that fits exactly under the cap is accepted', () async {
    final iv = Uint8List(12);
    final key = Uint8List(32);
    // envelope = 18 header + payload + 16 tag.
    final plain = Uint8List(maxEnvelopeBytes - 18 - 16);
    final envelope = await sealPayload(
      plain: plain,
      key: key,
      iv: iv,
      flags: 0,
    );
    expect(envelope.length, maxEnvelopeBytes);
  });

  test('share link puts the key in the fragment, base64url, no padding', () {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => 0x10 + i));
    final link = buildShareLink(id: 'abc_DEF-123', key: key);
    expect(
      link,
      'https://nabrila.com/r/abc_DEF-123#k=EBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8',
    );
  });
}
