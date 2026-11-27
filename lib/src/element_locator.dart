import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'design_widgets.dart';
import 'mask.dart';
import 'tap_resolver.dart';

/// Where a widget was written in the app's code. Only debug builds know it:
/// Flutter records it when it tracks widget creation (the default for
/// `flutter run`).
class SourceLocation {
  const SourceLocation({
    required this.file,
    required this.line,
    required this.column,
  });

  /// Path from the package root, like `lib/checkout/pay_button.dart`: the
  /// folders above it (and the developer's user name) never leave the phone.
  final String file;
  final int line;
  final int column;

  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'column': column,
  };

  @override
  String toString() => '$file:$line';
}

/// What the person pointed at on the screenshot.
class PointedElement {
  const PointedElement({
    required this.xNorm,
    required this.yNorm,
    this.widget,
    this.label,
    this.source,
  });

  /// Where on the screen, `0..1` from the top left.
  final double xNorm;
  final double yNorm;

  /// Type of the widget, like `ElevatedButton`.
  final String? widget;

  /// Its visible text or accessibility label; never inside a [NabrilaMask],
  /// never the value of a text field.
  final String? label;
  final SourceLocation? source;

  Map<String, Object?> toJson() => {
    'xNorm': xNorm,
    'yNorm': yNorm,
    'widget': ?widget,
    'label': ?label,
    if (source != null) 'source': source!.toJson(),
  };
}

const int _maxWidgetName = 80;
const int _maxSteps = 60;

/// Finds the widget under [xNorm], [yNorm] of [rootBox] (the scope's
/// boundary) in the live app, which sits right below the capture flow.
PointedElement locateElement(
  Element root,
  RenderBox rootBox, {
  required double xNorm,
  required double yNorm,
}) {
  final x = xNorm.clamp(0.0, 1.0);
  final y = yNorm.clamp(0.0, 1.0);
  final fallback = PointedElement(xNorm: x, yNorm: y);
  if (!rootBox.hasSize || rootBox.size.isEmpty) return fallback;
  try {
    final result = BoxHitTestResult();
    rootBox.hitTest(
      result,
      position: Offset(x * rootBox.size.width, y * rootBox.size.height),
    );
    final path = [
      for (final entry in result.path)
        if (entry.target is RenderObject) entry.target as RenderObject,
    ];
    final deepest = _deepestElement(root, path);
    if (deepest == null) return fallback;
    final chosen = _chooseWidget(deepest);
    final label = resolveTapHint(root, path, typeFallback: false);
    return PointedElement(
      xNorm: x,
      yNorm: y,
      widget: chosen == null ? null : _typeName(chosen.widget),
      label: label,
      source: chosen == null ? null : sourceOf(chosen),
    );
  } on Object {
    return fallback;
  }
}

/// The element of the deepest hit render object.
Element? _deepestElement(Element root, List<RenderObject> path) {
  if (path.isEmpty) return null;
  final wanted = path.toSet();
  final found = <RenderObject, Element>{};
  void visit(Element element) {
    final object = element.renderObject;
    if (element is RenderObjectElement && wanted.contains(object)) {
      found.putIfAbsent(object!, () => element);
    }
    element.visitChildElements(visit);
  }

  visit(root);
  for (final object in path) {
    final element = found[object];
    if (element != null) return element;
  }
  return null;
}

/// The widget worth naming: the nearest one written in the app's own code,
/// or the button it sits in when the next widget of the app's code up the
/// tree is a button (`ElevatedButton(child: Text('Pay'))` names the button).
/// Without source locations (release builds), the nearest public widget.
Element? _chooseWidget(Element start) {
  Element? local;
  Element? public;
  var steps = 0;
  bool look(Element element) {
    if (public == null && _isPublic(element.widget)) public = element;
    // Without source locations (release) the first public widget is it.
    if (!kDebugMode) return public == null;
    if (sourceOf(element) == null) {
      return local == null || ++steps < _maxSteps;
    }
    if (local == null) {
      local = element;
      return true;
    }
    if (_isActionable(element.widget)) local = element;
    return false;
  }

  if (look(start)) start.visitAncestorElements(look);
  return local ?? public;
}

bool _isPublic(Widget widget) =>
    (widget is StatelessWidget || widget is StatefulWidget) &&
    !widget.runtimeType.toString().startsWith('_');

bool _isActionable(Widget widget) =>
    isMaterialControl(widget) || widget is GestureDetector;

String _typeName(Widget widget) {
  final name = widget.runtimeType.toString();
  // `Foo<Bar>` is noise for a person reading the report.
  final generic = name.indexOf('<');
  final clean = generic > 0 ? name.substring(0, generic) : name;
  return clean.length > _maxWidgetName
      ? clean.substring(0, _maxWidgetName)
      : clean;
}

/// Where [element]'s widget was written, when that is in the app's own code
/// and the build tracks it (debug only). Null otherwise.
SourceLocation? sourceOf(Element element) {
  if (!kDebugMode) return null;
  try {
    final json = element.toDiagnosticsNode().toJsonMap(
      InspectorSerializationDelegate(
        service: WidgetInspectorService.instance,
        subtreeDepth: 0,
      ),
    );
    final location = json['creationLocation'];
    if (location is! Map) return null;
    final file = location['file'];
    final line = location['line'];
    final column = location['column'];
    if (file is! String || line is! int || column is! int) return null;
    final relative = appFile(file);
    if (relative == null) return null;
    return SourceLocation(file: relative, line: line, column: column);
  } on Object {
    return null;
  }
}

/// [uri] as a path from the app's package root, or null when it is not the
/// app's code: Flutter itself, the Dart SDK, a pub package or this SDK.
@visibleForTesting
String? appFile(String uri) {
  final path = uri.replaceAll('\\', '/');
  const outside = [
    '/packages/flutter/',
    '/packages/flutter_test/',
    '/.pub-cache/',
    '/Pub/Cache/',
    '/bin/cache/',
    'org-dartlang-sdk',
    '/.dart_tool/',
    '/nabrila/lib/src/',
  ];
  if (outside.any(path.contains)) return null;
  for (final root in const ['/lib/', '/test/', '/integration_test/']) {
    final at = path.lastIndexOf(root);
    if (at >= 0) return path.substring(at + 1);
  }
  return null;
}
