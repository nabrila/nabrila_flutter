import 'package:flutter_test/flutter_test.dart';
import 'package:nabrila/src/events.dart';
import 'package:nabrila/src/manifest.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 26, 12);

  test('the ring buffer keeps only the last 150 events', () {
    final buffer = EventBuffer();
    for (var i = 0; i < 200; i++) {
      buffer.add(
        RecordedEvent.log(
          at: t0.add(Duration(milliseconds: i)),
          level: 'info',
          message: 'm$i',
        ),
      );
    }
    final json = buffer.toJson();
    expect(json.length, 150);
    expect(json.first['message'], 'm50');
    expect(json.last['message'], 'm199');
    expect(json.first['tMs'], 0);
    expect(json.last['tMs'], 149);
  });

  test('events carry the shape of architecture 3.4', () {
    final buffer = EventBuffer()
      ..add(
        RecordedEvent.navigation(
          at: t0,
          action: 'push',
          fromRoute: '/cart',
          toRoute: '/checkout',
        ),
      )
      ..add(
        RecordedEvent.tap(
          at: t0.add(const Duration(seconds: 1)),
          xNorm: 1.4,
          yNorm: -2,
          targetHint: 'x' * 200,
        ),
      )
      ..add(
        RecordedEvent.http(
          at: t0.add(const Duration(seconds: 2)),
          method: 'POST',
          sanitizedUrl: 'https://a.example/x',
          statusCode: 502,
          durationMs: 10,
        ),
      );
    final json = buffer.toJson();
    expect(json[0], {
      'kind': 'navigation',
      'tMs': 0,
      'action': 'push',
      'fromRoute': '/cart',
      'toRoute': '/checkout',
    });
    expect(json[1]['kind'], 'tap');
    expect(json[1]['xNorm'], 1.0);
    expect(json[1]['yNorm'], 0.0);
    expect((json[1]['targetHint'] as String).length, 80);
    expect(json[2]['statusCode'], 502);
    expect(json[2].containsKey('reqHeaders'), isFalse);
  });

  test('the manifest has the required fields and caps the note', () {
    final manifest = buildManifest(
      capturedAt: t0,
      note: '  ${'n' * 1200}  ',
      app: const AppInfo(appName: 'Demo', appVersion: '1.0', buildNumber: '7'),
      activeRoute: '/home',
      device: const DeviceInfo(
        platform: 'android',
        osVersion: '15',
        logicalWidth: 412,
        logicalHeight: 915,
        pixelRatio: 2.6,
        textScaleFactor: 1,
        locale: 'es-BO',
      ),
      events: EventBuffer(),
    );
    expect(manifest['schemaVersion'], 1);
    expect(manifest['capturedAt'], '2026-11-26T12:00:00.000Z');
    expect((manifest['note'] as String).length, 1000);
    expect((manifest['app'] as Map)['sdkVersion'], '0.1.0');
    expect((manifest['app'] as Map)['activeRoute'], '/home');
    expect(manifest['events'], isEmpty);
  });
}
