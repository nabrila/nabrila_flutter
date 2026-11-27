import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nabrila/nabrila.dart';
import 'package:nabrila/src/report_status.dart';
import 'package:nabrila/src/runtime.dart';

import 'support/open_envelope.dart';

Widget _app() => NabrilaScope(
  child: MaterialApp(
    navigatorObservers: [Nabrila.navigatorObserver],
    initialRoute: '/home',
    routes: {
      '/home': (context) => Scaffold(
        body: Column(
          children: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pushNamed('/next?x=1'),
              child: const Text('Pay now'),
            ),
            NabrilaMask(
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('Card 4242'),
              ),
            ),
            TextField(controller: TextEditingController(text: 'hunter2')),
          ],
        ),
      ),
      '/next?x=1': (context) => const Scaffold(body: Text('Next')),
    },
  ),
);

final _bug = find.byIcon(Icons.bug_report_outlined);

/// A fresh outbox folder per test, so no report leaks between tests.
Future<Directory?> Function() _freshOutbox() {
  final dir = Directory.systemTemp.createTempSync('nabrila-scope-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  return () async => dir;
}

/// Pumps real time until [done] or about [tries] × 50 ms pass.
Future<void> _until(
  WidgetTester tester,
  bool Function() done, {
  int tries = 40,
}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < tries && !done(); i++) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await tester.pump();
  });
  await tester.pump();
}

