import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'config/carp_glitchtip_options.dart';
import 'config/dsn.dart';
import 'config/resolve.dart';
import 'filters/ignore_rule.dart';
import 'filters/network_errors.dart';
import 'filters/network_health.dart';
import 'metadata/glitchtip_tags.dart';
import 'metadata/scope_state.dart';
import 'network/caws.dart';
import 'network/url_normalizer.dart';
import 'pipeline/privacy.dart';
import 'util/diagnostics.dart';
import 'util/limits.dart';

/// Hint key of an error that stopped the app from starting. Such errors are
/// reported even when an ignore rule matches.
const startupFailureHint = 'carp_glitchtip.startup_failure';

/// The mechanism of events captured by the wrapper's HTTP client.
const httpClientMechanism = 'CarpGlitchTipHttpClient';

/// The origin of request transactions recorded by the wrapper.
const transactionOrigin = 'auto.http.carp_glitchtip';

/// The origin of transactions of `CarpGlitchTip.trace`.
const traceOrigin = 'manual';

/// A running GlitchTip reporter, created by a successful
/// `CarpGlitchTip.init`.
class GlitchTipRuntime {
  GlitchTipRuntime({
    required this.options,
    required this.config,
    required this.scope,
    Random? random,
  }) : random = random ?? Random(),
       rules = [?options.offlineErrors, ...options.ignoreErrors],
       pathTemplates = [...cawsPathTemplates, ...options.http.pathTemplates],
       failureThrottle = EventThrottle(options.http.failureEventWindow),
       transactionLimiter = RateLimiter(options.http.maxTransactionsPerMinute),
       ingest = config.dsn == null ? null : ingestPrefix(config.dsn!) {
    privacy = Privacy(
      user: scope.user ?? SentryUser(id: 'anonymous'),
      templates: pathTemplates,
      describeError: options.describeError,
    );
  }

  /// The running reporter, or `null` when reporting is off.
  static GlitchTipRuntime? current;

  final CarpGlitchTipOptions options;
  final ResolvedConfig config;
  final ScopeState scope;
  final Random random;
  final List<IgnoreRule> rules;
  final List<PathTemplate> pathTemplates;
  final EventThrottle failureThrottle;
  final RateLimiter transactionLimiter;

  /// Where the Sentry SDK sends envelopes; never recorded.
  final Uri? ingest;

  late final Privacy privacy;

  /// Whether the Sentry SDK finished starting.
  bool active = false;

  // hooks an app set directly on the Sentry options in `configure`; they run
  // inside the wrapper's own hooks
  BeforeSendCallback? _configuredBeforeSend;
  BeforeSendTransactionCallback? _configuredBeforeSendTransaction;
  BeforeBreadcrumbCallback? _configuredBeforeBreadcrumb;
  BeforeSendCallback? _configuredBeforeSendFeedback;
  BeforeSendLogCallback? _configuredBeforeSendLog;
  BeforeSendMetricCallback? _configuredBeforeSendMetric;

  // the url and method of the request an error of the instrumented client
  // came from, so ignore rules see them also when the error is reported
  // later; not the request, which would keep its body alive with the error
  static Expando<(Uri, String)> _requests = Expando();

  /// Remembers that [error] was thrown by [request].
  static void rememberRequest(Object error, http.BaseRequest request) {
    try {
      _requests[error] = (request.url, request.method);
    } catch (_) {
      // strings, numbers and other values cannot carry an expando
    }
  }

  /// The url and method of the request [error] was thrown by, if the
  /// instrumented client saw it.
  static (Uri, String)? requestOf(Object error) {
    try {
      return _requests[error];
    } catch (_) {
      return null;
    }
  }

  /// Forgets the requests of all errors. For tests.
  static void forgetRequests() => _requests = Expando();

  /// How long an app hook may take before the event is sent without it.
  static const hookTimeout = Duration(seconds: 2);

  HttpOptions get httpOptions => options.http;

  NetworkHealth get health => NetworkHealth.instance;

  // ---------------------------------------------------------------------
  // Sentry options
  // ---------------------------------------------------------------------

