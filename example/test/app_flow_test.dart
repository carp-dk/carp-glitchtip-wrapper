// Widget tests of the example's whole flow with GlitchTip's test transport:
// what is reported before sign-in, after accepting an invitation, for the
// network conditions of the sample CAWS and after leaving the study.
//
// The pattern for CARP apps: run the test body like main() runs the app,
// in CarpGlitchTip.runZoned (with the fake backend as innerClient), init the
// wrapper with the app's options and a test transport, bind the study like
// main() does, and drive the app.

import 'dart:convert';
import 'dart:math' as math;

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper_example/main.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/caws_repository.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/network_condition.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_client.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_server.dart';
import 'package:carp_glitchtip_wrapper_example/src/reporting/example_reporting.dart';
import 'package:carp_glitchtip_wrapper_example/src/reporting/report_outbox.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/home_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/invitations_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/report_detail_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/reports_tab.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/study_tab.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/tasks_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/try_it_tab.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/welcome_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/state/app_state.dart';
import 'package:carp_glitchtip_wrapper_example/src/state/try_it_actions.dart';
import 'package:carp_glitchtip_wrapper_example/src/widgets/outcome_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

const _cams = 'CAMS App - Demo Study';
const _family = 'Family Study w. Participant Data';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SampleCawsData data;
  late ReportOutbox transport;
  late SampleCawsServer server;
  AppState? appState;
  VoidCallback? unbind;

  AppState state() => appState!;

  setUpAll(() async => data = await SampleCawsData.load(rootBundle));

  setUp(() async {
    await CarpGlitchTip.resetForTest(); // init only works once otherwise
    // a GlitchTipTestTransport that also notifies the Reports tab
    transport = ReportOutbox();
    server = SampleCawsServer(
      data: () async => data,
      latency: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    unbind?.call();
    appState?.dispose();
    unbind = appState = null;
    await CarpGlitchTip.resetForTest();
  });

  // Runs a test body like main() runs the app: in the wrapper's zone, where
  // every http.Client() the app creates records its requests and goes to
  // the sample CAWS.
  Future<void> Function(WidgetTester) inApp(
    Future<void> Function(WidgetTester tester) body,
  ) =>
      (tester) => CarpGlitchTip.runZoned(
        () => body(tester),
        innerClient: () => SampleCawsClient(server),
      );

  // Alternates fake time (the sample CAWS latency, animations) with real
  // async work (the Sentry SDK) until [condition] holds. Loading indicators
  // animate forever, so pumpAndSettle would never return.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    String? reason,
  }) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(condition(), isTrue, reason: reason);
  }

  // Gives background work (e.g. the wrapper capturing a failed request) the
  // time to finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // Reports [error] now, like the app's code would.
  Future<SentryEvent> capture(WidgetTester tester, Object error) async {
    final before = transport.events.length;
    await tester.runAsync(() => CarpGlitchTip.captureException(error));
    await pumpUntil(tester, () => transport.events.length > before);
    return transport.events.last;
  }

  // Checks that nothing was reported after the first [before] events: an
  // error reported now, after everything the app did, is the only new one.
  Future<void> expectNothingReported(WidgetTester tester, int before) async {
    await settle(tester);
    final sentinel = await capture(tester, StateError('sentinel'));
    expect(transport.events.skip(before), [sentinel]);
  }

  // Lets the timers of the Sentry SDK (app start, transactions) run out
  // before the test ends.
  Future<void> finish(WidgetTester tester) async {
    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
  }

  // The rest of main(): reporting in preview mode, the app's state bound to
  // the wrapper, and the app, on a phone in portrait (an iPhone 16 by
  // default).
  Future<void> startApp(
    WidgetTester tester, {
    Size size = const Size(393, 852),
  }) async {
    tester.view
      ..physicalSize = size * 3
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(
      () => CarpGlitchTip.init(ExampleReporting.previewOptions(transport)),
    );
    final state = appState = AppState(
      caws: CawsRepository(),
      network: server.network,
    );
    unbind = CarpGlitchTip.bindStudy(state, () => state.study);
    await tester.pumpWidget(
      GlitchTipExampleApp(state: state, outbox: transport),
    );
    await tester.pump();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text).hitTestable().first;
    await tester.ensureVisible(finder);
    await tester.pump(); // lays out the scrolled page
    await tester.tap(finder);
    await tester.pump();
  }

  Future<void> signIn(WidgetTester tester) async {
    await tapText(tester, 'Sign in as demo participant');
    await pumpUntil(
      tester,
      () =>
          find.byType(InvitationsScreen).evaluate().isNotEmpty &&
          state().invitations != null,
      reason: 'the invitations are shown',
    );
  }

  Finder scrollableOf(Type screen) => find
      .descendant(of: find.byType(screen), matching: find.byType(Scrollable))
      .first;

  // Scrolls the page of [screen] to its end and back, so all of it is laid
  // out and painted: a layout overflow is only reported when it is painted.
  Future<void> scrollThrough(WidgetTester tester, Type screen) async {
    final position = tester
        .state<ScrollableState>(scrollableOf(screen))
        .position;
    for (var i = 0; i < 50 && position.extentAfter > 0; i++) {
      position.jumpTo(
        math.min(
          position.pixels + position.viewportDimension * 0.8,
          position.maxScrollExtent,
        ),
      );
      await tester.pump();
    }
    expect(position.extentAfter, 0, reason: 'the end of $screen is reached');
    position.jumpTo(0);
    await tester.pump();
  }

  Future<void> tapAccept(WidgetTester tester, String study) async {
    await tester.scrollUntilVisible(
      find.text(study),
      200,
      scrollable: scrollableOf(InvitationsScreen),
    );
    final card = find.ancestor(
      of: find.text(study),
      matching: find.byType(M3ECard),
    );
    final button = find.descendant(
      of: card,
      matching: find.text('Accept invitation'),
    );
    await tester.ensureVisible(button);
    await tester.pump(); // lays out the scrolled page
    await tester.tap(button);
    await tester.pump();
  }

  Future<void> accept(WidgetTester tester, String study) async {
    await tapAccept(tester, study);
    await pumpUntil(
      tester,
      () => find.byType(HomeScreen).evaluate().isNotEmpty,
      reason: 'the study is shown once its protocol is loaded',
    );
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).hitTestable().last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  // Runs an action of the Try it tab and waits for its outcome.
  Future<void> run(WidgetTester tester, String demo, String button) async {
    final card = find.byKey(ValueKey('try-it-$demo'));
    await tester.scrollUntilVisible(
      card,
      200,
      scrollable: scrollableOf(TryItTab),
    );
    final tap = find.descendant(of: card, matching: find.text(button));
    await tester.ensureVisible(tap);
    await tester.pump();
    ActionOutcome? outcome() => find
        .descendant(of: card, matching: find.byType(OutcomeView))
        .evaluate()
        .map((element) => (element.widget as OutcomeView).outcome)
        .firstOrNull;
    // the outcome of a previous run stays until the new one is shown
    final previous = outcome();
    await tester.tap(tap);
    await tester.pump();
    await pumpUntil(tester, () {
      final current = outcome();
      return current != null && !identical(current, previous);
    }, reason: 'the outcome of $demo is shown');
  }

  Future<void> network(WidgetTester tester, String condition) async {
    await tapText(tester, condition);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'a report before sign-in has no study, but onboarding',
    inApp((tester) async {
      await startApp(tester);
      // main() runs the app in runZoned, so its clients record requests
      expect(CarpGlitchTip.status.httpInstrumented, isTrue);
      final event = await capture(tester, StateError('before sign-in'));
      expect(event.tags, containsPair(AppState.onboardingTag, 'signed_out'));
      expect(event.tags, isNot(contains(GlitchTipTags.studyDeploymentId)));
      expect(event.tags, isNot(contains(GlitchTipTags.studyId)));
      expect(event.contexts['study'], isNull);

      await signIn(tester);
      final signedIn = await capture(tester, StateError('signed in'));
      expect(signedIn.tags, containsPair(AppState.onboardingTag, 'signed_in'));
      expect(signedIn.tags, isNot(contains(GlitchTipTags.studyDeploymentId)));
      await finish(tester);
    }),
  );

  testWidgets(
    'a caught error carries the study and its protocol',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      expect(state().study, isNotNull);
      expect(CarpGlitchTip.study, state().study);

      await openTab(tester, 'Try it');
      final before = transport.events.length;
      await run(tester, 'caughtError', 'Report');
      await settle(tester);
      expect(transport.events, hasLength(before + 1));

      final event = transport.events.last;
      expect(event.exceptions?.last.type, 'CawsException');
      // describeError gives the CAWS error a readable text
      expect(
        event.exceptions?.last.value,
        'HTTP 400: The device with role name "Smartwatch" is not part of '
        'this study deployment.',
      );
      expect(event.tags, containsPair(GlitchTipTags.handled, 'yes'));
      expect(
        event.tags,
        containsPair(
          GlitchTipTags.studyId,
          '25a7225a-6c6f-4990-a7c0-8b1da3edb5b4',
        ),
      );
      expect(
        event.tags,
        containsPair(
          GlitchTipTags.studyDeploymentId,
          'bf19ced6-7ede-47a9-ad87-c83a6ac8c600',
        ),
      );
      expect(
        event.tags,
        containsPair(GlitchTipTags.deviceRole, 'Primary Phone'),
      );
      expect(
        event.tags,
        containsPair(GlitchTipTags.participantRole, 'Participant'),
      );
      expect(event.tags, containsPair(AppState.onboardingTag, 'enrolled'));
      expect(
        event.tags,
        containsPair('protocol', 'CAMS App - Demo Study Protocol'),
      );
      expect(event.tags, containsPair(GlitchTipTags.screen, '/study'));

      final study = event.contexts['study'] as Map;
      expect(study['protocol'], 'CAMS App - Demo Study Protocol');
      expect(study['study_name'], _cams);
      expect(study['tasks'], 16);
      expect(study['devices'], contains('eSense'));
      // the participant id and the user name are never reported
      expect('${event.tags} $study', isNot(contains('e128a946')));
      expect('${event.tags} $study', isNot(contains('demo.participant')));
      await finish(tester);
    }),
  );

  testWidgets(
    'a sync is recorded as a transaction',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      await openTab(tester, 'Try it');

      await run(tester, 'sync', 'Sync');
      await pumpUntil(
        tester,
        () => transport.transactions.any(
          (t) => t.transaction == TryItActions.syncTransaction,
        ),
        reason: 'the request is recorded',
      );
      final sync = transport.transactions.lastWhere(
        (t) => t.transaction == TryItActions.syncTransaction,
      );
      // reduced to what GlitchTip stores: name, operation and timing
      expect(sync.contexts.trace?.operation, 'http.client');
      expect(sync.tags, isNull);
      expect(find.textContaining('Uploaded in'), findsOneWidget);
      await finish(tester);
    }),
  );

  testWidgets(
    'a measured task is recorded as a transaction',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      await openTab(tester, 'Try it');

      await run(tester, 'measureTask', 'Measure');
      await pumpUntil(
        tester,
        () => transport.transactions.any(
          (t) => t.transaction == TryItActions.taskName,
        ),
        reason: 'the task is recorded',
      );
      expect(find.textContaining('Measured'), findsOneWidget);
      await finish(tester);
    }),
  );

  testWidgets(
    'syncing while offline reports nothing',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      await openTab(tester, 'Try it');
      await network(tester, 'Offline');

      final before = transport.events.length;
      // the app reports the error; the offline rule drops it
      await run(tester, 'sync', 'Sync');
      await expectNothingReported(tester, before);
      expect(find.text('Ignored: offline'), findsOneWidget);
      await finish(tester);
    }),
  );

  testWidgets(
    'syncing with a server error reports one HTTP 500',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      await openTab(tester, 'Try it');
      await network(tester, 'Error');

      final before = transport.events.length;
      await run(tester, 'sync', 'Sync');
      await pumpUntil(tester, () => transport.events.length > before);
      // the app's own report of the CawsException is dropped by its rule
      await expectNothingReported(tester, before + 1);
      final event = transport.events[before];
      expect(
        event.exceptions?.last.value,
        'HTTP 500: POST caws.example.org/api/data-stream-service '
        'AppendToDataStreams',
      );
      expect(
        event.tags,
        containsPair(GlitchTipTags.mechanism, 'CarpGlitchTipHttpClient'),
      );
      expect(event.tags, contains(GlitchTipTags.studyDeploymentId));
      expect(find.text('CAWS answered 500'), findsOneWidget);

      // the same failure again is counted, not reported again
      final again = transport.events.length;
      await run(tester, 'sync', 'Sync');
      await expectNothingReported(tester, again);
      await finish(tester);
    }),
  );

  testWidgets(
    'an invitation accepted offline attaches the study, reports nothing',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      state().networkCondition = NetworkCondition.offline;

      final before = transport.events.length;
      await tapAccept(tester, _cams);
      // the study is attached at once, while the request is still going
      expect(CarpGlitchTip.study, isNotNull);
      expect(CarpGlitchTip.study, state().study);
      expect(find.text('Could not load the protocol'), findsNothing);
      await pumpUntil(
        tester,
        () => find.text('Could not load the protocol').evaluate().isNotEmpty,
        reason: 'the error is shown',
      );
      // the app reports the error; the offline rule drops it
      await expectNothingReported(tester, before);
      // the study stays attached after the failure
      expect(
        transport.events.last.tags,
        contains(GlitchTipTags.studyDeploymentId),
      );
      // the card at the top of the page says so
      await tester.drag(scrollableOf(InvitationsScreen), const Offset(0, 2000));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('GlitchTip knows your study'), findsOneWidget);
      expect(find.text('GlitchTip does not know your study yet'), findsNothing);

      // leaving from here detaches it again
      await tapText(tester, 'Leave study');
      expect(state().study, isNull);
      expect(
        find.text('GlitchTip does not know your study yet'),
        findsOneWidget,
      );
      await finish(tester);
    }),
  );

  testWidgets(
    'an invitation accepted during a server error reports one HTTP 500',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      state().networkCondition = NetworkCondition.serverError;

      final before = transport.events.length;
      await tapAccept(tester, _cams);
      await pumpUntil(tester, () => transport.events.length > before);
      // the app's own report of the CawsException is dropped by its rule
      await expectNothingReported(tester, before + 1);
      final event = transport.events[before];
      expect(
        event.exceptions?.last.value,
        'HTTP 500: POST caws.example.org/api/deployment-service '
        'GetDeviceDeploymentFor',
      );
      expect(
        event.tags,
        containsPair(
          GlitchTipTags.studyDeploymentId,
          'bf19ced6-7ede-47a9-ad87-c83a6ac8c600',
        ),
      );
      expect(find.text('Could not load the protocol'), findsOneWidget);
      await finish(tester);
    }),
  );

  testWidgets(
    'the expected error is ignored, personal data is scrubbed',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      await openTab(tester, 'Try it');

      final before = transport.events.length;
      await run(tester, 'expectedError', 'Report');
      await expectNothingReported(tester, before);
      expect(find.text('Ignored by the app'), findsOneWidget);

      final scrubbed = transport.events.length;
      await run(tester, 'personalData', 'Report');
      await pumpUntil(tester, () => transport.events.length > scrubbed);
      final value = transport.events.last.exceptions?.last.value;
      expect(
        value,
        'Bad state: Upload for {email} failed: '
        'https://caws.example.org/api/files',
      );
      expect(value, isNot(contains('jane')));
      expect(value, isNot(contains('abc123')));
      await finish(tester);
    }),
  );

  testWidgets(
    'a detail screen is the screen tag, without its route arguments',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      await openTab(tester, 'Try it');

      final card = find.byKey(const ValueKey('try-it-openScreen'));
      await tester.scrollUntilVisible(
        card,
        200,
        scrollable: scrollableOf(TryItTab),
      );
      final open = find.descendant(of: card, matching: find.text('Open'));
      await tester.ensureVisible(open);
      await tester.pump();
      await tester.tap(open);
      await pumpUntil(
        tester,
        () => find.byType(TasksScreen).evaluate().isNotEmpty,
        reason: 'the tasks are shown',
      );
      await tester.pump(const Duration(seconds: 1));

      final event = await capture(tester, StateError('on the tasks screen'));
      expect(event.tags, containsPair(GlitchTipTags.screen, '/study/tasks'));
      final breadcrumbs = jsonEncode([
        for (final breadcrumb in event.breadcrumbs ?? const <Breadcrumb>[])
          breadcrumb.toJson(),
      ]);
      expect(breadcrumbs, contains('/study/tasks'));
      expect(breadcrumbs, isNot(contains('opened_from')));
      await finish(tester);
    }),
  );

  testWidgets(
    'the Reports tab shows what GlitchTip gets',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      await openTab(tester, 'Try it');
      await run(tester, 'caughtError', 'Report');
      await settle(tester);

      await openTab(tester, 'Reports');
      final report = find.text('CawsException').hitTestable();
      expect(report, findsOneWidget);
      await tester.tap(report);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ReportDetailScreen), findsOneWidget);
      expect(find.text('Tags'), findsOneWidget);
      await finish(tester);
    }),
  );

  testWidgets(
    'leaving the study removes it and its breadcrumbs from reports',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _cams);
      String breadcrumbs(SentryEvent event) => jsonEncode([
        for (final breadcrumb in event.breadcrumbs ?? const <Breadcrumb>[])
          breadcrumb.toJson(),
      ]);
      final enrolled = await capture(tester, StateError('enrolled'));
      expect(enrolled.tags, contains(GlitchTipTags.studyDeploymentId));
      expect(breadcrumbs(enrolled), contains('/api/deployment-service'));

      final leave = find.text('Leave study');
      await tester.scrollUntilVisible(
        leave,
        300,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      await tester.tap(leave);
      await pumpUntil(
        tester,
        () => find.byType(InvitationsScreen).evaluate().isNotEmpty,
      );
      expect(CarpGlitchTip.study, isNull);

      final left = await capture(tester, StateError('left'));
      expect(left.tags, isNot(contains(GlitchTipTags.studyDeploymentId)));
      expect(left.tags, isNot(contains('protocol')));
      expect(left.tags, containsPair(AppState.onboardingTag, 'signed_in'));
      expect(left.contexts['study'], isNull);
      // the requests made during the study are no longer breadcrumbs
      expect(breadcrumbs(left), isNot(contains('/api/deployment-service')));
      await finish(tester);
    }),
  );

  testWidgets(
    'accepting the family study reports its roles',
    inApp((tester) async {
      await startApp(tester);
      await signIn(tester);
      await accept(tester, _family);
      final event = await capture(tester, StateError('family'));
      expect(event.tags, containsPair(GlitchTipTags.participantRole, 'Mother'));
      expect(
        event.tags,
        containsPair(GlitchTipTags.deviceRole, "Mother's Phone"),
      );
      expect(
        event.tags,
        containsPair(
          GlitchTipTags.studyId,
          'd6d047d5-4cfd-479b-87ac-99f4b5fee172',
        ),
      );
      expect(event.tags, containsPair('protocol', 'Input Data Types'));
      await finish(tester);
    }),
  );

  testWidgets(
    'every screen fits a small phone with large text',
    inApp((tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // a layout overflow fails the test
      await startApp(tester, size: const Size(360, 740));
      await scrollThrough(tester, WelcomeScreen);
      await signIn(tester);
      await scrollThrough(tester, InvitationsScreen);
      await accept(tester, _cams);
      await scrollThrough(tester, StudyTab);
      final tasks = find.text('Show 16 tasks');
      await tester.scrollUntilVisible(
        tasks,
        200,
        scrollable: scrollableOf(HomeScreen),
      );
      await tester.ensureVisible(tasks);
      await tester.pump();
      await tester.tap(tasks);
      await pumpUntil(
        tester,
        () => find.byType(TasksScreen).evaluate().isNotEmpty,
      );
      await scrollThrough(tester, TasksScreen);
      // the app bar's back button
      await tester.tap(find.byType(BackButtonIcon));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await openTab(tester, 'Try it');
      await run(tester, 'caughtError', 'Report');
      await scrollThrough(tester, TryItTab);
      await openTab(tester, 'Reports');
      await scrollThrough(tester, ReportsTab);
      await tester.tap(find.text('CawsException').hitTestable().first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ReportDetailScreen), findsOneWidget);
      await scrollThrough(tester, ReportDetailScreen);
      await finish(tester);
    }),
  );
}
