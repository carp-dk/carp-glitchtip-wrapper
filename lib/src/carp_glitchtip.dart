import 'dart:async';
import 'dart:async' as async show runZoned;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'config/carp_glitchtip_options.dart';
import 'config/glitchtip_env.dart';
import 'config/glitchtip_status.dart';
import 'config/resolve.dart';
import 'filters/network_health.dart';
import 'metadata/glitchtip_tags.dart';
import 'metadata/scope_state.dart';
import 'metadata/study_metadata.dart';
import 'navigation/glitchtip_navigator_observer.dart';
import 'network/glitchtip_http_client.dart';
import 'runtime.dart';
import 'util/diagnostics.dart';
import 'util/platform.dart';

/// GlitchTip error and network performance reporting for CARP apps.
///
/// Wrap the whole body of `main()` in [runZoned] and call [init] in it,
/// after anything the configuration depends on (e.g. the CARP debug
/// toolkit's runtime overrides):
///
/// ```dart
/// Future<void> main() => CarpGlitchTip.runZoned(() async {
///   WidgetsFlutterBinding.ensureInitialized(); // now a no-op, may stay
///   await CarpGlitchTip.init(const CarpGlitchTipOptions());
///   // ... the rest of the app's startup, unchanged
///   runApp(const MyApp());
/// });
/// ```
///
/// All methods are safe to call at any time and the wrapper's own failures
/// never throw. Metadata (study, tags, contexts) set before [init] or after
/// [close] is kept and applied at the next [init]; reporting calls do
/// nothing while reporting is off (by default in debug builds and tests).
/// Errors of the body passed to [runZoned] or [trace] are rethrown.
abstract final class CarpGlitchTip {
  static const _zoneKey = #carpGlitchTipZone;
  static const _httpZoneKey = #carpGlitchTipHttp;

  static ScopeState _scope = ScopeState();
  static GlitchTipStatus _status = GlitchTipStatus.notInitialized;

  // init and close run one after the other, in call order
  static Future<void> _lifecycle = Future.value();
  static Future<void>? _initializing;

  // the start of the Sentry SDK, which may outlive init's timeout
  static Future<void>? _sdkStart;
  static Duration _sdkStartTimeout = Duration.zero;

  /// Runs [body], i.e. the app's whole `main()`, in a zone where every
  /// `http.Client()` (also those created inside packages, such as
  /// carp_webservices) records its requests, see [httpClient].
  ///
  /// The Flutter binding is created here, inside the zone, so taps and
  /// other platform callbacks also run in it. Nothing may create the
  /// binding before (debug builds assert this): move code such as
  /// `WidgetsFlutterBinding.ensureInitialized()` into [body], where it is a
  /// no-op.
  ///
  /// An error escaping [body] means the app did not start; it is reported
  /// (tagged `startup_failure`) even if an ignore rule matches it, then
  /// rethrown. Under `flutter test` on the Dart VM it is rethrown without
  /// waiting for the report, so a widget test that fails in the zone does
  /// not hang in fake time.
  ///
  /// Set [instrumentHttp] to `false` to skip the HTTP instrumentation. To
  /// use another HTTP client implementation (e.g. `cupertino_http`), pass
  /// it as [innerClient] instead of using your own `http.runWithClient`
  /// inside [body], which would hide the instrumentation.
  static Future<void> runZoned(
    FutureOr<void> Function() body, {
    bool instrumentHttp = true,
    http.Client Function()? innerClient,
  }) {
    if (Zone.current[_zoneKey] == true) return Future.sync(body);
    assert(
      _noBindingYet(),
      'The Flutter binding was created before CarpGlitchTip.runZoned, e.g. '
      'by WidgetsFlutterBinding.ensureInitialized() at the start of main(). '
      'Move everything in main() into the body of CarpGlitchTip.runZoned, so '
      'the app runs in the instrumented zone.',
    );

    Future<void> run() async {
      SentryWidgetsFlutterBinding.ensureInitialized();
      try {
        await body();
      } catch (error, stackTrace) {
        final report = _reportStartupFailure(error, stackTrace);
        // widget tests run in fake time, where the report would never
        // finish: a failing test would hang instead of failing
        if (isFlutterTest) {
          unawaited(report);
        } else {
          await report;
        }
        rethrow;
      }
    }

    Future<void> zoned() {
      final values = {_zoneKey: true, _httpZoneKey: instrumentHttp};
      if (!kIsWeb) return async.runZoned(run, zoneValues: values);
      // the web zone handles uncaught errors, so the error of a future
      // created in it would go to that handler instead of the caller, whose
      // future would never complete
      final done = Completer<void>();
      async.runZoned(
        () => run().then((_) => done.complete(), onError: done.completeError),
        zoneValues: values,
        zoneSpecification: _webZoneSpecification(),
      );
      return done.future;
    }

    if (!instrumentHttp) return zoned();
    return http.runWithClient(zoned, () => _zoneClient(innerClient));
  }

