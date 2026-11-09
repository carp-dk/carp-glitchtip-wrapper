/// GlitchTip error and network performance reporting for CARP Flutter apps.
///
/// Wraps the Sentry Flutter SDK (GlitchTip speaks the Sentry protocol) so
/// every CARP app reports the same way:
///
///  * configured from the env: `GLITCHTIP_DSN` and the other
///    [GlitchTipKeys], passed with `--dart-define` /
///    `--dart-define-from-file`, see [CarpGlitchTipOptions];
///  * the environment, release and study ([StudyMetadata]) on every report;
///  * every request of `package:http` recorded, also inside CARP packages
///    such as carp_webservices, see [CarpGlitchTip.runZoned];
///  * expected errors ignored, e.g. the network errors CARP packages throw
///    while the phone is offline, see [IgnoreRule];
///  * settings GlitchTip needs and a privacy policy suitable for health
///    research applied by default.
///
/// ```dart
/// Future<void> main() => CarpGlitchTip.runZoned(() async {
///   await CarpGlitchTip.init(const CarpGlitchTipOptions());
///   runApp(const MyApp());
/// });
/// ```
library;

export 'package:sentry_flutter/sentry_flutter.dart'
    show Breadcrumb, Hint, SentryEvent, SentryFlutterOptions, SentryLevel;

export 'src/carp_glitchtip.dart';
export 'src/config/carp_glitchtip_options.dart';
export 'src/config/glitchtip_env.dart';
export 'src/config/glitchtip_status.dart';
export 'src/filters/ignore_rule.dart'
    show IgnoreCandidate, IgnoreRule, IgnoreType;
export 'src/metadata/glitchtip_tags.dart';
export 'src/metadata/study_metadata.dart';
export 'src/network/url_normalizer.dart' show PathTemplate;
