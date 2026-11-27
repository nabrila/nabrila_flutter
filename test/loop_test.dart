import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nabrila/src/envelope.dart';
import 'package:nabrila/src/manifest.dart';
import 'package:nabrila/src/outbox.dart';
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

  group('shared vectors', () {
    final all =
        jsonDecode(File('test/vectors/status.json').readAsStringSync()) as Map;

    test('the verdict hash is SHA-256 of the secret', () async {
      final verdict = all['verdict'] as Map;
      final secret = _hex(verdict['secretHex'] as String);
      expect(base64UrlNoPad(secret), verdict['secretB64url']);
      expect(await verdictHashOf(secret), verdict['hashB64url']);
    });

    test('fixedIn cases', () {
      final cases = all['fixedInCases'] as Map;
      for (final v in (cases['valid'] as List).cast<String>()) {
        expect(isFixedIn(v), isTrue, reason: 'valid "$v"');
      }
      for (final v in (cases['invalid'] as List).cast<String>()) {
        expect(isFixedIn(v), isFalse, reason: 'invalid "$v"');
      }
    });

    test('hasVersion cases', () {
      final cases = ((all['hasVersionCases'] as Map)['cases'] as List)
          .cast<Map>();
      for (final c in cases) {
        expect(
          hasVersion(
            fixedIn: c['fixedIn'] as String,
            version: c['version'] as String,
            build: c['build'] as String,
          ),
          c['expected'],
          reason: '$c',
        );
      }
    });

    test('commit cases', () {
      final cases = ((all['commitCases'] as Map)['cases'] as List).cast<Map>();
      for (final c in cases) {
        expect(commitOf(c['input'] as String), c['expected'], reason: '$c');
      }
    });
  });

  test('every upload carries the same verdict hash, also on a retry', () async {
    final secret = Uint8List.fromList(List<int>.generate(32, (i) => 32 + i));
    final seen = <String?>[];
    var calls = 0;
    final client = MockClient((request) async {
      seen.add(request.headers[verdictHashHeader]);
      if (++calls == 1) return http.Response('down', 503);
      return http.Response('{"id":"r1","keyCustody":"none"}', 201);
    });
    final sealed = SealedReport(
      envelope: Uint8List(40),
      key: Uint8List(32),
      verdictSecret: secret,
    );
    for (var i = 0; i < 2; i++) {
      try {
        await uploadReport(
          client: client,
          endpoint: 'https://x.test',
          appKey: 'nbr_x',
          sealed: sealed,
        );
      } on UploadException {
        // The first try fails on purpose.
      }
    }
    final hash = await verdictHashOf(secret);
    expect(seen, [hash, hash]);
    // The hash is not the secret, and an old report sends no header.
    expect(hash, isNot(base64UrlNoPad(secret)));
    String? old = 'x';
    await uploadReport(
      client: MockClient((request) async {
        old = request.headers[verdictHashHeader];
        return http.Response('{"id":"r2","keyCustody":"none"}', 201);
      }),
      endpoint: 'https://x.test',
      appKey: 'nbr_x',
      sealed: SealedReport(envelope: Uint8List(40), key: Uint8List(32)),
    );
    expect(old, isNull);
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

  final withVersion =
      ((jsonDecode(File('test/vectors/status.json').readAsStringSync())
                  as Map)['vectors']
              as List)
          .cast<Map>()
          .firstWhere((v) => v['name'] == 'fixed_with_version');

  test(
    'the note with the fixing version opens like the web seals it',
    () async {
      final plain = await openStatusNote(
        key,
        id,
        withVersion['sealedNoteB64url'] as String,
      );
      expect(plain, withVersion['note']);
      final note = StatusNote.decode(plain!);
      expect(note.text, withVersion['noteText']);
      expect(note.fixedIn, withVersion['fixedIn']);
      // A note sealed before the version existed is plain text.
      final old = StatusNote.decode(vector['note'] as String);
      expect(old.text, vector['note']);
      expect(old.fixedIn, isNull);
    },
  );

  final verdictSecret = Uint8List.fromList(
    List<int>.generate(32, (i) => 32 + i),
  );
  final verdictB64 = base64UrlNoPad(verdictSecret);

  /// A loop whose server says `fixed` with a version and takes answers with
  /// [postStatus]. [posts] collects the answers; [asks] counts the lists.
  ({
    ReportLoop loop,
    List<Map<String, Object?>> posts,
    List<http.BaseRequest> requests,
    void Function(int status) answerWith,
    void Function(bool online) setOnline,
    void Function(({String version, String build})) install,
    Directory Function() dir,
  })
  harness({DateTime Function()? clock}) {
    var app = (version: '1.4.1', build: '36');
    var postStatus = 200;
    var online = true;
    final posts = <Map<String, Object?>>[];
    final requests = <http.BaseRequest>[];
    final storage = Directory.systemTemp.createTempSync('nabrila-loop-test');
    addTearDown(() => storage.deleteSync(recursive: true));
    final loop = ReportLoop(
      client: MockClient((request) async {
        requests.add(request);
        if (!online) throw const SocketException('down');
        if (request.url.path == '/api/v1/reports/$id/status') {
          posts.add((jsonDecode(request.body) as Map).cast<String, Object?>());
          return http.Response('{"status":"verified"}', postStatus);
        }
        return http.Response(
          jsonEncode({
            'reports': [
              {
                'id': id,
                'status': 'fixed',
                'note': withVersion['sealedNoteB64url'],
                'updatedAt': '2026-11-27T10:00:00.123Z',
              },
            ],
          }),
          200,
        );
      }),
      storageDir: () async => storage,
      clock: clock ?? () => DateTime.utc(2026, 11, 27, 12),
      appVersion: () async => app,
    );
    return (
      loop: loop,
      posts: posts,
      requests: requests,
      answerWith: (code) => postStatus = code,
      setOnline: (value) => online = value,
      install: (value) => app = value,
      dir: () => storage,
    );
  }

  Future<ReportStatus> asked(
    ({
      ReportLoop loop,
      List<Map<String, Object?>> posts,
      List<http.BaseRequest> requests,
      void Function(int) answerWith,
      void Function(bool) setOnline,
      void Function(({String version, String build})) install,
      Directory Function() dir,
    })
    h,
  ) async {
    await h.loop.remember(
      id: id,
      key: key,
      endpoint: 'https://x.test',
      appKey: 'nbr_x',
      verdictSecret: verdictSecret,
    );
    h.install((version: '1.4.2', build: '37'));
    await h.loop.poll();
    final ask = h.loop.updates.value.single;
    expect(ask.askVerdict, isTrue);
    return ask;
  }

  test('the answer carries only the verdict, status and askedAt', () async {
    final h = harness();
    await h.loop.remember(
      id: id,
      key: key,
      endpoint: 'https://x.test',
      appKey: 'nbr_x',
      verdictSecret: verdictSecret,
    );

    // An older build: told which version has the fix, not asked yet.
    await h.loop.poll();
    final told = h.loop.updates.value.single;
    expect(told.fixedIn, '1.4.2+37');
    expect(told.note, withVersion['noteText']);
    expect(told.askVerdict, isFalse);
    await h.loop.seen(told);

    // The new build is installed: asked at once, even within 15 minutes.
    h.install((version: '1.4.2', build: '37'));
    await h.loop.poll();
    final ask = h.loop.updates.value.single;
    expect(ask.askVerdict, isTrue);

    expect(await h.loop.answer(ask, works: true), isTrue);
    expect(h.loop.updates.value, isEmpty);
    expect(h.posts.single, {
      'verdict': verdictB64,
      'status': 'verified',
      'askedAt': '2026-11-27T10:00:00.123Z',
    });
    final post = h.requests.last;
    expect(post.headers['Authorization'], isNull);
    expect(post.headers['X-Nabrila-Client'], startsWith('nabrila-flutter/'));
    // Nothing of the link's key, the status secret or the note travels.
    final body = jsonEncode(h.posts);
    expect(body, isNot(contains(vector['keyB64url'])));
    expect(body, isNot(contains(vector['statusSecretB64url'])));
    expect(body, isNot(contains('appKey')));
    expect(body, isNot(contains('note')));

    // Its own answer is never shown back, and nothing stays pending.
    await h.loop.poll(force: true);
    expect(h.loop.updates.value, isEmpty);
    final saved =
        jsonDecode(File('${h.dir().path}/loop/sent.json').readAsStringSync())
            as Map;
    expect((saved['reports'] as Map)[id], isNot(contains('pendingVerdict')));
  });

  test(
    'a failed answer stays pending, survives closing, and is retried',
    () async {
      final h = harness();
      final ask = await asked(h);

      h.answerWith(500);
      expect(await h.loop.answer(ask, works: false), isFalse);
      expect(h.loop.answering.value[id], AnswerState.failed);
      expect(h.loop.updates.value.single, ask);
      var saved =
          jsonDecode(File('${h.dir().path}/loop/sent.json').readAsStringSync())
              as Map;
      expect((saved['reports'] as Map)[id]['pendingVerdict'], {
        'status': 'reopened',
        'askedAt': '2026-11-27T10:00:00.123Z',
      });
      expect((saved['reports'] as Map)[id]['verdictSecret'], verdictB64);

      // Closing the banner does not lose it.
      await h.loop.seen(ask);
      expect(h.loop.updates.value, isEmpty);

      // Network down: still pending, the next poll tries again.
      h.setOnline(false);
      h.posts.clear();
      await h.loop.poll();
      saved =
          jsonDecode(File('${h.dir().path}/loop/sent.json').readAsStringSync())
              as Map;
      expect((saved['reports'] as Map)[id], contains('pendingVerdict'));

      // Back online, even inside the 15 minutes: it goes out and is dropped.
      h.setOnline(true);
      h.answerWith(200);
      await h.loop.poll();
      expect(h.posts.single['status'], 'reopened');
      saved =
          jsonDecode(File('${h.dir().path}/loop/sent.json').readAsStringSync())
              as Map;
      expect((saved['reports'] as Map)[id], isNot(contains('pendingVerdict')));
      h.posts.clear();
      await h.loop.poll(force: true);
      expect(h.posts, isEmpty);
    },
  );

  for (final code in [403, 404, 409]) {
    test('a $code drops the pending answer for good', () async {
      final h = harness();
      final ask = await asked(h);
      h.answerWith(code);
      expect(await h.loop.answer(ask, works: true), isTrue);
      expect(h.loop.updates.value, isEmpty);
      expect(h.loop.answering.value, isEmpty);
      h.posts.clear();
      await h.loop.poll(force: true);
      expect(h.posts, isEmpty);
      expect(h.loop.updates.value, isEmpty);
    });
  }

  test('429 and network errors keep the answer pending', () async {
    final h = harness();
    final ask = await asked(h);
    h.answerWith(429);
    expect(await h.loop.answer(ask, works: true), isFalse);
    h.setOnline(false);
    expect(await h.loop.answer(ask, works: true), isFalse);
    expect(h.loop.answering.value[id], AnswerState.failed);
  });

  test('a report without a verdict secret is never asked', () async {
    final h = harness();
    await h.loop.remember(
      id: id,
      key: key,
      endpoint: 'https://x.test',
      appKey: 'nbr_x',
    );
    h.install((version: '2.0.0', build: '1'));
    await h.loop.poll();
    expect(h.loop.updates.value.single.askVerdict, isFalse);
  });

  test('an app update seen offline is asked as soon as it is online', () async {
    final h = harness();
    await h.loop.remember(
      id: id,
      key: key,
      endpoint: 'https://x.test',
      appKey: 'nbr_x',
      verdictSecret: verdictSecret,
    );
    h.install((version: '1.4.2', build: '37'));
    h.setOnline(false);
    await h.loop.poll();
    expect(h.loop.updates.value, isEmpty);
    // Offline did not count as a check: online it asks right away.
    h.setOnline(true);
    await h.loop.poll();
    expect(h.loop.updates.value.single.askVerdict, isTrue);
  });

  test('one failing server does not stop the others', () async {
    final storage = Directory.systemTemp.createTempSync('nabrila-loop-test');
    addTearDown(() => storage.deleteSync(recursive: true));
    final loop = ReportLoop(
      client: MockClient((request) async {
        if (request.url.host == 'a.test') {
          throw const SocketException('down');
        }
        return http.Response(
          jsonEncode({
            'reports': [
              {
                'id': 'r2',
                'status': 'needs_info',
                'updatedAt': '2026-11-27T10:00:00Z',
              },
            ],
          }),
          200,
        );
      }),
      storageDir: () async => storage,
    );
    for (final (rid, host) in [('r1', 'a'), ('r2', 'b')]) {
      await loop.remember(
        id: rid,
        key: key,
        endpoint: 'https://$host.test',
        appKey: 'nbr_$host',
      );
    }
    await loop.poll();
    expect(loop.updates.value.single.id, 'r2');
  });

  test('the outbox keeps the verdict secret for every retry', () async {
    final dir = Directory.systemTemp.createTempSync('nabrila-outbox-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pending = await ReportOutbox(dir).add(
      SealedReport(
        envelope: Uint8List(40),
        key: Uint8List(32),
        verdictSecret: verdictSecret,
      ),
      appKey: 'nbr_x',
      endpoint: 'https://x.test',
    );
    expect((await pending.load()).verdictSecret, verdictSecret);
    final again = (await ReportOutbox(dir).pending()).single;
    expect((await again.load()).verdictSecret, verdictSecret);
    // Sealing makes a fresh one each time.
    final a = await sealReport(manifest: {'a': 1}, png: null);
    final b = await sealReport(manifest: {'a': 1}, png: null);
    expect(a.verdictSecret, hasLength(32));
    expect(a.verdictSecret, isNot(b.verdictSecret));
  });

  test('a question closed without an answer is not asked again', () async {
    final loop = ReportLoop(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'reports': [
              {
                'id': id,
                'status': 'fixed',
                'note': withVersion['sealedNoteB64url'],
                'updatedAt': '2026-11-27T10:00:00Z',
              },
            ],
          }),
          200,
        ),
      ),
      storageDir: _tempDir(),
      appVersion: () async => (version: '2.0.0', build: '1'),
    );
    await loop.remember(
      id: id,
      key: key,
      endpoint: 'https://x.test',
      appKey: 'nbr_x',
    );
    await loop.poll();
    await loop.seen(loop.updates.value.single);
    await loop.poll(force: true);
    expect(loop.updates.value, isEmpty);
  });

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
