import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'mask.dart';

const int _maxHintLength = 80;
const int _maxAncestors = 14;
const int _maxTextDepth = 8;

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
}) {
  if (hitPath.isEmpty) return null;
  final wanted = hitPath.toSet();
  final found = <RenderObject, Element>{};
  var masked = false;
  var textField = false;

  void visit(Element element, bool inMask, bool inText) {
    final widget = element.widget;
    final mask = inMask || widget is NabrilaMask;
    final text = inText || widget is EditableText || widget is TextField;
    final object = element.renderObject;
    if (element is RenderObjectElement && wanted.contains(object)) {
      found.putIfAbsent(object!, () => element);
      if (mask) masked = true;
      if (text) textField = true;
    }
    element.visitChildElements((child) => visit(child, mask, text));
  }

  visit(root, false, false);
  if (masked) return null;
  if (textField) return 'TextField';

  for (final object in hitPath) {
    final element = found[object];
    if (element == null) continue;
    final hint = _hintFor(element, typeFallback);
    if (hint != null) return _clip(hint);
  }
  return null;
}

String? _hintFor(Element start, bool typeFallback) {
  String? label = _directLabel(start.widget);
  if (label != null) return label;

  String? fallback;
  var steps = 0;
  start.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    label = _directLabel(widget);
    if (label == null && _isActionable(widget)) {
      label = _firstText(ancestor, 0);
    }
    if (label == null && fallback == null && _isNamedWidget(widget)) {
      fallback = widget.runtimeType.toString();
    }
    steps++;
    return label == null && steps < _maxAncestors;
  });
  if (label != null || !typeFallback) return label;
  return fallback ?? start.widget.runtimeType.toString();
}

bool _isActionable(Widget widget) =>
    widget is ButtonStyleButton ||
    widget is IconButton ||
    widget is FloatingActionButton ||
    widget is ListTile ||
    widget is Chip ||
    widget is Tab ||
    widget is BottomNavigationBar ||
    widget is NavigationDestination ||
    widget is InkResponse;

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
  } else if (widget is Tooltip) {
    value = widget.message;
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

String? _firstText(Element element, int depth) {
  if (depth > _maxTextDepth) return null;
  final own = _directLabel(element.widget);
  if (own != null) return own;
  String? result;
  element.visitChildElements((child) {
    result ??= _firstText(child, depth + 1);
  });
  return result;
}

String _clip(String value) =>
    value.length > _maxHintLength ? value.substring(0, _maxHintLength) : value;

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
