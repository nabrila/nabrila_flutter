import 'package:flutter/widgets.dart';

import 'annotations.dart';
import 'capture.dart';

/// [point] marks the one spot the report is about; it is not drawn on the
/// picture, the viewer shows it.
enum AnnotationTool { pen, block, point }

/// The frozen screenshot with a layer to draw strokes or opaque blocks on it.
class AnnotationCanvas extends StatefulWidget {
  const AnnotationCanvas({
    super.key,
    required this.capture,
    required this.annotations,
    required this.tool,
    required this.onChanged,
    this.pointed,
    this.onPoint,
  });

  final ScreenCapture capture;
  final List<Annotation> annotations;
  final AnnotationTool tool;
  final VoidCallback onChanged;

  /// The marked spot, `0..1`.
  final Offset? pointed;
  final ValueChanged<Offset>? onPoint;

  @override
  State<AnnotationCanvas> createState() => _AnnotationCanvasState();
}

class _AnnotationCanvasState extends State<AnnotationCanvas> {
  Offset? _start;
  Annotation? _active;

  Offset _norm(Offset local, Size size) => Offset(
    (local.dx / size.width).clamp(0.0, 1.0),
    (local.dy / size.height).clamp(0.0, 1.0),
  );

  void _begin(Offset local, Size size) {
    final point = _norm(local, size);
    _start = point;
    _active = widget.tool == AnnotationTool.pen
        ? Stroke([point])
        : Block(Rect.fromPoints(point, point));
    widget.annotations.add(_active!);
    widget.onChanged();
  }

  void _update(Offset local, Size size) {
    final active = _active;
    final start = _start;
    if (active == null || start == null) return;
    final point = _norm(local, size);
    final next = switch (active) {
      Stroke(:final points) => Stroke([...points, point]),
      Block() => Block(Rect.fromPoints(start, point)),
    };
    widget.annotations[widget.annotations.length - 1] = next;
    _active = next;
    widget.onChanged();
  }

  void _end() {
    _active = null;
    _start = null;
  }

  @override
  Widget build(BuildContext context) {
    final logical = widget.capture.logicalSize;
    return Center(
      child: AspectRatio(
        aspectRatio: logical.width / logical.height,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = box.biggest;
            final pointing = widget.tool == AnnotationTool.point;
            final pointed = widget.pointed;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: pointing
                  ? (d) => widget.onPoint?.call(_norm(d.localPosition, size))
                  : null,
              onPanStart: pointing
                  ? null
                  : (d) => _begin(d.localPosition, size),
              onPanUpdate: pointing
                  ? null
                  : (d) => _update(d.localPosition, size),
              onPanEnd: pointing ? null : (_) => _end(),
              onPanCancel: pointing ? null : _end,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(image: widget.capture.image, fit: BoxFit.fill),
                  CustomPaint(painter: AnnotationPainter(widget.annotations)),
                  if (pointed != null)
                    CustomPaint(painter: _PointPainter(pointed)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A target ring on the marked spot.
class _PointPainter extends CustomPainter {
  _PointPainter(this.point);

  final Offset point;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(point.dx * size.width, point.dy * size.height);
    canvas
      ..drawCircle(center, 18, Paint()..color = const Color(0x55F97316))
      ..drawCircle(
        center,
        18,
        Paint()
          ..color = const Color(0xFFF97316)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      )
      ..drawCircle(center, 4, Paint()..color = const Color(0xFFF97316));
  }

  @override
  bool shouldRepaint(_PointPainter old) => old.point != point;
}
