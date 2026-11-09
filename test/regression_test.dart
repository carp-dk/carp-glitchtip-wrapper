// Regression tests for the defects found in the first review round, each
// asserting the fixed behaviour (FIXES_v3): reserved context keys, the order
// of init and close and a slow or failing SDK start, in-app frames and the
// stack trace of captureException, the network error throttle, aborted
// requests, empty ignore patterns, ignore rules on reported request errors,
// the network health of uploads, app hooks that never complete, warnings on
// a disabled status line, study switches, the trace origin and DSNs the
// Sentry SDK cannot use. Every test starts the real Sentry SDK with a
// GlitchTipTestTransport, so nothing is sent.

import 'dart:async';
import 'dart:io';

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/src/config/resolve.dart';
import 'package:carp_glitchtip_wrapper/src/filters/network_health.dart';
import 'package:carp_glitchtip_wrapper/src/runtime.dart';
import 'package:carp_glitchtip_wrapper/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const _dsn = 'https://public-key@glitchtip.example.com/1';

const _studyA = StudyMetadata(studyId: 'sA', studyDeploymentId: 'dA');
const _studyB = StudyMetadata(studyId: 'sB', studyDeploymentId: 'dB');

/// Context keys the Sentry SDK reads as typed objects, and the wrapper's own
/// study context. An app map under one of them used to break every report.
const _reservedContexts = [
  'app',
  'device',
  'os',
  'culture',
  'trace',
  'response',
  'gpu',
  'browser',
  'runtime',
  'runtimes',
  'feedback',
  'flags',
  'study',
];

/// An exception of the app's own code: it has no stack trace of its own.
class _BackendBug implements Exception {
  @override
  String toString() => 'backend bug';
}

/// What a request throws while the server is down. A new error every time
/// (the Sentry SDK drops an error object it has already reported).
SocketException _refused() => SocketException(
  'Connection refused',
  osError: OSError(
    'Connection refused',
    Platform.isMacOS || Platform.isIOS ? 61 : 111,
  ),
);

/// Delays the start of the Sentry SDK by [delay], like a slow native SDK,
/// and then fails it with [error], if given.
class _SlowStart implements Integration<SentryFlutterOptions> {
  _SlowStart(this.delay, {this.error});

  final Duration delay;
  final Object? error;

  @override
  Future<void> call(Hub hub, SentryFlutterOptions options) async {
    await Future<void>.delayed(delay);
    if (error case final error?) throw error;
  }

  @override
  void close() {}
}

/// Reports [error] the way the Sentry SDK reports an error the app did not
/// catch.
Future<SentryId> _captureUnhandled(Object error) => Sentry.captureEvent(
  SentryEvent(
    throwable: ThrowableMechanism(
      Mechanism(type: 'PlatformDispatcher.onError', handled: false),
      error,
    ),
  ),
);

// Named functions, so their frames can be recognised in reported stack
// traces.

Future<void> _reportFromHelper(Object error) =>
    CarpGlitchTip.captureException(error);

void _reportAndForget(Object error) {
  unawaited(CarpGlitchTip.captureException(error));
}

StateError _thrownError() {
  try {
    throw StateError('thrown by _thrownError');
  } on StateError catch (error) {
    return error;
  }
}

_BackendBug _thrownException() {
  try {
    throw _BackendBug();
  } on _BackendBug catch (exception) {
    return exception;
  }
}

/// The frames of the exception of [event], outermost first.
List<SentryStackFrame> _frames(SentryEvent event) =>
    event.exceptions!.single.stackTrace!.frames;

/// The frame GlitchTip names the issue of [event] after: the innermost
/// in-app frame.
SentryStackFrame _culprit(SentryEvent event) =>
    _frames(event).lastWhere((frame) => frame.inApp == true);

/// The file name and line of every frame of [stackTrace], innermost first,
/// e.g. `('main.dart', 42)` for the frame `#0 f (file:///app/main.dart:42:5)`.
List<(String, int)> _linesOf(StackTrace stackTrace) => [
  for (final match in RegExp(
    r'([^/\s(:]+):(\d+)(?::\d+)?\)$',
    multiLine: true,
  ).allMatches('$stackTrace'))
    (match[1]!, int.parse(match[2]!)),
];

