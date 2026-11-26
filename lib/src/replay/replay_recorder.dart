import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../native_views.dart';
import 'replay_codec.dart';
import 'replay_masks.dart';
import 'replay_options.dart';

/// Color of the boxes that cover masked zones in replay frames.
const Color replayMaskColor = Color(0xFF1F2937);

/// One picture of the app, already masked and encoded.
class ReplayFrame {
  const ReplayFrame({
    required this.at,
    required this.bytes,
    required this.width,
    required this.height,
    this.format = 'jpeg',
  });

  final DateTime at;
  final Uint8List bytes;
  final int width;
  final int height;

  /// `jpeg` from the native encoder, or `png` where it is missing.
  final String format;
}

/// What the recorder did, for benchmarks and tests.
class ReplayStats {
  /// Time spent on the UI thread per frame: the mask scan and the `toImage`
  /// call. This is the part that can make the app stutter.
  final List<int> syncMicros = [];

  /// From the capture to the encoded frame being ready (mostly off the UI
  /// thread).
  final List<int> totalMicros = [];

  /// Encoded size of every frame that was produced.
  final List<int> bytes = [];

  /// Frames that fell back to PNG because the native encoder was missing.
  int png = 0;

  int skippedSame = 0;
  int skippedFrozen = 0;
  int failures = 0;

  Map<String, Object?> toJson() => {
    'frames': bytes.length,
    'skippedSame': skippedSame,
    'skippedFrozen': skippedFrozen,
    'failures': failures,
    'png': png,
    'syncMicros': _summary(syncMicros),
    'totalMicros': _summary(totalMicros),
    'bytes': _summary(bytes),
  };

  static Map<String, int> _summary(List<int> values) {
    if (values.isEmpty) return const {};
    final sorted = [...values]..sort();
    int at(double p) => sorted[((sorted.length - 1) * p).round()];
    return {
      'p50': at(0.5),
      'p90': at(0.9),
      'p99': at(0.99),
      'max': sorted.last,
    };
  }
}

/// Keeps the last moments of the app as small masked JPEGs, in memory.
///
/// It copies what Flutter itself painted (`RenderRepaintBoundary.toImage`),
/// so the phone asks for no permission and nothing outside the app is seen.
/// A picture is taken only when a frame was painted since the last one, at
/// most once per [interval]; an idle app costs nothing. Masks are painted on
/// the copy, never on screen. Frames never touch the disk or the network
/// until the person sends a report.
class ReplayRecorder with WidgetsBindingObserver {
  ReplayRecorder({
    this.options = const NabrilaReplay(),
    ReplayCodec codec = const ReplayCodec(),
    DateTime Function()? clock,
  }) : _codec = codec,
       _clock = clock ?? DateTime.now;

  final NabrilaReplay options;

  final ReplayCodec _codec;
  final DateTime Function() _clock;
  final ListQueue<ReplayFrame> _frames = ListQueue<ReplayFrame>();
  final ReplayStats stats = ReplayStats();

  BuildContext? Function()? _boundary;
  Timer? _timer;
  int _bytes = 0;
  bool _running = false;
  bool _hooked = false;
  bool _paused = false;
  bool _foreground = true;
  bool _busy = false;
  bool _dirty = true;
  bool _ownFrame = false;
  DateTime? _last;

  /// Frames kept right now, oldest first.
  List<ReplayFrame> get frames => List.unmodifiable(_frames);

