import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nabrila/src/envelope.dart';
import 'package:nabrila/src/uploader.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => 0x10 + i));
  final sealed = SealedReport(
    envelope: Uint8List.fromList([1, 2, 3]),
    key: key,
  );
  const keyInLink = 'EBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8';

  Future<UploadResult> upload(http.Client client) => uploadReport(
    client: client,
    endpoint: 'https://nabrila.com',
    appKey: 'nbr_test',
    sealed: sealed,
  );

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  test('201 with keyCustody none: one request, link with the key', () async {
    final requests = <http.Request>[];
    final result = await upload(
      MockClient((request) async {
        requests.add(request);
        return json(201, {
          'id': 'rep123',
          'expiresAt': '2026-12-26T00:00:00Z',
          'keyCustody': 'none',
        });
      }),
    );
    expect(requests.length, 1);
    final r = requests.single;
    expect(r.method, 'POST');
    expect(r.url.toString(), 'https://nabrila.com/api/v1/reports');
    expect(r.headers['Authorization'], 'Bearer nbr_test');
    expect(r.headers['Content-Type'], 'application/octet-stream');
    expect(r.bodyBytes, [1, 2, 3]);
    expect(result.link, 'https://nabrila.com/r/rep123#k=$keyInLink');
    expect(result.keyStoredOnServer, isFalse);
    expect(result.keyCustodyFailed, isFalse);
  });

  test('keyCustody server: PUT the raw key and expect 204', () async {
    final requests = <http.Request>[];
    final result = await upload(
      MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST') {
          return json(201, {
            'id': 'rep9',
            'expiresAt': 'x',
            'keyCustody': 'server',
          });
        }
        return http.Response('', 204);
      }),
    );
    expect(requests.length, 2);
    final put = requests.last;
    expect(put.method, 'PUT');
    expect(put.url.path, '/api/v1/reports/rep9/key');
    expect(put.headers['Authorization'], 'Bearer nbr_test');
    expect(put.headers['Content-Type'], 'application/octet-stream');
    expect(put.bodyBytes, key);
    expect(result.keyStoredOnServer, isTrue);
  });

  test('a failed key PUT keeps the link and flags it', () async {
    final result = await upload(
      MockClient((request) async {
        if (request.method == 'POST') {
          return json(201, {'id': 'a', 'keyCustody': 'server'});
        }
        return http.Response('', 500);
      }),
    );
    expect(result.keyCustodyFailed, isTrue);
    expect(result.link, contains('#k='));
  });

  Future<UploadException> failWith(int status, Object body) async {
    try {
      await upload(MockClient((_) async => json(status, body)));
    } on UploadException catch (e) {
      return e;
    }
    throw StateError('expected a failure');
  }

  test('error codes map to failures', () async {
    expect(
      (await failWith(401, {'error': 'invalid_key'})).failure,
      UploadFailure.invalidKey,
    );
    expect(
      (await failWith(403, {'error': 'suspended'})).failure,
      UploadFailure.suspended,
    );
    expect(
      (await failWith(413, {'error': 'too_large'})).failure,
      UploadFailure.tooLarge,
    );
    expect(
      (await failWith(400, {'error': 'bad_envelope'})).failure,
      UploadFailure.badEnvelope,
    );
    expect(
      (await failWith(429, {'error': 'quota'})).failure,
      UploadFailure.quota,
    );
    expect(
      (await failWith(429, {'error': 'rate_limited'})).failure,
      UploadFailure.rateLimited,
    );
    expect((await failWith(500, {'error': 'x'})).failure, UploadFailure.server);
  });

  test('a network error becomes UploadFailure.network', () async {
    await expectLater(
      upload(MockClient((_) async => throw http.ClientException('offline'))),
      throwsA(
        isA<UploadException>().having(
          (e) => e.failure,
          'failure',
          UploadFailure.network,
        ),
      ),
    );
  });
}