  /// Starts reporting to GlitchTip, configured by [options] and the env
  /// (see [CarpGlitchTipOptions] and [GlitchTipKeys]).
  ///
  /// Call it from the app's `main()` only, never from a background entry
  /// point (WorkManager, push or notification handlers): the native SDKs
  /// are shared by the whole process.
  ///
  /// Never throws, and never blocks app start for longer than
  /// [CarpGlitchTipOptions.initTimeout] (after a [close] that is still
  /// stopping a slow start, it first waits for that). When reporting is
  /// disabled (e.g. no DSN, or a debug build without
  /// `GLITCHTIP_ENABLED=true`), the Sentry SDK is not started at all. The
  /// outcome is printed as one line and is available as [status].
  ///
  /// Calling it again does nothing; call [close] first to re-initialise,
  /// e.g. after the CARP debug toolkit switched the deployment mode.
  static Future<void> init([
    CarpGlitchTipOptions options = const CarpGlitchTipOptions(),
  ]) => _initializing ??= _serial(() => _init(options));

  // runs [step] after the previous init or close; never fails, so the chain
  // cannot get stuck
  static Future<void> _serial(Future<void> Function() step) {
    final next = _lifecycle.then((_) => step()).catchError((Object error) {
      debugWarn('CarpGlitchTip failed: $error');
    });
    _lifecycle = next;
    return next;
  }

  static Future<void> _init(CarpGlitchTipOptions options) async {
    if (!isRootIsolate) {
      _setStatus(
        const GlitchTipStatus(
          enabled: false,
          disabledReason: DisabledReason.notRootIsolate,
        ),
      );
      return;
    }
    final config = resolveConfig(
      options,
      lookup: GlitchTipEnv.chain([options.env, GlitchTipEnv.compileTime]),
      buildMode: buildMode,
      isFlutterTest: isFlutterTest,
    );
    final instrumented = Zone.current[_httpZoneKey] == true;
    if (!config.enabled) {
      _setStatus(config.toStatus(httpInstrumented: instrumented));
      return;
    }
    if (Zone.current[_zoneKey] != true) {
      debugWarn(
        'init() was called outside CarpGlitchTip.runZoned: HTTP '
        'clients created by packages are not instrumented',
      );
    }

    _scope
      ..deactivate() // a new SDK: push everything again
      ..user = SentryUser(id: SentryId.newId().toString())
      ..baseTags = {
        GlitchTipTags.buildMode: config.buildMode,
        GlitchTipTags.deploymentMode: ?config.deploymentMode,
      };
    final runtime = GlitchTipRuntime(
      options: options,
      config: config,
      scope: _scope,
    );
    GlitchTipRuntime.current = runtime;

    try {
      SentryWidgetsFlutterBinding.ensureInitialized();
      final starting = SentryFlutter.init(runtime.configure);
      _sdkStart = starting;
      _sdkStartTimeout = options.initTimeout;
      final started = await starting
          .then((_) => true)
          .timeout(options.initTimeout, onTimeout: () => false);
      if (started) {
        _started(runtime, config, instrumented: instrumented);
      } else {
        _setStatus(
          config.toStatus(
            httpInstrumented: instrumented,
            disabled: DisabledReason.starting,
            detail: 'after ${options.initTimeout.inMilliseconds} ms',
          ),
        );
        unawaited(
          starting.then(
            (_) => _started(runtime, config, instrumented: instrumented),
            onError: (Object error) =>
                _failed(runtime, error, instrumented: instrumented),
          ),
        );
      }
    } catch (error) {
      await _failed(runtime, error, instrumented: instrumented);
    }
  }

  static void _started(
    GlitchTipRuntime runtime,
    ResolvedConfig config, {
    required bool instrumented,
  }) {
    if (!identical(GlitchTipRuntime.current, runtime)) return; // closed
    runtime.active = true;
    _scope.activate();
    _setStatus(config.toStatus(httpInstrumented: instrumented));
  }

  static Future<void> _failed(
    GlitchTipRuntime runtime,
    Object error, {
    required bool instrumented,
  }) async {
    debugWarn('starting the Sentry SDK failed: $error');
    // a start that was closed or replaced meanwhile must not touch the
    // reporter that replaced it
    if (!identical(GlitchTipRuntime.current, runtime)) return;
    GlitchTipRuntime.current = null;
    _scope.deactivate();
    _setStatus(
      runtime.config.toStatus(
        httpInstrumented: instrumented,
        disabled: DisabledReason.initFailed,
        // the message could contain the DSN
        detail: error.runtimeType.toString(),
      ),
    );
    try {
      await Sentry.close();
    } catch (_) {}
  }

