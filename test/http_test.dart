import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nabrila/dio.dart';
import 'package:nabrila/nabrila.dart';
import 'package:nabrila/src/runtime.dart';

class _FakeAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{"token":"zzz","ok":true}',
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
      'set-cookie': ['sid=1'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  late NabrilaRuntime runtime;

  setUp(() {
    runtime = NabrilaRuntime(appKey: 'nbr_test');
    Nabrila.debugSetRuntime(runtime);
  });
  tearDown(() => Nabrila.debugSetRuntime(null));

  final inner = MockClient(
    (request) async => http.Response(
      '{"password":"p","name":"ana"}',
      200,
      headers: {'set-cookie': 'sid=1', 'content-type': 'application/json'},
    ),
  );

  test(
    'NabrilaHttpClient keeps only method, URL, status, time and size',
    () async {
      final client = NabrilaHttpClient(inner);
      await client.post(
        Uri.parse('https://api.example.com/pay?token=abc'),
        headers: {'Authorization': 'Bearer secret'},
        body: 'card=4242',
      );
      final event = runtime.buffer.toJson().single;
      expect(event['kind'], 'http');
      expect(event['method'], 'POST');
      expect(
        event['sanitizedUrl'],
        'https://api.example.com/pay?token=[REDACTED]',
      );
      expect(event['statusCode'], 200);
      expect(event.containsKey('reqHeaders'), isFalse);
      expect(event.containsKey('resHeaders'), isFalse);
      expect(event.containsKey('reqBodyPreview'), isFalse);
      expect(event.containsKey('resBodyPreview'), isFalse);
    },
  );

  test('captureBodies true records redacted headers and bodies', () async {
    final client = NabrilaHttpClient(inner, captureBodies: true);
    final response = await client.post(
      Uri.parse('https://api.example.com/pay'),
      headers: {
        'Authorization': 'Bearer secret',
        'content-type': 'application/json',
      },
      body: '{"password":"hunter2","amount":5}',
    );
    expect(
      response.body,
      contains('ana'),
      reason: 'body still reaches the app',
    );
    final event = runtime.buffer.toJson().single;
    expect((event['reqHeaders'] as Map)['authorization'], '[REDACTED]');
    expect((event['resHeaders'] as Map)['set-cookie'], '[REDACTED]');
    expect(event['reqBodyPreview'], '{"password":"[REDACTED]","amount":5}');
    expect(event['resBodyPreview'], '{"password":"[REDACTED]","name":"ana"}');
  });

  test('a failing call is recorded without a status and rethrown', () async {
    final client = NabrilaHttpClient(
      MockClient((_) async => throw http.ClientException('offline')),
    );
    await expectLater(
      client.get(Uri.parse('https://api.example.com/x')),
      throwsA(isA<http.ClientException>()),
    );
    expect(runtime.buffer.toJson().single.containsKey('statusCode'), isFalse);
  });

  test('nothing is recorded while the SDK is off', () async {
    Nabrila.debugSetRuntime(null);
    await NabrilaHttpClient(inner).get(Uri.parse('https://api.example.com/x'));
    expect(runtime.buffer.length, 0);
  });

  test('NabrilaDioInterceptor records a call and redacts on opt-in', () async {
    final dio = Dio()..httpClientAdapter = _FakeAdapter();
    dio.interceptors.add(NabrilaDioInterceptor());
    await dio.get<dynamic>('https://api.example.com/me?api_key=k');
    var event = runtime.buffer.toJson().single;
    expect(
      event['sanitizedUrl'],
      'https://api.example.com/me?api_key=[REDACTED]',
    );
    expect(event['statusCode'], 200);
    expect(event.containsKey('resBodyPreview'), isFalse);

    final dio2 = Dio()..httpClientAdapter = _FakeAdapter();
    dio2.interceptors.add(NabrilaDioInterceptor(captureBodies: true));
    await dio2.get<dynamic>('https://api.example.com/me');
    event = runtime.buffer.toJson().last;
    expect(event['resBodyPreview'], '{"token":"[REDACTED]","ok":true}');
    expect((event['resHeaders'] as Map)['set-cookie'], '[REDACTED]');
  });
}
