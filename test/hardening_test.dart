import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nabrila/dio.dart';
import 'package:nabrila/nabrila.dart';
import 'package:nabrila/src/annotations.dart';
import 'package:nabrila/src/capture.dart';
import 'package:nabrila/src/events.dart';
import 'package:nabrila/src/mask.dart';
import 'package:nabrila/src/redaction.dart';
import 'package:nabrila/src/runtime.dart';
import 'package:nabrila/src/scope.dart';
import 'package:nabrila/src/tap_resolver.dart';

/// Security audit of 26 Nov 2026 (docs/security-audit.md): one test per
/// finding that had none.
void main() {
  tearDown(() => Nabrila.debugSetRuntime(null));

  group('text and redaction', () {
    test('clip never cuts an emoji in half (CL-03)', () {
      final value = '${'a' * 79}😀';
      final cut = clip(value, 80);
      expect(cut, 'a' * 79);
      expect(() => utf8.encode(cut), returnsNormally);
      final tap = RecordedEvent.tap(
        at: DateTime(2026),
        xNorm: 0,
        yNorm: 0,
        targetHint: value,
      );
      expect(tap.fields['targetHint'], 'a' * 79);
    });

    test('more secret names, and none of their look-alikes (AUD-07)', () {
      for (final name in [
        'private_key',
        'aws_access_key_id',
        'X-CSRF-Token',
        'otp',
        'otpCode',
        'card_cvv',
        'cvc',
        'cpf',
        'dni',
        'curp',
        'userPin',
        'bearer',
      ]) {
        expect(isSensitiveName(name), isTrue, reason: name);
      }
      for (final name in ['shipping', 'footprint', 'spinner', 'description']) {
        expect(isSensitiveName(name), isFalse, reason: name);
      }
    });

    test('an OAuth code, a signature and a redirect are cleaned (CL-24)', () {
      expect(
        sanitizeUrl(Uri.parse('https://a.test/cb?code=abc&sig=x&key=k&p=1')),
        'https://a.test/cb?code=$redacted&sig=$redacted&key=$redacted&p=1',
      );
      final headers = sanitizeHeaders({
        'Location': ['https://a.test/cb?code=abc&state=s#access_token=t'],
      });
      expect(headers['location'], 'https://a.test/cb?code=$redacted&state=s');
    });

    test('a query name that is not valid encoding never throws (AUD-07)', () {
      expect(
        sanitizeUrl(Uri.parse('https://a.test/?%FF=1&token=t')),
        'https://a.test/?%FF=1&token=$redacted',
      );
    });

    test('a body too large to parse or not JSON is still redacted', () {
      final big = '{"password":"hunter2","pad":"${'x' * 210000}"}';
      expect(sanitizeBody(big), isNot(contains('hunter2')));
      final graphql =
          'query { login(password: "hunter2", user: "ana") } '
          'Authorization: Bearer abcdefghijkl '
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig';
      final out = sanitizeBody(graphql)!;
      expect(out, contains('user: "ana"'));
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('abcdefghijkl')));
      expect(out, isNot(contains('eyJzdWIi')));
    });

    test('logs are redacted before they are kept (SOL #3)', () {
      final runtime = NabrilaRuntime(appKey: 'nbr_test');
      runtime.recordLog(
        'info',
        'login ok token=abc123 for ana',
        'Exception: Authorization: Bearer abcdefghijkl',
      );
      final log = runtime.buffer.toJson().single;
      expect(log['message'], 'login ok token=$redacted for ana');
      expect(log['stackTrace'], isNot(contains('abcdefghijkl')));
    });

    test('a route keeps neither its query nor its fragment (CL-19)', () {
      final runtime = NabrilaRuntime(appKey: 'nbr_test');
      runtime.recordNavigation(
        action: 'push',
        fromRoute: '/login?next=1',
        toRoute: '/callback#access_token=secret',
      );
      expect(runtime.activeRoute, '/callback');
      expect(runtime.buffer.toJson().toString(), isNot(contains('secret')));
    });
  });

  test('the console dump of a Flutter error is not kept twice (CL-21)', () {
    final lines = <String>[];
    final saved = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.addAll(message!.split('\n'));
    try {
      FlutterError.resetErrorCount();
      final details = FlutterErrorDetails(
        exception: Exception('boom'),
        stack: StackTrace.current,
        library: 'widgets library',
      );
      FlutterError.dumpErrorToConsole(details, forceReport: true);
      FlutterError.dumpErrorToConsole(details);
    } finally {
      debugPrint = saved;
      FlutterError.resetErrorCount();
    }
    expect(lines.length, greaterThan(5));
    final runtime = NabrilaRuntime(appKey: 'nbr_test');
    lines.forEach(runtime.recordPrint);
    runtime.recordPrint('a line of the app');
    expect(runtime.buffer.toJson().map((e) => e['message']), [
      'a line of the app',
    ]);
  });

  test('reports go over https only, but localhost in debug (AUD-07)', () {
    expect(isAllowedEndpoint('https://nabrila.com'), isTrue);
    expect(isAllowedEndpoint('http://nabrila.com'), isFalse);
    expect(isAllowedEndpoint('http://localhost:5173', debug: true), isTrue);
    expect(isAllowedEndpoint('http://10.0.2.2:5173', debug: true), isTrue);
    expect(isAllowedEndpoint('http://localhost:5173', debug: false), isFalse);
    expect(isAllowedEndpoint('nabrila.com'), isFalse);
  });

  test('the SDK client ignores HttpOverrides.global (CL-18)', () {
    final overrides = _CountingOverrides();
    final saved = HttpOverrides.current;
    HttpOverrides.global = overrides;
    addTearDown(() => HttpOverrides.global = saved);
    sdkHttpClient().close();
    expect(overrides.made, 0);
    HttpClient().close();
    expect(overrides.made, 1, reason: 'the app itself still gets them');
  });

  test('clearSession forgets the previous person (SOL #4)', () {
    final runtime = NabrilaRuntime(appKey: 'nbr_test');
    Nabrila.debugSetRuntime(runtime);
    runtime
      ..recordNavigation(action: 'push', fromRoute: null, toRoute: '/inbox')
      ..recordLog('info', 'hello ana');
    Nabrila.setContext('env', 'staging');
    Nabrila.clearSession();
    expect(runtime.buffer.length, 0);
    expect(runtime.activeRoute, isNull);
    expect(runtime.context, {'env': 'staging'});
  });

  test('the floating button fits any window, even a tiny one (AUD-18)', () {
    expect(
      clampButtonOffset(const Offset(-5, 900), const Size(400, 800)),
      const Offset(0, 744),
    );
    expect(
      clampButtonOffset(const Offset(30, 30), const Size(40, 40)),
      Offset.zero,
    );
  });

  test('drawings that fail are never dropped silently (AUD-05)', () async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawPaint(Paint()..color = const Color(0xFFFFFFFF));
    final base = await recorder.endRecording().toImage(10, 10);
    final png = Uint8List.fromList([1, 2, 3]);
    expect(await screenshotToSend(base, png, const []), same(png));
    await expectLater(
      screenshotToSend(base, png, [
        Block(const Rect.fromLTRB(0, 0, 1, 1)),
      ], compose: (_, _) async => null),
      throwsA(isA<AnnotationsLostException>()),
    );
    await expectLater(
      screenshotToSend(base, png, [
        Block(const Rect.fromLTRB(0, 0, 1, 1)),
      ], compose: (_, _) async => throw StateError('gpu')),
      throwsA(isA<AnnotationsLostException>()),
    );
  });

  testWidgets('a label is never read inside a mask or a field (AUD-05)', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          key: key,
          children: const [
            NabrilaMask(child: Text('4242 4242')),
            Text('Pay'),
          ],
        ),
      ),
    );
    expect(firstText(key.currentContext! as Element), 'Pay');
  });

  testWidgets('an icon button is named, not its plumbing (CL-22)', (
    tester,
  ) async {
    final runtime = NabrilaRuntime(appKey: 'nbr_test');
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(
      NabrilaScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    final tap = runtime.buffer.toJson().singleWhere((e) => e['kind'] == 'tap');
    expect(tap['targetHint'], 'IconButton');
    runtime.delivery.dispose();
  });

  testWidgets('no capture while a transition shows an old picture (CL-04)', (
    tester,
  ) async {
    final key = GlobalKey();
    final controller = SnapshotController(allowSnapshotting: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: SnapshotWidget(
            controller: controller,
            child: const NabrilaMask(
              child: SizedBox(width: 50, height: 50, child: Text('PIN')),
            ),
          ),
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final capture = await tester.runAsync(() async {
      final capturing = captureBoundary(
        boundary,
        1,
        root: key.currentContext! as Element,
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return capturing;
    });
    expect(capture, isNull);
    expect(RenderNabrilaMask.hidden.value, isFalse);
  });

  group('HTTP integrations', () {
    late NabrilaRuntime runtime;
    setUp(() {
      runtime = NabrilaRuntime(appKey: 'nbr_test');
      Nabrila.debugSetRuntime(runtime);
    });

    test('captureBodies keeps the response streaming (SOL #15)', () async {
      final body = StreamController<List<int>>();
      final client = NabrilaHttpClient(
        MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
        captureBodies: true,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://api.test/feed')),
      );
      // Headers arrive before the body ends, as they do without the SDK.
      final received = <int>[];
      final done = response.stream.forEach(received.addAll);
      body
        ..add(utf8.encode('{"token":"t",'))
        ..add(utf8.encode('"n":1}'));
      await body.close();
      await done;
      expect(utf8.decode(received), '{"token":"t","n":1}');
      final event = runtime.buffer.toJson().single;
      expect(event['resBodyPreview'], '{"token":"$redacted","n":1}');
      expect(event['resBytes'], received.length);
    });

    test('a binary request goes out untouched (Astra #26)', () async {
      final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe]);
      List<int>? sent;
      final client = NabrilaHttpClient(
        MockClient((request) async {
          sent = request.bodyBytes;
          return http.Response.bytes(
            png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
        captureBodies: true,
      );
      final request = http.Request('POST', Uri.parse('https://api.test/upload'))
        ..headers['content-type'] = 'image/png'
        ..bodyBytes = png;
      final response = await http.Response.fromStream(
        await client.send(request),
      );
      expect(sent, png);
      expect(response.bodyBytes, png);
      final event = runtime.buffer.toJson().single;
      expect(event.containsKey('reqBodyPreview'), isFalse);
      expect(event.containsKey('resBodyPreview'), isFalse);
    });

    test('a URL the SDK cannot read never breaks the call (AUD-07)', () async {
      final client = NabrilaHttpClient(
        MockClient((request) async => http.Response('ok', 200)),
      );
      final response = await client.get(Uri.parse('https://api.test/?%FF=1'));
      expect(response.body, 'ok');
    });

    test('Dio: bytes are never serialized (CL-25)', () async {
      final dio = Dio()..httpClientAdapter = _BytesAdapter();
      dio.interceptors.add(NabrilaDioInterceptor(captureBodies: true));
      await dio.post<List<int>>(
        'https://api.test/photo',
        data: Uint8List.fromList(List.filled(1000, 7)),
        options: Options(
          contentType: 'image/jpeg',
          responseType: ResponseType.bytes,
        ),
      );
      final event = runtime.buffer.toJson().single;
      expect(event.containsKey('reqBodyPreview'), isFalse);
      expect(event.containsKey('resBodyPreview'), isFalse);
    });
  });
}

class _CountingOverrides extends HttpOverrides {
  int made = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    made++;
    return super.createHttpClient(context);
  }
}

class _BytesAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromBytes(
      List.filled(500, 9),
      200,
      headers: {
        Headers.contentTypeHeader: ['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