  static void _setStatus(GlitchTipStatus status) {
    _status = status;
    printLine(status.toString());
  }

  /// Stops reporting; [status] then says `closed` if reporting was on.
  /// [init] can be called again afterwards, e.g. with a new configuration.
  static Future<void> close() {
    _initializing = null;
    return _serial(_close);
  }

  static Future<void> _close() async {
    // detached first, so a start that finishes while close waits for it
    // does not turn reporting on again
    final runtime = GlitchTipRuntime.current;
    GlitchTipRuntime.current = null;
    runtime?.active = false;
    _scope.deactivate();
    // never close the SDK while it is still starting
    final start = _sdkStart;
    _sdkStart = null;
    if (start != null) {
      await start
          .then<void>((_) {}, onError: (Object _) {})
          .timeout(
            _sdkStartTimeout + const Duration(seconds: 5),
            onTimeout: () {},
          );
    }
    if (runtime == null && start == null) return;
    try {
      await Sentry.close();
    } catch (_) {}
    _status = const GlitchTipStatus(
      enabled: false,
      disabledReason: DisabledReason.closed,
    );
  }

  /// Whether the Sentry SDK has started and everything is reported: errors,
  /// requests, traces and navigation. While the SDK is still starting
  /// (see [DisabledReason.starting]), errors are already reported.
  static bool get isEnabled => GlitchTipRuntime.current?.active ?? false;

  // also while the SDK is still starting: it already reports unhandled
  // errors through the wrapper's hooks, so the app's own reports are sent
  // too
  static bool get _reporting =>
      isEnabled || (GlitchTipRuntime.current != null && Sentry.isEnabled);

  /// The state of reporting, e.g. for an about or debug screen.
  static GlitchTipStatus get status => _status;

  /// Attaches [study] to every report, see [StudyMetadata].
  static void setStudy(StudyMetadata study) => _scope.setStudy(study);

  /// Stops attaching the study, e.g. when the participant leaves it. The
  /// breadcrumbs recorded during the study are cleared too.
  static void clearStudy() => _scope.setStudy(null);

  /// The study attached to every report.
  static StudyMetadata? get study => _scope.study;

  /// Keeps the attached study in sync with the app: [read] is called now,
  /// every time [source] notifies its listeners, and when an error is
  /// reported. It returns the current study, or `null` when there is none.
  ///
  /// ```dart
  /// CarpGlitchTip.bindStudy(bloc, () => bloc.study?.toGlitchTip());
  /// ```
  ///
  /// [read] may throw, e.g. before the app's settings are loaded; the study
  /// then stays as it was. Returns a function that stops the binding.
  static VoidCallback bindStudy(
    Listenable source,
    StudyMetadata? Function() read,
  ) {
    _scope.studyReader = read;
    _scope.refresh();
    void listener() => _scope.refresh();
    source.addListener(listener);
    return () {
      source.removeListener(listener);
      if (identical(_scope.studyReader, read)) _scope.studyReader = null;
    };
  }

  /// Adds searchable tags to every report; a `null` value removes a tag.
  /// The keys in [GlitchTipTags] are set by the wrapper and cannot be used.
  static void setTags(Map<String, String?> tags) => _scope.setTags(tags);

  /// Adds a context (shown on every report, not searchable) under [key];
  /// a `null` [value] removes it. Keys the Sentry SDK or the wrapper own,
  /// such as `app`, `device`, `os` or `study`, cannot be used.
  static void setContext(String key, Map<String, Object?>? value) =>
      _scope.setContext(key, value);

