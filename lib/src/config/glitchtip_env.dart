/// Looks up a configuration value by [key], e.g. a `--dart-define` name.
///
/// Returns `null` when the key is not set. This is the same shape as CARP's
/// `debugLaunchOverride` hook and `DebugEnv().overrideOf`, so those can be
/// passed directly as an env source.
typedef EnvLookup = String? Function(String key);

/// The env keys read by the wrapper.
///
/// All keys are SCREAMING_SNAKE so they work with `--dart-define`, with
/// `--dart-define-from-file` (both `.env` and `.json` files) and as CI
/// variable names.
abstract final class GlitchTipKeys {
  /// The GlitchTip DSN. Reporting is disabled when it is missing or invalid.
  static const dsn = 'GLITCHTIP_DSN';

  /// `true` / `false` to force reporting on or off.
  static const enabled = 'GLITCHTIP_ENABLED';

  /// The environment name, e.g. `production`.
  static const environment = 'GLITCHTIP_ENVIRONMENT';

  /// The release name. Defaults to `<package>@<version>+<build>`.
  static const release = 'GLITCHTIP_RELEASE';

  /// The distribution (build) name. Defaults to the build number.
  static const dist = 'GLITCHTIP_DIST';

  /// `true` to print the Sentry SDK's own diagnostic logs.
  static const debug = 'GLITCHTIP_DEBUG';

  /// Share of error events to send, from `0` to `1`.
  static const sampleRate = 'GLITCHTIP_SAMPLE_RATE';

  /// Share of transactions to send, from `0` to `1`.
  static const tracesSampleRate = 'GLITCHTIP_TRACES_SAMPLE_RATE';

  /// Share of network requests recorded as transactions, from `0` to `1`.
  static const httpSampleRate = 'GLITCHTIP_HTTP_SAMPLE_RATE';

  /// Sentry's DSN key, used when [dsn] is not set.
  static const sentryDsn = 'SENTRY_DSN';

  /// Sentry's environment key, used when [environment] is not set.
  static const sentryEnvironment = 'SENTRY_ENVIRONMENT';

  /// Sentry's release key, used when [release] is not set.
  static const sentryRelease = 'SENTRY_RELEASE';

  /// Sentry's dist key, used when [dist] is not set.
  static const sentryDist = 'SENTRY_DIST';

  /// CARP's deployment mode launch argument (`production`, `test`, `dev`,
  /// `local`), used as the environment when no environment key is set.
  static const deploymentMode = 'deployment-mode';

  /// Every key the wrapper reads.
  static const all = [
    dsn,
    enabled,
    environment,
    release,
    dist,
    debug,
    sampleRate,
    tracesSampleRate,
    httpSampleRate,
    sentryDsn,
    sentryEnvironment,
    sentryRelease,
    sentryDist,
    deploymentMode,
  ];
}

/// Sources of configuration values for the wrapper.
///
/// By default the wrapper reads the compile-time defines ([compileTime]),
/// i.e. values passed with `--dart-define=KEY=value` or
/// `--dart-define-from-file=glitchtip.env`. Other sources, e.g. runtime
/// overrides from the CARP debug toolkit or a `flutter_dotenv` map, can be
/// placed in front of them with [chain].
abstract final class GlitchTipEnv {
  /// The compile-time define of every key in [GlitchTipKeys.all], or `null`
  /// when it was not defined.
  ///
  /// `String.fromEnvironment` only works reliably when it is evaluated as a
  /// constant, so the set of keys is fixed. Read other keys in the app with
  /// `const String.fromEnvironment('KEY')` and pass them with [fromMap].
  static const Map<String, String?> defines = {
    GlitchTipKeys.dsn: bool.hasEnvironment(GlitchTipKeys.dsn)
        ? String.fromEnvironment(GlitchTipKeys.dsn)
        : null,
    GlitchTipKeys.enabled: bool.hasEnvironment(GlitchTipKeys.enabled)
        ? String.fromEnvironment(GlitchTipKeys.enabled)
        : null,
    GlitchTipKeys.environment: bool.hasEnvironment(GlitchTipKeys.environment)
        ? String.fromEnvironment(GlitchTipKeys.environment)
        : null,
    GlitchTipKeys.release: bool.hasEnvironment(GlitchTipKeys.release)
        ? String.fromEnvironment(GlitchTipKeys.release)
        : null,
    GlitchTipKeys.dist: bool.hasEnvironment(GlitchTipKeys.dist)
        ? String.fromEnvironment(GlitchTipKeys.dist)
        : null,
    GlitchTipKeys.debug: bool.hasEnvironment(GlitchTipKeys.debug)
        ? String.fromEnvironment(GlitchTipKeys.debug)
        : null,
    GlitchTipKeys.sampleRate: bool.hasEnvironment(GlitchTipKeys.sampleRate)
        ? String.fromEnvironment(GlitchTipKeys.sampleRate)
        : null,
    GlitchTipKeys.tracesSampleRate:
        bool.hasEnvironment(GlitchTipKeys.tracesSampleRate)
        ? String.fromEnvironment(GlitchTipKeys.tracesSampleRate)
        : null,
    GlitchTipKeys.httpSampleRate:
        bool.hasEnvironment(GlitchTipKeys.httpSampleRate)
        ? String.fromEnvironment(GlitchTipKeys.httpSampleRate)
        : null,
    GlitchTipKeys.sentryDsn: bool.hasEnvironment(GlitchTipKeys.sentryDsn)
        ? String.fromEnvironment(GlitchTipKeys.sentryDsn)
        : null,
    GlitchTipKeys.sentryEnvironment:
        bool.hasEnvironment(GlitchTipKeys.sentryEnvironment)
        ? String.fromEnvironment(GlitchTipKeys.sentryEnvironment)
        : null,
    GlitchTipKeys.sentryRelease:
        bool.hasEnvironment(GlitchTipKeys.sentryRelease)
        ? String.fromEnvironment(GlitchTipKeys.sentryRelease)
        : null,
    GlitchTipKeys.sentryDist: bool.hasEnvironment(GlitchTipKeys.sentryDist)
        ? String.fromEnvironment(GlitchTipKeys.sentryDist)
        : null,
    GlitchTipKeys.deploymentMode:
        bool.hasEnvironment(GlitchTipKeys.deploymentMode)
        ? String.fromEnvironment(GlitchTipKeys.deploymentMode)
        : null,
  };

  /// Looks up [key] in the compile-time [defines].
  static String? compileTime(String key) => defines[key];

  /// An env source backed by [values], e.g. `dotenv.env` or values the app
  /// read itself.
  static EnvLookup fromMap(Map<String, String?> values) =>
      (key) => values[key];

  /// An env source that asks each of [sources] in order and returns the
  /// first usable value.
  ///
  /// Values are trimmed; empty values and the text `null` (what a JSON
  /// define file turns `null` into) count as not set. A source that throws
  /// is skipped. `null` sources are ignored, so an optional hook such as
  /// `debugLaunchOverride` can be passed directly.
  static EnvLookup chain(Iterable<EnvLookup?> sources) {
    final lookups = sources.whereType<EnvLookup>().toList(growable: false);
    return (key) {
      for (final lookup in lookups) {
        final String? value;
        try {
          value = lookup(key)?.trim();
        } catch (_) {
          continue;
        }
        if (value == null || value.isEmpty || value.toLowerCase() == 'null') {
          continue;
        }
        return value;
      }
      return null;
    };
  }
}
