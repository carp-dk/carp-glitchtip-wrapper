import 'carp_glitchtip_options.dart';
import 'dsn.dart';
import 'glitchtip_env.dart';
import 'glitchtip_status.dart';

/// The configuration the wrapper runs with, resolved from
/// [CarpGlitchTipOptions] and the env.
final class ResolvedConfig {
  ResolvedConfig({
    required this.enabled,
    this.disabledReason,
    this.disabledDetail,
    this.dsn,
    required this.environment,
    this.release,
    this.dist,
    this.debug,
    required this.sampleRate,
    required this.tracesSampleRate,
    required this.httpSampleRate,
    required this.buildMode,
    this.deploymentMode,
    this.warnings = const [],
  });

  final bool enabled;
  final DisabledReason? disabledReason;
  final String? disabledDetail;

  /// The validated DSN; `null` when reporting is disabled.
  final String? dsn;

  final String environment;
  final String? release;
  final String? dist;
  final bool? debug;
  final double sampleRate;
  final double tracesSampleRate;
  final double httpSampleRate;
  final String buildMode;
  final String? deploymentMode;
  final List<String> warnings;

  /// The status of this configuration; with [disabled], of a start that
  /// is not done ([DisabledReason.starting]) or failed, described by
  /// [detail].
  GlitchTipStatus toStatus({
    required bool httpInstrumented,
    DisabledReason? disabled,
    String? detail,
  }) => GlitchTipStatus(
    enabled: enabled && disabled == null,
    disabledReason: disabled ?? disabledReason,
    detail: disabled == null ? disabledDetail : detail,
    dsn: dsn == null ? null : dsnLabel(dsn!),
    environment: environment,
    release: release,
    dist: dist,
    sampleRate: sampleRate,
    tracesSampleRate: tracesSampleRate,
    httpSampleRate: httpSampleRate,
    buildMode: buildMode,
    httpInstrumented: httpInstrumented,
    warnings: List.unmodifiable(warnings),
  );
}

/// Resolves [options] against the env [lookup] (see [CarpGlitchTipOptions]
/// for the precedence). Never throws; problems end up in
/// [ResolvedConfig.warnings] or disable reporting with a reason.
///
/// [buildMode] is `debug`, `profile` or `release`. Under `flutter test`
/// ([isFlutterTest]) only `enabled: true` in code turns reporting on, so a
/// shared define file cannot make host tests report.
ResolvedConfig resolveConfig(
  CarpGlitchTipOptions options, {
  required EnvLookup lookup,
  required String buildMode,
  bool isFlutterTest = false,
}) {
  final warnings = <String>[];
  final isRelease = buildMode == 'release';
  final isDebug = buildMode == 'debug';

  // GLITCHTIP_X before its SENTRY_X alias
  (String, String)? fromEnv(String key, [String? alias]) {
    final value = lookup(key);
    if (value != null) return (key, value);
    if (alias == null) return null;
    final aliased = lookup(alias);
    return aliased == null ? null : (alias, aliased);
  }

  String? text(String what, String? value, String key, [String? alias]) {
    final code = value?.trim();
    final fromCode = code == null || code.isEmpty ? null : code;
    final env = fromEnv(key, alias);
    if (env != null && fromCode != null && env.$2 != fromCode) {
      warnings.add('${env.$1} overrides $what set in code');
    }
    return env?.$2 ?? fromCode;
  }

  bool? flag(String what, bool? value, String key) {
    final raw = lookup(key);
    if (raw == null) return value;
    final parsed = _parseBool(raw);
    if (parsed == null) {
      warnings.add('ignored $key=$raw (not a boolean)');
      return value;
    }
    if (value != null && value != parsed) {
      warnings.add('$key overrides $what set in code');
    }
    return parsed;
  }

  double? rate(String what, double? value, String key) {
    double? fromCode = value;
    if (fromCode != null && !_isRate(fromCode)) {
      warnings.add('ignored $what=$fromCode (not between 0 and 1)');
      fromCode = null;
    }
    final raw = lookup(key);
    if (raw == null) return fromCode;
    final parsed = double.tryParse(raw);
    if (parsed == null || !_isRate(parsed)) {
      warnings.add('ignored $key=$raw (not a number between 0 and 1)');
      return fromCode;
    }
    if (fromCode != null && fromCode != parsed) {
      warnings.add('$key overrides $what set in code');
    }
    return parsed;
  }

  // enabled
  var enabled = false;
  DisabledReason? reason;
  String? detail;
  if (isFlutterTest && options.enabled != true) {
    reason = DisabledReason.flutterTest;
  } else {
    final value = isFlutterTest
        ? true
        : flag('enabled', options.enabled, GlitchTipKeys.enabled);
    enabled = value ?? !isDebug;
    if (!enabled) {
      reason = value == false
          ? DisabledReason.disabledByConfig
          : DisabledReason.debugBuild;
    }
  }

  // DSN
  String? dsn;
  final rawDsn = text(
    'dsn',
    options.dsn,
    GlitchTipKeys.dsn,
    GlitchTipKeys.sentryDsn,
  );
  if (rawDsn == null) {
    if (enabled) {
      enabled = false;
      reason = DisabledReason.missingDsn;
    }
  } else {
    final normalized = normalizeDsn(rawDsn);
    final problem = validateDsn(normalized, allowInsecureLocal: isDebug);
    if (problem == null) {
      dsn = normalized;
    } else if (enabled) {
      enabled = false;
      reason = DisabledReason.invalidDsn;
      detail = '$problem: ${dsnLabel(normalized)}';
    }
  }

  // environment, from CARP's deployment mode unless set explicitly
  final deploymentMode = lookup(GlitchTipKeys.deploymentMode);
  final environment =
      text(
        'environment',
        options.environment,
        GlitchTipKeys.environment,
        GlitchTipKeys.sentryEnvironment,
      ) ??
      (isRelease
          ? deploymentMode ?? 'production'
          : '${deploymentMode ?? 'production'}-$buildMode');

  final defaultRate = isRelease ? 0.1 : 0.0;
  return ResolvedConfig(
    enabled: enabled,
    disabledReason: reason,
    disabledDetail: detail,
    dsn: enabled ? dsn : null,
    environment: environment,
    release: text(
      'release',
      options.release,
      GlitchTipKeys.release,
      GlitchTipKeys.sentryRelease,
    ),
    dist: text(
      'dist',
      options.dist,
      GlitchTipKeys.dist,
      GlitchTipKeys.sentryDist,
    ),
    debug: flag('debug', options.debug, GlitchTipKeys.debug),
    sampleRate:
        rate('sampleRate', options.sampleRate, GlitchTipKeys.sampleRate) ?? 1,
    tracesSampleRate:
        rate(
          'tracesSampleRate',
          options.tracesSampleRate,
          GlitchTipKeys.tracesSampleRate,
        ) ??
        defaultRate,
    httpSampleRate:
        rate(
          'http.sampleRate',
          options.http.sampleRate,
          GlitchTipKeys.httpSampleRate,
        ) ??
        defaultRate,
    buildMode: buildMode,
    deploymentMode: deploymentMode,
    warnings: warnings,
  );
}

bool _isRate(double value) => value.isFinite && value >= 0 && value <= 1;

bool? _parseBool(String value) => switch (value.trim().toLowerCase()) {
  'true' || '1' || 'yes' || 'on' => true,
  'false' || '0' || 'no' || 'off' => false,
  _ => null,
};
