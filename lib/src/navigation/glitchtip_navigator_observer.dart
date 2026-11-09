import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../network/url_normalizer.dart';
import '../runtime.dart';
import '../util/diagnostics.dart';

/// Records navigation as breadcrumbs and keeps the `screen` tag up to date.
///
/// Only route names are recorded, without query or fragment and never route
/// arguments (GoRouter puts path and query parameters there), and ids in
/// names are replaced by placeholders. No screen transactions are started:
/// bound to the scope, they would become the GlitchTip culprit of errors and
/// split issues.
///
/// One route event is recorded once, even when several observers see it:
/// since go_router 17, routes of a `ShellRoute` are also reported to the
/// observers of the root navigator.
class GlitchTipNavigatorObserver extends NavigatorObserver {
  // the events already recorded per route, shared by all observers
  static final Expando<Set<String>> _recorded = Expando();

  static final _queryOrFragment = RegExp('[?#]');

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record('didPush', route, from: previousRoute, to: route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record('didPop', route, from: route, to: previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    _record('didReplace', newRoute, from: oldRoute, to: newRoute);
  }

  void _record(
    String state,
    Route<dynamic> route, {
    Route<dynamic>? from,
    Route<dynamic>? to,
  }) {
    final runtime = GlitchTipRuntime.current;
    if (runtime == null || !runtime.active) return;
    guard('recording navigation', () {
      final recorded = _recorded[route] ??= {};
      if (!recorded.add(state)) return;
      final fromName = _name(from);
      final toName = _name(to);
      if (fromName == null && toName == null) return;
      unawaited(
        Sentry.addBreadcrumb(
          Breadcrumb(
            type: 'navigation',
            category: 'navigation',
            data: {'state': state, 'from': ?fromName, 'to': ?toName},
          ),
        ).catchError((Object _) {}),
      );
      if (toName != null) runtime.scope.screen = toName;
    });
  }

  static String? _name(Route<dynamic>? route) {
    // a deep-link location used as name can carry codes in its query
    final name = route?.settings.name?.split(_queryOrFragment).first;
    if (name == null || name.isEmpty) return null;
    final normalized = name.split('/').map(normalizePathSegment).join('/');
    return normalized.length <= 200 ? normalized : normalized.substring(0, 200);
  }
}
