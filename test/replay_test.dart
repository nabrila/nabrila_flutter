import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nabrila/nabrila.dart';
import 'package:nabrila/src/envelope.dart';
import 'package:nabrila/src/replay/replay_codec.dart';
import 'package:nabrila/src/replay/replay_masks.dart';
import 'package:nabrila/src/replay/replay_recorder.dart';

import 'support/open_envelope.dart';

const _red = Color(0xFFFF0000);

/// A page with a mask, a text field and three hidden fields, under a route
/// that was pushed over another page with its own text field.
Widget _app(GlobalKey boundary) => RepaintBoundary(
  key: boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    home: const Scaffold(body: TextField()),
    routes: {
      '/top': (_) => Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 40),
            const NabrilaMask(
              child: SizedBox(width: 120, height: 30, child: Text('4242')),
            ),
            const SizedBox(height: 20),
            const SizedBox(width: 200, child: TextField()),
            const Opacity(opacity: 0, child: TextField()),
            const Offstage(child: TextField()),
            const Visibility(visible: false, child: TextField()),
            Container(width: 60, height: 60, color: _red),
          ],
        ),
      ),
    },
  ),
);

Future<void> _pushTop(WidgetTester tester, GlobalKey boundary) async {
  await tester.pumpWidget(_app(boundary));
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  navigator.pushNamed('/top');
  await tester.pumpAndSettle();
}

Future<Uint8List> _rgba(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData();
  final width = frame.image.width;
  frame.image.dispose();
  return Uint8List.fromList([width, ...data!.buffer.asUint8List()]);
}

Color _pixel(Uint8List rgbaWithWidth, int width, int x, int y) {
  final i = 1 + (y * width + x) * 4;
  return Color.fromARGB(
    rgbaWithWidth[i + 3],
    rgbaWithWidth[i],
    rgbaWithWidth[i + 1],
    rgbaWithWidth[i + 2],
  );
}