  /// Starts recording what is painted under the `RepaintBoundary` whose
  /// context [boundary] returns.
  void attach(BuildContext? Function() boundary) {
    _boundary = boundary;
    if (_running) return;
    _running = true;
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    if (!_hooked) {
      _hooked = true;
      binding.addPersistentFrameCallback(_onFrame);
    }
    unawaited(
      _codec.supported().then((ok) {
        if (!_running || _timer != null) return;
        if (!ok) return detach();
        _timer = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => _tick(),
        );
      }),
    );
  }

  void detach() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _boundary = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Stops taking frames (while the report sheet is open) and keeps them.
  void pause() => _paused = true;

  void resume() {
    _paused = false;
    _dirty = true;
  }

  void clear() {
    _frames.clear();
    _bytes = 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _dirty = true;
  }

  void _onFrame(Duration _) {
    if (!_ownFrame) _dirty = true;
  }

  void _tick() {
    if (!_running || _paused || _busy || !_dirty || !_foreground) return;
    final now = _clock();
    final last = _last;
    if (last != null && now.difference(last) < options.frameInterval) return;
    _busy = true;
    _dirty = false;
    _ownFrame = true;
    // Captured right after a frame is painted, when the tree is clean.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _ownFrame = false;
      unawaited(_capture() ?? Future<void>.value());
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Takes one frame right now, as the timer would. Tests only.
  @visibleForTesting
  Future<void> debugCaptureNow(BuildContext? Function() boundary) async {
    _boundary = boundary;
    _running = true;
    _busy = true;
    await _capture();
  }

  /// Must not be async: the mask scan and `toImage` have to see the same
  /// frame, with no gap between them. Returns the rest of the work, or null
  /// when no frame was taken.
  Future<void>? _capture() {
    final context = _boundary?.call();
    final box = context?.findRenderObject();
    // The app may have left the foreground since the frame was scheduled:
    // copying a surface that is being torn down crashes some GPU drivers
    // (Impeller on Vulkan and GLES).
    if (!_running ||
        !_foreground ||
        context is! Element ||
        box is! RenderRepaintBoundary ||
        !box.hasSize ||
        box.size.isEmpty) {
      _busy = false;
      return null;
    }
    final at = _clock();
    final total = Stopwatch()..start();
    final sync = Stopwatch()..start();
    final MaskScan scan;
    final Future<ui.Image> pending;
    final double ratio;
    try {
      scan = scanMasks(
        context,
        box,
        maskText: options.maskAllText,
        maskImages: options.maskAllImages,
      );
      if (scan.frozen) {
        stats.skippedFrozen++;
        _dirty = true;
        _busy = false;
        return null;
      }
      final density =
          ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1;
      ratio = math.min(
        math.min(1.0, density),
        options.maxSide / math.max(box.size.width, box.size.height),
      );
      pending = box.toImage(pixelRatio: ratio);
    } on Object {
      stats.failures++;
      _busy = false;
      return null;
    }
    sync.stop();
    return _finish(pending, scan.rects, scan.native, ratio, at, sync, total);
  }

  Future<void> _finish(
    Future<ui.Image> pending,
    List<Rect> rects,
    List<Rect> native,
    double ratio,
    DateTime at,
    Stopwatch sync,
    Stopwatch total,
  ) async {
    try {
      final raw = await pending;
      final width = raw.width;
      final height = raw.height;
      var image = raw;
      if (rects.isNotEmpty || native.isNotEmpty) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..drawImage(raw, Offset.zero, Paint());
        final paint = Paint()..color = replayMaskColor;
        for (final r in rects) {
          canvas.drawRect(
            Rect.fromLTRB(
              r.left * ratio,
              r.top * ratio,
              r.right * ratio,
              r.bottom * ratio,
            ),
            paint,
          );
        }
        paintNativePlaceholders(canvas, native, ratio);
        final picture = recorder.endRecording();
        try {
          image = await picture.toImage(width, height);
        } finally {
          picture.dispose();
          raw.dispose();
        }
      }
      final Uint8List? bytes;
      final String format;
      try {
        (bytes, format) = await _encode(image);
      } finally {
        image.dispose();
      }
      if (bytes == null) {
        stats.failures++;
        return;
      }
      total.stop();
      stats.syncMicros.add(sync.elapsedMicroseconds);
      stats.totalMicros.add(total.elapsedMicroseconds);
      stats.bytes.add(bytes.length);
      if (format == 'png') stats.png++;
      _last = at;
      if (_frames.isNotEmpty && listEquals(_frames.last.bytes, bytes)) {
        stats.skippedSame++;
        return;
      }
      _frames.addLast(
        ReplayFrame(
          at: at,
          bytes: bytes,
          width: width,
          height: height,
          format: format,
        ),
      );
      _bytes += bytes.length;
      while (_frames.length > options.maxFrames ||
          _bytes > options.maxMemoryBytes) {
        _bytes -= _frames.removeFirst().bytes.length;
      }
    } on Object {
      stats.failures++;
    } finally {
      _busy = false;
    }
  }

  /// JPEG through the native encoder, PNG from the engine when it is missing.
  Future<(Uint8List?, String)> _encode(ui.Image image) async {
    final raw = await image.toByteData();
    if (raw != null) {
      final jpeg = await _codec.jpeg(
        raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
        image.width,
        image.height,
        quality: options.imageQuality,
      );
      if (jpeg != null) return (jpeg, 'jpeg');
    }
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return (
      png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      'png',
    );
  }
}

