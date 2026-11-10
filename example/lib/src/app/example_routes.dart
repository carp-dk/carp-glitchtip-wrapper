// Contains the named routes of the example app.
//
// Parts:
// - `ExampleRoutes`, the route names, which the wrapper's navigator observer
//   records as breadcrumbs and as the `screen` tag.

/// The route names of the example. They are what GlitchTip sees of the
/// navigation: route arguments are never recorded.
abstract final class ExampleRoutes {
  /// The welcome screen, where the participant signs in.
  static const welcome = '/';

  /// The participant's study invitations.
  static const invitations = '/invitations';

  /// The study, with the Study, Try it and Reports tabs.
  static const study = '/study';

  /// The tasks of the study's protocol.
  static const tasks = '/study/tasks';

  /// One report of the Reports tab.
  static const report = '/reports/detail';
}
