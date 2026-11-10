// Tests of the CarpGlitchTip facade against the v2 design: init outcomes and
// the status line, the Sentry options the wrapper enforces, the event
// pipeline (study, tags, contexts, user, ignore rules, privacy), runZoned,
// trace() and the navigator observer. Every test starts the real Sentry SDK
// with a GlitchTipTestTransport, so nothing is sent.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/src/util/platform.dart'
    show debugIsFlutterTest;
import 'package:carp_glitchtip_wrapper/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const _dsn = 'https://public-key@glitchtip.example.com/1';

const _study1 = StudyMetadata(studyId: 's1', studyDeploymentId: 'd1');
const _study2 = StudyMetadata(studyId: 's2', studyDeploymentId: 'd2');

/// An error whose `toString()` says nothing: "Instance of '_OpaqueError'".
class _OpaqueError {}

/// Stands in for the app's BLoC that knows the current study.
class _StudyBloc extends ChangeNotifier {
  StudyMetadata? study;

  void update(StudyMetadata? value) {
    study = value;
    notifyListeners();
  }
}

/// Makes the Sentry SDK fail to start.
class _FailingIntegration implements Integration<SentryFlutterOptions> {
  @override
  void call(Hub hub, SentryFlutterOptions options) =>
      throw StateError('cannot start $_dsn');

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GlitchTipTestTransport transport;

  setUp(() async {
    await CarpGlitchTip.resetForTest();
    transport = GlitchTipTestTransport();
  });
  tearDown(CarpGlitchTip.resetForTest);

  // Options that turn reporting on under flutter test and send to transport.
  CarpGlitchTipOptions options({
    EnvLookup? env,
    String? environment,
    double? tracesSampleRate,
    HttpOptions httpOptions = const HttpOptions(),
    IgnoreRule? offlineErrors = const IgnoreRule.offline(),
    List<IgnoreRule> ignoreErrors = const [],
    String? Function(Object error)? describeError,
    FutureOr<SentryEvent?> Function(SentryEvent event, Hint hint)? beforeSend,
    Breadcrumb? Function(Breadcrumb? crumb, Hint hint)? beforeBreadcrumb,
    Duration initTimeout = const Duration(seconds: 5),
    void Function(SentryFlutterOptions options)? configure,
  }) => CarpGlitchTipOptions(
    enabled: true,
    dsn: _dsn,
    env: env,
    environment: environment,
    tracesSampleRate: tracesSampleRate,
    http: httpOptions,
    offlineErrors: offlineErrors,
    ignoreErrors: ignoreErrors,
    describeError: describeError,
    beforeSend: beforeSend,
    beforeBreadcrumb: beforeBreadcrumb,
    initTimeout: initTimeout,
    configure: (o) {
      o
        ..transport = transport
        ..autoInitializeNativeSdk = false;
      configure?.call(o);
    },
  );

