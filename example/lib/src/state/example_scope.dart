// Contains the inherited scope that gives screens the app's state.
//
// Parts:
// - `ExampleScope`, which provides the `AppState` and, in preview mode, the
//   `ReportOutbox`.

import 'package:flutter/widgets.dart';

import '../reporting/report_outbox.dart';
import 'app_state.dart';
import 'try_it_actions.dart';

/// Gives the screens the app's [state] and the preview mode's [outbox].
class ExampleScope extends InheritedNotifier<AppState> {
  /// Creates a scope for [state] and [outbox] above [child].
  const ExampleScope({
    required this.state,
    required this.outbox,
    required super.child,
    super.key,
  }) : super(notifier: state);

  /// The app's state.
  final AppState state;

  /// The reports of preview mode; `null` in live mode, where reports go to
  /// GlitchTip.
  final ReportOutbox? outbox;

  /// The scope, rebuilding the caller when the state changes.
  static ExampleScope watch(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ExampleScope>();
    assert(scope != null, 'ExampleScope was not found.');
    return scope!;
  }

  /// The scope, without rebuilding the caller when the state changes.
  static ExampleScope read(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<ExampleScope>();
    final scope = element?.widget as ExampleScope?;
    assert(scope != null, 'ExampleScope was not found.');
    return scope!;
  }

  /// The actions of the Try it tab.
  TryItActions get actions => TryItActions(state, outbox: outbox);

  @override
  bool updateShouldNotify(ExampleScope oldWidget) =>
      super.updateShouldNotify(oldWidget) || outbox != oldWidget.outbox;
}