  /// Reports an [error] the app caught, tagged `handled:yes`. Without a
  /// [stackTrace], the error's own (for an [Error] that was thrown) or the
  /// caller's stack trace is used.
  static Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
  }) async {
    if (!_reporting) return;
    // taken before any await, so it shows where the app reported the error
    final trace = stackTrace ?? (error is Error ? error.stackTrace : null);
    try {
      await Sentry.captureEvent(
        SentryEvent(
          throwable: ThrowableMechanism(
            Mechanism(type: 'CarpGlitchTip.captureException', handled: true),
            error,
            snapshot: trace == null,
          ),
        ),
        stackTrace: trace ?? StackTrace.current,
      );
    } catch (_) {}
  }

  /// Reports a [message].
  static Future<void> captureMessage(
    String message, {
    SentryLevel level = SentryLevel.info,
  }) async {
    if (!_reporting) return;
    try {
      await Sentry.captureMessage(message, level: level);
    } catch (_) {}
  }

  /// Adds a [breadcrumb] to the trail of events shown with later reports.
  static void addBreadcrumb(Breadcrumb breadcrumb) {
    if (!_reporting) return;
    unawaited(Sentry.addBreadcrumb(breadcrumb).catchError((Object _) {}));
  }

  /// Runs [body] and records how long it takes as a GlitchTip transaction
  /// named [name], e.g. `CarpGlitchTip.trace('bloc.initialize', bloc.initialize)`.
  ///
  /// Sampled with `tracesSampleRate`, and counted towards
  /// `HttpOptions.maxTransactionsPerMinute`. GlitchTip shows the count and
  /// the duration percentiles of each name, so keep names free of ids.
  static Future<T> trace<T>(
    String name,
    FutureOr<T> Function() body, {
    String operation = 'task',
  }) async {
    final runtime = GlitchTipRuntime.current;
    if (runtime == null || !runtime.active) return await body();
    final decision = guard('sampling a trace', runtime.sampleTrace);
    if (decision == null) return await body();

    final start = DateTime.now().toUtc();
    var status = const SpanStatus.ok();
    try {
      return await body();
    } catch (_) {
      status = const SpanStatus.internalError();
      rethrow;
    } finally {
      final end = DateTime.now().toUtc();
      guard('recording a trace', () {
        runtime.recordTransaction(
          name: runtime.privacy.transactionName(name),
          operation: operation,
          decision: decision,
          start: start,
          end: end,
          status: status,
          origin: traceOrigin,
        );
      });
    }
  }

  /// An HTTP client that records its requests: breadcrumbs, transactions
  /// and failure events. Wraps [inner], or a new default client.
  ///
  /// Inside [runZoned] every `http.Client()` is already such a client; use
  /// this for clients created elsewhere, e.g. in another zone. Never wraps
  /// a client twice.
  static http.Client httpClient([http.Client? inner]) =>
      _wrap(inner ?? http.Client());

  /// A navigator observer that records navigation as breadcrumbs and keeps
  /// the `screen` tag up to date. Add one to every navigator, e.g. to
  /// `GoRouter(observers: [...])` and to each `ShellRoute(observers: [...])`;
  /// a route event seen by several observers is recorded once.
  static NavigatorObserver navigatorObserver() => GlitchTipNavigatorObserver();

  /// Stops reporting and forgets all state. For tests.
  @visibleForTesting
  static Future<void> resetForTest() async {
    await close();
    _scope = ScopeState();
    _status = GlitchTipStatus.notInitialized;
    NetworkHealth.reset();
    GlitchTipRuntime.forgetRequests();
    resetDiagnostics();
  }

  static bool _noBindingYet() {
    final type = BindingBase.debugBindingType();
    return type != WidgetsFlutterBinding && type != SentryWidgetsFlutterBinding;
  }

  static http.Client _wrap(http.Client client) =>
      client is GlitchTipHttpClient ? client : GlitchTipHttpClient(client);

  static http.Client _zoneClient(http.Client Function()? innerClient) {
    // runs in the zone runZoned was called from, so http.Client() returns
    // the default (or an outer zone's) client instead of recursing
    final inner =
        (innerClient == null ? null : guard('innerClient', innerClient)) ??
        http.Client();
    return _wrap(inner);
  }

  static Future<void> _reportStartupFailure(
    Object error,
    StackTrace stackTrace,
  ) async {
    if (!_reporting) return;
    try {
      await Sentry.captureEvent(
        SentryEvent(
          throwable: ThrowableMechanism(
            Mechanism(type: 'CarpGlitchTip.runZoned', handled: false),
            error,
          ),
          level: SentryLevel.error,
        ),
        stackTrace: stackTrace,
        hint: Hint.withMap({startupFailureHint: true}),
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  // on the web, Sentry only reports uncaught errors itself when it runs the
  // app (appRunner) from the root zone
  static ZoneSpecification _webZoneSpecification() => ZoneSpecification(
    handleUncaughtError: (self, parent, zone, error, stackTrace) {
      FlutterError.dumpErrorToConsole(
        FlutterErrorDetails(exception: error, stack: stackTrace),
        forceReport: true,
      );
      if (!_reporting) return;
      unawaited(
        Sentry.captureEvent(
          SentryEvent(
            throwable: ThrowableMechanism(
              Mechanism(type: 'runZonedGuarded', handled: false),
              error,
            ),
            level: SentryLevel.error,
          ),
          stackTrace: stackTrace,
        ).then<void>((_) {}).catchError((Object _) {}),
      );
    },
  );
}
