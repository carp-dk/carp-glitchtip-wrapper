// Contains the root widget of the example app.
//
// Parts:
// - `GlitchTipExampleApp`, the Material 3 Expressive app with its named
//   routes, observed by the wrapper's navigator observer.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../reporting/report.dart';
import '../reporting/report_outbox.dart';
import '../screens/home_screen.dart';
import '../screens/invitations_screen.dart';
import '../screens/report_detail_screen.dart';
import '../screens/tasks_screen.dart';
import '../screens/welcome_screen.dart';
import '../state/app_state.dart';
import '../state/example_scope.dart';
import 'example_routes.dart';

/// The example app: a CARP study app that reports to GlitchTip.
///
/// Build it after `CarpGlitchTip.init`, as `main()` does; tests build it
/// directly with their own [state] and [outbox].
class GlitchTipExampleApp extends StatefulWidget {
  /// Creates the app for [state]; [outbox] holds the reports in preview
  /// mode and is `null` in live mode.
  const GlitchTipExampleApp({super.key, required this.state, this.outbox});

  /// The CARP brand color the light and dark color schemes are seeded from.
  static const carpBlue = Color(0xFF006398);

  /// The app's state.
  final AppState state;

  /// The reports of preview mode; `null` in live mode.
  final ReportOutbox? outbox;

  @override
  State<GlitchTipExampleApp> createState() => _GlitchTipExampleAppState();
}

class _GlitchTipExampleAppState extends State<GlitchTipExampleApp> {
  // records navigation as breadcrumbs and keeps the screen tag up to date
  final _observer = CarpGlitchTip.navigatorObserver();

  @override
  Widget build(BuildContext context) => M3EMaterialApp(
    title: 'CARP GlitchTip',
    debugShowCheckedModeBanner: false,
    data: M3EThemeData.light(seedColor: GlitchTipExampleApp.carpBlue),
    autoTheming: true,
    navigatorObservers: [_observer],
    home: const WelcomeScreen(),
    routes: {
      ExampleRoutes.invitations: (context) => const InvitationsScreen(),
      ExampleRoutes.study: (context) => const HomeScreen(),
      ExampleRoutes.tasks: (context) => const TasksScreen(),
    },
    onGenerateRoute: (settings) => switch (settings) {
      RouteSettings(name: ExampleRoutes.report, :final Report arguments) =>
        MaterialPageRoute<void>(
          settings: settings,
          builder: (context) => ReportDetailScreen(report: arguments),
        ),
      _ => null,
    },
    appBuilder: (context, child) => ExampleScope(
      state: widget.state,
      outbox: widget.outbox,
      child: child ?? const SizedBox.shrink(),
    ),
  );
}
