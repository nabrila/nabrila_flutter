import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nabrila/src/delivery.dart';
import 'package:nabrila/src/envelope.dart';
import 'package:nabrila/src/outbox.dart';
import 'package:nabrila/src/uploader.dart';

/// A server that can be cut, answers a repeat of the same envelope with the
/// report it already made (as the real one does) and records every request.
class _Server {
  bool down = false;
  int status = 201;
  bool keyCustody = false;

  /// The first N key uploads fail.
  int keyFailures = 0;

  /// Answers every request with this, as a captive portal or proxy would.
  http.Response? intercept;
  final List<http.Request> requests = [];
  final Map<String, String> _made = {};
  final Set<String> _keys = {};

  http.Client get client => MockClient((request) async {
    requests.add(request);
    if (down) throw const SocketException('Network is unreachable');
    final intercepted = intercept;
    if (intercepted != null) return intercepted;
    if (request.method == 'PUT') {
      if (keyFailures > 0) {
        keyFailures--;
        return http.Response('', 503);
      }
      _keys.add(request.url.pathSegments[3]);
      return http.Response('', 204);
    }
    if (status != 201) {
      return http.Response(
        '{"error":"${status == 401 ? 'invalid_key' : 'unavailable'}"}',
        status,
        headers: {'retry-after': '120'},
      );
    }
    final hash = base64Encode(request.bodyBytes);
    final existing = _made[hash];
    final id = existing ?? 'rep${_made.length + 1}';
    _made[hash] = id;
    return http.Response(
      jsonEncode({
        'id': id,
        'expiresAt': '2026-12-26T00:00:00Z',
        'keyCustody': keyCustody ? 'server' : 'none',
        'keyStored': _keys.contains(id),
      }),
      existing == null ? 201 : 200,
    );
  });

  int get reports => _made.length;
  int get posts => requests.where((r) => r.method == 'POST').length;
  int get puts => requests.where((r) => r.method == 'PUT').length;
}

SealedReport _sealed(int seed) => SealedReport(
  envelope: Uint8List.fromList(List<int>.generate(64, (i) => (i + seed) % 256)),
  key: Uint8List.fromList(List<int>.generate(32, (i) => i)),
);

