import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Something the tester drew. Coordinates are normalized to `0..1` so the same
/// drawing works on the on-screen canvas and on the exported PNG.
sealed class Annotation {
  const Annotation();
}

/// Free-hand red stroke.
class Stroke extends Annotation {
  const Stroke(this.points);

  final List<Offset> points;
}

/// Opaque black rectangle that hides what is under it.
class Block extends Annotation {
  const Block(this.rect);

  final Rect rect;
}

const Color _strokeColor = Color(0xFFE5484D);
const Color _blockColor = Color(0xFF000000);

/// Stroke width as a fraction of the image width.
const double _strokeWidthFraction = 0.008;

/// Paints [annotations] over a canvas of [size].
void paintAnnotations(Canvas canvas, Size size, List<Annotation> annotations) {
  final stroke = Paint()
    ..color = _strokeColor
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = size.width * _strokeWidthFraction;
  final fill = Paint()..color = _blockColor;
  for (final note in annotations) {
    switch (note) {
      case Stroke(:final points):
        if (points.length == 1) {
          canvas.drawCircle(
            Offset(points.first.dx * size.width, points.first.dy * size.height),
            stroke.strokeWidth / 2,
            Paint()..color = _strokeColor,
          );
          continue;
        }
        final path = Path()
          ..moveTo(points.first.dx * size.width, points.first.dy * size.height);
        for (final p in points.skip(1)) {
          path.lineTo(p.dx * size.width, p.dy * size.height);
        }
        canvas.drawPath(path, stroke);
      case Block(:final rect):
        canvas.drawRect(
          Rect.fromLTRB(
            rect.left * size.width,
            rect.top * size.height,
            rect.right * size.width,
            rect.bottom * size.height,
          ),
          fill,
        );
    }
  }
}

/// Painter for the on-screen canvas.
class AnnotationPainter extends CustomPainter {
  AnnotationPainter(this.annotations);

  final List<Annotation> annotations;

  @override
  void paint(Canvas canvas, Size size) =>
      paintAnnotations(canvas, size, annotations);

  @override
  bool shouldRepaint(AnnotationPainter oldDelegate) => true;
}

/// Largest PNG the SDK sends (architecture.md, section 3.4).
const int maxPngBytes = 1500000;

Future<Uint8List?> encodePng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Draws [annotations] over [base] and encodes a PNG. If it is over
/// [maxBytes] it shrinks the picture by a quarter and tries again.
Future<Uint8List?> composeAnnotated(
  ui.Image base,
  List<Annotation> annotations, {
  int maxBytes = maxPngBytes,
}) async {
  var scale = 1.0;
  Uint8List? bytes;
  while (scale >= 0.3) {
    final width = (base.width * scale).round().clamp(1, base.width);
    final height = (base.height * scale).round().clamp(1, base.height);
    final size = Size(width.toDouble(), height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      base,
      Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    paintAnnotations(canvas, size, annotations);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    bytes = await encodePng(image);
    image.dispose();
    if (bytes != null && bytes.length <= maxBytes) return bytes;
    scale *= 0.75;
  }
  return bytes;
}

/// The drawings could not be put on the screenshot. The report is not sent:
/// without them the boxes that hide what the tester chose to hide would be
/// missing too.
class AnnotationsLostException implements Exception {
  @override
  String toString() => 'AnnotationsLostException';
}

/// The PNG to send: [png] as captured when there are no [annotations],
/// otherwise [base] with them drawn on. Never falls back to the bare
/// capture when drawing fails; it throws [AnnotationsLostException].
Future<Uint8List> screenshotToSend(
  ui.Image base,
  Uint8List png,
  List<Annotation> annotations, {
  Future<Uint8List?> Function(ui.Image, List<Annotation>) compose =
      composeAnnotated,
}) async {
  if (annotations.isEmpty) return png;
  final Uint8List? drawn;
  try {
    drawn = await compose(base, annotations);
  } on Object {
    throw AnnotationsLostException();
  }
  if (drawn == null) throw AnnotationsLostException();
  return drawn;
}