/// The file name and line of every frame in [frames], innermost first.
List<(String, int)> _linesOfFrames(List<SentryStackFrame> frames) => [
  for (final frame in frames.reversed)
    if ((frame.fileName, frame.lineNo) case (final file?, final line?))
      (file, line),
];

/// The breadcrumb messages of [event].
List<String?> _crumbs(SentryEvent event) => [
  for (final crumb in event.breadcrumbs ?? const <Breadcrumb>[]) crumb.message,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GlitchTipTestTransport transport;

  setUp(() async {
    await CarpGlitchTip.resetForTest();
    transport = GlitchTipTestTransport();
  });
  tearDown(CarpGlitchTip.resetForTest);

  // Options that turn reporting on under flutter test and send to [into],
  // by default to [transport].
  CarpGlitchTipOptions options({
    GlitchTipTestTransport? into,
    String dsn = _dsn,
    EnvLookup? env,
    String? environment,
    double? tracesSampleRate,
    HttpOptions httpOptions = const HttpOptions(),
    List<IgnoreRule> ignoreErrors = const [],
    FutureOr<SentryEvent?> Function(SentryEvent event, Hint hint)? beforeSend,
    Duration initTimeout = const Duration(seconds: 5),
    void Function(SentryFlutterOptions options)? configure,
  }) => CarpGlitchTipOptions(
    enabled: true,
    dsn: dsn,
    env: env,
    environment: environment,
    tracesSampleRate: tracesSampleRate,
    http: httpOptions,
    ignoreErrors: ignoreErrors,
    beforeSend: beforeSend,
    initTimeout: initTimeout,
    configure: (o) {
      o
        ..transport = into ?? transport
        ..autoInitializeNativeSdk = false;
      configure?.call(o);
    },
  );

  Future<void> start([CarpGlitchTipOptions? custom]) =>
      CarpGlitchTip.init(custom ?? options());

  // Options whose SDK start takes [delay], longer than their initTimeout of
  // 50 ms, and then fails with [error], if given. The delay comes before
  // the wrapper's own integration, as for a slow native SDK.
  CarpGlitchTipOptions slowStart(Duration delay, {Object? error}) => options(
    initTimeout: const Duration(milliseconds: 50),
    configure: (o) =>
        o.addIntegrationByIndex(0, _SlowStart(delay, error: error)),
  );

  // The lines printed with debugPrint from now until the end of the test.
  List<String> capturePrints() {
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    addTearDown(() => debugPrint = original);
    return printed;
  }

  // The status lines (GlitchTipStatus.toString) among [printed].
  List<String> statusLines(List<String> printed) => [
    for (final line in printed)
      if (line.startsWith(
        RegExp(r'\[CarpGlitchTip\] (enabled|DISABLED|starting \()'),
      ))
        line,
  ];

  String currentStatusLine() => '[CarpGlitchTip] ${CarpGlitchTip.status}';

  // Waits for work the wrapper does not await, e.g. finishing transactions.
  Future<void> eventually(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final waited = Stopwatch()..start();
    while (!condition() && waited.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  // Gives pending work time to finish before checking nothing happened.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  List<SentryTransaction> traced(String name) => [
    for (final transaction in transport.transactions)
      if (transaction.transaction == name) transaction,
  ];

  // The scope of the running Sentry SDK.
  Future<Scope> sentryScope() async {
    late Scope scope;
    await Sentry.configureScope((s) => scope = s);
    return scope;
  }

  group('setContext', () {
    test('ignores reserved keys, so events and transactions still '
        'arrive', () async {
      final printed = capturePrints();
      await start(options(tracesSampleRate: 1));
      final scope = await sentryScope();
      for (final (index, key) in _reservedContexts.indexed) {
        CarpGlitchTip.setContext(key, {'flavor': 'dev'});
        // synced after it: a reserved context would be on the scope by now
        CarpGlitchTip.setContext('protocol', {'after': key});
        await eventually(() {
          final synced = scope.contexts['protocol'];
          return synced is Map && synced['after'] == key;
        });

        await CarpGlitchTip.captureException(StateError('with $key'));
        expect(transport.events, hasLength(index + 1), reason: key);
        await CarpGlitchTip.trace('with $key', () => key);
        await eventually(() => traced('with $key').isNotEmpty);
        expect(traced('with $key'), hasLength(1), reason: key);
        expect(
          printed,
          anyElement(allOf(contains('"$key"'), contains('reserved'))),
          reason: 'warns about $key',
        );
      }

      final event = transport.events.last;
      expect(event.contexts['protocol'], {'after': 'study'});
      for (final key in _reservedContexts) {
        expect(event.contexts[key], isNot({'flavor': 'dev'}), reason: key);
        expect(scope.contexts[key], isNot({'flavor': 'dev'}), reason: key);
      }
    });
  });

  group('init and close', () {
    test('close() and init() called together run in call order', () async {
      await start(options(environment: 'first'));
      final second = GlitchTipTestTransport();
      final closing = CarpGlitchTip.close();
      final starting = CarpGlitchTip.init(
        options(into: second, environment: 'second'),
      );
      await closing;
      await starting;
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(CarpGlitchTip.status.enabled, isTrue);
      expect(CarpGlitchTip.status.environment, 'second');
      expect(Sentry.isEnabled, isTrue);
      await CarpGlitchTip.captureException(StateError('after init'));
      expect(second.events.single.environment, 'second');

      await CarpGlitchTip.close();
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.closed);
      expect(Sentry.isEnabled, isFalse);
    });

    test('init() after a close() that is not awaited ends enabled', () async {
      await start(options(environment: 'first'));
      final second = GlitchTipTestTransport();
      unawaited(CarpGlitchTip.close());
      await CarpGlitchTip.init(options(into: second, environment: 'second'));
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(CarpGlitchTip.status.environment, 'second');
      expect(Sentry.isEnabled, isTrue);
      await CarpGlitchTip.captureException(StateError('after init'));
      expect(second.events, hasLength(1));
    });

    test('closing twice closes once and init() still starts', () async {
      await start();
      await Future.wait([CarpGlitchTip.close(), CarpGlitchTip.close()]);
      await CarpGlitchTip.close();
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.closed);
      expect(Sentry.isEnabled, isFalse);

      await start();
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(Sentry.isEnabled, isTrue);
      await CarpGlitchTip.captureException(StateError('after init'));
      expect(transport.events, hasLength(1));
    });

    test('close() during a slow start, then init(), gives the new SDK the '
        'user and the tags', () async {
      final printed = capturePrints();
      const delay = Duration(milliseconds: 400);
      final elapsed = Stopwatch()..start();
      await start(slowStart(delay));
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.starting);
      expect(statusLines(printed), [currentStatusLine()]);
      expect(
        statusLines(printed).single,
        startsWith('[CarpGlitchTip] starting (after 50 ms): env='),
      );

      await CarpGlitchTip.close();
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.closed);
      expect(Sentry.isEnabled, isFalse);
      // the old start is over by now, also if close() did not wait for it
      await Future<void>.delayed(delay + delay ~/ 4 - elapsed.elapsed);

      final second = GlitchTipTestTransport();
      await CarpGlitchTip.init(
        options(
          into: second,
          env: GlitchTipEnv.fromMap({GlitchTipKeys.deploymentMode: 'test'}),
        ),
      );
      expect(CarpGlitchTip.isEnabled, isTrue);
      final scope = await sentryScope();
      await eventually(
        () => scope.user != null && scope.tags.containsKey('deployment_mode'),
      );
      expect(scope.user?.id, isNotEmpty);
      expect(scope.tags, containsPair('build_mode', 'debug'));
      expect(scope.tags, containsPair('deployment_mode', 'test'));

      await CarpGlitchTip.captureException(StateError('after init'));
      final event = second.events.single;
      expect(event.user?.id, scope.user?.id);
      expect(event.tags, containsPair('build_mode', 'debug'));
      expect(event.tags, containsPair('deployment_mode', 'test'));
    });

    test('a slow start that finishes after close() is not turned on', () async {
      final printed = capturePrints();
      await start(slowStart(const Duration(milliseconds: 300)));
      final beforeClose = printed.length;
      // the old start finishes while close() waits for it
      await CarpGlitchTip.close();
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.closed);
      expect(
        statusLines(printed.sublist(beforeClose)),
        isNot(anyElement(startsWith('[CarpGlitchTip] enabled'))),
        reason: 'the log must not say reporting is on after close()',
      );
    });

    test('a start that fails late does not stop the SDK started after '
        'it', () async {
      const delay = Duration(milliseconds: 300);
      final elapsed = Stopwatch()..start();
      await start(slowStart(delay, error: StateError('the native SDK failed')));
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.starting);

      final second = GlitchTipTestTransport();
      final closing = CarpGlitchTip.close();
      final starting = CarpGlitchTip.init(options(into: second));
      await closing;
      await starting;
      expect(CarpGlitchTip.isEnabled, isTrue);
      // until well after the old start failed, also if close() did not wait
      // for it
      await Future<void>.delayed(delay * 2 - elapsed.elapsed);
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(CarpGlitchTip.status.enabled, isTrue);
      expect(Sentry.isEnabled, isTrue);
      await CarpGlitchTip.captureException(StateError('after init'));
      expect(second.events, hasLength(1));
    });
  });

  group('stack traces', () {
    test('the culprit of captureException is its caller, not the '
        'wrapper', () async {
      await start();
      await _reportFromHelper(StateError('reported by a helper'));
      final event = transport.events.single;
      final culprit = _culprit(event);
      expect(culprit.function, '_reportFromHelper');
      expect(culprit.fileName, 'regression_test.dart');
      final wrapper = [
        for (final frame in _frames(event))
          if (frame.package == 'carp_glitchtip_wrapper') frame,
      ];
      expect(wrapper, isNotEmpty);
      expect(wrapper.map((frame) => frame.inApp), everyElement(isFalse));
    });

    test('a 5xx event has no in-app frame of the wrapper or '
        'package:http', () async {
      await start();
      final client = CarpGlitchTip.httpClient(
        MockClient((_) async => http.Response('', 503)),
      );
      await client.get(Uri.parse('https://api.example.com/studies'));
      client.close();
      await eventually(() => transport.events.isNotEmpty);
      final event = transport.events.single;
      final libraries = [
        for (final frame in _frames(event))
          if (frame.package == 'carp_glitchtip_wrapper' ||
              frame.package == 'http')
            frame,
      ];
      expect(libraries.map((frame) => frame.package).toSet(), {
        'carp_glitchtip_wrapper',
        'http',
      });
      expect(libraries.map((frame) => frame.inApp), everyElement(isFalse));
      expect(_culprit(event).fileName, 'regression_test.dart');
    });

    test('a captureException that is not awaited keeps the caller '
        'frame', () async {
      await start();
      _reportAndForget(StateError('not awaited'));
      await eventually(() => transport.events.isNotEmpty);
      final culprit = _culprit(transport.events.single);
      expect(culprit.function, '_reportAndForget');
      expect(culprit.fileName, 'regression_test.dart');
    });

    test('captureException uses the stack trace of a thrown Error', () async {
      await start();
      final error = _thrownError();
      await _reportFromHelper(error);
      final exception = transport.events.single.exceptions!.single;
      final frames = exception.stackTrace!.frames;
      expect(_linesOfFrames(frames), _linesOf(error.stackTrace!));
      expect(frames.last.function, '_thrownError');
      expect(
        frames.map((frame) => frame.function),
        isNot(contains('_reportFromHelper')),
      );
      expect(exception.stackTrace!.snapshot, isNot(isTrue));
      expect(exception.mechanism?.type, 'CarpGlitchTip.captureException');
      expect(exception.mechanism?.handled, isTrue);
    });

    test('captureException uses the stack trace of its caller for an '
        'Exception', () async {
      await start();
      await _reportFromHelper(_thrownException());
      final event = transport.events.single;
      final exception = event.exceptions!.single;
      final functions = exception.stackTrace!.frames.map((f) => f.function);
      expect(functions, contains('_reportFromHelper'));
      expect(functions, isNot(contains('_thrownException')));
      expect(exception.stackTrace!.snapshot, isTrue);
      expect(exception.mechanism?.type, 'CarpGlitchTip.captureException');
      expect(event.tags, containsPair('handled', 'yes'));
      expect(
        event.tags,
        containsPair('mechanism', 'CarpGlitchTip.captureException'),
      );
    });
  });

  group('network error throttle', () {
    test('errors the app reports itself are all reported', () async {
      await start();
      final errors = [
        TimeoutException('the scan timed out'),
        TimeoutException('the database is locked'),
        const HttpException('Invalid response status line'),
        const HttpException('Content size exceeds specified contentLength'),
      ];
      for (final error in errors) {
        await CarpGlitchTip.captureException(error);
      }
      expect([for (final event in transport.events) event.throwable], errors);
    });

    test('unhandled errors without a URL are all reported', () async {
      await start();
      final errors = [
        TimeoutException('first'),
        TimeoutException('second'),
        _refused(),
        _refused(),
      ];
      for (final error in errors) {
        await _captureUnhandled(error);
      }
      expect([for (final event in transport.events) event.throwable], errors);
    });

    test('an unhandled error of a request is reported once per '
        'window', () async {
      const window = Duration(milliseconds: 500);
      await start(
        options(httpOptions: const HttpOptions(failureEventWindow: window)),
      );
      final url = Uri.parse('https://api.example.com/studies/42');
      http.ClientException refused() =>
          http.ClientException('Connection refused', url);

      await _captureUnhandled(refused());
      await _captureUnhandled(refused());
      expect(transport.events, hasLength(1));
      expect(transport.events.single.contexts['carp_glitchtip'], isNull);

      await Future<void>.delayed(window);
      await _captureUnhandled(refused());
      expect(transport.events, hasLength(2));
      expect(transport.events.last.contexts['carp_glitchtip'], {
        'suppressed_since_last': 1,
      });
    });
  });

  group('HTTP client', () {
    test('an aborted request is a cancelled transaction, not an '
        'error', () async {
      await start(options(httpOptions: const HttpOptions(sampleRate: 1)));
      final url = Uri.parse('https://api.example.com/upload');
      final aborted = http.RequestAbortedException(url);
      final client = CarpGlitchTip.httpClient(
        MockClient((_) async => throw aborted),
      );
      await expectLater(client.get(url), throwsA(same(aborted)));
      client.close();
      await eventually(() => transport.transactions.isNotEmpty);
      await settle();
      expect(transport.events, isEmpty);
      final transaction = transport.transactions.single;
      expect(transaction.transaction, 'GET api.example.com/upload');
      expect(transaction.contexts.trace!.status, const SpanStatus.cancelled());
    });

    test('a long upload does not look offline, a hanging request '
        'does', () async {
      await start();
      var now = DateTime.utc(2026, 11, 9, 12);
      NetworkHealth.reset(NetworkHealth(clock: () => now));
      final responses = <Completer<http.Response>>[];
      final client = CarpGlitchTip.httpClient(
        MockClient((_) {
          final response = Completer<http.Response>();
          responses.add(response);
          return response.future;
        }),
      );
      final url = Uri.parse('https://api.example.com/data');

      // 1 MB takes about a minute at the assumed 16 KB/s
      final upload = client.post(url, body: Uint8List(1024 * 1024));
      await eventually(() => responses.length == 1);
      now = now.add(const Duration(seconds: 10));
      expect(NetworkHealth.instance.looksOffline, isFalse);

      final download = client.get(url);
      await eventually(() => responses.length == 2);
      now = now.add(const Duration(seconds: 6));
      expect(NetworkHealth.instance.looksOffline, isTrue);

      for (final response in responses) {
        response.complete(http.Response('', 200));
      }
      await upload;
      await download;
      client.close();
    });
  });

  group('ignore rules', () {
    test('an empty message pattern ignores nothing', () async {
      final rules = [
        const IgnoreRule.message(''),
        IgnoreRule.message(RegExp('')),
        const IgnoreType<Object>(message: ''),
        IgnoreType<Object>(message: RegExp('')),
      ];
      final candidate = IgnoreCandidate(
        error: StateError('a real bug'),
        message: 'a message',
      );
      for (final rule in rules) {
        expect(rule.matches(candidate), isFalse, reason: '$rule');
      }

      await start(options(ignoreErrors: rules));
      await CarpGlitchTip.captureException(StateError('a real bug'));
      await CarpGlitchTip.captureMessage('a message');
      expect(transport.events, hasLength(2));
    });

    test('a rule on the request drops the failure event and a later '
        'report of the same error', () async {
      final failure = _BackendBug();
      final seen = <String>[];
      await start(
        options(
          ignoreErrors: [
            IgnoreRule.custom((c) {
              if (identical(c.error, failure)) seen.add('${c.method} ${c.url}');
              return c.isHttp && c.method == 'GET';
            }),
          ],
        ),
      );
      final url = Uri.parse('https://api.example.com/studies');
      final client = CarpGlitchTip.httpClient(
        MockClient((_) async => throw failure),
      );
      await expectLater(client.get(url), throwsA(same(failure)));
      client.close();
      // the app reports the error it got from the request
      await CarpGlitchTip.captureException(failure);
      await CarpGlitchTip.captureException(StateError('a real bug'));
      await settle();
      expect(seen, ['GET $url', 'GET $url']);
      expect(transport.events.single.throwable, isA<StateError>());
    });
  });

  group('app hooks', () {
    test('hooks that never complete delay a report by 2 s, not '
        'forever', () async {
      await start(
        options(
          tracesSampleRate: 1,
          beforeSend: (event, hint) => Completer<SentryEvent?>().future,
          configure: (o) =>
              o.beforeSendTransaction = (transaction, hint) =>
                  Completer<SentryTransaction?>().future,
        ),
      );
      final scope = await sentryScope();
      await eventually(() => scope.user != null);

      final waited = Stopwatch()..start();
      await CarpGlitchTip.trace('job', () => 1);
      await CarpGlitchTip.captureException(
        StateError('mail participant@example.com'),
      );
      expect(waited.elapsed, greaterThan(const Duration(milliseconds: 1500)));
      expect(
        transport.events.single.exceptions!.single.value,
        'Bad state: mail {email}',
      );

      await eventually(() => traced('job').isNotEmpty);
      final transaction = traced('job').single;
      expect(transaction.user, isNull, reason: 'scrubbed');
      expect(transaction.tags, isNull, reason: 'scrubbed');
    });
  });

  group('status', () {
    test('a disabled status lists the warnings', () {
      final cases = {
        'release': (const CarpGlitchTipOptions(), DisabledReason.missingDsn),
        'debug': (
          const CarpGlitchTipOptions(dsn: _dsn),
          DisabledReason.debugBuild,
        ),
      };
      for (final MapEntry(key: mode, value: (code, reason)) in cases.entries) {
        final config = resolveConfig(
          code,
          lookup: GlitchTipEnv.fromMap({GlitchTipKeys.enabled: 'ture'}),
          buildMode: mode,
        );
        final status = config.toStatus(httpInstrumented: true);
        expect(status.disabledReason, reason, reason: mode);
        expect(status.warnings, [
          contains('GLITCHTIP_ENABLED=ture'),
        ], reason: mode);
        final line = status.toString();
        expect(line, startsWith('DISABLED: ${reason.description}'));
        expect(line, contains('GLITCHTIP_ENABLED=ture'), reason: mode);
      }
    });

    test('init prints the warnings of a disabled status', () async {
      final printed = capturePrints();
      await CarpGlitchTip.init(
        const CarpGlitchTipOptions(enabled: true, sampleRate: 2),
      );
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.missingDsn);
      expect(CarpGlitchTip.status.warnings, [contains('sampleRate')]);
      expect(statusLines(printed), [currentStatusLine()]);
      expect(statusLines(printed).single, contains('sampleRate=2'));
    });
  });

  group('study', () {
    for (final syncing in [false, true]) {
      test('a switch drops the breadcrumbs of the previous study'
          '${syncing ? ', also while tags sync' : ''}', () async {
        await start();
        CarpGlitchTip.setStudy(_studyA);
        await settle();
        CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'during A'));
        if (syncing) CarpGlitchTip.setTags({'wave': '2'});
        CarpGlitchTip.setStudy(_studyB);
        await CarpGlitchTip.captureException(StateError('right after'));
        CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'during B'));
        await settle();
        await CarpGlitchTip.captureMessage('later');

        final [rightAfter, later] = transport.events;
        expect(rightAfter.tags, containsPair('study_id', 'sB'));
        expect(rightAfter.tags, containsPair('study_deployment_id', 'dB'));
        expect(
          rightAfter.contexts['study'],
          containsPair('study_deployment_id', 'dB'),
        );
        if (syncing) expect(rightAfter.tags, containsPair('wave', '2'));
        expect(_crumbs(rightAfter), isNot(contains('during A')));
        expect(_crumbs(later), contains('during B'));
        expect(_crumbs(later), isNot(contains('during A')));
      });
    }
  });

  group('trace', () {
    test('records a manual transaction with a custom name', () async {
      await start(options(tracesSampleRate: 1));
      await CarpGlitchTip.trace('bloc.initialize', () => 1);
      await eventually(() => traced('bloc.initialize').isNotEmpty);
      final transaction = traced('bloc.initialize').single;
      expect(transaction.contexts.trace!.origin, 'manual');
      expect(transaction.transactionInfo?.source, 'custom');
    });
  });

  group('DSN', () {
    test('init rejects DSNs the Sentry SDK cannot use', () async {
      for (final dsn in [
        // Sentry takes the empty last path segment as the project id
        'https://key@h/7/?x=1',
        // Sentry cannot build the ingest URL of an IPv6 host
        'http://key@[::1]:8000/7',
      ]) {
        await CarpGlitchTip.resetForTest();
        await start(options(dsn: dsn));
        final status = CarpGlitchTip.status;
        expect(status.disabledReason, DisabledReason.invalidDsn, reason: dsn);
        expect(CarpGlitchTip.isEnabled, isFalse, reason: dsn);
        expect(Sentry.isEnabled, isFalse, reason: dsn);
      }
    });

    test('init accepts a DSN with a path prefix', () async {
      await start(options(dsn: 'https://key@h/glitchtip/7'));
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(CarpGlitchTip.status.dsn, 'h/glitchtip/7');
      await CarpGlitchTip.captureException(StateError('boom'));
      expect(transport.events, hasLength(1));
    });
  });

  group('round 3', () {
    // Options whose SDK start takes [delay] (initTimeout 50 ms), with [env].
    CarpGlitchTipOptions slowStartWith(Duration delay, {EnvLookup? env}) =>
        options(
          env: env,
          initTimeout: const Duration(milliseconds: 50),
          configure: (o) => o.addIntegrationByIndex(0, _SlowStart(delay)),
        );

    for (final (name, unmodifiable)
        in <(String, List<Breadcrumb> Function(List<Breadcrumb>))>[
          ('const []', (_) => const []),
          ('List.unmodifiable', List.unmodifiable),
          ('a fixed-length list', (crumbs) => crumbs.toList(growable: false)),
        ]) {
      test('an app hook that sets $name does not drop events after a study '
          'switch', () async {
        await start(
          options(
            beforeSend: (event, hint) =>
                event..breadcrumbs = unmodifiable(event.breadcrumbs ?? []),
          ),
        );
        CarpGlitchTip.setStudy(_studyA);
        CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'in study A'));
        CarpGlitchTip.setStudy(_studyB);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'in study B'));
        await CarpGlitchTip.captureException(StateError('after the switch'));
        await CarpGlitchTip.captureMessage('also after the switch');

        expect(transport.events, hasLength(2));
        for (final event in transport.events) {
          expect(_crumbs(event), isNot(contains('in study A')));
        }
      });
    }

    test('a breadcrumb right after a study switch survives a scope sync in '
        'flight', () async {
      await start();
      await settle(); // the first sync is done
      CarpGlitchTip.setTags({'flavor': 'a'}); // a sync in flight
      CarpGlitchTip.setStudy(_studyA);
      CarpGlitchTip.setStudy(_studyB);
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'study B, right after'));
      await settle(); // all syncs are done
      await CarpGlitchTip.captureException(StateError('boom'));
      expect(
        _crumbs(transport.events.single),
        contains('study B, right after'),
      );
    });

    test('a breadcrumb right after a study switch during a slow start '
        'survives the start', () async {
      await start(slowStartWith(const Duration(milliseconds: 300)));
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.starting);
      CarpGlitchTip.setStudy(_studyA);
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'in study A'));
      CarpGlitchTip.setStudy(_studyB);
      CarpGlitchTip.addBreadcrumb(
        Breadcrumb(message: 'study B, while starting'),
      );
      await eventually(() => CarpGlitchTip.isEnabled);
      await settle();
      await CarpGlitchTip.captureException(StateError('boom'));
      final crumbs = _crumbs(transport.events.single);
      expect(crumbs, contains('study B, while starting'));
      expect(crumbs, isNot(contains('in study A')));
    });

    test(
      'the app\'s reports are sent while the SDK is still starting',
      () async {
        await start(slowStartWith(const Duration(milliseconds: 300)));
        expect(CarpGlitchTip.isEnabled, isFalse);
        expect(CarpGlitchTip.status.disabledReason, DisabledReason.starting);
        await CarpGlitchTip.captureException(StateError('while starting'));
        await CarpGlitchTip.captureMessage('also while starting');

        expect(transport.events, hasLength(2));
        for (final event in transport.events) {
          // through the wrapper's pipeline: its user and tags
          expect(event.user?.id, isNot(isEmpty));
          expect(event.tags, containsPair('build_mode', 'debug'));
        }
      },
    );

    test('the starting line shows the configuration and warnings', () async {
      final printed = capturePrints();
      await start(
        slowStartWith(
          const Duration(milliseconds: 300),
          env: GlitchTipEnv.fromMap({GlitchTipKeys.tracesSampleRate: '7'}),
        ),
      );
      final line = statusLines(printed).single;
      expect(line, startsWith('[CarpGlitchTip] starting (after 50 ms): '));
      expect(line, contains('dsn=glitchtip.example.com/1'));
      expect(line, contains('warnings='));
      expect(line, contains(CarpGlitchTip.status.warnings.single));
      await eventually(() => CarpGlitchTip.isEnabled);
      expect(statusLines(printed).last, startsWith('[CarpGlitchTip] enabled'));
    });

    test('a failed start keeps the configuration warnings', () async {
      final printed = capturePrints();
      await start(
        options(
          env: GlitchTipEnv.fromMap({GlitchTipKeys.tracesSampleRate: '7'}),
          configure: (o) => o.addIntegrationByIndex(
            0,
            _SlowStart(Duration.zero, error: StateError('native failed')),
          ),
        ),
      );
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.initFailed);
      expect(
        statusLines(printed).single,
        allOf(contains('DISABLED'), contains('(StateError)'), contains('7')),
      );
    });

    test('only the url and method of a failed request stay with its error, '
        'until resetForTest', () async {
      await start();
      final error = http.ClientException('Connection closed while receiving');
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async => throw error),
      );
      await expectLater(
        client.post(Uri.parse('https://h/upload?x=1'), body: 'big body'),
        throwsA(same(error)),
      );
      expect(GlitchTipRuntime.requestOf(error), (
        Uri.parse('https://h/upload?x=1'),
        'POST',
      ));
      await CarpGlitchTip.resetForTest();
      expect(GlitchTipRuntime.requestOf(error), isNull);
    });
  });
}
