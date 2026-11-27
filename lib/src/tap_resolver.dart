import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'design_widgets.dart';
import 'events.dart' show clip;
import 'mask.dart';

const int _maxHintLength = 80;

/// Material 3 builds an `IconButton` about 60 levels above its glyph.
const int _maxAncestors = 80;
const int _maxTextDepth = 8;

/// What a tap touched: a short text, and whether it landed inside a
/// [NabrilaMask] (then there is never a hint, and the tap keeps no
/// coordinates).
typedef TapTarget = ({String? hint, bool masked});

/// Works out what a tap touched, as a short text. Returns null when nothing
/// useful can be said, and always null inside a [NabrilaMask]. For text fields
/// it only says "TextField": the typed value is never read.
///
/// Release builds can minify widget type names, so a type fallback may look
/// like `Xa`; labels from `Semantics`, `Text` and tooltips are always exact.
///
/// With [typeFallback] false it only returns real text (a label, a tooltip,
/// a visible text), never a widget type name.
String? resolveTapHint(
  Element root,
  List<RenderObject> hitPath, {
  bool typeFallback = true,
}) => resolveTap(root, hitPath, typeFallback: typeFallback).hint;

/// [resolveTapHint], also telling whether the tap was inside a mask.
TapTarget resolveTap(
  Element root,
  List<RenderObject> hitPath, {
  bool typeFallback = true,
}) {
  if (hitPath.isEmpty) return (hint: null, masked: false);
  final wanted = hitPath.toSet();
  final found = <RenderObject, Element>{};
  var masked = false;
  var textField = false;

  void visit(Element element, bool inMask, bool inText) {
    final widget = element.widget;
    final mask = inMask || widget is NabrilaMask;
    final text = inText || isTextField(widget);
    final object = element.renderObject;
    if (element is RenderObjectElement && wanted.contains(object)) {
      found.putIfAbsent(object!, () => element);
      if (mask) masked = true;
      if (text) textField = true;
    }
    element.visitChildElements((child) => visit(child, mask, text));
  }

  visit(root, false, false);
  if (masked) return (hint: null, masked: true);
  if (textField) return (hint: 'TextField', masked: false);

  for (final object in hitPath) {
    final element = found[object];
    if (element == null) continue;
    final hint = _hintFor(element, typeFallback);
    if (hint != null) return (hint: clip(hint, _maxHintLength), masked: false);
  }
  return (hint: null, masked: false);
}

/// Subtrees whose text never names a tap: masked content and what a person
/// typed.
bool _isProtected(Widget widget) =>
    widget is NabrilaMask || isTextField(widget);

String? _hintFor(Element start, bool typeFallback) {
  String? label = _directLabel(start.widget);
  if (label != null) return label;

  String? fallback;
  String? actionable;
  var steps = 0;
  start.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    label = _directLabel(widget);
    if (label == null && _isActionable(widget)) {
      label = firstText(ancestor);
      // `IconButton` says more than the `RawGestureDetector` inside it.
      if (actionable == null &&
          _isNamedWidget(widget) &&
          !_isPlumbing(widget)) {
        actionable = _typeName(widget);
      }
    }
    if (label == null &&
        fallback == null &&
        _isNamedWidget(widget) &&
        !_isPlumbing(widget)) {
      fallback = _typeName(widget);
    }
    steps++;
    return label == null && actionable == null && steps < _maxAncestors;
  });
  if (label != null || !typeFallback) return label;
  return actionable ?? fallback ?? _typeName(start.widget);
}

/// Widgets every button is built from: their names tell nothing.
bool _isPlumbing(Widget widget) =>
    isMaterialPlumbing(widget) ||
    widget is GestureDetector ||
    widget is RawGestureDetector ||
    widget is Listener ||
    widget is MouseRegion ||
    widget is Semantics ||
    widget is Focus ||
    widget is Actions ||
    widget is Shortcuts ||
    widget is DefaultTextStyle ||
    widget is IconTheme;

/// `Foo<Bar>` → `Foo`.
String _typeName(Widget widget) {
  final name = widget.runtimeType.toString();
  final generic = name.indexOf('<');
  return generic > 0 ? name.substring(0, generic) : name;
}

bool _isActionable(Widget widget) => isMaterialTapTarget(widget);

bool _isNamedWidget(Widget widget) =>
    (widget is StatelessWidget || widget is StatefulWidget) &&
    !widget.runtimeType.toString().startsWith('_');

String? _directLabel(Widget widget) {
  String? value;
  if (widget is Semantics) {
    value = widget.properties.label ?? widget.properties.tooltip;
  } else if (widget is Text) {
    value = widget.data ?? widget.textSpan?.toPlainText();
  } else if (widget is RichText) {
    value = widget.text.toPlainText();
  } else if (tooltipMessage(widget) case final message?) {
    value = message;
  } else if (widget is Icon) {
    value = widget.semanticLabel;
  }
  // Icon fonts draw their glyphs from the Private Use Area: an icon's
  // "text" is a character nobody can read.
  final trimmed = value?.replaceAll(_privateUse, '').trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

final RegExp _privateUse = RegExp(
  '[\u{E000}-\u{F8FF}\u{F0000}-\u{FFFFD}\u{100000}-\u{10FFFD}]',
  unicode: true,
);

/// The first visible text under [element], never inside a [NabrilaMask]
/// or a text field: a button with a masked card number in it is named by
/// its other text, or not at all.
@visibleForTesting
String? firstText(Element element, [int depth = 0]) {
  if (depth > _maxTextDepth || _isProtected(element.widget)) return null;
  final own = _directLabel(element.widget);
  if (own != null) return own;
  String? result;
  element.visitChildElements((child) {
    result ??= firstText(child, depth + 1);
  });
  return result;
}

/// Hit-tests [position] (in the root coordinate space) and returns the render
/// objects under it, deepest first.
List<RenderObject> hitRenderObjects(int viewId, Offset position) {
  final result = HitTestResult();
  GestureBinding.instance.hitTestInView(result, position, viewId);
  return [
    for (final entry in result.path)
      if (entry.target is RenderObject) entry.target as RenderObject,
  ];
}
