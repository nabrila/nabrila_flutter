import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nabrila/dio.dart';
import 'package:nabrila/nabrila.dart';
import 'package:nabrila/src/capture.dart';
import 'package:nabrila/src/clipboard.dart';
import 'package:nabrila/src/redaction.dart';
import 'package:nabrila/src/runtime.dart';

/// Gaps an independent review found in the fixes of docs/security-audit.md.
void main() {
  tearDown(() => Nabrila.debugSetRuntime(null));

  group('paths and emails (SOL #3)', () {
    test('a JWT, a long token or an email in the path is redacted', () {
      final jwt = sanitizeUrl(
        Uri.parse(
          'https://a.test/reset/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc',
        ),
      );
      expect(jwt, 'https://a.test/reset/$redacted');
      expect(
        sanitizeUrl(
          Uri.parse('https://a.test/verify/a1b2c3d4e5f6g7h8i9j0k1l2'),
        ),
        'https://a.test/verify/$redacted',
      );
      expect(
        sanitizeUrl(Uri.parse('https://a.test/users/ana%40mail.com/profile')),
        'https://a.test/users/$redacted/profile',
      );
    });

    test('a normal route stays as it is', () {
      expect(
        sanitizeUrl(Uri.parse('https://a.test/api/v1/users/42/orders')),
        'https://a.test/api/v1/users/42/orders',
      );
      // A record id keeps the request reproducible.
      expect(
        sanitizeUrl(
          Uri.parse(
            'https://a.test/orders/550e8400-e29b-41d4-a716-446655440000',
          ),
        ),
        'https://a.test/orders/550e8400-e29b-41d4-a716-446655440000',
      );
      expect(
        sanitizeUrl(Uri.parse('https://a.test/internationalization-settings')),
        'https://a.test/internationalization-settings',
      );
    });

    test('an email in a log line is redacted', () {
      final runtime = NabrilaRuntime(appKey: 'nbr_test')
        ..recordLog('info', 'signed in as ana.perez+qa@mail.example.com ok');
      final message = runtime.buffer.toJson().single['message']! as String;
      expect(message, 'signed in as $redacted ok');
    });
  });

  test('a call that answers after clearSession is dropped (SOL #4)', () async {
    final runtime = NabrilaRuntime(appKey: 'nbr_test');
    Nabrila.debugSetRuntime(runtime);
    final answer = Completer<http.Response>();
    final client = NabrilaHttpClient(MockClient((_) => answer.future));
    final call = client.get(Uri.parse('https://api.test/me'));
    await Future<void>.delayed(Duration.zero);
    Nabrila.clearSession();
    answer.complete(http.Response('ok', 200));
    await call;
    expect(runtime.buffer.length, 0);
    // A call that starts after the change is kept.
    await client.get(Uri.parse('https://api.test/me'));
    expect(runtime.buffer.length, 1);
  });

  testWidgets('a snapshot that ends while waiting still captures (CL-04)', (
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
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      controller.allowSnapshotting = false;
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return capturing;
    });
    expect(capture, isNotNull);
    capture!.dispose();
  });

  group('error hooks', () {
    void restoreAfter() {
      final flutter = FlutterError.onError;
      final platform = PlatformDispatcher.instance.onError;
      addTearDown(() {
        FlutterError.onError = flutter;
        PlatformDispatcher.instance.onError = platform;
      });
    }

    testWidgets('a handler assigned after an await and a frame (CL-23)', (
      tester,
    ) async {
      restoreAfter();
      FlutterError.onError = (_) {};
      final seenByApp = <String>[];
      Nabrila.run(
        appKey: 'nbr_x',
        enabled: true,
        app: () => unawaited(
          Future<void>.delayed(const Duration(milliseconds: 5)).then((_) {
            FlutterError.onError = (details) =>
                seenByApp.add(details.exceptionAsString());
          }),
        ),
      );
      // The timer lives in the test's fake clock, so time is moved with pump.
      await tester.pump(const Duration(milliseconds: 30));
      // A frame draws only with a tree; every real app has one.
      await tester.pumpWidget(const SizedBox());
      FlutterError.onError!(FlutterErrorDetails(exception: Exception('late')));
      expect(seenByApp, hasLength(1));
      final errors = NabrilaRuntime.current!.buffer.toJson().where(
        (e) => e['level'] == 'error',
      );
      expect(errors.single['message'], contains('late'));
    });

    testWidgets('a second run takes the errors, not the first (AUD-18)', (
      tester,
    ) async {
      restoreAfter();
      FlutterError.onError = (_) {};
      Nabrila.run(appKey: 'nbr_a', enabled: true, app: () {});
      final first = NabrilaRuntime.current!;
      Nabrila.run(appKey: 'nbr_b', enabled: true, app: () {});
      final second = NabrilaRuntime.current!;
      expect(identical(first, second), isFalse);
      FlutterError.onError!(FlutterErrorDetails(exception: Exception('two')));
      expect(first.buffer.length, 0);
      expect(second.buffer.toJson().single['message'], contains('two'));
    });
  });

  test('an endpoint without https leaves the SDK off (AUD-07)', () {
    var called = 0;
    Nabrila.run(
      appKey: 'nbr_x',
      enabled: true,
      endpoint: 'http://x.com',
      app: () => called++,
    );
    expect(called, 1);
    expect(NabrilaRuntime.current, isNull);
    expect(Nabrila.isEnabled, isFalse);
  });

  test('a runtime without a client ignores HttpOverrides.global (CL-18)', () {
    final overrides = _CountingOverrides();
    final saved = HttpOverrides.current;
    HttpOverrides.global = overrides;
    addTearDown(() => HttpOverrides.global = saved);
    NabrilaRuntime(appKey: 'nbr_test').client.close();
    expect(overrides.made, 0);
  });

  testWidgets('the link goes to the sensitive copy with its key (CL-26)', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('nabrila/replay'),
      (call) async {
        calls.add(call);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('nabrila/replay'),
        null,
      ),
    );
    const link = 'https://nabrila.com/r/abc#k=EBESExQVFhcYGRobHB0eHyAhIiMk';
    await copySecret(link);
    expect(calls.single.method, 'copySensitive');
    expect((calls.single.arguments as Map)['text'], link);
  });

  test(
    'Dio: a List<int> without contentType is not serialized (CL-25)',
    () async {
      final runtime = NabrilaRuntime(appKey: 'nbr_test');
      Nabrila.debugSetRuntime(runtime);
      final dio = Dio()..httpClientAdapter = _EmptyAdapter();
      dio.interceptors.add(NabrilaDioInterceptor(captureBodies: true));
      await dio.post<Object>(
        'https://api.test/raw',
        data: List<int>.filled(100, 7),
        options: Options(headers: {Headers.contentTypeHeader: null}),
      );
      final event = runtime.buffer.toJson().single;
      expect(event.containsKey('reqBodyPreview'), isFalse);
    },
  );
}

class _CountingOverrides extends HttpOverrides {
  int made = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    made++;
    return super.createHttpClient(context);
  }
}

class _EmptyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}