  /// Configures the Sentry SDK, as the options callback of
  /// `SentryFlutter.init`. Never throws: Sentry would swallow the error and
  /// continue with half-applied options.
  void configure(SentryFlutterOptions o) {
    try {
      _applyDefaults(o);
      final configure = options.configure;
      if (configure != null) {
        try {
          configure(o);
        } catch (error) {
          debugWarn('configure() failed: $error');
        }
      }
    } catch (error) {
      debugWarn('configuring the Sentry SDK failed: $error');
    } finally {
      _applyInvariants(o);
    }
  }

  void _applyDefaults(SentryFlutterOptions o) {
    // always assigned: Sentry pre-fills them from SENTRY_* defines and, on
    // desktop and in tests, from the process environment
    o.dsn = config.dsn;
    o.environment = config.environment;
    o.release = config.release;
    o.dist = config.dist;
    final debug = config.debug;
    if (debug != null) o.debug = debug;
    o.sampleRate = config.sampleRate;
    o.tracesSampleRate = config.tracesSampleRate;
    // GlitchTip only stores transactions: streamed spans are dropped
    o.traceLifecycle = SentryTraceLifecycle.static;

    // GlitchTip drops sessions and client reports, and stores no frame
    // measurements
    o.enableAutoSessionTracking = false;
    o.sendClientReports = false;
    o.enableFramesTracking = false;
    // a tap transaction bound to the scope would become the GlitchTip
    // culprit of errors and split issues
    o.enableUserInteractionTracing = false;
    o.enableAppLifecycleBreadcrumbs = true;
    // phones can be offline for days; the native offline cache is shared by
    // errors and transactions
    o.maxCacheItems = 100;
    // GlitchTip rejects envelopes over 5 MB as a whole
    o.maxAttachmentSize = 1024 * 1024;

    // GlitchTip names an issue after its innermost in-app frame: that must
    // be the app's code, not the wrapper's or package:http's
    o.addInAppExclude('carp_glitchtip_wrapper');
    o.addInAppExclude('http');

    // runs before the native enrichment, so dropped events cost nothing
    o.addEventProcessor(_EarlyProcessor(this));
    // runs after the native SDK started, so the scope reaches native too
    o.addIntegration(_ScopeIntegration(this));

    o.beforeSend = null;
    o.beforeSendTransaction = null;
    o.beforeBreadcrumb = null;
    o.beforeSendFeedback = null;
    o.beforeSendLog = null;
    o.beforeSendMetric = null;
  }

  void _applyInvariants(SentryFlutterOptions o) {
    // decided before init; configure cannot change them
    o.dsn = config.dsn;
    o.environment = config.environment;

    if (o.traceLifecycle != SentryTraceLifecycle.static) {
      debugWarn(
        'configure() set a streaming trace lifecycle; GlitchTip only '
        'stores transactions, so it is reset to static',
      );
      o.traceLifecycle = SentryTraceLifecycle.static;
    }
    // without tracing, the wrapper's own transactions would be no-ops
    if (o.tracesSampleRate == null && o.tracesSampler == null) {
      o.tracesSampleRate = 0;
    }

    // the CARP privacy policy
    o.sendDefaultPii = false;
    o.maxRequestBodySize = MaxRequestBodySize.never;
    o.attachScreenshot = false;
    o.attachViewHierarchy = false;
    o.replay.sessionSampleRate = 0;
    o.replay.onErrorSampleRate = 0;
    // replaces debugPrint in release builds: console output would be lost
    // and every log line (incl. CARP user names) recorded
    o.enablePrintBreadcrumbs = false;
    // screen on/off, charging, connectivity, ... of the participant
    o.enableAutoNativeBreadcrumbs = false;
    // on iOS this also adds trace headers to every native request
    o.recordHttpBreadcrumbs = false;
    o.captureNativeFailedRequests = false;
    // failed requests are captured by the wrapper's own client
    o.captureFailedRequests = false;
    o.tracePropagationTargets
      ..clear()
      ..addAll(httpOptions.tracePropagationTargets);
    // the SDK puts the raw name of a transaction into the trace header of
    // the envelopes, before any hook could scrub it
    o.addIntegrationByIndex(0, _TraceHeaderIntegration());

    if (o.ignoreErrors.isNotEmpty) {
      debugWarn(
        'SentryOptions.ignoreErrors only matches message events; use '
        'CarpGlitchTipOptions.ignoreErrors',
      );
    }

    // keep what configure set and run it inside the wrapper's hooks
    _configuredBeforeSend = o.beforeSend;
    _configuredBeforeSendTransaction = o.beforeSendTransaction;
    _configuredBeforeBreadcrumb = o.beforeBreadcrumb;
    _configuredBeforeSendFeedback = o.beforeSendFeedback;
    _configuredBeforeSendLog = o.beforeSendLog;
    _configuredBeforeSendMetric = o.beforeSendMetric;
    o.beforeSend = beforeSend;
    o.beforeSendTransaction = beforeSendTransaction;
    o.beforeBreadcrumb = beforeBreadcrumb;
    o.beforeSendFeedback = beforeSendFeedback;
    o.beforeSendLog = beforeSendLog;
    o.beforeSendMetric = beforeSendMetric;
  }