/// Frames frozen when the person opened the report, and the instant their
/// `tMs` count from (the same origin as the events).
class ReplayTake {
  ReplayTake({
    required this.frames,
    required this.origin,
    this.quality = 0.5,
    ReplayCodec codec = const ReplayCodec(),
  }) : _codec = codec;

  final List<ReplayFrame> frames;
  final DateTime origin;

  /// Video quality, above 0 up to 1.
  final double quality;
  final ReplayCodec _codec;
  Future<ReplayVideo?>? _video;

  /// The frames as one H.264 video, or null without the native encoder.
  /// Called as soon as the report sheet opens, so the video is usually
  /// ready by the time the person taps send; later calls reuse it. With
  /// [newest], only that many of the last frames go in, and nothing is kept.
  Future<ReplayVideo?> video({int? newest}) {
    if (newest != null) return _build(newest);
    return _video ??= _build(null);
  }

  Future<ReplayVideo?> _build(int? newest) async {
    // Only JPEGs of the same size as the last frame: a rotation starts over.
    final last = frames.isEmpty ? null : frames.last;
    if (last == null || last.format != 'jpeg') return null;
    var start = frames.length - 1;
    while (start > 0) {
      final f = frames[start - 1];
      if (f.format != 'jpeg' ||
          f.width != last.width ||
          f.height != last.height) {
        break;
      }
      start--;
    }
    if (newest != null) start = math.max(start, frames.length - newest);
    final run = frames.sublist(start);
    if (run.length < 2) return null;
    final times = videoTimes(run);
    final bytes = await _codec
        .video(
          [for (final f in run) f.bytes],
          times,
          last.width,
          last.height,
          quality: quality,
        )
        .timeout(videoTimeout, onTimeout: () => null);
    if (bytes == null) return null;
    return ReplayVideo(bytes: bytes, frames: run, times: times);
  }
}

/// Longest wait for the native video. Some phones' encoders hang (reported
/// on HyperOS); past this the report goes out with single frames instead.
const Duration videoTimeout = Duration(seconds: 8);

/// An MP4 of [frames]; frame `i` is shown at `times[i]` ms of the video.
class ReplayVideo {
  const ReplayVideo({
    required this.bytes,
    required this.frames,
    required this.times,
  });

  final Uint8List bytes;
  final List<ReplayFrame> frames;
  final List<int> times;
}

/// Longest pause the video shows. Nothing changed on screen during a longer
/// one (no frame was taken), so playing it would only be a still picture;
/// the real time of every frame stays in the report.
const int maxVideoGapMs = 1500;

/// Where each frame goes in the video: real gaps, with idle ones shortened
/// to [maxVideoGapMs]. Encoders also spend bits by elapsed time, so a long
/// pause would make the next frame needlessly heavy.
List<int> videoTimes(List<ReplayFrame> frames) {
  final times = <int>[];
  var t = 0;
  for (var i = 0; i < frames.length; i++) {
    if (i > 0) {
      final gap = frames[i].at.difference(frames[i - 1].at).inMilliseconds;
      t += gap.clamp(1, maxVideoGapMs);
    }
    times.add(t);
  }
  return times;
}

/// The newest [frames] whose bytes fit in [budget], oldest first.
List<ReplayFrame> framesWithin(List<ReplayFrame> frames, int budget) {
  final kept = <ReplayFrame>[];
  var used = 0;
  for (final frame in frames.reversed) {
    if (used + frame.bytes.length > budget) break;
    used += frame.bytes.length;
    kept.add(frame);
  }
  return kept.reversed.toList();
}
