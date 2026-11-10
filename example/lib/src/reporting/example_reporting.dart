// Contains how the example reports to GlitchTip, in preview and live mode.
//
// Parts:
// - `ReportingMode`, preview (no DSN) or live (a DSN is defined).
// - `ExampleReporting`, the options of each mode and the app's rules.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';

import '../caws/caws_exception.dart';
import '../models/device_not_connected_exception.dart';
import 'report_outbox.dart';

/// Where the example's reports go.
enum ReportingMode {
  /// No DSN is defined: reports are kept on the device, in a
  /// `ReportOutbox`, and shown on the Reports tab.
  preview,

  /// A DSN is defined with `--dart-define=GLITCHTIP_DSN=...`: the env
  /// decides, as in a real CARP app (off in debug builds unless
  /// `GLITCHTIP_ENABLED=true`).
  live,
}

/// The GlitchTip setup of the example.
abstract final class ExampleReporting {
  /// The placeholder DSN of preview mode. The outbox keeps the app's
  /// reports; only the native SDK's own reports go to this DSN, whose host
  /// does not exist.
  static const previewDsn = 'https://preview@glitchtip.invalid/1';

  /// The mode of this build: [ReportingMode.live] when `GLITCHTIP_DSN` (or
  /// `SENTRY_DSN`) is defined, else [ReportingMode.preview].
  static ReportingMode get mode {
    final env = GlitchTipEnv.chain([GlitchTipEnv.compileTime]);
    final dsn = env(GlitchTipKeys.dsn) ?? env(GlitchTipKeys.sentryDsn);
    return dsn == null ? ReportingMode.preview : ReportingMode.live;
  }

  /// The errors the app reports with `captureException` but must not reach
  /// GlitchTip. The wrapper already ignores network errors while the phone
  /// is offline.
  static const ignoreErrors = <IgnoreRule>[
    // expected: the participant switched the device off
    IgnoreType<DeviceNotConnectedException>(),
    // the wrapper's HTTP client already reported the response, as
    // "HTTP 500: POST caws.example.org/api/... <operation>"
    IgnoreType<CawsException>(
      where: reportedByHttpClient,
      name: 'reported by the HTTP client',
    ),
  ];

  /// Whether the wrapper's HTTP client reported the response of [error]
  /// itself: a server error (5xx, its failures by default), while it records
  /// requests. It does not yet while the Sentry SDK is starting, when errors
  /// are already sent.
  static bool reportedByHttpClient(CawsException error) =>
      CarpGlitchTip.isEnabled && HttpOptions.isServerError(error.statusCode);

  /// Gives errors without a useful `toString()` a readable text in
  /// GlitchTip, here the CAWS errors of the app's repository.
  static String? describeError(Object error) =>
      error is CawsException ? error.description : null;

  /// Live mode: like a real CARP app, everything else comes from the env.
  static CarpGlitchTipOptions liveOptions() => const CarpGlitchTipOptions(
    ignoreErrors: ignoreErrors,
    describeError: describeError,
  );

  /// Preview mode: reporting is on in every build, every request and trace
  /// is recorded, and [outbox] keeps the reports instead of sending them.
  ///
  /// The native SDK starts as in live mode, so the reports get the device
  /// contexts it adds (on iOS, the SDK waits for them forever when it is
  /// not started). Its own reports, e.g. of native crashes, go to the
  /// placeholder DSN, whose host does not exist.
  static CarpGlitchTipOptions previewOptions(ReportOutbox outbox) =>
      CarpGlitchTipOptions(
        enabled: true,
        dsn: previewDsn,
        environment: 'preview',
        tracesSampleRate: 1,
        http: const HttpOptions(sampleRate: 1),
        ignoreErrors: ignoreErrors,
        describeError: describeError,
        configure: (options) => options.transport = outbox,
      );
}
