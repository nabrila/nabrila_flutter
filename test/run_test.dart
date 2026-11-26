import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nabrila/nabrila.dart';
import 'package:nabrila/src/annotations.dart';
import 'package:nabrila/src/capture.dart';
import 'package:nabrila/src/mask.dart';
import 'package:nabrila/src/runtime.dart';

void main() {
  tearDown(() => Nabrila.debugSetRuntime(null));

  test('run with enabled false only calls the app', () {
    var called = 0;
    Nabrila.run(appKey: 'nbr_x', enabled: false, app: () => called++);
    expect(called, 1);
    expect(Nabrila.isEnabled, isFalse);
    expect(NabrilaRuntime.current, isNull);
  });

  testWidgets('run with enabled true captures print and chains error hooks', (
    tester,
  ) async {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    final seenByFlutter = <String>[];
    final seenByPlatform = <Object>[];
    FlutterError.onError = (details) =>
        seenByFlutter.add(details.exceptionAsString());
    PlatformDispatcher.instance.onError = (error, stack) {
      seenByPlatform.add(error);
      return true;
    };
    addTearDown(() {
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    });

    Nabrila.run(
      appKey: 'nbr_x',
      enabled: true,
      app: () {
        // ignore: avoid_print
        print('hello from the app');
        debugPrint('hello from debugPrint');
      },
    );
    final runtime = NabrilaRuntime.current!;
    final logs = runtime.buffer.toJson();
    expect(logs.map((e) => e['message']), contains('hello from the app'));
    expect(logs.map((e) => e['message']), contains('hello from debugPrint'));

    FlutterError.onError!(FlutterErrorDetails(exception: Exception('boom')));
    expect(seenByFlutter.single, contains('boom'));
    expect(
      PlatformDispatcher.instance.onError!(StateError('bad'), StackTrace.empty),
      isTrue,
    );
    expect(seenByPlatform.single, isA<StateError>());
    final errors = runtime.buffer.toJson().where((e) => e['level'] == 'error');
    expect(errors.length, 2);
  });

  testWidgets('the capture paints a NabrilaMask as a solid block', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: const Align(
            alignment: Alignment.topLeft,
            child: NabrilaMask(
              child: SizedBox(
                width: 100,
                height: 100,
                child: ColoredBox(color: Color(0xFF00FF00)),
              ),
            ),
          ),
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;

    await tester.runAsync(() async {
      final capturing = captureBoundary(boundary, 1);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final capture = (await capturing)!;
      final rgba = (await capture.image.toByteData())!.getUint32(0);
      expect(rgba, 0x000000FF, reason: 'mask exported as opaque black');
      capture.dispose();
      expect(RenderNabrilaMask.hidden.value, isFalse);
    });
    // Outside a capture the child paints normally.
    await tester.pump();
    final normal = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData();
      return data!.getUint32(0);
    });
    expect(normal, 0x00FF00FF);
  });

  test('annotations are drawn into a PNG within the size cap', () async {
    final recorder = PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 100, 200),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final base = await recorder.endRecording().toImage(100, 200);
    final png = await composeAnnotated(base, [
      Stroke(const [Offset(0.1, 0.1), Offset(0.9, 0.9)]),
      Block(const Rect.fromLTRB(0.5, 0.0, 1.0, 0.5)),
    ]);
    expect(png, isNotNull);
    expect(png!.length, lessThanOrEqualTo(maxPngBytes));
    expect(png.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
  });
}
