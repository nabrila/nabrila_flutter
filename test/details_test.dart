import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nabrila/nabrila.dart';
import 'package:nabrila/src/element_locator.dart';
import 'package:nabrila/src/events.dart';
import 'package:nabrila/src/manifest.dart';
import 'package:nabrila/src/replay/replay_masks.dart';
import 'package:nabrila/src/runtime.dart';
import 'package:nabrila/src/shake.dart';

void main() {
  tearDown(() {
    Nabrila.debugSetRuntime(null);
    ShakeTrigger.debugShakes = null;
  });

  group('app context', () {
    test('text, clipped, secrets redacted, at most 30 pairs', () {
      final context = <String, String>{};
      putContext(context, 'env', 'staging');
      putContext(context, 'beta', true);
      putContext(context, 'Session-Id', 'abc');
      putContext(context, 'long', 'x' * 500);
      putContext(context, '  ', 'ignored');
      expect(context['env'], 'staging');
      expect(context['beta'], 'true');
      expect(context['Session-Id'], '[REDACTED]');
      expect(context['long'], hasLength(200));
      expect(context.containsKey(''), isFalse);
      putContext(context, 'env', null);
      expect(context.containsKey('env'), isFalse);
      for (var i = 0; i < 40; i++) {
        putContext(context, 'k$i', i);
      }
      expect(context, hasLength(maxContextEntries));
      // An existing key still changes when the map is full.
      putContext(context, 'beta', false);
      expect(context['beta'], 'false');
    });

    test('the manifest carries kind, element and context only when set', () {
      Map<String, Object?> build({String? kind}) => buildManifest(
        capturedAt: DateTime.utc(2026),
        note: '',
        app: const AppInfo(appName: 'a', appVersion: '1', buildNumber: '1'),
        activeRoute: null,
        device: const DeviceInfo(
          platform: 'ios',
          osVersion: '18',
          logicalWidth: 1,
          logicalHeight: 1,
          pixelRatio: 1,
          textScaleFactor: 1,
          locale: null,
        ),
        events: EventBuffer(),
        kind: kind,
      );
      expect(build().containsKey('kind'), isFalse);
      expect(build().containsKey('context'), isFalse);
      expect(build().containsKey('element'), isFalse);
      expect(build(kind: 'visual')['kind'], 'visual');
      expect(build(kind: 'crash').containsKey('kind'), isFalse);
    });
  });

  group('source locations', () {
    test('only the app code, as a path from its package root', () {
      expect(
        appFile('file:///Users/ana/shop/lib/checkout/pay.dart'),
        'lib/checkout/pay.dart',
      );
      expect(
        appFile(r'file:///C:\Users\ana\shop\lib\main.dart'),
        'lib/main.dart',
      );
      expect(
        appFile(
          'file:///Users/ana/flutter/packages/flutter/lib/src/material/text.dart',
        ),
        isNull,
      );
      expect(
        appFile('file:///Users/ana/.pub-cache/hosted/pub.dev/x/lib/y.dart'),
        isNull,
      );
      expect(appFile('file:///Users/ana/shop/tool/gen.dart'), isNull);
    });
  });

  testWidgets('pointing inside a mask names the widget but not its text', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          home: Scaffold(
            body: NabrilaMask(
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('Card 4242'),
              ),
            ),
          ),
        ),
      ),
    );
    final box = key.currentContext!.findRenderObject()! as RenderBox;
    final center = tester.getCenter(find.text('Card 4242'));
    final pointed = locateElement(
      key.currentContext! as Element,
      box,
      xNorm: center.dx / box.size.width,
      yNorm: center.dy / box.size.height,
    );
    expect(pointed.label, isNull);
    expect(pointed.widget, 'ElevatedButton');
    expect(pointed.toJson().toString(), isNot(contains('4242')));
  });

  testWidgets('an icon is never named by its glyph', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
                IconButton(
                  tooltip: 'Cart',
                  onPressed: () {},
                  icon: const Icon(Icons.shopping_cart),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final box = key.currentContext!.findRenderObject()! as RenderBox;
    PointedElement at(IconData icon) {
      final c = tester.getCenter(find.byIcon(icon));
      return locateElement(
        key.currentContext! as Element,
        box,
        xNorm: c.dx / box.size.width,
        yNorm: c.dy / box.size.height,
      );
    }

    expect(at(Icons.add).widget, 'IconButton');
    expect(at(Icons.add).label, isNull);
    expect(at(Icons.shopping_cart).label, 'Cart');
  });

  testWidgets('native views are found and marked, never masked away', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              const SizedBox(height: 100),
              SizedBox(
                width: 300,
                height: 200,
                child: PlatformViewLink(
                  viewType: 'map',
                  surfaceFactory: (context, controller) =>
                      const ColoredBox(color: Color(0xFF000000)),
                  onCreatePlatformView: (params) {
                    params.onPlatformViewCreated(params.id);
                    return _FakeViewController(params.id);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final box = key.currentContext!.findRenderObject()! as RenderBox;
    final scan = scanMasks(key.currentContext! as Element, box);
    expect(scan.rects, isEmpty);
    expect(scan.native, hasLength(1));
    expect(scan.native.single.top, 100);
    expect(scan.native.single.height, 200);
  });

  testWidgets('shaking the phone opens the report', (tester) async {
    final shakes = StreamController<Object?>.broadcast();
    addTearDown(shakes.close);
    ShakeTrigger.debugShakes = shakes.stream;
    final runtime = NabrilaRuntime(appKey: 'nbr_test', storageDir: _noDisk);
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(
      const NabrilaScope(
        child: MaterialApp(home: Scaffold(body: Text('Shop'))),
      ),
    );
    await tester.runAsync(() async {
      shakes.add(null);
      for (var i = 0; i < 20 && find.text('Send').evaluate().isEmpty; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();
    expect(find.text('Send'), findsOneWidget);
    runtime.delivery.dispose();
  });

  testWidgets('shake off: shaking does nothing', (tester) async {
    final shakes = StreamController<Object?>.broadcast();
    addTearDown(shakes.close);
    ShakeTrigger.debugShakes = shakes.stream;
    final runtime = NabrilaRuntime(appKey: 'nbr_test', storageDir: _noDisk)
      ..shake = false;
    Nabrila.debugSetRuntime(runtime);
    await tester.pumpWidget(
      const NabrilaScope(
        child: MaterialApp(home: Scaffold(body: Text('Shop'))),
      ),
    );
    expect(shakes.hasListener, isFalse);
    runtime.delivery.dispose();
  });

  test('the clock of events never goes back', () {
    final runtime = NabrilaRuntime(appKey: 'nbr_test');
    var last = runtime.now();
    for (var i = 0; i < 1000; i++) {
      final now = runtime.now();
      expect(now.isBefore(last), isFalse);
      last = now;
    }
  });

  testWidgets('go_router: pushes, goes and shell tabs are recorded', (
    tester,
  ) async {
    final runtime = NabrilaRuntime(appKey: 'nbr_test', storageDir: _noDisk);
    Nabrila.debugSetRuntime(runtime);
    final router = GoRouter(
      initialLocation: '/home',
      observers: [Nabrila.navigatorObserver],
      routes: [
        ShellRoute(
          builder: (context, state, child) => Scaffold(body: child),
          routes: [
            GoRoute(path: '/home', builder: (_, _) => const Text('Home')),
            GoRoute(path: '/cart', builder: (_, _) => const Text('Cart')),
          ],
        ),
        GoRoute(
          path: '/product/:id',
          builder: (_, state) => Text('Product ${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      NabrilaScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();
    router.go('/cart');
    await tester.pumpAndSettle();
    unawaited(router.push('/product/7?ref=mail'));
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    final routes = [
      for (final e in runtime.buffer.toJson())
        if (e['kind'] == 'navigation') '${e['action']} ${e['toRoute']}',
    ];
    expect(routes, [
      'push /home',
      'push /cart',
      'push /product/:id',
      'pop /cart',
    ]);
    expect(runtime.activeRoute, '/cart');
    expect(routes.join(), isNot(contains('ref=mail')));
    runtime.delivery.dispose();
  });

  test('discarding removes every saved report', () async {
    final dir = Directory.systemTemp.createTempSync('nabrila-discard');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File('${dir.path}/1-a.nbr').writeAsBytesSync([1, 2, 3]);
    File('${dir.path}/1-a.json').writeAsStringSync(
      '{"v":1,"key":"AAAA","appKey":"nbr_x","endpoint":"https://x",'
      '"createdAt":"${DateTime.now().toUtc().toIso8601String()}",'
      '"attempts":0,"nextAt":"${DateTime.now().toUtc().toIso8601String()}"}',
    );
    final runtime = NabrilaRuntime(
      appKey: 'nbr_test',
      storageDir: () async => dir,
    );
    Nabrila.debugSetRuntime(runtime);
    await Nabrila.discardSavedReports();
    expect(dir.listSync(), isEmpty);
  });

  test('run with enabled false never throws without a binding', () {
    var called = 0;
    Nabrila.run(appKey: 'nbr_x', enabled: false, app: () => called++);
    expect(called, 1);
  });
}

Future<Directory?> _noDisk() async => null;

class _FakeViewController extends PlatformViewController {
  _FakeViewController(this.viewId);

  @override
  final int viewId;

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}

  @override
  Future<void> dispose() async {}
}
