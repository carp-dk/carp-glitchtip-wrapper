# carp_glitchtip_wrapper example

A CARP study app that shows how an app uses [carp_glitchtip_wrapper](../README.md), and what it reports to GlitchTip. It talks to a sample CARP Web Services (CAWS) backend that runs inside the app, so it works without an account and without a network.

## What it shows

In most CARP apps, the study is only known after the participant has signed in and accepted a study invitation, and the protocol only after the study deployment has been loaded. The example goes through these steps and shows what GlitchTip gets at each one:

1. **Sign in.** A simulated OIDC sign-in at the sample CAWS. Reports carry no study yet; the app tag `onboarding` is `signed_out`, then `signed_in`.
2. **Invitations.** The participant's invitations, loaded from the sample CAWS in the CAWS JSON format. Accepting one attaches the study at once: `study_id`, `study_deployment_id`, `device_role` and `participant_role`.
3. **Study.** The protocol of the deployment is loaded and added to the study, as a `protocol` tag and with the study name, devices and task count in the `study` context. The *What GlitchTip sees* cards list the study's tags and context. Leaving the study removes it again, with the breadcrumbs recorded during it.
4. **Try it.** Switch the network of the sample CAWS and try what is reported and what is ignored: syncing data, a caught and an unhandled error, an error with an e-mail address and a token (both are scrubbed; other personal data, such as names, is not), an expected error (ignored by the app's rule), a measured task (a transaction) and navigation.
5. **Reports.** In preview mode, every report of the app as GlitchTip would get it, with its tags, `study` context, breadcrumbs and request.

The parts a CARP app copies:

| File | Contents |
|---|---|
| `lib/main.dart` | `CarpGlitchTip.runZoned` (with the sample CAWS as `innerClient`), `init` and `bindStudy` |
| `lib/src/reporting/example_reporting.dart` | The options of both reporting modes, the app's ignore rules and `describeError` |
| `lib/src/reporting/glitchtip_study.dart` | `toGlitchTip()`: from an accepted invitation and its protocol to `StudyMetadata` |
| `lib/src/state/app_state.dart` | The app state that is bound to the wrapper, like the BLoC of a CARP app. It reports every error it catches; the ignore rules drop the expected ones |

## Running it

The example needs Flutter 3.47 or later, as it uses the [`material_ui`](https://pub.dev/packages/material_ui) and [`material_3_expressive`](https://pub.dev/packages/material_3_expressive) packages for its Material 3 Expressive design.

**Preview mode** is what `flutter run` starts. Without a DSN, the example turns reporting on with a placeholder DSN and keeps the app's reports on the device, in a `GlitchTipTestTransport`; nothing is sent. The Reports tab shows them as GlitchTip would get them, after the wrapper's ignore rules and privacy policy. The native SDK starts as in live mode, so the reports carry its device contexts; its own reports, e.g. of native crashes, are not shown and go to the placeholder DSN, whose host (`glitchtip.invalid`) does not exist.

```sh
flutter run
```

**Live mode** starts when a DSN is defined. The example then reports like a real CARP app: everything comes from the env, and reporting is off in debug builds unless `GLITCHTIP_ENABLED=true` is set. Debug builds also record no transactions unless the sample rates are set. The status sheet (the icon in the app bar) shows the status line.

```sh
flutter run \
  --dart-define=GLITCHTIP_DSN=https://<key>@<glitchtip-host>/<project-id> \
  --dart-define=GLITCHTIP_ENABLED=true \
  --dart-define=GLITCHTIP_TRACES_SAMPLE_RATE=1 \
  --dart-define=GLITCHTIP_HTTP_SAMPLE_RATE=1
```

## The sample CAWS

`lib/src/caws/` contains a sample of CARP Web Services at `https://caws.example.org`, which runs in the app. Every `http.Client()` the app creates goes through the wrapper and then through this server, so its requests are recorded like real ones, e.g. as `POST caws.example.org/api/participation-service GetActiveParticipationInvitations`. It answers the sign-in and the `GetActiveParticipationInvitations`, `GetDeviceDeploymentFor` and `AppendToDataStreams` calls. For simplicity, `GetDeviceDeploymentFor` returns the protocol of the study.

The Try it tab switches its network condition:

| Condition | What the app gets | What GlitchTip gets |
|---|---|---|
| Online | An answer after 0.4 s | A breadcrumb and a transaction per request |
| Offline | `ClientException: Failed host lookup: 'caws.example.org'`, as on a phone without signal | A breadcrumb; the app reports the error, and the default offline rule drops it |
| Error | HTTP 500 | An `HTTP 500` error event from the wrapper's HTTP client, at most once per 10 minutes per request; the app's own report of the error is dropped by its rule |
| Slow | An answer after 2.5 s | Transactions that show the slow responses |

## Tests

```sh
flutter test
```

| Test | Covers |
|---|---|
| `test/app_flow_test.dart` | The whole flow, run like `main()` runs the app (in `CarpGlitchTip.runZoned`, with the preview options) and checked with `GlitchTipTestTransport`: the pattern for testing an app's GlitchTip integration. Also on a small phone with large text |
| `test/glitchtip_study_test.dart` | The `toGlitchTip()` mapping |
| `test/models_test.dart` | Parsing invitations and protocols |
| `test/sample_caws_test.dart` | The sample CAWS and its network conditions |

The screenshots of the package README are taken by an integration test, on a device or a simulator. It writes them to `build/screenshots/`; the README shows them from `../images/`, 600 pixels wide (on macOS, `sips` scales them):

```sh
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshots_test.dart -d <device>
for f in build/screenshots/*.png; do sips --resampleWidth 600 "$f" --out ../images/; done
```

## Sample data

The sample data comes from the tests of the public [CARP Mobile Sensing](https://github.com/carp-dk/carp.sensing-flutter) repository (MIT license):

* `assets/carp/protocols/cams_demo_protocol.json` is `apps/carp_mobile_sensing_app/test/json/study_protocol.json`.
* `assets/carp/protocols/family_protocol.json` is `backends/carp_webservices/test/json/family_input_data_protocol.json`.
* `assets/carp/invitations.json` is based on `backends/carp_webservices/test/json/invitations.json`.
