import 'package:flutter/widgets.dart';

import 'runtime.dart';

/// Records route changes into the ring buffer. Add it to
/// `MaterialApp.navigatorObservers` through `Nabrila.navigatorObserver`, or
/// to `GoRouter(observers: …)`; go_router hands it to the navigators of its
/// shell routes too, so bottom tabs are recorded as well.
///
/// Routes are named by `RouteSettings.name` without the query or the
/// fragment (go_router names them by their path pattern, like
/// `/product/:id`). An unnamed route
/// of a private type (a go_router shell, a popup menu) is not a screen of
/// the app: it is not recorded, and going back to it records the screen
/// that was showing inside it.
class NabrilaNavigatorObserver extends NavigatorObserver {
  /// The screen that was showing when a route was covered by another one.
  final Expando<String> _covered = Expando('nabrila-covered');

  static String? _named(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name == null || name.isEmpty) return null;
    final clean = routeName(name);
    return clean.isEmpty ? null : clean;
  }

  /// `DialogRoute<bool>` → `DialogRoute`; null for private types.
  static String? _typeName(Route<dynamic> route) {
    final raw = route.runtimeType.toString();
    final generic = raw.indexOf('<');
    final type = generic < 0 ? raw : raw.substring(0, generic);
    return type.startsWith('_') ? null : type;
  }

  static String? _label(Route<dynamic>? route) =>
      route == null ? null : _named(route) ?? _typeName(route);

  void _record(String action, String? from, String? to) {
    final runtime = NabrilaRuntime.current;
    if (runtime == null || to == null) return;
    runtime.recordNavigation(action: action, fromRoute: from, toRoute: to);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final current = NabrilaRuntime.current?.activeRoute;
    if (previousRoute != null && current != null) {
      _covered[previousRoute] = current;
    }
    _record('push', current ?? _label(previousRoute), _label(route));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final from = _label(route);
    if (from == null) return;
    final to = previousRoute == null
        ? null
        : _named(previousRoute) ??
              _covered[previousRoute] ??
              _typeName(previousRoute);
    _record('pop', from, to);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _record('replace', _label(oldRoute), _label(newRoute));

  // didRemove is left out: a route removed from below never changes what
  // is on screen, and go_router removes the old page right after pushing
  // the new one when it swaps them.
}