  Future<void> start([CarpGlitchTipOptions? custom]) =>
      CarpGlitchTip.init(custom ?? options());

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
  Future<void> eventually(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
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

  group('init', () {
    test('stays off under flutter test without enabled: true', () async {
      final printed = capturePrints();
      var configured = false;
      await CarpGlitchTip.init(
        CarpGlitchTipOptions(
          dsn: _dsn,
          env: GlitchTipEnv.fromMap({'GLITCHTIP_ENABLED': 'true'}),
          configure: (_) => configured = true,
        ),
      );
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.enabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.flutterTest);
      expect(configured, isFalse, reason: 'the Sentry SDK must not start');
      expect(Sentry.isEnabled, isFalse);
      expect(statusLines(printed), [currentStatusLine()]);
    });

    test('stays off without a DSN', () async {
      final printed = capturePrints();
      for (final dsn in [null, '', '   ']) {
        await CarpGlitchTip.resetForTest();
        printed.clear();
        await CarpGlitchTip.init(CarpGlitchTipOptions(enabled: true, dsn: dsn));
        final status = CarpGlitchTip.status;
        expect(status.disabledReason, DisabledReason.missingDsn, reason: dsn);
        expect(CarpGlitchTip.isEnabled, isFalse);
        expect(Sentry.isEnabled, isFalse);
        expect(statusLines(printed), [currentStatusLine()]);
      }
    });

    test('stays off with an invalid DSN, named without its key', () async {
      final printed = capturePrints();
      const labels = {
        'http://secret-key@glitchtip.example.com/1': 'glitchtip.example.com/1',
        'https://secret-key@glitchtip.example.com': 'glitchtip.example.com',
        'https://glitchtip.example.com/1': 'glitchtip.example.com/1',
      };
      for (final MapEntry(key: dsn, value: label) in labels.entries) {
        await CarpGlitchTip.resetForTest();
        printed.clear();
        await CarpGlitchTip.init(CarpGlitchTipOptions(enabled: true, dsn: dsn));
        final status = CarpGlitchTip.status;
        expect(status.disabledReason, DisabledReason.invalidDsn, reason: dsn);
        expect(status.detail, endsWith(': $label'), reason: dsn);
        expect(status.detail, isNot(contains('secret-key')));
        expect(CarpGlitchTip.isEnabled, isFalse);
        expect(Sentry.isEnabled, isFalse);
        expect(statusLines(printed), [currentStatusLine()]);
        expect(printed.join('\n'), isNot(contains('secret-key')));
      }
    });

    test('starts with enabled: true and a valid DSN', () async {
      final printed = capturePrints();
      await start();
      final status = CarpGlitchTip.status;
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(status.enabled, isTrue);
      expect(status.disabledReason, isNull);
      expect(status.dsn, 'glitchtip.example.com/1');
      expect(status.environment, 'production-debug');
      expect(status.buildMode, 'debug');
      expect(status.httpInstrumented, isFalse);
      expect(statusLines(printed), [currentStatusLine()]);
      expect(printed.join('\n'), isNot(contains('public-key')));
      expect(
        printed.where((line) => line.contains('runZoned')),
        isNotEmpty,
        reason: 'warns that init ran outside CarpGlitchTip.runZoned',
      );
    });

    test('stays off outside the main isolate', () async {
      final reason = await Isolate.run(() async {
        await CarpGlitchTip.init(
          const CarpGlitchTipOptions(
            enabled: true,
            dsn: _dsn,
            initTimeout: Duration(seconds: 1),
          ),
        );
        return CarpGlitchTip.status.disabledReason?.name;
      });
      expect(reason, DisabledReason.notRootIsolate.name);
    });

    test('reports a failed SDK start by error type only', () async {
      final printed = capturePrints();
      await start(
        options(configure: (o) => o.addIntegration(_FailingIntegration())),
      );
      final status = CarpGlitchTip.status;
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(status.disabledReason, DisabledReason.initFailed);
      expect(status.detail, 'StateError');
      expect(Sentry.isEnabled, isFalse, reason: 'the SDK is closed again');
      expect(statusLines(printed), [currentStatusLine()]);
    });

    test('a second init does nothing', () async {
      final printed = capturePrints();
      await start(options(environment: 'first'));
      await start(options(environment: 'second'));
      expect(CarpGlitchTip.status.environment, 'first');
      expect(statusLines(printed), hasLength(1));
    });

    test('concurrent inits start the Sentry SDK once', () async {
      final printed = capturePrints();
      var configured = 0;
      await Future.wait([
        start(options(configure: (_) => configured++)),
        start(options(configure: (_) => configured++)),
      ]);
      expect(configured, 1);
      expect(statusLines(printed), hasLength(1));
    });

    test('keeps starting in the background after initTimeout', () async {
      final printed = capturePrints();
      await start(options(initTimeout: Duration.zero));
      await eventually(() => CarpGlitchTip.isEnabled);
      expect(CarpGlitchTip.status.enabled, isTrue);
      // the starting line already shows the configuration
      expect(statusLines(printed), [
        currentStatusLine().replaceFirst(
          '] enabled ',
          '] starting (after 0 ms): ',
        ),
        currentStatusLine(),
      ]);
      await CarpGlitchTip.captureException(StateError('after the start'));
      expect(transport.events, hasLength(1));
    });

    test('close stops reporting', () async {
      await start();
      await CarpGlitchTip.close();
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.enabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.closed);
      expect(Sentry.isEnabled, isFalse);
      await CarpGlitchTip.captureException(StateError('after close'));
      expect(transport.events, isEmpty);
    });

    test('close waits for a pending init', () async {
      final starting = start();
      await CarpGlitchTip.close();
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.closed);
      await starting;
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.closed);
    });

    test('init after close starts again with the new options', () async {
      await start(options(environment: 'first'));
      await CarpGlitchTip.captureException(StateError('first'));
      await CarpGlitchTip.close();
      final printed = capturePrints();
      await start(options(environment: 'second'));
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(CarpGlitchTip.status.environment, 'second');
      expect(statusLines(printed), [currentStatusLine()]);
      await CarpGlitchTip.captureException(StateError('second'));
      expect(transport.events.map((e) => e.environment), ['first', 'second']);
    });

    test('init after close reads the env again', () async {
      var mode = 'test';
      final reporting = options(
        env: (key) => key == 'deployment-mode' ? mode : null,
      );
      await start(reporting);
      expect(CarpGlitchTip.status.environment, 'test-debug');
      await CarpGlitchTip.close();
      mode = 'dev';
      await start(reporting);
      expect(CarpGlitchTip.status.environment, 'dev-debug');
    });

    test('lists configuration warnings in the status', () async {
      await start(
        options(
          environment: 'from-code',
          env: GlitchTipEnv.fromMap({'GLITCHTIP_ENVIRONMENT': 'from-env'}),
        ),
      );
      expect(CarpGlitchTip.status.environment, 'from-env');
      expect(CarpGlitchTip.status.warnings, isNotEmpty);
    });
  });

  group('before init and after close', () {
    // Calls every method of the facade once.
    Future<void> useEveryMethod() async {
      final bloc = _StudyBloc();
      addTearDown(bloc.dispose);
      CarpGlitchTip.setStudy(_study1);
      final unbind = CarpGlitchTip.bindStudy(bloc, () => bloc.study);
      bloc.update(_study2);
      unbind();
      CarpGlitchTip.clearStudy();
      CarpGlitchTip.setTags({'site': 'cph', 'wave': null});
      CarpGlitchTip.setContext('protocol', {'name': 'sleep'});
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'step'));
      await CarpGlitchTip.captureException(
        StateError('boom'),
        stackTrace: StackTrace.current,
      );
      await CarpGlitchTip.captureMessage('hello', level: SentryLevel.warning);
      expect(await CarpGlitchTip.trace('job', () => 42), 42);
      final client = CarpGlitchTip.httpClient(
        MockClient((_) async => http.Response('ok', 200)),
      );
      expect(CarpGlitchTip.httpClient(client), same(client));
      expect((await client.get(Uri.parse('https://example.com/'))).body, 'ok');
      client.close();
      expect(CarpGlitchTip.navigatorObserver(), isA<NavigatorObserver>());
    }

    test('every method does nothing before init and never throws', () async {
      await useEveryMethod();
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(
        CarpGlitchTip.status.disabledReason,
        DisabledReason.notInitialized,
      );
      expect(Sentry.isEnabled, isFalse);
    });

    test('every method does nothing after close and never throws', () async {
      await start();
      await CarpGlitchTip.close();
      transport.clear();
      await useEveryMethod();
      await CarpGlitchTip.close();
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.closed);
      expect(transport.envelopes, isEmpty);
    });

    test('metadata set before init is reported once init ran', () async {
      CarpGlitchTip.setStudy(_study1);
      CarpGlitchTip.setTags({'site': 'cph'});
      CarpGlitchTip.setContext('protocol', {'name': 'sleep'});
      expect(CarpGlitchTip.study, _study1);
      await start();
      await CarpGlitchTip.captureException(StateError('boom'));
      final event = transport.events.single;
      expect(event.tags, containsPair('study_deployment_id', 'd1'));
      expect(event.tags, containsPair('site', 'cph'));
      expect(event.contexts['protocol'], {'name': 'sleep'});
    });

    test('metadata changed while closed is reported after re-init', () async {
      await start();
      CarpGlitchTip.setTags({'site': 'cph'});
      await CarpGlitchTip.close();
      CarpGlitchTip.setStudy(_study2);
      CarpGlitchTip.setTags({'site': null, 'wave': '2'});
      await start();
      await CarpGlitchTip.captureException(StateError('boom'));
      final tags = transport.events.single.tags;
      expect(tags, containsPair('study_deployment_id', 'd2'));
      expect(tags, containsPair('wave', '2'));
      expect(tags, isNot(contains('site')));
    });
  });

  group('Sentry options', () {
    test('applies GlitchTip defaults that configure may change', () async {
      late SentryFlutterOptions sentry;
      await start(options(configure: (o) => sentry = o));
      expect(sentry.dsn, _dsn);
      expect(sentry.environment, 'production-debug');
      expect(sentry.sampleRate, 1);
      expect(sentry.tracesSampleRate, 0);
      expect(sentry.traceLifecycle, SentryTraceLifecycle.static);
      expect(sentry.enableAutoSessionTracking, isFalse);
      expect(sentry.sendClientReports, isFalse);
      expect(sentry.enableFramesTracking, isFalse);
      expect(sentry.enableUserInteractionTracing, isFalse);
      expect(sentry.enableAppLifecycleBreadcrumbs, isTrue);
      expect(sentry.maxCacheItems, 100);
      expect(sentry.maxAttachmentSize, 1024 * 1024);

      await CarpGlitchTip.close();
      await start(
        options(
          configure: (o) => sentry = o
            ..enableAppLifecycleBreadcrumbs = false
            ..maxCacheItems = 30
            ..maxAttachmentSize = 2 * 1024 * 1024,
        ),
      );
      expect(sentry.enableAppLifecycleBreadcrumbs, isFalse);
      expect(sentry.maxCacheItems, 30);
      expect(sentry.maxAttachmentSize, 2 * 1024 * 1024);
    });

    test(
      'reverts privacy and GlitchTip settings changed in configure',
      () async {
        final printed = capturePrints();
        late SentryFlutterOptions sentry;
        await start(
          options(
            httpOptions: const HttpOptions(
              tracePropagationTargets: ['cans.cachet.dk'],
            ),
            configure: (o) {
              sentry = o
                ..dsn = 'https://other-key@other.example.com/2'
                ..environment = 'changed'
                ..traceLifecycle = SentryTraceLifecycle.stream
                ..sendDefaultPii = true
                ..maxRequestBodySize = MaxRequestBodySize.always
                ..attachScreenshot = true
                ..attachViewHierarchy = true
                ..enablePrintBreadcrumbs = true
                ..enableAutoNativeBreadcrumbs = true
                ..recordHttpBreadcrumbs = true
                ..captureNativeFailedRequests = true
                ..captureFailedRequests = true
                ..ignoreErrors = ['boom'];
              o.replay
                ..sessionSampleRate = 1
                ..onErrorSampleRate = 1;
              o.tracePropagationTargets
                ..clear()
                ..add('.*');
            },
          ),
        );
        expect(CarpGlitchTip.isEnabled, isTrue);
        expect(sentry.dsn, _dsn);
        expect(sentry.environment, 'production-debug');
        expect(sentry.traceLifecycle, SentryTraceLifecycle.static);
        expect(sentry.sendDefaultPii, isFalse);
        expect(sentry.maxRequestBodySize, MaxRequestBodySize.never);
        expect(sentry.attachScreenshot, isFalse);
        expect(sentry.attachViewHierarchy, isFalse);
        expect(sentry.enablePrintBreadcrumbs, isFalse);
        expect(sentry.enableAutoNativeBreadcrumbs, isFalse);
        expect(sentry.recordHttpBreadcrumbs, isFalse);
        expect(sentry.captureNativeFailedRequests, isFalse);
        expect(sentry.captureFailedRequests, isFalse);
        expect(sentry.replay.sessionSampleRate, 0);
        expect(sentry.replay.onErrorSampleRate, 0);
        expect(sentry.tracePropagationTargets, ['cans.cachet.dk']);
        expect(sentry.beforeSendFeedback, isNotNull);
        expect(printed.where((line) => line.contains('lifecycle')), isNotEmpty);
        expect(
          printed.where((line) => line.contains('ignoreErrors')),
          isNotEmpty,
        );
      },
    );

    test('keeps tracing on when configure removes the sample rate', () async {
      late SentryFlutterOptions sentry;
      await start(
        options(
          configure: (o) => sentry = o
            ..tracesSampleRate = null
            ..tracesSampler = null,
        ),
      );
      expect(sentry.tracesSampleRate, 0);
    });

    test('runs the hooks set in configure, then the privacy scrub', () async {
      await start(
        options(
          configure: (o) {
            o.beforeSend = (event, hint) => event
              ..tags = {...?event.tags, 'configured': 'yes'}
              ..user = SentryUser(
                id: 'participant-7',
                email: 'participant@example.com',
              )
              ..serverName = 'participant-phone';
            o.beforeBreadcrumb = (crumb, hint) {
              if (crumb != null) {
                crumb.data = {
                  ...?crumb.data,
                  'note': 'mail participant@example.com',
                };
              }
              return crumb;
            };
          },
        ),
      );
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'step'));
      await settle();
      await CarpGlitchTip.captureException(StateError('boom'));
      final event = transport.events.single;
      expect(event.tags, containsPair('configured', 'yes'));
      expect(event.user?.id, isNot('participant-7'));
      expect(event.user?.email, isNull);
      expect(event.serverName, isNull);
      final step = event.breadcrumbs!.singleWhere((b) => b.message == 'step');
      expect(step.data, containsPair('note', 'mail {email}'));
    });

    test('drops an event the beforeSend set in configure drops', () async {
      await start(
        options(configure: (o) => o.beforeSend = (event, hint) => null),
      );
      await CarpGlitchTip.captureException(StateError('boom'));
      await settle();
      expect(transport.events, isEmpty);
    });

    test('runs beforeSend of the options before the configure one', () async {
      final calls = <String>[];
      await start(
        options(
          beforeSend: (event, hint) {
            calls.add('options: ${event.exceptions!.single.value}');
            return event;
          },
          configure: (o) => o.beforeSend = (event, hint) {
            calls.add('configure');
            return event;
          },
        ),
      );
      await CarpGlitchTip.captureException(
        StateError('mail participant@example.com'),
      );
      expect(calls, [
        'options: Bad state: mail participant@example.com',
        'configure',
      ]);
      expect(
        transport.events.single.exceptions!.single.value,
        'Bad state: mail {email}',
      );
    });

    test('keeps the event when the configure beforeSend throws', () async {
      await start(
        options(
          configure: (o) =>
              o.beforeSend = (event, hint) => throw StateError('buggy hook'),
        ),
      );
      await CarpGlitchTip.captureException(
        StateError('mail participant@example.com'),
      );
      expect(
        transport.events.single.exceptions!.single.value,
        'Bad state: mail {email}',
      );
    });

    test('starts even when configure throws', () async {
      late SentryFlutterOptions sentry;
      await start(
        options(
          configure: (o) {
            sentry = o..sendDefaultPii = true;
            throw StateError('broken configure');
          },
        ),
      );
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(sentry.sendDefaultPii, isFalse);
      await CarpGlitchTip.captureException(StateError('boom'));
      expect(transport.events, hasLength(1));
    });
  });

  group('event pipeline', () {
    test('setStudy adds the study tags and context', () async {
      await start();
      CarpGlitchTip.setStudy(
        const StudyMetadata(
          studyId: 's1',
          studyDeploymentId: 'd1',
          deviceRoleName: 'Primary phone',
          participantRoleName: 'Mother',
          tags: {'site': 'cph', 'study_id': 'not-the-id'},
          context: {'protocol': 'sleep'},
        ),
      );
      expect(CarpGlitchTip.study?.studyDeploymentId, 'd1');
      await CarpGlitchTip.captureException(StateError('boom'));
      final event = transport.events.single;
      expect(event.tags, containsPair('study_id', 's1'));
      expect(event.tags, containsPair('study_deployment_id', 'd1'));
      expect(event.tags, containsPair('device_role', 'Primary phone'));
      expect(event.tags, containsPair('participant_role', 'Mother'));
      expect(event.tags, containsPair('site', 'cph'));
      expect(event.contexts['study'], {
        'study_id': 's1',
        'study_deployment_id': 'd1',
        'device_role': 'Primary phone',
        'participant_role': 'Mother',
        'protocol': 'sleep',
      });
    });

    test('a study known only after sign-in is attached from then on, and '
        'protocol details added later keep the breadcrumbs', () async {
      await start();
      // before sign-in and before an invitation was accepted
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'signed in'));
      await CarpGlitchTip.captureMessage('before the invitation');
      // the invitation was accepted
      CarpGlitchTip.setStudy(
        const StudyMetadata(
          studyId: 's1',
          studyDeploymentId: 'd1',
          deviceRoleName: 'Primary phone',
          participantRoleName: 'Participant',
        ),
      );
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'invitation accepted'));
      // the deployment and its protocol were loaded: same deployment
      CarpGlitchTip.setStudy(
        const StudyMetadata(
          studyId: 's1',
          studyDeploymentId: 'd1',
          deviceRoleName: 'Primary phone',
          participantRoleName: 'Participant',
          context: {'protocol': 'CAMS App - Demo Study Protocol'},
        ),
      );
      await CarpGlitchTip.captureMessage('in the study');

      final [before, during] = transport.events;
      for (final key in GlitchTipTags.all.where((k) => k.contains('_role'))) {
        expect(before.tags, isNot(contains(key)));
      }
      expect(before.tags, isNot(contains('study_deployment_id')));
      expect(before.contexts['study'], isNull);
      expect(during.tags, containsPair('participant_role', 'Participant'));
      expect(
        during.contexts['study'],
        containsPair('protocol', 'CAMS App - Demo Study Protocol'),
      );
      // the same deployment: the breadcrumbs from before are kept
      expect(
        during.breadcrumbs!.map((b) => b.message),
        containsAll(['signed in', 'invitation accepted']),
      );
    });

    test('a changed participant role of the same deployment is applied', () {
      const mother = StudyMetadata(
        studyDeploymentId: 'd1',
        participantRoleName: 'Mother',
      );
      const father = StudyMetadata(
        studyDeploymentId: 'd1',
        participantRoleName: 'Father',
      );
      expect(mother, isNot(father));
      expect(
        mother,
        const StudyMetadata(
          studyDeploymentId: 'd1',
          participantRoleName: 'Mother',
        ),
      );
      CarpGlitchTip.setStudy(mother);
      CarpGlitchTip.setStudy(father);
      expect(CarpGlitchTip.study?.participantRoleName, 'Father');
      expect(father.toTags(), containsPair('participant_role', 'Father'));
      expect(father.toString(), contains('participantRoleName: Father'));
    });

    test('clearStudy removes the study and its breadcrumbs', () async {
      await start();
      CarpGlitchTip.setStudy(
        const StudyMetadata(
          studyId: 's1',
          studyDeploymentId: 'd1',
          deviceRoleName: 'Primary phone',
        ),
      );
      await settle();
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'during the study'));
      await CarpGlitchTip.captureMessage('in the study');
      CarpGlitchTip.clearStudy();
      await settle();
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'after the study'));
      await CarpGlitchTip.captureMessage('after the study');

      final [during, after] = transport.events;
      expect(
        during.breadcrumbs!.map((b) => b.message),
        contains('during the study'),
      );
      expect(CarpGlitchTip.study, isNull);
      for (final key in [
        'study_id',
        'study_deployment_id',
        'device_role',
        'participant_role',
      ]) {
        expect(after.tags, isNot(contains(key)));
      }
      expect(after.contexts['study'], isNull);
      final messages = after.breadcrumbs!.map((b) => b.message);
      expect(messages, isNot(contains('during the study')));
      expect(messages, contains('after the study'));
    });

    test(
      'clearStudy also clears the breadcrumbs of an error right after it',
      () async {
        await start();
        CarpGlitchTip.setStudy(_study1);
        await settle();
        CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'during the study'));
        CarpGlitchTip.setTags({'wave': '2'}); // still syncing to the scope
        CarpGlitchTip.clearStudy();
        await CarpGlitchTip.captureException(StateError('leaving failed'));
        final event = transport.events.single;
        expect(event.tags, isNot(contains('study_deployment_id')));
        expect(
          event.breadcrumbs!.map((b) => b.message),
          isNot(contains('during the study')),
        );
      },
    );

    test('bindStudy reads the study now and on every notification', () async {
      await start();
      final bloc = _StudyBloc()..study = _study1;
      addTearDown(bloc.dispose);
      CarpGlitchTip.bindStudy(bloc, () => bloc.study);
      expect(CarpGlitchTip.study, _study1);
      bloc.update(_study2);
      expect(CarpGlitchTip.study, _study2);
      await CarpGlitchTip.captureException(StateError('boom'));
      expect(
        transport.events.single.tags,
        containsPair('study_deployment_id', 'd2'),
      );
      bloc.update(null);
      expect(CarpGlitchTip.study, isNull);
    });

    test('bindStudy keeps the previous study when the reader throws', () async {
      await start();
      final bloc = _StudyBloc();
      addTearDown(bloc.dispose);
      CarpGlitchTip.setStudy(_study1);
      var loaded = false;
      CarpGlitchTip.bindStudy(
        bloc,
        () => loaded ? bloc.study : throw StateError('settings not loaded'),
      );
      expect(CarpGlitchTip.study, _study1);
      loaded = true;
      bloc.update(_study2);
      expect(CarpGlitchTip.study, _study2);
      loaded = false;
      bloc.update(null);
      expect(CarpGlitchTip.study, _study2);
      await CarpGlitchTip.captureException(StateError('boom'));
      expect(
        transport.events.single.tags,
        containsPair('study_deployment_id', 'd2'),
      );
    });

    test('bindStudy reads the study again for every reported error', () async {
      await start();
      final bloc = _StudyBloc()..study = _study1;
      addTearDown(bloc.dispose);
      CarpGlitchTip.bindStudy(bloc, () => bloc.study);
      bloc.study = _study2; // without a notification
      await CarpGlitchTip.captureException(StateError('boom'));
      expect(
        transport.events.single.tags,
        containsPair('study_deployment_id', 'd2'),
      );
    });

    test('the callback bindStudy returns stops the updates', () async {
      await start();
      final bloc = _StudyBloc()..study = _study1;
      addTearDown(bloc.dispose);
      final unbind = CarpGlitchTip.bindStudy(bloc, () => bloc.study);
      unbind();
      bloc.update(_study2);
      expect(CarpGlitchTip.study, _study1);
      await CarpGlitchTip.captureException(StateError('boom'));
      expect(
        transport.events.single.tags,
        containsPair('study_deployment_id', 'd1'),
      );
    });

    test('setTags adds, removes and caps tags', () async {
      await start();
      CarpGlitchTip.setTags({'site': 'cph', 'wave': '1', 'long': 'x' * 300});
      CarpGlitchTip.setTags({'wave': null});
      await CarpGlitchTip.captureException(StateError('boom'));
      final tags = transport.events.single.tags;
      expect(tags, containsPair('site', 'cph'));
      expect(tags, isNot(contains('wave')));
      expect(tags, containsPair('long', 'x' * 200));
    });

    test('setTags rejects the keys the wrapper sets', () async {
      final printed = capturePrints();
      await start();
      CarpGlitchTip.setTags({
        for (final key in GlitchTipTags.all) key: 'app',
        'site': 'cph',
      });
      await CarpGlitchTip.captureException(StateError('boom'));
      final tags = transport.events.single.tags!;
      expect(tags, containsPair('site', 'cph'));
      expect(tags, containsPair('build_mode', 'debug'));
      for (final key in GlitchTipTags.all) {
        expect(tags[key], isNot('app'), reason: key);
      }
      expect(
        printed.where((line) => line.contains('study_id')),
        isNotEmpty,
        reason: 'warns about the rejected key',
      );
    });

    test('setContext adds and removes a context', () async {
      await start();
      CarpGlitchTip.setContext('protocol', {'name': 'sleep', 'version': 2});
      await CarpGlitchTip.captureMessage('with the context');
      CarpGlitchTip.setContext('protocol', null);
      await CarpGlitchTip.captureMessage('without the context');
      final [withContext, withoutContext] = transport.events;
      expect(withContext.contexts['protocol'], {'name': 'sleep', 'version': 2});
      expect(withoutContext.contexts['protocol'], isNull);
    });

    test('syncs the metadata to the Sentry scope', () async {
      await start();
      late Scope scope;
      await Sentry.configureScope((s) => scope = s);
      CarpGlitchTip.setStudy(_study1);
      CarpGlitchTip.setTags({'site': 'cph'});
      CarpGlitchTip.setContext('protocol', {'name': 'sleep'});
      await eventually(() => scope.tags.containsKey('site'));
      expect(scope.tags, containsPair('study_deployment_id', 'd1'));
      expect(scope.tags, containsPair('build_mode', 'debug'));
      expect(scope.contexts['protocol'], {'name': 'sleep'});
      expect(scope.contexts['study'], containsPair('study_id', 's1'));
      await CarpGlitchTip.captureMessage('hello');
      expect(scope.user?.id, transport.events.single.user?.id);

      CarpGlitchTip.clearStudy();
      CarpGlitchTip.setTags({'site': null});
      await eventually(() => !scope.tags.containsKey('site'));
      expect(scope.tags, isNot(contains('study_deployment_id')));
      expect(scope.contexts, isNot(contains('study')));
    });

    test('reports a random per-launch user, never the app user', () async {
      await start();
      await Sentry.configureScope(
        (scope) => scope.setUser(
          SentryUser(
            id: 'participant-7',
            email: 'participant@example.com',
            username: 'participant',
          ),
        ),
      );
      await CarpGlitchTip.captureException(StateError('one'));
      await CarpGlitchTip.captureMessage('two');
      final [first, second] = [for (final e in transport.events) e.user!];
      expect(first.id, isNotEmpty);
      expect(first.id, isNot('participant-7'));
      expect(second.id, first.id);
      for (final user in [first, second]) {
        expect(user.email, isNull);
        expect(user.username, isNull);
        expect(user.ipAddress, isNull);
      }

      await CarpGlitchTip.close();
      await start();
      await CarpGlitchTip.captureMessage('three');
      final third = transport.events.last.user!;
      expect(third.id, isNotEmpty);
      expect(third.id, isNot(first.id));
    });

    test('tags every event with the build and deployment mode', () async {
      await start(
        options(env: GlitchTipEnv.fromMap({'deployment-mode': 'test'})),
      );
      await CarpGlitchTip.captureMessage('hello');
      final event = transport.events.single;
      expect(event.tags, containsPair('build_mode', 'debug'));
      expect(event.tags, containsPair('deployment_mode', 'test'));
      expect(event.environment, 'test-debug');

      await CarpGlitchTip.close();
      await start();
      await CarpGlitchTip.captureMessage('hello');
      expect(transport.events.last.tags, isNot(contains('deployment_mode')));
    });

    test('turns the transaction of an event into the screen tag', () async {
      await start();
      final screen = Sentry.startTransaction(
        'StudyScreen',
        'ui.load',
        bindToScope: true,
      );
      await CarpGlitchTip.captureException(StateError('boom'));
      await screen.finish();
      final event = transport.events.single;
      expect(event.transaction, isNull);
      expect(event.tags, containsPair('screen', 'StudyScreen'));
    });

    test('describeError replaces the value of opaque errors', () async {
      await start(
        options(
          describeError: (error) => error is _OpaqueError
              ? 'Opaque failure for participant@example.com'
              : null,
        ),
      );
      await CarpGlitchTip.captureException(_OpaqueError());
      final value = transport.events.single.exceptions!.single.value;
      expect(value, 'Opaque failure for {email}');
      expect(value, isNot(contains('Instance of')));
    });

    test('ignore rules see the describeError text', () async {
      await start(
        options(
          describeError: (error) => error is _OpaqueError ? 'code 42' : null,
          ignoreErrors: [const IgnoreRule.message('code 42')],
        ),
      );
      await CarpGlitchTip.captureException(_OpaqueError());
      await settle();
      expect(transport.events, isEmpty);
    });

    test('an app beforeSend that throws keeps the scrubbed event', () async {
      await start(
        options(beforeSend: (event, hint) => throw StateError('buggy hook')),
      );
      await CarpGlitchTip.captureException(
        StateError('mail participant@example.com'),
      );
      final event = transport.events.single;
      expect(event.exceptions!.single.value, 'Bad state: mail {email}');
    });

    test('an app beforeSend that returns null drops the event', () async {
      await start(options(beforeSend: (event, hint) => null));
      await CarpGlitchTip.captureException(StateError('boom'));
      await settle();
      expect(transport.events, isEmpty);
    });

    test('drops offline errors by default', () async {
      await start();
      await CarpGlitchTip.captureException(
        const SocketException(
          "Failed host lookup: 'cans.cachet.dk'",
          osError: OSError('nodename nor servname provided, or not known', 8),
        ),
      );
      await CarpGlitchTip.captureException(StateError('real bug'));
      await settle();
      expect(transport.events.single.throwable, isA<StateError>());
    });

    test('reports offline errors when offlineErrors is null', () async {
      await start(options(offlineErrors: null));
      await CarpGlitchTip.captureException(
        const SocketException(
          "Failed host lookup: 'cans.cachet.dk'",
          osError: OSError('nodename nor servname provided, or not known', 8),
        ),
      );
      expect(transport.events.single.throwable, isA<SocketException>());
    });

    test('drops errors an IgnoreType rule matches', () async {
      await start(options(ignoreErrors: [const IgnoreType<FormatException>()]));
      await CarpGlitchTip.captureException(const FormatException('bad input'));
      await CarpGlitchTip.captureException(StateError('real bug'));
      await settle();
      expect(transport.events.single.throwable, isA<StateError>());
    });

    test('a throwing ignore rule does not hide the error', () async {
      await start(
        options(
          ignoreErrors: [
            IgnoreRule.custom((_) => throw StateError('buggy rule')),
          ],
        ),
      );
      await CarpGlitchTip.captureException(StateError('real bug'));
      expect(transport.events, hasLength(1));
    });

    test('reports fatal events as errors', () async {
      await start();
      await CarpGlitchTip.captureMessage('fatal', level: SentryLevel.fatal);
      FlutterError.reportError(
        FlutterErrorDetails(exception: StateError('layout failed')),
      );
      await eventually(() => transport.events.length == 2);
      expect(transport.events.map((e) => e.level), [
        SentryLevel.error,
        SentryLevel.error,
      ]);
    });

    test('tags whether an error was handled and how it was caught', () async {
      await start();
      FlutterError.reportError(
        FlutterErrorDetails(exception: StateError('layout failed')),
      );
      await Sentry.captureEvent(
        SentryEvent(
          throwable: ThrowableMechanism(
            Mechanism(type: 'app.retry', handled: true),
            StateError('retried'),
          ),
        ),
      );
      await eventually(() => transport.events.length == 2);
      expect(
        {
          for (final event in transport.events)
            event.tags!['mechanism']: event.tags!['handled'],
        },
        {'FlutterError': 'no', 'app.retry': 'yes'},
      );
    });

    test('scrubs reported messages', () async {
      await start();
      await CarpGlitchTip.captureMessage(
        'sync for participant@example.com failed: '
        'https://cans.cachet.dk/api/studies/42?token=abc',
      );
      final message = transport.events.single.message!;
      expect(
        message.formatted,
        'sync for {email} failed: https://cans.cachet.dk/api/studies/{id}',
      );
      expect(message.params, isNull);
    });

    test('drops device breadcrumbs and runs the breadcrumb hooks', () async {
      await start(
        options(
          beforeBreadcrumb: (crumb, hint) =>
              crumb?.category == 'secret' ? null : crumb,
          configure: (o) =>
              o.beforeBreadcrumb = (crumb, hint) =>
                  throw StateError('buggy hook'),
        ),
      );
      for (final category in ['device.connectivity', 'touch', 'secret']) {
        CarpGlitchTip.addBreadcrumb(
          Breadcrumb(category: category, message: category),
        );
      }
      CarpGlitchTip.addBreadcrumb(
        Breadcrumb(category: 'app', message: 'mail participant@example.com'),
      );
      await settle();
      await CarpGlitchTip.captureMessage('probe');
      final crumbs = transport.events.single.breadcrumbs!;
      for (final category in ['device.connectivity', 'touch', 'secret']) {
        expect(crumbs.map((c) => c.category), isNot(contains(category)));
      }
      expect(
        crumbs.singleWhere((c) => c.category == 'app').message,
        'mail {email}',
      );
    });
  });

  group('runZoned', () {
    test(
      'reports a startup failure once, even if ignored, and rethrows it',
      () async {
        final failure = StateError('startup failed');
        await expectLater(
          CarpGlitchTip.runZoned(() async {
            await start(
              options(ignoreErrors: [const IgnoreType<StateError>()]),
            );
            throw failure;
          }),
          throwsA(same(failure)),
        );
        // under flutter test it is rethrown before the report is sent
        await eventually(() => transport.events.isNotEmpty);
        await settle();
        final event = transport.events.single;
        expect(event.throwable, same(failure));
        expect(event.tags, containsPair('startup_failure', 'true'));
        expect(event.tags, containsPair('handled', 'no'));

        await CarpGlitchTip.captureException(StateError('later'));
        await settle();
        expect(transport.events, hasLength(1), reason: 'ignored later on');
      },
    );

    testWidgets('a widget test failing in the zone fails, not hangs', (
      tester,
    ) async {
      final failure = TestFailure('expected something else');
      // in fake time, waiting for the report to be sent would never end
      await expectLater(
        CarpGlitchTip.runZoned(() async {
          await tester.runAsync(start);
          throw failure;
        }),
        throwsA(same(failure)),
      );
      // the report is still sent
      for (var i = 0; i < 50 && transport.events.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(transport.events.single.throwable, same(failure));
      // the timers of the SDK's app start tracking, which waits for a frame
      tester.binding.scheduleFrame();
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      // a hang fails at once, not after the default 10 minutes
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('in an app, reports a startup failure before rethrowing it', () async {
      addTearDown(() => debugIsFlutterTest = null);
      final failure = StateError('startup failed');
      await expectLater(
        CarpGlitchTip.runZoned(() async {
          await start();
          debugIsFlutterTest = false;
          throw failure;
        }),
        throwsA(same(failure)),
      );
      expect(transport.events.single.throwable, same(failure));
    });

    test('rethrows a startup failure while reporting is off', () async {
      final failure = StateError('startup failed');
      await expectLater(
        CarpGlitchTip.runZoned(() => throw failure),
        throwsA(same(failure)),
      );
      expect(CarpGlitchTip.isEnabled, isFalse);
    });

    test('init inside the zone instruments HTTP without a warning', () async {
      final printed = capturePrints();
      await CarpGlitchTip.runZoned(start);
      expect(CarpGlitchTip.isEnabled, isTrue);
      expect(CarpGlitchTip.status.httpInstrumented, isTrue);
      expect(printed.where((line) => line.contains('runZoned')), isEmpty);
    });

    test('a nested runZoned runs the body and reports once', () async {
      var ran = false;
      await CarpGlitchTip.runZoned(
        () => CarpGlitchTip.runZoned(() => ran = true),
      );
      expect(ran, isTrue);

      final failure = StateError('nested failure');
      await expectLater(
        CarpGlitchTip.runZoned(() async {
          await start();
          await CarpGlitchTip.runZoned(() => throw failure);
        }),
        throwsA(same(failure)),
      );
      await eventually(() => transport.events.isNotEmpty);
      await settle();
      expect(transport.events.single.throwable, same(failure));
    });
  });

  group('trace', () {
    test('records a sampled root transaction of the body', () async {
      await start(options(tracesSampleRate: 1));
      late DateTime began, ended;
      final result = await CarpGlitchTip.trace('bloc.initialize', () async {
        began = DateTime.now().toUtc();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        ended = DateTime.now().toUtc();
        return 42;
      }, operation: 'app.init');
      expect(result, 42);
      await eventually(() => traced('bloc.initialize').isNotEmpty);
      final transaction = traced('bloc.initialize').single;
      final trace = transaction.contexts.trace!;
      expect(trace.operation, 'app.init');
      expect(trace.status, const SpanStatus.ok());
      expect(trace.parentSpanId, isNull);
      expect(transaction.startTimestamp.isAfter(began), isFalse);
      expect(transaction.timestamp!.isBefore(ended), isFalse);
    });

    test('uses the task operation and scrubs the name', () async {
      await start(options(tracesSampleRate: 1));
      await CarpGlitchTip.trace('sync participant@example.com', () => 1);
      await eventually(() => traced('sync {email}').isNotEmpty);
      expect(traced('sync {email}').single.contexts.trace!.operation, 'task');
      expect(
        transport.transactions.map((t) => t.transaction),
        everyElement(isNot(contains('@'))),
      );
    });

    test('marks a failing body internal_error and rethrows', () async {
      await start(options(tracesSampleRate: 1));
      final failure = StateError('upload failed');
      await expectLater(
        CarpGlitchTip.trace('upload', () async => throw failure),
        throwsA(same(failure)),
      );
      await eventually(() => traced('upload').isNotEmpty);
      expect(
        traced('upload').single.contexts.trace!.status,
        const SpanStatus.internalError(),
      );
    });

    test('records nothing with tracesSampleRate 0', () async {
      await start(options(tracesSampleRate: 0));
      expect(await CarpGlitchTip.trace('job', () => 1), 1);
      await settle();
      expect(traced('job'), isEmpty);
    });

    test('runs the body while reporting is off', () async {
      var ran = false;
      final result = await CarpGlitchTip.trace('job', () {
        ran = true;
        return 'done';
      });
      expect(result, 'done');
      expect(ran, isTrue);
      final failure = StateError('job failed');
      await expectLater(
        CarpGlitchTip.trace('job', () => throw failure),
        throwsA(same(failure)),
      );
    });

    test('stays a root transaction while a transaction is bound', () async {
      await start(options(tracesSampleRate: 1));
      final screen = Sentry.startTransaction(
        'StudyScreen',
        'ui.load',
        bindToScope: true,
      );
      await CarpGlitchTip.trace('job', () => 1);
      await screen.finish();
      await eventually(
        () => traced('job').isNotEmpty && traced('StudyScreen').isNotEmpty,
      );
      expect(traced('job').single.contexts.trace!.parentSpanId, isNull);
      expect(traced('StudyScreen').single.spans, isEmpty);
    });

    test('runs the configure beforeSendTransaction, then the scrub', () async {
      final seen = <String?>[];
      await start(
        options(
          tracesSampleRate: 1,
          configure: (o) => o.beforeSendTransaction = (transaction, hint) {
            seen.add(transaction.transaction);
            return transaction
              ..tags = {'site': 'cph'}
              ..user = SentryUser(email: 'participant@example.com');
          },
        ),
      );
      await CarpGlitchTip.trace('job', () => 1);
      await eventually(() => traced('job').isNotEmpty);
      expect(seen, ['job']);
      expect(traced('job').single.tags, isNull);
      expect(traced('job').single.user, isNull);
    });

    test('shares the transaction rate limit with requests', () async {
      await start(
        options(
          tracesSampleRate: 1,
          httpOptions: const HttpOptions(
            sampleRate: 1,
            maxTransactionsPerMinute: 1,
          ),
        ),
      );
      await CarpGlitchTip.trace('first', () => 1);
      await CarpGlitchTip.trace('second', () => 2);
      final client = CarpGlitchTip.httpClient(
        MockClient((_) async => http.Response('ok', 200)),
      );
      await client.get(Uri.parse('https://example.com/studies'));
      client.close();
      await eventually(() => traced('first').isNotEmpty);
      await settle();
      expect(transport.transactions.map((t) => t.transaction), ['first']);
    });
  });

  group('navigatorObserver', () {
    // An app with two observers on one navigator, like a go_router
    // ShellRoute whose routes also reach the root navigator's observers.
    Future<NavigatorState> pumpApp(WidgetTester tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [
            CarpGlitchTip.navigatorObserver(),
            CarpGlitchTip.navigatorObserver(),
          ],
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => Text(settings.name ?? ''),
          ),
        ),
      );
      return navigator.currentState!;
    }

    // The event of a message captured now.
    Future<SentryEvent> capture(WidgetTester tester) async {
      await tester.runAsync(() => CarpGlitchTip.captureMessage('probe'));
      return transport.events.last;
    }

    List<Breadcrumb> navigation(SentryEvent event) => [
      for (final crumb in event.breadcrumbs ?? const <Breadcrumb>[])
        if (crumb.category == 'navigation') crumb,
    ];

    // Lets the Sentry SDK's app start tracking, which waits for a frame and
    // then starts timers, run out before the test ends.
    Future<void> finish(WidgetTester tester) async {
      tester.binding.scheduleFrame();
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
    }

    testWidgets('records every route event once, without arguments', (
      tester,
    ) async {
      await tester.runAsync(start);
      final navigator = await pumpApp(tester);
      unawaited(
        navigator.pushNamed(
          '/studies/123e4567-e89b-12d3-a456-426614174000/participants/42',
          arguments: {'token': 'secret-token', 'mail': 'p@example.com'},
        ),
      );
      await tester.pumpAndSettle();
      unawaited(navigator.pushReplacementNamed('/studies/42'));
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();

      final crumbs = navigation(await capture(tester));
      const participant = '/studies/{uuid}/participants/{id}';
      expect(
        [for (final crumb in crumbs) (crumb.data?['from'], crumb.data?['to'])],
        [
          (null, '/'),
          ('/', participant),
          (participant, '/studies/{id}'),
          ('/studies/{id}', '/'),
        ],
      );
      expect(
        [for (final crumb in crumbs) crumb.data?['state']],
        [
          matches(RegExp('push', caseSensitive: false)),
          matches(RegExp('push', caseSensitive: false)),
          matches(RegExp('replace', caseSensitive: false)),
          matches(RegExp('pop', caseSensitive: false)),
        ],
      );
      for (final crumb in crumbs) {
        expect(crumb.type, 'navigation');
        expect(crumb.data!.keys, everyElement(isIn(['state', 'from', 'to'])));
      }
      expect('${crumbs.map((c) => c.data)}', isNot(contains('secret-token')));
      expect('${crumbs.map((c) => c.data)}', isNot(contains('@')));
      await finish(tester);
    });

    testWidgets('keeps the screen tag on the current route', (tester) async {
      await tester.runAsync(start);
      final navigator = await pumpApp(tester);
      expect((await capture(tester)).tags, containsPair('screen', '/'));

      unawaited(navigator.pushNamed('/participants/p@example.com/consent'));
      await tester.pumpAndSettle();
      expect(
        (await capture(tester)).tags,
        containsPair('screen', '/participants/{email}/consent'),
      );

      unawaited(navigator.pushReplacementNamed('/studies/42'));
      await tester.pumpAndSettle();
      expect(
        (await capture(tester)).tags,
        containsPair('screen', '/studies/{id}'),
      );

      navigator.pop();
      await tester.pumpAndSettle();
      expect((await capture(tester)).tags, containsPair('screen', '/'));
      await finish(tester);
    });

    testWidgets('a bound transaction does not replace the screen tag', (
      tester,
    ) async {
      await tester.runAsync(start);
      final navigator = await pumpApp(tester);
      unawaited(navigator.pushNamed('/consent'));
      await tester.pumpAndSettle();
      final transaction = Sentry.startTransaction(
        'ConsentPage',
        'ui.load',
        bindToScope: true,
      );
      final event = await capture(tester);
      expect(event.tags, containsPair('screen', '/consent'));
      expect(event.transaction, isNull);
      await tester.runAsync(transaction.finish);
      await finish(tester);
    });

    testWidgets('does nothing while reporting is off', (tester) async {
      final navigator = await pumpApp(tester);
      unawaited(navigator.pushNamed('/studies/42'));
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.runAsync(start);
      final event = await capture(tester);
      expect(navigation(event), isEmpty);
      expect(event.tags, isNot(contains('screen')));
      await finish(tester);
    });
  });
}
