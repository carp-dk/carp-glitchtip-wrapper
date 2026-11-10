// Widget tests of the example's whole flow with GlitchTip's test transport:
// what is reported before sign-in, after accepting an invitation, for the
// network conditions of the sample CAWS and after leaving the study.
//
// The pattern for CARP apps: init the wrapper with `enabled: true` and a
// test transport, build the app widget with injected dependencies (main()
// cannot run under `flutter test`: its runZoned needs to create the
// binding), bind the study like main() does, and drive the app.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper_example/main.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/caws_repository.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_client.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_server.dart';
import 'package:carp_glitchtip_wrapper_example/src/reporting/example_reporting.dart';
import 'package:carp_glitchtip_wrapper_example/src/reporting/report_outbox.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/home_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/invitations_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/report_detail_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/try_it_tab.dart';
import 'package:carp_glitchtip_wrapper_example/src/state/app_state.dart';
import 'package:carp_glitchtip_wrapper_example/src/widgets/outcome_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

const _cams = 'CAMS App - Demo Study';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SampleCawsData data;
  late ReportOutbox transport;
  late SampleCawsServer server;
  late AppState state;
  late VoidCallback unbind;

  setUpAll(() async => data = await SampleCawsData.load(rootBundle));

  setUp(() async {
    await CarpGlitchTip.resetForTest(); // init only works once otherwise
    // a GlitchTipTestTransport that also notifies the Reports tab
    transport = ReportOutbox();
    await CarpGlitchTip.init(
      CarpGlitchTipOptions(
        enabled: true, // reporting is off under flutter test otherwise
        dsn: 'https://key@glitchtip.example.com/1',
        ignoreErrors: ExampleReporting.ignoreErrors,
        describeError: ExampleReporting.describeError,
        configure: (o) => o
          ..transport = transport
          ..autoInitializeNativeSdk = false,
      ),
    );

    server = SampleCawsServer(
      data: () async => data,
      latency: const Duration(milliseconds: 100),
    );
    // main() lets runZoned instrument every http.Client(); here the
    // repository gets instrumented clients directly
    state = AppState(
      caws: CawsRepository(
        client: () => CarpGlitchTip.httpClient(SampleCawsClient(server)),
      ),
      network: server.network,
    );
    unbind = CarpGlitchTip.bindStudy(state, () => state.study);
  });

  tearDown(() async {
    unbind();
    state.dispose();
    await CarpGlitchTip.resetForTest();
  });

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
  // time to finish, so a test can check that nothing more arrived.
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

  // Lets the Sentry SDK's app start tracking, which starts timers after the
  // first frame, run out before the test ends.
  Future<void> finish(WidgetTester tester) async {
    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
  }

  Future<void> startApp(WidgetTester tester) async {
    // a phone in portrait, e.g. an iPhone 16
    tester.view
      ..physicalSize = const Size(1179, 2556)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
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
      () => find.text(_cams).evaluate().isNotEmpty,
      reason: 'the invitations are shown',
    );
  }

  Future<void> accept(WidgetTester tester, String study) async {
    await tester.scrollUntilVisible(
      find.text(study),
      200,
      scrollable: find
          .descendant(
            of: find.byType(InvitationsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
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
      scrollable: find
          .descendant(
            of: find.byType(TryItTab),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final tap = find.descendant(of: card, matching: find.text(button));
    await tester.ensureVisible(tap);
    await tester.pump();
    await tester.tap(tap);
    await tester.pump();
    await pumpUntil(
      tester,
      () => find
          .descendant(of: card, matching: find.byType(OutcomeView))
          .evaluate()
          .isNotEmpty,
      reason: 'the outcome of $demo is shown',
    );
  }

  Future<void> network(WidgetTester tester, String condition) async {
    await tapText(tester, condition);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a report before sign-in has no study, but onboarding', (
    tester,
  ) async {
    await startApp(tester);
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
  });

  testWidgets('a caught error carries the study and its protocol', (
    tester,
  ) async {
    await startApp(tester);
    await signIn(tester);
    await accept(tester, _cams);
    expect(
      CarpGlitchTip.study?.studyDeploymentId,
      state.study?.studyDeploymentId,
    );

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
      'HTTP 400: The device with role name "Smartwatch" is not part of this '
      'study deployment.',
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
    expect(event.tags, containsPair(GlitchTipTags.deviceRole, 'Primary Phone'));
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
  });

  testWidgets('syncing while offline reports nothing', (tester) async {
    await startApp(tester);
    await signIn(tester);
    await accept(tester, _cams);
    await openTab(tester, 'Try it');
    await network(tester, 'Offline');

    final before = transport.events.length;
    await run(tester, 'sync', 'Sync');
    await settle(tester);
    expect(transport.events, hasLength(before));
    expect(find.text('No connection'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('syncing with a server error reports one HTTP 500', (
    tester,
  ) async {
    await startApp(tester);
    await signIn(tester);
    await accept(tester, _cams);
    await openTab(tester, 'Try it');
    await network(tester, 'Error');

    final before = transport.events.length;
    await run(tester, 'sync', 'Sync');
    await pumpUntil(tester, () => transport.events.length > before);
    await settle(tester);
    final events = transport.events.skip(before).toList();
    expect(events, hasLength(1));
    expect(
      events.single.exceptions?.last.value,
      'HTTP 500: POST caws.example.org/api/data-stream-service '
      'AppendToDataStreams',
    );
    expect(
      events.single.tags,
      containsPair(GlitchTipTags.mechanism, 'CarpGlitchTipHttpClient'),
    );
    expect(events.single.tags, contains(GlitchTipTags.studyDeploymentId));

    // the same failure again is counted, not reported again
    await run(tester, 'sync', 'Sync');
    await settle(tester);
    expect(transport.events, hasLength(before + 1));
    await finish(tester);
  });

  testWidgets('the expected error is ignored, personal data is scrubbed', (
    tester,
  ) async {
    await startApp(tester);
    await signIn(tester);
    await accept(tester, _cams);
    await openTab(tester, 'Try it');

    final before = transport.events.length;
    await run(tester, 'expectedError', 'Report');
    await settle(tester);
    expect(transport.events, hasLength(before));
    expect(find.text('Ignored by the app'), findsOneWidget);

    await run(tester, 'personalData', 'Report');
    await pumpUntil(tester, () => transport.events.length > before);
    final value = transport.events.last.exceptions?.last.value;
    expect(
      value,
      'Bad state: Upload for {email} failed: '
      'https://caws.example.org/api/files',
    );
    expect(value, isNot(contains('jane')));
    expect(value, isNot(contains('abc123')));
    await finish(tester);
  });

  testWidgets('the Reports tab shows what GlitchTip gets', (tester) async {
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
  });

  testWidgets('leaving the study removes it from reports', (tester) async {
    await startApp(tester);
    await signIn(tester);
    await accept(tester, _cams);
    final enrolled = await capture(tester, StateError('enrolled'));
    expect(enrolled.tags, contains(GlitchTipTags.studyDeploymentId));

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
    await finish(tester);
  });

  testWidgets('accepting the family study reports its roles', (tester) async {
    await startApp(tester);
    await signIn(tester);
    await accept(tester, 'Family Study w. Participant Data');
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
  });
}