  // ---------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------

  /// Text from `CarpGlitchTipOptions.describeError` for [error], if any.
  String? describe(Object error) {
    final describe = options.describeError;
    if (describe == null) return null;
    return guard<String?>('describeError', () => describe(error));
  }

  /// The first rule that ignores [candidate], or `null`.
  IgnoreRule? ignoringRule(IgnoreCandidate candidate) =>
      firstMatchingRule(rules, candidate);

  /// What ignore rules see of [event].
  IgnoreCandidate candidateFor(SentryEvent event, Hint hint) {
    final error = event.throwable as Object?;
    Uri? url;
    String? method;
    final request = hint.get(TypeCheckHint.httpRequest);
    final remembered = error == null ? null : requestOf(error);
    if (request is http.BaseRequest) {
      url = request.url;
      method = request.method;
    } else if (remembered != null) {
      (url, method) = remembered;
    } else if (error is http.ClientException) {
      url = error.uri;
    }
    final response = hint.get(TypeCheckHint.httpResponse);
    final statusCode = response is http.BaseResponse
        ? response.statusCode
        : event.contexts.response?.statusCode;
    return IgnoreCandidate(
      error: error,
      message: event.message?.formatted,
      url: url,
      method: method ?? event.request?.method,
      statusCode: statusCode,
      details: [
        for (final exception in event.exceptions ?? const <SentryException>[])
          '${exception.type}: ${exception.value}',
        if (error != null) ?describe(error),
      ],
    );
  }

  /// The early event processor: applies the ignore rules and throttles
  /// repeated network errors. Returns `null` to drop [event].
  SentryEvent? processEvent(SentryEvent event, Hint hint) {
    scope.refresh();
    scope.stamp(event);

    if (hint.get(startupFailureHint) == true) {
      event.tags = {...?event.tags, GlitchTipTags.startupFailure: 'true'};
    } else {
      final candidate = candidateFor(event, hint);
      final rule = ignoringRule(candidate);
      if (rule != null) {
        final what = candidate.error?.runtimeType ?? 'message';
        debugWarn('not reporting $what, ignored by $rule', once: true);
        return null;
      }
      if (_throttled(event, candidate)) return null;
    }

    // GlitchTip uses the transaction name as the issue culprit, which would
    // split one error into an issue per screen (or app start window)
    final transaction = event.transaction;
    if (transaction != null) {
      final screen = transaction.split(RegExp('[?#]')).first;
      event.tags = {GlitchTipTags.screen: screen, ...?event.tags};
      event.transaction = null;
    }
    return event;
  }

  // unhandled network errors of a request, e.g. what carp_webservices
  // rethrows after its retries, are reported once per window per request;
  // errors the app reports itself and errors without a request are not
  // throttled, as unrelated errors would share a window
  bool _throttled(SentryEvent event, IgnoreCandidate candidate) {
    final error = candidate.error;
    final url = candidate.url;
    if (error == null || url == null || !isNetworkError(error)) return false;
    final mechanisms = event.exceptions?.map((e) => e.mechanism).nonNulls;
    if (mechanisms == null || !mechanisms.any((m) => m.handled == false)) {
      return false;
    }
    // the client's own failure events are throttled by the client
    if (mechanisms.any((m) => m.type == httpClientMechanism)) return false;
    final route = normalizeUrl(url, templates: pathTemplates);
    final key =
        'event ${error.runtimeType} ${networkErrorCode(error) ?? ''} $route';
    final suppressed = failureThrottle.admit(key);
    if (suppressed == null) {
      debugWarn(
        'not reporting ${error.runtimeType} again within the '
        'failure window',
        once: true,
      );
      return true;
    }
    _addSuppressed(event, suppressed);
    return false;
  }