void main() {
  testWidgets('masks the mask and the visible text field only', (tester) async {
    final boundary = GlobalKey();
    await _pushTop(tester, boundary);
    final element = boundary.currentContext! as Element;
    final box = element.findRenderObject()! as RenderBox;

    final scan = scanMasks(element, box);

    expect(scan.frozen, isFalse);
    // The NabrilaMask and the one visible TextField; the hidden ones and the
    // field of the page behind the current route add nothing.
    expect(scan.rects, hasLength(2));
    final mask = tester.getRect(find.byType(NabrilaMask));
    expect(scan.rects.first, mask);
    // The finder skips the offstage page, so the first field is the visible one.
    final field = tester.getRect(find.byType(EditableText).first);
    expect(scan.rects.last.overlaps(field), isTrue);
  });

  testWidgets('maskAllText and maskAllImages cover every text and image', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('Ana Quispe'),
              SizedBox(width: 40, height: 40, child: RawImage()),
            ],
          ),
        ),
      ),
    );
    final element = boundary.currentContext! as Element;
    final box = element.findRenderObject()! as RenderBox;

    expect(scanMasks(element, box).rects, isEmpty);
    expect(scanMasks(element, box, maskText: true).rects, hasLength(1));
    expect(
      scanMasks(element, box, maskText: true, maskImages: true).rects,
      hasLength(2),
    );
  });

  testWidgets('a frame covers masked pixels and keeps the rest', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _pushTop(tester, boundary);
    final recorder = ReplayRecorder(
      options: const NabrilaReplay(maxSide: 4000),
    );

    await tester.runAsync(
      () => recorder.debugCaptureNow(() => boundary.currentContext),
    );

    expect(recorder.frames, hasLength(1));
    final frame = recorder.frames.single;
    // No native encoder under flutter_test: the frame falls back to PNG.
    expect(frame.format, 'png');
    final pixels = (await tester.runAsync(() => _rgba(frame.bytes)))!;
    final width = frame.width;
    final ratio = width / tester.getSize(find.byKey(boundary)).width;
    Offset scaled(Offset o) => o * ratio;

    final mask = scaled(tester.getCenter(find.byType(NabrilaMask)));
    expect(
      _pixel(pixels, width, mask.dx.round(), mask.dy.round()),
      replayMaskColor,
    );
    final red = scaled(tester.getCenter(find.byType(Container).last));
    expect(_pixel(pixels, width, red.dx.round(), red.dy.round()), _red);
    expect(recorder.stats.syncMicros, hasLength(1));
  });

  test('frames that fit the budget are the newest ones', () {
    ReplayFrame f(int ms, int size) => ReplayFrame(
      at: DateTime(2026, 1, 1).add(Duration(milliseconds: ms)),
      bytes: Uint8List(size),
      width: 1,
      height: 1,
    );
    final kept = framesWithin([f(0, 50), f(1000, 40), f(2000, 30)], 75);
    expect(kept.map((e) => e.bytes.length), [40, 30]);
  });

  test('without the native encoder the report carries single frames', () async {
    final origin = DateTime.utc(2026, 11, 26, 14);
    final screenshot = Uint8List.fromList(List.filled(10, 7));
    final frames = [
      ReplayFrame(
        at: origin.subtract(const Duration(seconds: 2)),
        bytes: Uint8List.fromList(List.filled(5, 1)),
        format: 'png',
        width: 412,
        height: 915,
      ),
      ReplayFrame(
        at: origin.add(const Duration(milliseconds: 1500)),
        bytes: Uint8List.fromList(List.filled(6, 2)),
        format: 'png',
        width: 412,
        height: 915,
      ),
    ];
    final sealed = await sealReport(
      manifest: {'schemaVersion': 1, 'events': <Object>[]},
      png: screenshot,
      replay: ReplayTake(frames: frames, origin: origin),
    );

    final opened = await openEnvelope(sealed.envelope, sealed.key);
    final manifest = opened.manifest;
    expect(manifest['screenshotBytes'], 10);
    final replay = manifest['replay']! as Map<String, Object?>;
    expect(replay['format'], 'images');
    final meta = (replay['frames']! as List).cast<Map<String, Object?>>();
    expect(meta.map((m) => m['tMs']), [-2000, 1500]);
    expect(meta.map((m) => m['bytes']), [5, 6]);
    final rest = opened.png!;
    expect(rest.sublist(0, 10), screenshot);
    expect(rest.sublist(10, 15), List.filled(5, 1));
    expect(rest.sublist(15), List.filled(6, 2));
  });

  test('with the native encoder the report carries one video', () async {
    final origin = DateTime.utc(2026, 11, 26, 14);
    final codec = _FakeCodec();
    ReplayFrame jpeg(int ms, int fill) => ReplayFrame(
      at: origin.add(Duration(milliseconds: ms)),
      bytes: Uint8List.fromList(List.filled(4, fill)),
      width: 390,
      height: 844,
    );
    final sealed = await sealReport(
      manifest: {'schemaVersion': 1, 'events': <Object>[]},
      png: Uint8List.fromList(List.filled(10, 7)),
      replay: ReplayTake(
        frames: [jpeg(-3000, 1), jpeg(-1800, 2), jpeg(-400, 3)],
        origin: origin,
        codec: codec,
      ),
    );

    // The 1.4 s pause is shortened to 1.5 s at most: it stays as it is.
    expect(codec.times, [0, 1200, 2600]);
    final opened = await openEnvelope(sealed.envelope, sealed.key);
    final replay = opened.manifest['replay']! as Map<String, Object?>;
    expect(replay['format'], 'mp4');
    expect(replay['bytes'], 3);
    final meta = (replay['frames']! as List).cast<Map<String, Object?>>();
    expect(meta.map((m) => m['tMs']), [-3000, -1800, -400]);
    expect(meta.map((m) => m['vMs']), [0, 1200, 2600]);
    expect(opened.png!.sublist(10), [9, 9, 9]);
  });

  test('idle pauses are shortened in the video, not in the report', () {
    final t0 = DateTime(2026);
    ReplayFrame at(int ms) => ReplayFrame(
      at: t0.add(Duration(milliseconds: ms)),
      bytes: Uint8List(1),
      width: 1,
      height: 1,
    );
    expect(videoTimes([at(0), at(1000), at(41000), at(42200)]), [
      0,
      1000,
      2500,
      3700,
    ]);
  });

  test('a video heavier than its frames is replaced by the frames', () async {
    final origin = DateTime.utc(2026, 11, 26, 14);
    final frames = [
      for (var i = 0; i < 3; i++)
        ReplayFrame(
          at: origin.add(Duration(seconds: i)),
          bytes: Uint8List(100),
          width: 390,
          height: 844,
        ),
    ];
    final sealed = await sealReport(
      manifest: {'schemaVersion': 1},
      png: null,
      replay: ReplayTake(
        frames: frames,
        origin: origin,
        codec: _FakeCodec(bytesPerFrame: 150),
      ),
    );

    final opened = await openEnvelope(sealed.envelope, sealed.key);
    final replay = opened.manifest['replay']! as Map<String, Object?>;
    expect(replay['format'], 'images');
    expect((replay['frames']! as List), hasLength(3));
  });

  test('a video over the budget keeps the newest half', () async {
    final origin = DateTime.utc(2026, 11, 26, 14);
    final codec = _FakeCodec(bytesPerFrame: 600000);
    final frames = [
      for (var i = 0; i < 8; i++)
        ReplayFrame(
          at: origin.add(Duration(seconds: i)),
          bytes: Uint8List(700000),
          width: 390,
          height: 844,
        ),
    ];
    final take = ReplayTake(frames: frames, origin: origin, codec: codec);
    final sealed = await sealReport(
      manifest: {'schemaVersion': 1},
      png: null,
      replay: take,
    );

    final opened = await openEnvelope(sealed.envelope, sealed.key);
    final replay = opened.manifest['replay']! as Map<String, Object?>;
    // 8 frames are 4.8 MB and 4 are 2.4 MB: only the newest 2 fit.
    expect((replay['frames']! as List), hasLength(2));
    expect(replay['format'], 'mp4');
  });
}

class _FakeCodec extends ReplayCodec {
  _FakeCodec({this.bytesPerFrame});

  final int? bytesPerFrame;
  List<int>? times;

  @override
  Future<Uint8List?> video(
    List<Uint8List> frames,
    List<int> times,
    int width,
    int height, {
    int bitrate = 0,
    double quality = 0,
  }) async {
    this.times = times;
    final size = bytesPerFrame;
    return size == null
        ? Uint8List.fromList([9, 9, 9])
        : Uint8List(size * frames.length);
  }
}