void main() {
  tearDown(() => Nabrila.debugSetRuntime(null));

  testWidgets('disabled: no button and nothing recorded', (tester) async {
    await tester.pumpWidget(_app());
    expect(_bug, findsNothing);
    await tester.tap(find.text('Pay now'));
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsOneWidget);
    expect(Nabrila.isEnabled, isFalse);
  });

  testWidgets('enabled: taps and routes land in the buffer', (tester) async {
    final runtime = NabrilaRuntime(appKey: 'nbr_test');
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(_app());
    expect(_bug, findsOneWidget);

    await tester.tap(find.text('Pay now'));
    await tester.pumpAndSettle();
    final events = runtime.buffer.toJson();
    final tap = events.firstWhere((e) => e['kind'] == 'tap');
    expect(tap['targetHint'], 'Pay now');
    expect(tap['xNorm'], inInclusiveRange(0, 1));
    final nav = events.where((e) => e['kind'] == 'navigation').toList();
    expect(
      nav.any((e) => e['toRoute'] == '/next' && e['action'] == 'push'),
      isTrue,
    );
    expect(runtime.activeRoute, '/next');
  });

  testWidgets('a tap in a mask or a text field never reveals content', (
    tester,
  ) async {
    final runtime = NabrilaRuntime(appKey: 'nbr_test');
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(_app());

    await tester.tap(find.text('Card 4242'));
    await tester.tap(find.byType(TextField));
    final taps = runtime.buffer
        .toJson()
        .where((e) => e['kind'] == 'tap')
        .toList();
    expect(taps[0]['targetHint'], isNull);
    // Where a finger lands on a masked PIN pad spells the PIN (CL-05).
    expect(taps[0]['xNorm'], isNull);
    expect(taps[0]['yNorm'], isNull);
    expect(taps[1]['targetHint'], 'TextField');
    expect(taps[1]['xNorm'], isA<double>());
    final all = runtime.buffer.toJson().toString();
    expect(all.contains('4242'), isFalse);
    expect(all.contains('hunter2'), isFalse);
  });

  testWidgets('capture flow: draw, write a note, send and get the link', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final runtime = NabrilaRuntime(
      appKey: 'nbr_test',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          '{"id":"rep1","expiresAt":"x","keyCustody":"none"}',
          201,
        );
      }),
      storageDir: _freshOutbox(),
    );
    Nabrila.debugSetRuntime(runtime);
    Nabrila.setContext('env', 'staging');
    Nabrila.setContext('auth_token', 'abc');
    await tester.pumpWidget(_app());
    final payCenter = tester.getCenter(find.text('Pay now'));
    final screen = tester.getSize(find.byType(MaterialApp).first);

    await tester.runAsync(() async {
      await tester.tap(_bug);
      for (var i = 0; i < 20 && find.text('Send').evaluate().isEmpty; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();
    expect(find.text('Report'), findsOneWidget);

    // The tester says what kind of report it is and points at the button.
    await tester.tap(find.text('Looks wrong'));
    await tester.tap(find.text('Point'));
    await tester.pump();
    final picture = tester.getRect(find.byType(RawImage));
    await tester.tapAt(
      picture.topLeft +
          Offset(
            payCenter.dx / screen.width * picture.width,
            payCenter.dy / screen.height * picture.height,
          ),
    );
    await tester.pump();
    expect(find.textContaining('"Pay now"'), findsOneWidget);
    expect(find.textContaining('test/scope_test.dart:'), findsOneWidget);

    // What gets sent, before sending.
    await tester.tap(find.text('What gets sent'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Data from the app: env, auth_token'), findsOne);
    expect(find.textContaining('native views'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'The pay button hangs');
    await tester.runAsync(() async {
      await tester.tap(find.text('Send'));
      for (var i = 0; i < 40 && requests.isEmpty; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pump();
    });
    await tester.pump();
    expect(requests.length, 1);
    expect(requests.single.headers['Authorization'], 'Bearer nbr_test');
    expect(requests.single.bodyBytes.sublist(0, 4), [0x4e, 0x42, 0x52, 0x31]);
    expect(find.text('Report ready'), findsOneWidget);
    // The key is never shown whole (CL-26); Copy hands over the full link.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.runAsync(() async => tester.tap(find.byIcon(Icons.copy)));
    await _until(tester, () => copied != null);
    final link = copied!;
    expect(link, contains('https://nabrila.com/r/rep1#k='));
    final shown = find.textContaining('/r/rep1#k=');
    expect(tester.widget<Text>(shown).data, endsWith('…'));
    expect(find.textContaining(link.split('#k=').last), findsNothing);
    final key = base64Url.decode(base64Url.normalize(link.split('#k=').last));
    final opened = await tester.runAsync(
      () => openEnvelope(requests.single.bodyBytes, key),
    );
    final manifest = opened!.manifest;
    expect(manifest['kind'], 'visual');
    expect(manifest['context'], {'env': 'staging', 'auth_token': '[REDACTED]'});
    final element = manifest['element']! as Map;
    expect(element['label'], 'Pay now');
    expect(element['widget'], 'ElevatedButton');
    expect((element['source']! as Map)['file'], 'test/scope_test.dart');
    expect(element['xNorm'], closeTo(payCenter.dx / screen.width, 0.02));
  });

  for (final locale in const [Locale('es'), Locale('pt'), Locale('en')]) {
    testWidgets('a 320 pt phone in $locale: nothing overflows', (tester) async {
      tester.view
        ..physicalSize = const Size(320, 568)
        ..devicePixelRatio = 1;
      tester.platformDispatcher.localeTestValue = locale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final runtime = NabrilaRuntime(
        appKey: 'nbr_test',
        storageDir: _freshOutbox(),
      );
      Nabrila.debugSetRuntime(runtime);
      Nabrila.setContext('env', 'staging');
      await tester.pumpWidget(_app());
      await tester.runAsync(() async {
        await tester.tap(_bug);
        for (
          var i = 0;
          i < 20 && find.byType(RawImage).evaluate().isEmpty;
          i++
        ) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
      // Every kind picked, a point marked and the sheet opened: the longest
      // texts of the flow, all on screen.
      await tester.tap(find.byType(ChoiceChip).at(2));
      await tester.tap(find.byIcon(Icons.my_location));
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.byType(RawImage)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      runtime.delivery.dispose();
    });
  }

  testWidgets('the fix banner names the version, then asks if it works', (
    tester,
  ) async {
    final runtime = NabrilaRuntime(
      appKey: 'nbr_test',
      client: MockClient((_) async => http.Response('{"reports":[]}', 200)),
      storageDir: _freshOutbox(),
    );
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(_app());

    runtime.loop.updates.value = [
      const ReportStatus(id: 'r1', status: 'fixed', fixedIn: '1.4.2+37'),
    ];
    await tester.pump();
    expect(find.textContaining('fixed in version 1.4.2+37'), findsOneWidget);
    expect(find.bySemanticsLabel('It works'), findsNothing);

    runtime.loop.updates.value = [
      const ReportStatus(
        id: 'r1',
        status: 'fixed',
        fixedIn: '1.4.2+37',
        askVerdict: true,
      ),
    ];
    await tester.pump();
    expect(
      find.text('Your report was fixed. Does it work now?'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('It works'), findsOneWidget);
    expect(find.bySemanticsLabel('It still fails'), findsOneWidget);

    // A report this phone no longer remembers: the question just goes away.
    await tester.runAsync(
      () async => tester.tap(find.bySemanticsLabel('It still fails')),
    );
    await _until(tester, () => runtime.loop.updates.value.isEmpty);
    expect(find.text('Your report was fixed. Does it work now?'), findsNothing);
  });

  testWidgets('the banner shows sending, then could not send', (tester) async {
    final runtime = NabrilaRuntime(
      appKey: 'nbr_test',
      client: MockClient((_) async => http.Response('{"reports":[]}', 200)),
      storageDir: _freshOutbox(),
    );
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(_app());
    runtime.loop.updates.value = [
      const ReportStatus(
        id: 'r1',
        status: 'fixed',
        fixedIn: '1.4.2',
        updatedAt: '2026-11-27T10:00:00Z',
        askVerdict: true,
      ),
    ];
    await tester.pump();
    expect(find.bySemanticsLabel('It works'), findsOneWidget);

    runtime.loop.answering.value = {'r1': AnswerState.sending};
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);
    expect(find.bySemanticsLabel('It works'), findsNothing);

    runtime.loop.answering.value = {'r1': AnswerState.failed};
    await tester.pump();
    expect(
      find.text('Could not send; we will try again later'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('It still fails'), findsNothing);
    // It can still be closed.
    expect(find.bySemanticsLabel('Close'), findsOneWidget);
  });

  testWidgets('no network: the report waits on the phone and goes out later', (
    tester,
  ) async {
    var down = true;
    var posts = 0;
    var now = DateTime.utc(2026, 11, 26, 12);
    final runtime = NabrilaRuntime(
      appKey: 'nbr_test',
      clock: () => now,
      client: MockClient((request) async {
        posts++;
        if (down) throw const SocketException('Network is unreachable');
        return http.Response(
          '{"id":"rep9","expiresAt":"x","keyCustody":"none"}',
          201,
        );
      }),
      storageDir: _freshOutbox(),
    );
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(_app());

    await tester.runAsync(() async => tester.tap(_bug));
    await _until(tester, () => find.text('Send').evaluate().isNotEmpty);
    await tester.runAsync(() async => tester.tap(find.text('Send')));
    // Three quick attempts, one and three seconds apart.
    await _until(
      tester,
      () => find.textContaining('saved on this phone').evaluate().isNotEmpty,
      tries: 120,
    );
    expect(posts, 3);
    expect(find.textContaining('No connection'), findsOneWidget);
    expect(find.textContaining('saved on this phone'), findsOneWidget);

    // The network comes back; the next attempt is due 30 s (±20 %) after
    // the failed send, and the tester closes the flow after that.
    down = false;
    now = now.add(const Duration(minutes: 1));
    await tester.runAsync(() async => tester.tap(find.text('Close')));
    await _until(
      tester,
      () => find.text('A saved report was sent.').evaluate().isNotEmpty,
    );
    expect(find.text('A saved report was sent.'), findsOneWidget);
    expect(
      runtime.delivery.delivered.value.single.link,
      contains('/r/rep9#k='),
    );
    await tester.tap(find.bySemanticsLabel('Close'));
    await tester.pump();
    expect(find.text('A saved report was sent.'), findsNothing);
    runtime.delivery.dispose();
  });

  testWidgets('a double tap on Send makes one report', (tester) async {
    var posts = 0;
    final runtime = NabrilaRuntime(
      appKey: 'nbr_test',
      client: MockClient((request) async {
        posts++;
        return http.Response(
          '{"id":"rep1","expiresAt":"x","keyCustody":"none"}',
          201,
        );
      }),
      storageDir: _freshOutbox(),
    );
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(_app());
    await tester.runAsync(() async => tester.tap(_bug));
    await _until(tester, () => find.text('Send').evaluate().isNotEmpty);
    final send = find.text('Send');
    await tester.runAsync(() async {
      await tester.tap(send);
      await tester.tap(send, warnIfMissed: false);
    });
    await _until(tester, () => find.text('Report ready').evaluate().isNotEmpty);
    expect(find.text('Report ready'), findsOneWidget);
    expect(posts, 1);
    runtime.delivery.dispose();
  });

  testWidgets('too large: back to editing, and the next send is new', (
    tester,
  ) async {
    var posts = 0;
    final runtime = NabrilaRuntime(
      appKey: 'nbr_test',
      client: MockClient((request) async {
        posts++;
        return http.Response('{"error":"too_large"}', 413);
      }),
      storageDir: _freshOutbox(),
    );
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(_app());
    await tester.runAsync(() async => tester.tap(_bug));
    await _until(tester, () => find.text('Send').evaluate().isNotEmpty);
    await tester.runAsync(() async => tester.tap(find.text('Send')));
    await _until(
      tester,
      () => find.text('Back to editing').evaluate().isNotEmpty,
    );
    expect(find.text('Try again'), findsNothing);
    await tester.tap(find.text('Back to editing'));
    await tester.pump();
    expect(find.text('Send'), findsOneWidget);
    expect(posts, 1);
    runtime.delivery.dispose();
  });
}
