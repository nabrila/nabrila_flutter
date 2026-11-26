import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nabrila/src/envelope.dart';

import 'support/open_envelope.dart';

Uint8List _b64(String value) => base64.decode(value);
Uint8List _b64url(String value) => base64Url.decode(base64Url.normalize(value));

void main() {
  final file = File('test/vectors/vectors.json');
  final vectors =
      (jsonDecode(file.readAsStringSync()) as Map)['vectors'] as List;

  group('NBR1 vectors', () {
    for (final raw in vectors.cast<Map<String, dynamic>>()) {
      final name = raw['name'] as String;
      final expected = raw['expect'] as Map<String, dynamic>;
      final key = _b64url(raw['keyB64url'] as String);
      final envelope = _b64(raw['envelopeB64'] as String);

      if (raw.containsKey('payloadB64')) {
        test(
          '$name: encrypting the payload gives the exact envelope',
          () async {
            final sealed = await sealPayload(
              plain: _b64(raw['payloadB64'] as String),
              key: key,
              iv: _b64url(raw['ivB64url'] as String),
              flags: raw['flags'] as int,
            );
            expect(sealed, envelope);
          },
        );
      }

      if (expected['ok'] == true) {
        test('$name: opens to the same manifest and PNG', () async {
          final opened = await openEnvelope(envelope, key);
          expect(opened.manifest, expected['manifest']);
          final image = expected['imageB64'] as String?;
          expect(opened.png, image == null ? isNull : _b64(image));
        });
      } else {
        test('$name: fails with ${expected['problem']}', () async {
          await expectLater(
            openEnvelope(envelope, key),
            throwsA(
              isA<OpenProblem>().having(
                (p) => p.problem,
                'problem',
                expected['problem'],
              ),
            ),
          );
        });
      }
    }

    test('the file has valid and broken vectors', () {
      final ok = vectors
          .where((v) => ((v as Map)['expect'] as Map)['ok'] == true)
          .length;
      expect(ok, greaterThan(0));
      expect(vectors.length - ok, greaterThan(0));
    });
  });
}
