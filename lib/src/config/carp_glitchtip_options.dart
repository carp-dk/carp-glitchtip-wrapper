import 'dart:async';

import 'package:sentry_flutter/sentry_flutter.dart';

import '../filters/ignore_rule.dart';
import '../network/url_normalizer.dart';
import 'glitchtip_env.dart';

/// How an app reports to GlitchTip, passed to `CarpGlitchTip.init`.
///
/// Values set here are the app's **defaults**: the env keys in
/// [GlitchTipKeys] (from [env] or `--dart-define`) override them, so a CI
/// build or the CARP debug toolkit can change them without a code change.
/// [configure] runs last and can change any other Sentry option.
///
/// For each setting the first available value wins:
///
/// 1. `GLITCHTIP_*` key, then its `SENTRY_*` alias, from [env] then from
///    `--dart-define`,
/// 2. the value in these options,
/// 3. a value derived by the wrapper (e.g. the environment from CARP's
///    `deployment-mode`),
/// 4. the wrapper default.
final class CarpGlitchTipOptions {
  /// Creates the reporting options. All values are optional.
  const CarpGlitchTipOptions({
    this.env,
    this.dsn,
    this.enabled,
    this.environment,
    this.release,
    this.dist,
    this.debug,
    this.sampleRate,
    this.tracesSampleRate,
    this.http = const HttpOptions(),
    this.offlineErrors = const IgnoreRule.offline(),
    this.ignoreErrors = const [],
    this.describeError,
    this.beforeSend,
    this.beforeBreadcrumb,
    this.configure,
    this.initTimeout = const Duration(seconds: 5),
  });

  /// An extra env source consulted before the compile-time defines, e.g.
  /// the CARP debug toolkit's runtime overrides (`debugLaunchOverride`) or
  /// `GlitchTipEnv.fromMap(dotenv.env)`.
  final EnvLookup? env;

  /// The GlitchTip DSN, e.g. `https://<key>@glitchtip.example.com/<id>`.
  /// Overridden by `GLITCHTIP_DSN` / `SENTRY_DSN`. Only `https` DSNs are
  /// accepted; debug builds also accept `http` for a server on the
  /// development machine (`localhost`, `127.0.0.1`, `10.0.2.2`).
  final String? dsn;

  /// Whether to report at all. Overridden by `GLITCHTIP_ENABLED`. Defaults
  /// to `false` in debug builds (incl. `flutter test`) and `true` otherwise.
  /// Under `flutter test` only `enabled: true` in code turns reporting on.
  final bool? enabled;

  /// The environment, e.g. `production`. Overridden by
  /// `GLITCHTIP_ENVIRONMENT` / `SENTRY_ENVIRONMENT`. Defaults to CARP's
  /// `deployment-mode` launch argument, else `production`; debug and
  /// profile builds get a `-debug` / `-profile` suffix.
  final String? environment;

  /// The release, overridden by `GLITCHTIP_RELEASE` / `SENTRY_RELEASE`.
  /// Defaults to `<package>@<version>+<build>` of the app.
  final String? release;

  /// The distribution, overridden by `GLITCHTIP_DIST` / `SENTRY_DIST`.
  /// Defaults to the build number.
  final String? dist;

  /// Whether the Sentry SDK prints diagnostics, overridden by
  /// `GLITCHTIP_DEBUG`. Defaults to the SDK default (on in debug builds).
  final bool? debug;

  /// Share of error events to send, from `0` to `1`. Overridden by
  /// `GLITCHTIP_SAMPLE_RATE`. Defaults to `1`.
  final double? sampleRate;

  /// Share of transactions to send for `CarpGlitchTip.trace` and the app
  /// start, from `0` to `1`. Overridden by `GLITCHTIP_TRACES_SAMPLE_RATE`.
  /// Defaults to `0.1` in release builds and `0` otherwise.
  final double? tracesSampleRate;

  /// How network requests are recorded.
  final HttpOptions http;

  /// The rule for expected network failures while the phone is offline
  /// (see [IgnoreRule.offline]), on by default. Set it to `null` to report
  /// these errors, or refine it, e.g.
  /// `IgnoreRule.offline().when(() => !isOnline)`.
  final IgnoreRule? offlineErrors;

  /// The app's rules for errors that must not be reported, in addition to
  /// [offlineErrors]. They apply to every reported error, including failed
  /// requests of the instrumented HTTP client.
  final List<IgnoreRule> ignoreErrors;

  /// Describes errors whose `toString()` says nothing, e.g.
  /// `(e) => e is CarpServiceException ? e.message : null`.
  ///
  /// The text is matched by ignore rules and replaces the error's value in
  /// the report, which gives GlitchTip readable titles and better grouping.
  final String? Function(Object error)? describeError;