void main() {
  late Directory dir;
  late DateTime now;
  late List<Duration> slept;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nabrila-outbox-test');
    now = DateTime.utc(2026, 11, 26, 12);
    slept = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ReportDelivery delivery(_Server server) => ReportDelivery(
    client: server.client,
    endpoint: 'https://nabrila.com',
    appKey: 'nbr_test',
    storageDir: () async => dir,
    clock: () => now,
    sleep: (d) async => slept.add(d),
  );

  List<String> files() =>
      dir.listSync().map((f) => f.uri.pathSegments.last).toList()..sort();

  test('sent at once: nothing stays on disk', () async {
    final server = _Server();
    final d = delivery(server);
    final sealed = _sealed(1);
    final pending = await d.keep(sealed);
    expect(files(), hasLength(2));
    final outcome = await d.deliver(sealed, pending);
    expect(outcome.result?.link, startsWith('https://nabrila.com/r/rep1#k='));
    expect(files(), isEmpty);
  });

  test('no network: quick retries, then saved for later', () async {
    final server = _Server()..down = true;
    final d = delivery(server);
    final sealed = _sealed(1);
    final outcome = await d.deliver(sealed, await d.keep(sealed));
    expect(outcome.failure, UploadFailure.network);
    expect(outcome.saved, isTrue);
    expect(server.posts, 3);
    expect(slept, ReportDelivery.quickRetries);
    expect(files().where((f) => f.endsWith('.nbr')), hasLength(1));
  });

  test('a refused report is not kept', () async {
    final server = _Server()..status = 401;
    final d = delivery(server);
    final sealed = _sealed(1);
    final outcome = await d.deliver(sealed, await d.keep(sealed));
    expect(outcome.failure, UploadFailure.invalidKey);
    expect(outcome.saved, isFalse);
    expect(server.posts, 1);
    expect(files(), isEmpty);
  });

  test('the app is closed mid-send: the next start sends it, once', () async {
    final server = _Server()..down = true;
    final first = delivery(server);
    final sealed = _sealed(7);
    final pending = await first.keep(sealed);
    await first.deliver(sealed, pending);
    // The app dies here: the flow never released the report.

    server.down = false;
    now = now.add(const Duration(minutes: 1));
    final second = delivery(server);
    await second.drain();
    second.dispose();
    expect(server.reports, 1);
    expect(second.delivered.value.single.id, 'rep1');
    // The envelope is gone; the link waits until the tester sees it.
    expect(files().where((f) => f.endsWith('.nbr')), isEmpty);
    await second.seen(second.delivered.value.single, dismiss: true);
    expect(files(), isEmpty);
    // The very same bytes went out every time.
    final bodies = server.requests.map((r) => base64Encode(r.bodyBytes));
    expect(bodies.toSet(), {base64Encode(sealed.envelope)});
  });

  test('a lost answer is harmless: the repeat gets the same report', () async {
    final server = _Server()..keyCustody = true;
    final d = delivery(server);
    final sealed = _sealed(3);
    final a = await d.deliver(sealed, null);
    final b = await d.deliver(sealed, null);
    expect(a.result!.id, b.result!.id);
    expect(server.reports, 1);
    // The key went up once; the repeat saw keyStored and skipped it.
    expect(server.puts, 1);
    expect(b.result!.keyStoredOnServer, isTrue);
  });

  test('the drain waits longer after each failure', () async {
    final server = _Server()..down = true;
    final d = delivery(server);
    final sealed = _sealed(1);
    final pending = await d.keep(sealed);
    await d.deliver(sealed, pending);
    d.release(pending);
    await d.drain();
    // Not due yet: the drain did not try.
    expect(server.posts, 3);

    final waits = <Duration>[];
    for (var i = 0; i < 9; i++) {
      final state = (await ReportOutbox(
        dir,
        clock: () => now,
      ).pending()).single;
      waits.add(state.nextAt.difference(now));
      now = state.nextAt;
      await d.drain();
    }
    d.dispose();
    expect(server.posts, 3 + 9);
    // 30 s, 1 min, 2, 4 … up to an hour, each within ±20 %.
    final expected = [30, 60, 120, 240, 480, 960, 1920, 3600, 3600];
    for (var i = 0; i < expected.length; i++) {
      expect(
        waits[i].inSeconds,
        inInclusiveRange(expected[i] * 0.8, expected[i] * 1.2),
      );
    }
  });

  test('the open flow keeps its report; the drain leaves it alone', () async {
    final server = _Server()..down = true;
    final d = delivery(server);
    final sealed = _sealed(1);
    final pending = await d.keep(sealed);
    await d.deliver(sealed, pending);
    server.down = false;
    now = now.add(const Duration(hours: 2));
    await d.drain();
    expect(server.reports, 0);
    d.release(pending);
    await d.drain();
    d.dispose();
    expect(server.reports, 1);
    expect(d.delivered.value, hasLength(1));
  });

  test('a busy server does not stop the round', () async {
    final server = _Server()..status = 503;
    final d = delivery(server);
    for (var i = 0; i < 3; i++) {
      final p = await d.keep(_sealed(i));
      d.release(p);
    }
    // The release drained them all once: 503 is worth trying the next one.
    await d.drain();
    d.dispose();
    expect(server.posts, 3);
    final left = await ReportOutbox(dir, clock: () => now).pending();
    expect(left.map((p) => p.attempts), everyElement(1));
  });

  test(
    'a captive portal answering 200 with a web page keeps the report',
    () async {
      final server = _Server()
        ..intercept = http.Response('<html>Wi-Fi login</html>', 200);
      final d = delivery(server);
      final sealed = _sealed(1);
      final outcome = await d.deliver(sealed, await d.keep(sealed));
      expect(outcome.saved, isTrue);
      expect(files().where((f) => f.endsWith('.nbr')), hasLength(1));
    },
  );

  test('a proxy 401 or 403 without our JSON is retried, ours is not', () async {
    for (final status in [401, 403, 400, 302, 404, 407]) {
      final server = _Server()..intercept = http.Response('denied', status);
      final d = delivery(server);
      final sealed = _sealed(status);
      final outcome = await d.deliver(sealed, await d.keep(sealed));
      expect(outcome.saved, isTrue, reason: 'status $status');
      expect(outcome.failure, UploadFailure.server, reason: 'status $status');
    }
  });

  test('the server Retry-After is respected', () async {
    final server = _Server()..status = 503;
    final d = delivery(server);
    final sealed = _sealed(1);
    final pending = (await d.keep(sealed))!;
    await d.deliver(sealed, pending);
    // 503 is retried quickly twice, then waits at least the 120 s asked.
    expect(server.posts, 3);
    expect(pending.nextAt.difference(now).inSeconds, greaterThanOrEqualTo(120));
  });

  test('a clock set back still sends the report', () async {
    final server = _Server()..down = true;
    final d = delivery(server);
    final sealed = _sealed(1);
    final pending = await d.keep(sealed);
    await d.deliver(sealed, pending);
    d.release(pending);
    await d.drain();
    server.down = false;
    // The phone's clock goes back a day: nextAt now looks a day away.
    now = now.subtract(const Duration(days: 1));
    await d.drain();
    d.dispose();
    expect(server.reports, 1);
  });

  test(
    'a report goes where it was meant to, even after a key change',
    () async {
      final server = _Server()..down = true;
      final first = delivery(server);
      final sealed = _sealed(1);
      await first.deliver(sealed, await first.keep(sealed));
      server.down = false;
      now = now.add(const Duration(minutes: 5));
      final next = ReportDelivery(
        client: server.client,
        endpoint: 'https://other.example',
        appKey: 'nbr_other',
        storageDir: () async => dir,
        clock: () => now,
        sleep: (d) async {},
      );
      await next.drain();
      next.dispose();
      final post = server.requests.lastWhere((r) => r.method == 'POST');
      expect(post.url.host, 'nabrila.com');
      expect(post.headers['Authorization'], 'Bearer nbr_test');
    },
  );

  test('a key that failed to upload is retried until stored', () async {
    final server = _Server()
      ..keyCustody = true
      ..keyFailures = 2;
    final d = delivery(server);
    final sealed = _sealed(1);
    final pending = (await d.keep(sealed))!;
    final outcome = await d.deliver(sealed, pending);
    expect(outcome.result!.keyCustodyFailed, isTrue);
    expect(files(), hasLength(1));
    d.release(pending);
    // Not shown again: the tester already has the link.
    for (var i = 0; i < 3 && files().isNotEmpty; i++) {
      now = now.add(const Duration(hours: 2));
      await d.drain();
    }
    d.dispose();
    expect(server.puts, 3);
    expect(files(), isEmpty);
    expect(d.delivered.value, isEmpty);
  });

  test('a link sent in the background survives a restart until seen', () async {
    final server = _Server()..down = true;
    final first = delivery(server);
    final sealed = _sealed(1);
    final pending = await first.keep(sealed);
    await first.deliver(sealed, pending);
    first.release(pending);
    server.down = false;
    now = now.add(const Duration(minutes: 5));
    await first.drain();
    first.dispose();
    expect(first.delivered.value, hasLength(1));
    final posts = server.posts;

    // The app is closed before the tester sees the banner.
    final second = delivery(server);
    await second.drain();
    second.dispose();
    expect(
      second.delivered.value.single.link,
      first.delivered.value.single.link,
    );
    expect(server.posts, posts);
    await second.seen(second.delivered.value.single);
    expect(files(), isEmpty);
  });

  test('two flows racing on the same report make one report', () async {
    final server = _Server();
    final d = delivery(server);
    final sealed = _sealed(1);
    final pending = await d.keep(sealed);
    final both = await Future.wait([
      d.deliver(sealed, pending),
      d.deliver(sealed, pending),
    ]);
    expect(both.map((o) => o.result!.id).toSet(), {'rep1'});
    expect(server.reports, 1);
  });

  group('outbox', () {
    test('drops expired, broken and half-written entries', () async {
      final box = ReportOutbox(dir, clock: () => now);
      final old = await box.add(
        _sealed(1),
        appKey: 'nbr_test',
        endpoint: 'https://nabrila.com',
      );
      now = now.add(const Duration(days: 8));
      final kept = await box.add(
        _sealed(2),
        appKey: 'nbr_test',
        endpoint: 'https://nabrila.com',
      );
      File('${dir.path}/orphan.nbr').writeAsBytesSync([1]);
      File('${dir.path}/broken.nbr').writeAsBytesSync([1]);
      File('${dir.path}/broken.json').writeAsStringSync('{not json');
      File('${dir.path}/cut.nbr.tmp').writeAsBytesSync([1]);
      final left = await box.pending();
      expect(left.map((p) => p.name), [kept.name]);
      expect(files(), ['${kept.name}.json', '${kept.name}.nbr']);
      expect(old.name, isNot(kept.name));
    });

    test('a locked file is kept for later, a garbled one is dropped', () async {
      final box = ReportOutbox(dir, clock: () => now);
      final locked = await box.add(
        _sealed(1),
        appKey: 'nbr_test',
        endpoint: 'https://nabrila.com',
      );
      final garbled = await box.add(
        _sealed(2),
        appKey: 'nbr_test',
        endpoint: 'https://nabrila.com',
      );
      File(
        '${dir.path}/${garbled.name}.json',
      ).writeAsBytesSync([0xff, 0xfe, 0]);
      final state = File('${dir.path}/${locked.name}.json');
      // Unreadable, as files are on iOS before the first unlock.
      Process.runSync('chmod', ['000', state.path]);
      expect(await box.pending(), isEmpty);
      expect(files(), ['${locked.name}.json', '${locked.name}.nbr']);
      Process.runSync('chmod', ['644', state.path]);
      expect((await box.pending()).single.name, locked.name);
    });

    test('keeps the newest ten', () async {
      final box = ReportOutbox(dir, clock: () => now);
      final names = <String>[];
      for (var i = 0; i < 12; i++) {
        now = now.add(const Duration(seconds: 1));
        names.add(
          (await box.add(
            _sealed(i),
            appKey: 'nbr_test',
            endpoint: 'https://nabrila.com',
          )).name,
        );
      }
      final left = await box.pending();
      expect(left.map((p) => p.name), names.sublist(2));
    });

    test('loads the report byte for byte', () async {
      final box = ReportOutbox(dir, clock: () => now);
      final sealed = _sealed(9);
      await box.add(
        sealed,
        appKey: 'nbr_test',
        endpoint: 'https://nabrila.com',
      );
      final back = await (await box.pending()).single.load();
      expect(back.envelope, sealed.envelope);
      expect(back.key, sealed.key);
    });
  });

  test('upload time grows with the size', () {
    expect(uploadTimeout(0), const Duration(seconds: 30));
    expect(uploadTimeout(2 * 1024 * 1024).inSeconds, 30 + 128);
  });
}