  /// The wrapper's `beforeSend`: the app's hooks, then the privacy policy.
  Future<SentryEvent?> beforeSend(SentryEvent event, Hint hint) async {
    final current = await _runHooks('beforeSend', event, hint, [
      options.beforeSend,
      _configuredBeforeSend,
    ]);
    if (current == null) return null;
    _dropClearedBreadcrumbs(current);
    return privacy.event(current);
  }

  /// The wrapper's `beforeSendFeedback`: the app's hook, then the privacy
  /// policy (the participant's own message, name and e-mail are kept).
  Future<SentryEvent?> beforeSendFeedback(SentryEvent event, Hint hint) async {
    final current = await _runHooks('beforeSendFeedback', event, hint, [
      _configuredBeforeSendFeedback,
    ]);
    if (current == null) return null;
    _dropClearedBreadcrumbs(current);
    return privacy.feedback(current);
  }

  /// The wrapper's `beforeSendLog`: structured logs (`Sentry.logger`) are
  /// dropped, unless the app set a `beforeSendLog` in `configure`; their
  /// body and attributes are then scrubbed.
  Future<SentryLog?> beforeSendLog(SentryLog log, Hint hint) {
    final hook = _configuredBeforeSendLog;
    return _optedIn(
      'beforeSendLog',
      hook == null ? null : () => hook(log, hint),
      privacy.log,
    );
  }

  /// The wrapper's `beforeSendMetric`: metrics (`Sentry.metrics`), which
  /// GlitchTip does not store, are dropped, unless the app set a
  /// `beforeSendMetric` in `configure`; their attributes are then scrubbed.
  Future<SentryMetric?> beforeSendMetric(SentryMetric metric, Hint hint) {
    final hook = _configuredBeforeSendMetric;
    return _optedIn(
      'beforeSendMetric',
      hook == null ? null : () => hook(metric, hint),
      privacy.metric,
    );
  }

  // telemetry the app opted into by setting [hook]: dropped when the hook
  // or the privacy policy fails
  Future<T?> _optedIn<T extends Object>(
    String what,
    FutureOr<T?> Function()? hook,
    T Function(T) scrub,
  ) async {
    if (hook == null) return null;
    try {
      final result = await Future.value(hook()).timeout(hookTimeout);
      return result == null ? null : scrub(result);
    } catch (error) {
      debugWarn('$what failed, the item is dropped: $error', once: true);
      return null;
    }
  }

  // runs the app's [hooks]: a hook that throws or takes longer than
  // [hookTimeout] is skipped (the event is sent as if it was not set)
  Future<SentryEvent?> _runHooks(
    String what,
    SentryEvent event,
    Hint hint,
    List<BeforeSendCallback?> hooks,
  ) async {
    SentryEvent? current = event;
    for (final hook in hooks) {
      if (hook == null || current == null) continue;
      final before = current;
      try {
        final result = hook(before, hint);
        current = result is Future<SentryEvent?>
            ? await result.timeout(hookTimeout)
            : result;
      } catch (error) {
        debugWarn('$what failed, the event is sent as is: $error', once: true);
        current = before;
      }
    }
    return current;
  }

  // breadcrumbs of a study the participant left (also those the native SDK
  // still had when the event was enriched); never throws, as Sentry would
  // drop the event
  void _dropClearedBreadcrumbs(SentryEvent event) {
    final cleared = scope.breadcrumbsClearedAt;
    if (cleared == null) return;
    try {
      final crumbs = event.breadcrumbs;
      if (crumbs == null) return;
      // a new list: an app hook may have set an unmodifiable one
      event.breadcrumbs = [
        for (final crumb in crumbs)
          if (crumb.timestamp.isAfter(cleared)) crumb,
      ];
    } catch (error) {
      debugWarn('filtering breadcrumbs failed: $error', once: true);
      event.breadcrumbs = null;
    }
  }

