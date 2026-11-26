import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Marks native views (maps, web views, video players) on a picture.
/// Flutter cannot copy what they show: they come out blank or old. The mark
/// is a light veil with a dashed edge and, when there is room, [label], so
/// whoever reads the report knows that part is not what the tester saw.
/// [scale] turns the boundary's logical pixels into the picture's pixels.
void paintNativePlaceholders(
  Canvas canvas,
  List<Rect> rects,
  double scale, {
  String? label,
}) {
  final veil = Paint()..color = const Color(0x5964748B);
  final edge = Paint()
    ..color = const Color(0xFF94A3B8)
    ..style = PaintingStyle.stroke
    ..strokeWidth = (2 * scale).clamp(1.0, 4.0);
  for (final logical in rects) {
    final r = Rect.fromLTRB(
      logical.left * scale,
      logical.top * scale,
      logical.right * scale,
      logical.bottom * scale,
    );
    if (r.isEmpty) continue;
    canvas.drawRect(r, veil);
    _dashedRect(canvas, r.deflate(edge.strokeWidth / 2), edge);
    if (label != null && r.width > 80 * scale && r.height > 28 * scale) {
      _label(canvas, r, label, scale);
    }
  }
}

void _dashedRect(Canvas canvas, Rect r, Paint paint) {
  final dash = paint.strokeWidth * 4;
  void line(Offset a, Offset b) {
    final length = (b - a).distance;
    final step = (b - a) / length;
    for (var d = 0.0; d < length; d += dash * 2) {
      final end = d + dash > length ? length : d + dash;
      canvas.drawLine(a + step * d, a + step * end, paint);
    }
  }

  line(r.topLeft, r.topRight);
  line(r.topRight, r.bottomRight);
  line(r.bottomRight, r.bottomLeft);
  line(r.bottomLeft, r.topLeft);
}

void _label(Canvas canvas, Rect r, String text, double scale) {
  final builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(fontSize: 12 * scale, maxLines: 1, ellipsis: '…'),
        )
        ..pushStyle(ui.TextStyle(color: const Color(0xFFFFFFFF)))
        ..addText(text);
  final paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: r.width - 24 * scale));
  final pad = 6 * scale;
  final pill = Rect.fromLTWH(
    r.left + 6 * scale,
    r.top + 6 * scale,
    paragraph.maxIntrinsicWidth.clamp(0, r.width - 24 * scale) + pad * 2,
    paragraph.height + pad,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(pill, Radius.circular(6 * scale)),
    Paint()..color = const Color(0xCC1F2937),
  );
  canvas.drawParagraph(paragraph, Offset(pill.left + pad, pill.top + pad / 2));
  paragraph.dispose();
}
