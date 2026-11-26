import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nabrila/src/envelope.dart';
import 'package:nabrila/src/remote_config.dart';
import 'package:nabrila/src/report_status.dart';
import 'package:nabrila/src/uploader.dart';

List<int> _hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

Future<Directory?> Function() _tempDir() {
  final dir = Directory.systemTemp.createTempSync('nabrila-loop-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  return () async => dir;
}

void main() {
  final vector =
      (jsonDecode(File('test/vectors/status.json').readAsStringSync())
                  as Map)['vectors']
              .first
          as Map;
  final key = _hex(vector['keyHex'] as String);
  final id = vector['reportId'] as String;

  test('status secret, hash and note match the shared vectors', () async {
    expect(
      base64UrlNoPad(await statusSecretOf(key)),
      vector['statusSecretB64url'],
    );
    expect(await statusHashOf(key), vector['statusHashB64url']);
    expect(
      await openStatusNote(key, id, vector['sealedNoteB64url'] as String),
      vector['note'],
    );
    // Another report's id (the AAD) never opens it.
    expect(
      await openStatusNote(key, 'other', vector['sealedNoteB64url'] as String),
      isNull,
    );
  });

  test('every upload carries the status hash of its key', () async {
    String? header;
    final client = MockClient((request) async {
      header = request.headers[statusHashHeader];
      return http.Response(
        '{"id":"r1","expiresAt":"2026-12-26T00:00:00Z","keyCustody":"none"}',
        201,
      );
    });
    await uploadReport(
      client: client,
      endpoint: 'https://x.test',
      appKey: 'nbr_x',
      sealed: SealedReport(envelope: Uint8List(40), key: Uint8List(32)),
    );
    expect(header, await statusHashOf(Uint8List(32)));
  });

  test(
    'the team status shows once, with its note, and only when it changes',
    () async {
      var now = DateTime.utc(2026, 11, 26, 12);
      var status = 'fixed';
      var updatedAt = '2026-11-26T13:00:00Z';
      var asks = 0;
      final loop = ReportLoop(
        client: MockClient((request) async {
          asks++;
          expect(request.url.path, '/api/v1/reports/status');
          expect(request.headers['Authorization'], 'Bearer nbr_x');
          expect(jsonDecode(request.body), {
            'ids': [id],
          });
          return http.Response(
            jsonEncode({
              'reports': [
                {
                  'id': id,
                  'status': status,
                  'note': vector['sealedNoteB64url'],
                  'updatedAt': updatedAt,
                },
                {'id': 'not-mine', 'status': 'fixed'},
              ],
            }),
            200,
          );
        }),
        storageDir: _tempDir(),
        clock: () => now,
      );
      await loop.remember(
        id: id,
        key: key,
        endpoint: 'https://x.test',
        appKey: 'nbr_x',
        expiresAt: '2026-12-26T00:00:00Z',
      );
      await loop.poll();
      final update = loop.updates.value.single;
      expect(update.status, 'fixed');
      expect(update.note, vector['note']);
      await loop.seen(update);
      expect(loop.updates.value, isEmpty);

      // Within 15 minutes nothing is asked; the same status is not shown again.
      await loop.poll();
      expect(asks, 1);
      now = now.add(const Duration(minutes: 20));
      await loop.poll();
      expect(asks, 2);
      expect(loop.updates.value, isEmpty);

      // The team changes it: shown again.
      status = 'needs_info';
      updatedAt = '2026-11-26T14:00:00Z';
      await loop.poll(force: true);
      expect(loop.updates.value.single.status, 'needs_info');

      // Once the report expires it is no longer asked about.
      now = DateTime.utc(2027);
      await loop.poll(force: true);
      expect(asks, 3);
    },
  );

  test('a network failure while asking never throws', () async {
    final loop = ReportLoop(
      client: MockClient((_) async => throw const SocketException('down')),
      storageDir: _tempDir(),
    );
    await loop.remember(
      id: 'r1',
      key: key,
      endpoint: 'https://x.test',
      appKey: 'nbr_x',
    );
    await loop.poll();
    expect(loop.updates.value, isEmpty);
  });

  group('remote replay switch', () {
    test('globs match "manufacturer model"', () {
      expect(matchesDevice('samsung sm-a15*', 'samsung sm-a155f'), isTrue);
      expect(matchesDevice('samsung sm-a15*', 'samsung sm-a255f'), isFalse);
      expect(matchesDevice('*exynos*', 'samsung exynos 850'), isTrue);
      expect(matchesDevice('xiaomi (redmi)', 'xiaomi (redmi)'), isTrue);
      expect(matchesDevice('xiaomi', 'xiaomi 13'), isFalse);
    });

    test('a blocked model turns replay off, kept for offline starts', () async {
      final storage = _tempDir();
      var fetches = 0;
      RemoteConfig config({bool online = true}) => RemoteConfig(
        client: MockClient((request) async {
          fetches++;
          if (!online) throw const SocketException('down');
          expect(request.url.path, '/api/v1/config');
          return http.Response(
            jsonEncode({
              'replay': {
                'blockedDevices': ['samsung sm-a15*'],
              },
              'refreshAfterSeconds': 86400,
            }),
            200,
          );
        }),
        endpoint: 'https://x.test',
        appKey: 'nbr_x',
        storageDir: storage,
        deviceModel: () async => 'Samsung SM-A155F',
      );
      var off = 0;
      await config().apply(() => off++);
      expect(off, 1);
      // Next start, offline: the kept answer still turns it off.
      await config(online: false).apply(() => off++);
      expect(off, 2);
      expect(fetches, 1);
    });

    test('a model not on the list keeps replay on', () async {
      var off = 0;
      await RemoteConfig(
        client: MockClient(
          (_) async => http.Response(
            '{"replay":{"blockedDevices":["samsung sm-a15*"]}}',
            200,
          ),
        ),
        endpoint: 'https://x.test',
        appKey: 'nbr_x',
        storageDir: _tempDir(),
        deviceModel: () async => 'google pixel 8',
      ).apply(() => off++);
      expect(off, 0);
    });
  });
}