  /// The wrapper's `beforeSendTransaction`: the app's hook, then the
  /// privacy policy, which also reduces the transaction to what GlitchTip
  /// stores.
  Future<SentryTransaction?> beforeSendTransaction(
    SentryTransaction transaction,
    Hint hint,
  ) async {
    SentryTransaction? current = transaction;
    final hook = _configuredBeforeSendTransaction;
    if (hook != null) {
      try {
        current = await Future.value(
          hook(transaction, hint),
        ).timeout(hookTimeout);
      } catch (error) {
        debugWarn('beforeSendTransaction failed: $error', once: true);
        current = transaction;
      }
    }
    return current == null ? null : privacy.transaction(current);
  }

  /// The wrapper's `beforeBreadcrumb`: drops the participant's device
  /// events, runs the app's hooks, then the privacy policy.
  Breadcrumb? beforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
    if (breadcrumb == null ||
        Privacy.droppedBreadcrumbCategories.contains(breadcrumb.category)) {
      return null;
    }
    Breadcrumb? current = breadcrumb;
    for (final hook in [
      options.beforeBreadcrumb,
      _configuredBeforeBreadcrumb,
    ]) {
      if (hook == null || current == null) continue;
      final before = current;
      try {
        current = hook(before, hint);
      } catch (error) {
        debugWarn('beforeBreadcrumb failed: $error', once: true);
        current = before;
      }
    }
    final result = current;
    if (result == null) return null;
    // a crumb that cannot be scrubbed is dropped
    return guard<Breadcrumb?>(
      'scrubbing a breadcrumb',
      () => privacy.breadcrumb(result),
    );
  }

  // ---------------------------------------------------------------------
  // Network requests (see GlitchTipHttpClient)
  // ---------------------------------------------------------------------

  /// Whether requests to [url] are recorded at all.
  bool records(Uri url) {
    final ingest = this.ingest;
    if (ingest != null && isIngestUrl(url, ingest)) return false;
    if (httpOptions.excludeUrls.isEmpty) return true;
    final port = url.hasPort ? ':${url.port}' : '';
    final target = '${url.scheme}://${url.host}$port${url.path}';
    return !httpOptions.excludeUrls.any(target.contains);
  }

  /// Whether requests to [url] get `sentry-trace` / `baggage` headers.
  bool propagatesTo(Uri url) =>
      httpOptions.tracePropagationTargets.isNotEmpty &&
      containsTargetOrMatchesRegExp(
        httpOptions.tracePropagationTargets,
        url.toString(),
      );

  /// The transaction name of a request: `<METHOD> <route>`, plus the CAWS
  /// RPC operation, then renamed by `HttpOptions.transactionName`.
  String requestName(http.BaseRequest request) {
    final route = normalizeUrl(request.url, templates: pathTemplates);
    final operation = guard('reading the CAWS operation', () {
      return cawsOperation(request);
    });
    var name = '${request.method} $route';
    if (operation != null) name = '$name $operation';
    final rename = httpOptions.transactionName;
    if (rename != null) {
      final renamed = guard('transactionName', () {
        return rename(request.method, request.url, name);
      });
      if (renamed != null) name = privacy.text(renamed);
    }
    return name;
  }

  /// A per-request sampling decision for request transactions, or `null`
  /// when the request is not sampled.
  SentryTracesSamplingDecision? sampleRequest() =>
      _sample(config.httpSampleRate);

  /// A sampling decision for `CarpGlitchTip.trace`, or `null`.
  SentryTracesSamplingDecision? sampleTrace() =>
      _sample(config.tracesSampleRate);

  // explicit per call: Sentry's own decision is fixed for the whole trace,
  // i.e. all-or-nothing per app launch
  SentryTracesSamplingDecision? _sample(double rate) {
    if (rate <= 0) return null;
    final rand = random.nextDouble();
    return rand < rate
        ? SentryTracesSamplingDecision(true, sampleRate: rate, sampleRand: rand)
        : null;
  }

  /// Starts a transaction now, e.g. to propagate its trace headers.
  ISentrySpan startTransaction({
    required String name,
    required String operation,
    required SentryTracesSamplingDecision decision,
    String? description,
    DateTime? start,
    String origin = transactionOrigin,
  }) => Sentry.startTransactionWithContext(
    SentryTransactionContext(
      name,
      operation,
      description: description,
      transactionNameSource: origin == transactionOrigin
          ? SentryTransactionNameSource.route
          : SentryTransactionNameSource.custom,
      samplingDecision: decision,
      origin: origin,
    ),
    startTimestamp: start,
    bindToScope: false,
  );

  /// Records a transaction that already happened, from [start] to [end],
  /// or finishes [started] if it was started earlier. Never binds it to the
  /// scope, so it cannot pick up unrelated spans or become a culprit.
  void recordTransaction({
    required String name,
    required String operation,
    required SentryTracesSamplingDecision decision,
    required DateTime start,
    required DateTime end,
    required SpanStatus status,
    String? description,
    String origin = transactionOrigin,
    Map<String, Object?> data = const {},
    ISentrySpan? started,
  }) {
    if (!transactionLimiter.tryTake()) {
      if (started != null) discardTransaction(started);
      return;
    }
    final transaction =
        started ??
        startTransaction(
          name: name,
          operation: operation,
          decision: decision,
          description: description,
          start: start,
          origin: origin,
        );
    data.forEach((key, value) {
      if (value != null) transaction.setData(key, value);
    });
    transaction.status = status;
    unawaited(transaction.finish(endTimestamp: end).catchError((Object _) {}));
  }

  /// Finishes [transaction] without sending it.
  void discardTransaction(ISentrySpan transaction) {
    transaction.setData(Privacy.discardKey, true);
    unawaited(transaction.finish().catchError((Object _) {}));
  }

  DateTime? _lastFailureCrumbAt;
  String? _lastFailureCrumb;

  /// Records a request as a breadcrumb. Identical failures within a minute
  /// (e.g. retries while offline) are recorded once.
  void addRequestBreadcrumb({
    required String method,
    required String url,
    required Duration duration,
    int? statusCode,
    String? reason,
    int? requestSize,
    int? responseSize,
  }) {
    if (!httpOptions.breadcrumbs) return;
    final failed = reason != null || (statusCode != null && statusCode >= 400);
    if (failed) {
      final key = '$method $url $statusCode $reason';
      final now = DateTime.now();
      final last = _lastFailureCrumbAt;
      if (key == _lastFailureCrumb &&
          last != null &&
          now.difference(last) < const Duration(minutes: 1)) {
        return;
      }
      _lastFailureCrumb = key;
      _lastFailureCrumbAt = now;
    }
    final level = reason != null || (statusCode ?? 0) >= 500
        ? SentryLevel.error
        : (statusCode ?? 0) >= 400
        ? SentryLevel.warning
        : SentryLevel.info;
    unawaited(
      Sentry.addBreadcrumb(
        Breadcrumb(
          type: 'http',
          category: 'http',
          level: level,
          data: {
            'url': url,
            'method': method,
            'status_code': ?statusCode,
            'reason': ?reason,
            'duration': '${duration.inMilliseconds}ms',
            'request_body_size': ?requestSize,
            'response_body_size': ?responseSize,
          },
        ),
      ).catchError((Object _) {}),
    );
  }

  /// Reports a response whose status is a failure, at most once per window
  /// per request name and status.
  void captureFailedResponse({
    required http.BaseRequest request,
    required http.StreamedResponse response,
    required String name,
    required String url,
  }) {
    final status = response.statusCode;
    final error = SentryHttpClientError('HTTP $status: $name');
    final candidate = IgnoreCandidate(
      error: error,
      url: request.url,
      method: request.method,
      statusCode: status,
    );
    if (ignoringRule(candidate) != null) return;
    final suppressed = failureThrottle.admit('status $name $status');
    if (suppressed == null) return;
    final event = SentryEvent(
      throwable: ThrowableMechanism(
        Mechanism(type: httpClientMechanism, handled: true),
        error,
        snapshot: true,
      ),
      request: SentryRequest(url: url, method: request.method),
      level: SentryLevel.error,
    );
    event.contexts.response = SentryResponse(
      statusCode: status,
      bodySize: response.contentLength,
    );
    _addSuppressed(event, suppressed);
    _capture(
      event,
      Hint.withMap({
        TypeCheckHint.httpRequest: request,
        TypeCheckHint.httpResponse: response,
      }),
      // taken now, in the continuation of the caller: GlitchTip names the
      // issue after its innermost app frame
      stackTrace: StackTrace.current,
    );
  }

  /// Reports a request that failed with an exception that is not ignored,
  /// at most once per window per request name and error.
  void captureFailedRequest({
    required http.BaseRequest request,
    required Object error,
    required StackTrace stackTrace,
    required String name,
    required String url,
  }) {
    final key =
        'error $name ${error.runtimeType} ${networkErrorCode(error) ?? ''}';
    final suppressed = failureThrottle.admit(key);
    if (suppressed == null) return;
    final event = SentryEvent(
      throwable: ThrowableMechanism(
        Mechanism(type: httpClientMechanism, handled: true),
        error,
      ),
      request: SentryRequest(url: url, method: request.method),
      level: SentryLevel.error,
    );
    _addSuppressed(event, suppressed);
    _capture(
      event,
      Hint.withMap({TypeCheckHint.httpRequest: request}),
      stackTrace: stackTrace,
    );
  }

  void _addSuppressed(SentryEvent event, int suppressed) {
    if (suppressed > 0) {
      event.contexts['carp_glitchtip'] = {'suppressed_since_last': suppressed};
    }
  }

  // never awaited in the request path
  void _capture(SentryEvent event, Hint hint, {StackTrace? stackTrace}) {
    unawaited(
      Sentry.captureEvent(
        event,
        stackTrace: stackTrace,
        hint: hint,
      ).then<void>((_) {}).catchError((Object _) {}),
    );
  }
}

