import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Marks a zone of the screen that must never leave the phone.
///
/// In a screenshot the zone is exported as a solid block, and taps inside it
/// never get a `targetHint`. The widget paints normally the rest of the time.
///
/// It only protects what Flutter paints inside it. It does not detect text
/// inside images or `CustomPaint`, and it cannot hide native views.
class NabrilaMask extends SingleChildRenderObjectWidget {
  const NabrilaMask({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => RenderNabrilaMask();
}

/// Paints a solid block while [hidden] is true (only during a capture).
class RenderNabrilaMask extends RenderProxyBox {
  /// True while the screenshot is being taken, so every mask paints a block.
  static final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);

  static const Color blockColor = Color(0xFF000000);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    hidden.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    hidden.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (hidden.value) {
      context.canvas.drawRect(offset & size, Paint()..color = blockColor);
      return;
    }
    super.paint(context, offset);
  }
}