  /// Called for every error event after the ignore rules and before the
  /// wrapper's privacy scrubbing. Return `null` to drop the event. If it
  /// throws or takes longer than 2 seconds, the event is sent as if it was
  /// not set.
  final FutureOr<SentryEvent?> Function(SentryEvent event, Hint hint)?
  beforeSend;

  /// Called for every breadcrumb before the wrapper's privacy scrubbing.
  /// Return `null` to drop the breadcrumb.
  final Breadcrumb? Function(Breadcrumb? breadcrumb, Hint hint)?
  beforeBreadcrumb;

  /// Changes any other Sentry option. Runs after the wrapper applied its
  /// configuration; the wrapper then re-applies the DSN, the environment and
  /// the settings GlitchTip and the CARP privacy policy depend on (e.g. the
  /// static trace lifecycle, no PII, no screenshots). Hooks set here
  /// (`beforeSend`, `beforeBreadcrumb`, ...) run after the ignore rules and
  /// the hooks of these options, and before the privacy scrubbing.
  /// Structured logs and metrics are only sent when `beforeSendLog` or
  /// `beforeSendMetric` is set here.
  final void Function(SentryFlutterOptions options)? configure;

  /// How long `CarpGlitchTip.init` may delay app start. When the Sentry SDK
  /// takes longer to start, init returns and the SDK keeps starting in the
  /// background.
  final Duration initTimeout;
}

/// How network requests made with `package:http` are recorded.
///
/// Every request becomes a breadcrumb, sampled requests become a GlitchTip
/// transaction named `<METHOD> <host>/<normalised path>`, and failed
/// requests (server errors and unexpected exceptions) become error events.
final class HttpOptions {
  /// Creates the network recording options.
  const HttpOptions({
    this.sampleRate,
    this.maxTransactionsPerMinute = 30,
    this.captureFailedRequests = true,
    this.isFailedStatus = HttpOptions.isServerError,
    this.failureEventWindow = const Duration(minutes: 10),
    this.breadcrumbs = true,
    this.tracePropagationTargets = const [],
    this.pathTemplates = const [],
    this.transactionName,
    this.excludeUrls = const [],
    this.traceIgnoredErrors = false,
  });

  /// Whether [statusCode] is a server error (5xx). The default
  /// [isFailedStatus].
  static bool isServerError(int statusCode) =>
      statusCode >= 500 && statusCode <= 599;

  /// Share of requests recorded as transactions, from `0` to `1`.
  /// Overridden by `GLITCHTIP_HTTP_SAMPLE_RATE`. Defaults to `0.1` in
  /// release builds and `0` otherwise.
  final double? sampleRate;

  /// The most transactions recorded per minute, whatever the sample rate,
  /// so they cannot crowd out error reports in the offline cache. Shared by
  /// request transactions and `CarpGlitchTip.trace`.
  final int maxTransactionsPerMinute;

  /// Whether failed requests are reported as error events: responses for
  /// which [isFailedStatus] is true, and exceptions not ignored by the
  /// ignore rules.
  final bool captureFailedRequests;

  /// Which response status codes are failures. Defaults to [isServerError].
  ///
  /// Requests the app cancels itself (http's `abortTrigger`) are recorded as
  /// cancelled, never as failures.
  final bool Function(int statusCode) isFailedStatus;

  /// The same failure (request name and status code or error type) is
  /// reported at most once per window. Retries, e.g. the 15 attempts of
  /// every carp_webservices call during a server outage, are counted
  /// instead.
  final Duration failureEventWindow;

  /// Whether requests are recorded as breadcrumbs.
  final bool breadcrumbs;

  /// URLs that receive `sentry-trace` and `baggage` headers, for tracing
  /// across services. Entries are regular expressions or substrings.
  /// Defaults to none.
  final List<String> tracePropagationTargets;

  /// Rewrites of request paths, applied before the default normalisation,
  /// e.g. to hide secrets in paths. CAWS secrets (`/api/self-signup/<code>`)
  /// are always hidden. Applied to every URL the wrapper reports.
  final List<PathTemplate> pathTemplates;

  /// Renames request transactions, e.g. to split a generic endpoint by
  /// operation. Receives the request `method`, its raw `url` and the default
  /// `name`, which already has ids replaced: build new names from `name`,
  /// not from `url`. CAWS RPC calls are named after their operation already.
  final String Function(String method, Uri url, String name)? transactionName;

  /// Requests whose URL (`scheme://host[:port]/path`, without query)
  /// matches one of these patterns are not recorded at all.
  final List<Pattern> excludeUrls;

  /// Whether requests that failed with an ignored error (e.g. while
  /// offline) are still recorded as transactions. They would count towards
  /// the error rate of the endpoint in GlitchTip.
  final bool traceIgnoredErrors;
}
