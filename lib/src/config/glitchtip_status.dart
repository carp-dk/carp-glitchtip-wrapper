import 'package:meta/meta.dart';

/// Why GlitchTip reporting is off, see `GlitchTipStatus.disabledReason`.
enum DisabledReason {
  /// `CarpGlitchTip.init` has not been called (yet).
  notInitialized('init() has not been called'),

  /// The Sentry SDK is still starting after `CarpGlitchTipOptions.initTimeout`.
  /// Errors are already reported; HTTP requests and `CarpGlitchTip.trace`
  /// are recorded, and `CarpGlitchTip.isEnabled` is true, once it is done.
  starting('the Sentry SDK is still starting'),

  /// A debug build, where reporting is off by default.
  debugBuild('debug build; set GLITCHTIP_ENABLED=true to report'),

  /// Running under `flutter test`, where only `enabled: true` in code turns
  /// reporting on.
  flutterTest('flutter test; pass enabled: true in code to report'),

  /// Turned off with `GLITCHTIP_ENABLED=false` or `enabled: false`.
  disabledByConfig('turned off by GLITCHTIP_ENABLED or enabled: false'),

  /// No DSN was given.
  missingDsn('no DSN; set GLITCHTIP_DSN'),

  /// The DSN cannot be used, see `GlitchTipStatus.detail`.
  invalidDsn('invalid DSN'),

  /// `CarpGlitchTip.init` was called in an isolate that is not the root
  /// isolate of a Flutter engine.
  notRootIsolate('init() called outside a root isolate'),

  /// The Sentry SDK failed to start, see `GlitchTipStatus.detail`.
  initFailed('the Sentry SDK failed to start'),

  /// `CarpGlitchTip.close` was called.
  closed('close() was called');

  const DisabledReason(this.description);

  /// A human-readable description.
  final String description;
}

/// The state of GlitchTip reporting, e.g. for an about or debug screen.
///
/// The same information is printed as one line when `CarpGlitchTip.init`
/// finishes, in every build mode, so a build that does not report can be
/// recognised from its log.
final class GlitchTipStatus {
  /// Creates a status. Only the wrapper creates statuses.
  @internal
  const GlitchTipStatus({
    required this.enabled,
    this.disabledReason,
    this.detail,
    this.dsn,
    this.environment,
    this.release,
    this.dist,
    this.sampleRate,
    this.tracesSampleRate,
    this.httpSampleRate,
    this.buildMode,
    this.httpInstrumented = false,
    this.warnings = const [],
  });

  /// The status before `CarpGlitchTip.init`.
  static const notInitialized = GlitchTipStatus(
    enabled: false,
    disabledReason: DisabledReason.notInitialized,
  );

  /// Whether reporting is on. False while the Sentry SDK is still starting
  /// ([DisabledReason.starting]), although errors are already sent then.
  final bool enabled;

  /// Why events are not sent, when [enabled] is false.
  final DisabledReason? disabledReason;

  /// More about [disabledReason], e.g. what is wrong with the DSN.
  final String? detail;

  /// The DSN without its key, e.g. `glitchtip.example.com/7`.
  final String? dsn;

  /// The environment events are reported in.
  final String? environment;

  /// The release, or `null` for the default `<package>@<version>+<build>`.
  final String? release;

  /// The distribution, or `null` for the default build number.
  final String? dist;

  /// The share of error events sent.
  final double? sampleRate;

  /// The share of transactions sent for traces and the app start.
  final double? tracesSampleRate;

  /// The share of network requests recorded as transactions.
  final double? httpSampleRate;

  /// The Flutter build mode: `debug`, `profile` or `release`.
  final String? buildMode;

  /// Whether `http.Client()`s created where init ran record their requests,
  /// i.e. init ran inside `CarpGlitchTip.runZoned` with `instrumentHttp`.
  final bool httpInstrumented;

  /// Problems with the configuration, e.g. an invalid value that was
  /// ignored. Part of the status line, also when reporting is off.
  final List<String> warnings;

  @override
  String toString() {
    final problems = warnings.isEmpty ? '' : ' warnings=${warnings.join('; ')}';
    final reason = disabledReason;
    final starting = reason == DisabledReason.starting;
    if (!enabled && !starting) {
      final description = reason?.description ?? 'disabled';
      return 'DISABLED: $description${detail == null ? '' : ' ($detail)'}'
          '$problems';
    }
    return [
          if (starting)
            'starting${detail == null ? '' : ' ($detail)'}:'
          else
            'enabled',
          'env=$environment',
          if (release != null) 'release=$release',
          'dsn=$dsn',
          'errors=$sampleRate',
          'traces=$tracesSampleRate',
          'http=$httpSampleRate',
          if (!httpInstrumented) 'http-instrumentation=off',
        ].join(' ') +
        problems;
  }
}