class _EarlyProcessor implements EventProcessor {
  _EarlyProcessor(this.runtime);

  final GlitchTipRuntime runtime;

  @override
  SentryEvent? apply(SentryEvent event, Hint hint) {
    if (event is SentryTransaction) {
      // dropped here, before the native enrichment
      final data = event.contexts.trace?.data;
      return data?[Privacy.discardKey] == true ? null : event;
    }
    if (event.type == 'feedback') return event;
    try {
      return runtime.processEvent(event, hint);
    } catch (error) {
      // a bug in the wrapper must not hide the app's errors
      debugWarn('processing an event failed: $error', once: true);
      return event;
    }
  }
}

/// Wraps the SDK's transport in a [_TraceHeaderTransport]. Added as the
/// first integration: the SDK has set up its transport by then, and reads
/// it on every send.
class _TraceHeaderIntegration implements Integration<SentryFlutterOptions> {
  @override
  FutureOr<void> call(Hub hub, SentryFlutterOptions options) {
    options.transport = _TraceHeaderTransport(options.transport);
  }

  @override
  FutureOr<void> close() {}
}

/// Removes the transaction name from the trace header of each envelope,
/// i.e. from Sentry's dynamic sampling context, which GlitchTip does not
/// use. The SDK takes it from the raw name of a transaction (also one an
/// app binds to the scope), before any hook could scrub it.
class _TraceHeaderTransport implements Transport {
  _TraceHeaderTransport(this.inner);

