// Drives the example in preview mode on a device or simulator and takes the
// screenshots of the package README: welcome, invitations, study, Try it,
// reports and a report.
//
// flutter drive --driver=test_driver/integration_test.dart \
//   --target=integration_test/screenshots_test.dart -d <device>
//
// The screenshots are written to build/screenshots/.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper_example/main.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/caws_repository.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_client.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_server.dart';
import 'package:carp_glitchtip_wrapper_example/src/reporting/example_reporting.dart';
import 'package:carp_glitchtip_wrapper_example/src/reporting/report_outbox.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/home_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/report_detail_screen.dart';
import 'package:carp_glitchtip_wrapper_example/src/screens/try_it_tab.dart';
import 'package:carp_glitchtip_wrapper_example/src/state/app_state.dart';
import 'package:carp_glitchtip_wrapper_example/src/state/try_it_actions.dart';
import 'package:carp_glitchtip_wrapper_example/src/widgets/outcome_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

const _cams = 'CAMS App - Demo Study';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Waits in real time until [condition] holds; loading indicators animate
  // forever, so pumpAndSettle would not return.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() condition, {
    String? reason,
  }) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('Timed out: $reason');
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // Lets animations (springs, ripples, morphs) run for [time].
  Future<void> idle(WidgetTester tester, [int milliseconds = 1200]) async {
    final end = DateTime.now().add(Duration(milliseconds: milliseconds));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    await idle(tester);
    await binding.takeScreenshot(name);
  }

  // Runs an action of the Try it tab and waits for its outcome.
  Future<void> run(WidgetTester tester, String demo, String button) async {
    final card = find.byKey(ValueKey('try-it-$demo'));
    await tester.scrollUntilVisible(
      card,
      300,
      scrollable: find
          .descendant(
            of: find.byType(TryItTab),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    ActionOutcome? outcome() => find
        .descendant(of: card, matching: find.byType(OutcomeView))
        .evaluate()
        .map((element) => (element.widget as OutcomeView).outcome)
        .firstOrNull;
    final before = outcome();
    await tap(tester, find.descendant(of: card, matching: find.text(button)));
    await waitFor(tester, () {
      final now = outcome();
      return now != null && !identical(now, before);
    }, reason: 'the outcome of $demo');
    await idle(tester, 600);
  }

  Future<void> network(WidgetTester tester, String condition) async {
    await tap(tester, find.text(condition).hitTestable().first);
    await idle(tester, 600);
  }

  testWidgets('screenshots of the flow in preview mode', (tester) async {
    final server = SampleCawsServer(
      data: () => SampleCawsData.load(rootBundle),
    );
    // the wiring of main(), with pumpWidget instead of runApp; the test body
    // runs in the zone, so the app's taps create instrumented clients
    await CarpGlitchTip.runZoned(() async {
      final outbox = ReportOutbox();
      await CarpGlitchTip.init(ExampleReporting.previewOptions(outbox));
      final state = AppState(caws: CawsRepository(), network: server.network);
      CarpGlitchTip.bindStudy(state, () => state.study);
      await tester.pumpWidget(
        GlitchTipExampleApp(state: state, outbox: outbox),
      );

      // 1. welcome; a test report before sign-in has no study
      await idle(tester, 2500); // the logo is decoded in the background
      await screenshot(tester, '01_welcome');
      await CarpGlitchTip.captureMessage('Test report while signed_out');

      // 2. sign in: the invitations from the sample CAWS
      await tap(tester, find.text('Sign in as demo participant'));
      await waitFor(
        tester,
        () => find.text(_cams).evaluate().isNotEmpty,
        reason: 'the invitations',
      );
      await screenshot(tester, '02_invitations');

      // 3. accept the CAMS demo study: attached, then enriched
      final card = find.ancestor(
        of: find.text(_cams),
        matching: find.byType(M3ECard),
      );
      await tap(
        tester,
        find.descendant(of: card, matching: find.text('Accept invitation')),
      );
      await waitFor(
        tester,
        () => find.byType(HomeScreen).evaluate().isNotEmpty,
        reason: 'the study',
      );
      await screenshot(tester, '03_study');

      // 4. Try it: a 500, an ignored offline sync, a caught error, a
      // trace and a sync that is recorded as a transaction
      await tap(tester, find.text('Try it').hitTestable().last);
      await idle(tester, 600);
      await network(tester, 'Error');
      await run(tester, 'sync', 'Sync');
      await network(tester, 'Offline');
      await run(tester, 'sync', 'Sync');
      await network(tester, 'Online');
      await run(tester, 'measureTask', 'Measure');
      await run(tester, 'caughtError', 'Report');
      await run(tester, 'sync', 'Sync');
      await tester.drag(
        find
            .descendant(
              of: find.byType(TryItTab),
              matching: find.byType(Scrollable),
            )
            .first,
        const Offset(0, 4000),
      );
      await screenshot(tester, '04_try_it');

      // 5. the reports, newest first
      await tap(tester, find.text('Reports').hitTestable().last);
      await screenshot(tester, '05_reports');

      // 6. the caught error, with the study tags highlighted
      await tap(tester, find.text('CawsException').hitTestable().first);
      await waitFor(
        tester,
        () => find.byType(ReportDetailScreen).evaluate().isNotEmpty,
        reason: 'the report',
      );
      await screenshot(tester, '06_report_detail');
    }, innerClient: () => SampleCawsClient(server, http.Client()));
  });
}
