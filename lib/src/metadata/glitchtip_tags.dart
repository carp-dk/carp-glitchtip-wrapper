/// The tag keys the wrapper sets. Tags are what GlitchTip can search, e.g.
/// `study_deployment_id:<id>`, so these keys are part of the package's
/// stable API.
abstract final class GlitchTipTags {
  /// The CARP study id, see `StudyMetadata.studyId`.
  static const studyId = 'study_id';

  /// The CARP study deployment id, see `StudyMetadata.studyDeploymentId`.
  static const studyDeploymentId = 'study_deployment_id';

  /// The role of this device in the study, see
  /// `StudyMetadata.deviceRoleName`.
  static const deviceRole = 'device_role';

  /// The Flutter build mode: `debug`, `profile` or `release`.
  static const buildMode = 'build_mode';

  /// CARP's `deployment-mode` launch argument, when it is set.
  static const deploymentMode = 'deployment_mode';

  /// The screen (route) the app showed when the error happened.
  static const screen = 'screen';

  /// `yes` when the app caught and reported the error itself, `no` when the
  /// error was unhandled.
  static const handled = 'handled';

  /// How the error was captured, e.g. `PlatformDispatcher.onError`,
  /// `FlutterError` or `CarpGlitchTipHttpClient`.
  static const mechanism = 'mechanism';

  /// Set on an error that stopped the app from starting (it escaped the
  /// body of `CarpGlitchTip.runZoned`). Such errors are reported even when
  /// an ignore rule matches.
  static const startupFailure = 'startup_failure';

  /// Every key the wrapper sets.
  static const all = {
    studyId,
    studyDeploymentId,
    deviceRole,
    buildMode,
    deploymentMode,
    screen,
    handled,
    mechanism,
    startupFailure,
  };
}
