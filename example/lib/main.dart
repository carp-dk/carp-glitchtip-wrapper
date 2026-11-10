// Contains the entry point of the carp_glitchtip_wrapper example: a CARP
// study app that reports its errors and requests to GlitchTip.
//
// Parts:
// - `main`, which runs the app in the wrapper's zone, starts reporting in
//   preview or live mode and binds the study to the app's state.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import 'src/app/example_app.dart';
import 'src/caws/caws_repository.dart';
import 'src/caws/sample_caws_client.dart';
import 'src/caws/sample_caws_server.dart';
import 'src/reporting/example_reporting.dart';
import 'src/reporting/report_outbox.dart';
import 'src/state/app_state.dart';

export 'src/app/example_app.dart';

/// Starts the example.
///
/// The whole body runs in `CarpGlitchTip.runZoned`, so every
/// `http.Client()` of the app (and of packages such as carp_webservices)
/// records its requests. Here every client also goes to the in-process
/// sample CAWS at https://caws.example.org, so the example works offline.
Future<void> main() {
  final caws = SampleCawsServer(data: () => SampleCawsData.load(rootBundle));

  return CarpGlitchTip.runZoned(
    () async {
      // Preview mode (no GLITCHTIP_DSN): reports stay on the device, in the
      // outbox the Reports tab shows. Live mode: the env decides.
      final outbox = switch (ExampleReporting.mode) {
        ReportingMode.preview => ReportOutbox(),
        ReportingMode.live => null,
      };
      await CarpGlitchTip.init(
        outbox == null
            ? ExampleReporting.liveOptions()
            : ExampleReporting.previewOptions(outbox),
      );

      // like a CARP app's BLoC: the study is only known after signing in
      // and accepting an invitation
      final state = AppState(caws: CawsRepository(), network: caws.network);
      CarpGlitchTip.bindStudy(state, () => state.study);

      runApp(GlitchTipExampleApp(state: state, outbox: outbox));
    },
    // called for every http.Client(); requests to other hosts (e.g. the
    // GlitchTip server in live mode) go to the default client
    innerClient: () => SampleCawsClient(caws, http.Client()),
  );
}
