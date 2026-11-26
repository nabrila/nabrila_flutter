import 'package:flutter/widgets.dart';

import '../mask.dart';

/// What a replay frame must cover, found right before the frame is taken.
class MaskScan {
  const MaskScan(this.rects, {required this.frozen, this.native = const []});

  /// Boxes to paint over, in the boundary's logical pixels.
  final List<Rect> rects;

  /// Native views (maps, web views, players), which Flutter cannot copy:
  /// they come out blank or stale, so the frame marks them as such.
  final List<Rect> native;

  /// True when a [SnapshotWidget] is showing an old picture of its child
  /// (Android's zoom page transition does this): its content is not where it
  /// was painted, so the frame is skipped instead of risking a leak.
  final bool frozen;
}

/// Finds every [NabrilaMask] and text field that is on screen under [root],
/// plus every text with [maskText] and every image with [maskImages].
///
/// The walk is breadth-first over onstage elements only, so routes kept
/// alive behind the current one, `Offstage`, `Visibility(visible: false)`
/// and `Opacity(0)` never add a mask.
///
/// Must run in the same frame as the `toImage` call, with no `await` in
/// between, or the boxes would not match the picture.
MaskScan scanMasks(
  Element root,
  RenderBox rootBox, {
  bool maskText = false,
  bool maskImages = false,
}) {
  final bounds = Offset.zero & rootBox.size;
  final rects = <Rect>[];
  final native = <Rect>[];
  var frozen = false;
  var queue = <Element>[];
  root.visitChildElements(queue.add);
  while (queue.isNotEmpty) {
    final current = queue;
    queue = <Element>[];
    for (final element in current) {
      final widget = element.widget;
      if (widget is Visibility && !widget.visible) continue;
      if (widget is Opacity && widget.opacity == 0) continue;
      if (widget is Offstage && widget.offstage) continue;
      if (widget is SnapshotWidget && widget.controller.allowSnapshotting) {
        frozen = true;
      }
      if (widget is NabrilaMask ||
          widget is EditableText ||
          (maskText && widget is RichText) ||
          (maskImages && widget is RawImage)) {
        final rect = _boxOf(element, rootBox);
        if (rect != null && rect.overlaps(bounds)) {
          rects.add(rect.intersect(bounds));
        }
        continue;
      }
      if (isNativeView(widget)) {
        final rect = _boxOf(element, rootBox);
        if (rect != null && rect.overlaps(bounds)) {
          native.add(rect.intersect(bounds));
        }
        continue;
      }
      element.debugVisitOnstageChildren(queue.add);
    }
  }
  return MaskScan(rects, frozen: frozen, native: native);
}

/// Widgets that show a native view inside the Flutter screen.
bool isNativeView(Widget widget) =>
    widget is AndroidView ||
    widget is UiKitView ||
    widget is AppKitView ||
    widget is PlatformViewLink ||
    widget is HtmlElementView;

/// Native views on screen under [root], for the screenshot.
List<Rect> scanNativeViews(Element root, RenderBox rootBox) =>
    scanMasks(root, rootBox).native;

Rect? _boxOf(Element element, RenderBox rootBox) {
  final box = element.renderObject;
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return MatrixUtils.transformRect(
    box.getTransformTo(rootBox),
    Offset.zero & box.size,
  );
}