  final Transport inner;

  @override
  Future<SentryId?> send(SentryEnvelope envelope) => inner.send(
    guard<SentryEnvelope?>('scrubbing a trace header', () {
          return _withoutName(envelope);
        }) ??
        envelope,
  );

  static SentryEnvelope _withoutName(SentryEnvelope envelope) {
    final header = envelope.header;
    final trace = header.traceContext;
    final eventId = header.eventId;
    final sdk = header.sdkVersion;
    if (trace == null || eventId == null || sdk == null) return envelope;
    if (trace.transaction == null && trace.userId == null) return envelope;
    // the header type is not public: built through a public factory
    final scrubbed = SentryEnvelope.fromEvent(
      SentryEvent(eventId: eventId),
      sdk,
      dsn: header.dsn,
      traceContext: SentryTraceContextHeader(
        trace.traceId,
        trace.publicKey,
        release: trace.release,
        environment: trace.environment,
        sampleRate: trace.sampleRate,
        sampleRand: trace.sampleRand,
        sampled: trace.sampled,
        orgId: trace.orgId,
      ),
    ).header..sentAt = header.sentAt;
    return SentryEnvelope(
      scrubbed,
      envelope.items,
      containsUnhandledException: envelope.containsUnhandledException,
    );
  }
}

class _ScopeIntegration implements Integration<SentryFlutterOptions> {
  _ScopeIntegration(this.runtime);

  final GlitchTipRuntime runtime;

  @override
  FutureOr<void> call(Hub hub, SentryFlutterOptions options) {
    // not for a start that was closed or replaced meanwhile
    if (identical(GlitchTipRuntime.current, runtime)) runtime.scope.activate();
  }

  @override
  FutureOr<void> close() {}
}
