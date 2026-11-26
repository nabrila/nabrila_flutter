import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'annotations.dart';
import 'mask.dart';
import 'native_views.dart';
import 'replay/replay_masks.dart';

/// Longest side of the exported PNG, in pixels.
const int maxImageSide = 1440;

/// A frozen frame of the app and its PNG encoding.
class ScreenCapture {
  ScreenCapture({
    required this.image,
    required this.png,
    required this.logicalSize,
    required this.pixelRatio,
  });

  final ui.Image image;
  final Uint8List png;
  final Size logicalSize;
  final double pixelRatio;

  void dispose() => image.dispose();
}

/// Freezes [boundary] with `RepaintBoundary.toImage`. Every [NabrilaMask] is
/// painted as a solid block for the frame that gets captured. The picture is
/// at most [maxImageSide] px on its longest side; if the PNG is over 1.5 MB it
/// is captured again with a lower `pixelRatio`. Native views under [root]
/// are marked with [nativeLabel] (see [paintNativePlaceholders]).
Future<ScreenCapture?> captureBoundary(
  RenderRepaintBoundary boundary,
  double devicePixelRatio, {
  Element? root,
  String? nativeLabel,
}) async {
  final logical = boundary.size;
  if (logical.isEmpty) return null;
  var ratio = math.min(
    devicePixelRatio,
    maxImageSide / math.max(logical.width, logical.height),
  );

  RenderNabrilaMask.hidden.value = true;
  try {
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
    while (true) {
      var native = const <Rect>[];
      try {
        if (root != null) native = scanNativeViews(root, boundary);
      } on Object {
        native = const [];
      }
      var image = await boundary.toImage(pixelRatio: ratio);
      if (native.isNotEmpty) {
        image = await _marked(image, native, ratio, nativeLabel);
      }
      final png = await encodePng(image);
      if (png == null) {
        image.dispose();
        return null;
      }
      if (png.length <= maxPngBytes || ratio <= 0.3) {
        return ScreenCapture(
          image: image,
          png: png,
          logicalSize: logical,
          pixelRatio: ratio,
        );
      }
      image.dispose();
      ratio *= 0.75;
    }
  } finally {
    RenderNabrilaMask.hidden.value = false;
  }
}

Future<ui.Image> _marked(
  ui.Image raw,
  List<Rect> native,
  double ratio,
  String? label,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawImage(raw, Offset.zero, Paint());
  paintNativePlaceholders(canvas, native, ratio, label: label);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(raw.width, raw.height);
  } finally {
    picture.dispose();
    raw.dispose();
  }
}
