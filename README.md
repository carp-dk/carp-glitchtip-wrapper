# CARP GlitchTip

Unified error and network-performance reporting to a self-hosted
[GlitchTip](https://glitchtip.com) server for CARP Flutter apps. GlitchTip
uses the Sentry protocol, so this package wraps the
[Sentry Flutter SDK](https://pub.dev/packages/sentry_flutter) and configures it
the same way in every app.

## Features

| Feature | What it does |
|---------|--------------|
| **Setup from env** | The DSN and every other setting come from `--dart-define` / `--dart-define-from-file` (`GLITCHTIP_DSN`, ...), so builds and CI decide where and whether to report. |
| **Study metadata** | Every report carries the environment, the release and the study (`study_id`, `study_deployment_id`, `device_role`) as searchable tags. |
| **Network performance** | Every request made with `package:http`, including those inside CARP packages such as `carp_webservices`, is recorded as a breadcrumb and, when sampled, as a GlitchTip transaction per endpoint (count, average, p50/p95 duration, error rate). |
| **Ignore expected errors** | The network errors CARP packages throw while the phone is offline ("Failed host lookup", ...) are ignored by default. Apps add their own rules. |
| **GlitchTip-ready, privacy-safe** | Settings GlitchTip needs (e.g. classic transactions instead of streamed spans) and a privacy policy for health research (no PII, no screenshots, scrubbed URLs, no participant device events) are applied by default. |

## Requirements

* Flutter ≥ 3.44 and Dart ≥ 3.12 (required by `sentry_flutter` 10).
* iOS apps must use [Swift Package Manager](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers):
  `sentry_flutter` 10 no longer supports CocoaPods.
* GlitchTip 6.2 or later is recommended.

## Getting started

Add the package to `pubspec.yaml`. It is the only dependency an app needs;
the Sentry types used by its API are re-exported.

```yaml
dependencies:
  carp_glitchtip_wrapper: ^0.1.0
```

Wrap the **whole** body of `main()` in `CarpGlitchTip.runZoned` and call
`CarpGlitchTip.init` in it:

```dart
import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';

Future<void> main() => CarpGlitchTip.runZoned(() async {
  WidgetsFlutterBinding.ensureInitialized(); // may stay, now a no-op
  await CarpGlitchTip.init(const CarpGlitchTipOptions());

  // ... the rest of the app's startup, unchanged
  runApp(const MyApp());
});
```

and pass the DSN of the GlitchTip project when building or running:

```shell
flutter run --dart-define=GLITCHTIP_DSN=https://<key>@<glitchtip-host>/<project-id>
```

`runZoned` creates the Flutter binding inside a zone in which every
`http.Client()` records its requests, also the clients `carp_webservices`
and the OIDC login create internally. **Nothing may run before it**: debug
builds assert that no binding was created earlier. Call `init` only from
`main()`, never from background entry points (WorkManager, push or
notification handlers): the native SDKs are shared by the whole process.

Reporting is **off in debug builds** unless `GLITCHTIP_ENABLED=true` is set,
so local development does not pollute GlitchTip, and off under `flutter test`
unless `enabled: true` is passed in code. At startup the wrapper prints one
status line, also in release builds (logcat / Xcode console):

```text
[CarpGlitchTip] enabled env=production release=... dsn=glitchtip.example.com/7 errors=1.0 traces=0.1 http=0.1
[CarpGlitchTip] DISABLED: debug build; set GLITCHTIP_ENABLED=true to report
```

If the Sentry SDK needs longer than `initTimeout` (5 s by default) to start,
`init` returns and prints `starting (after 5000 ms): env=...` instead. Errors
are already reported then; the `enabled` line follows once the SDK has
started, and from then on requests and traces are recorded too.

The same information is available as `CarpGlitchTip.status`, e.g. for an
about or debug screen.

## Configuration

### Env keys

| Key | Default | Meaning |
|-----|---------|---------|
| `GLITCHTIP_DSN` | – | The project DSN. Reporting is off without a valid one. Only `https` is accepted; debug builds also accept `http` for a server on the development machine (`localhost`, `127.0.0.1`, `10.0.2.2`). Falls back to `SENTRY_DSN`. |
| `GLITCHTIP_ENABLED` | `false` in debug, `true` otherwise | Turns reporting on or off. |
| `GLITCHTIP_ENVIRONMENT` | `deployment-mode`, else `production` | The environment. Debug and profile builds get a `-debug` / `-profile` suffix (e.g. `production-debug`). Falls back to `SENTRY_ENVIRONMENT`. |
| `GLITCHTIP_RELEASE` | `<package>@<version>+<build>` | The release. Falls back to `SENTRY_RELEASE`. |
| `GLITCHTIP_DIST` | the build number | The distribution. Falls back to `SENTRY_DIST`. |
| `GLITCHTIP_SAMPLE_RATE` | `1` | Share of error events sent. |
| `GLITCHTIP_TRACES_SAMPLE_RATE` | `0.1` in release, else `0` | Share of `CarpGlitchTip.trace` and app-start transactions sent. |
| `GLITCHTIP_HTTP_SAMPLE_RATE` | `0.1` in release, else `0` | Share of network requests recorded as transactions. |
| `GLITCHTIP_DEBUG` | SDK default | `true` prints the Sentry SDK's diagnostics. |

CARP's existing `deployment-mode` launch argument (`production`, `test`,
`dev`, ...) is used as the environment and added as the `deployment_mode`
tag. `debug-level` is not used.

### Precedence

Values in `CarpGlitchTipOptions` are the app's **defaults**; env keys
override them per build or at runtime:

1. `GLITCHTIP_*` key, then its `SENTRY_*` alias, from `CarpGlitchTipOptions.env`
   (e.g. the CARP debug toolkit's runtime overrides), then from
   `--dart-define`;
2. the value in `CarpGlitchTipOptions`;
3. a value derived by the wrapper (environment from `deployment-mode`);
4. the wrapper default.

`CarpGlitchTipOptions.configure` runs last and can change any other Sentry
option. Afterwards, the wrapper re-applies what GlitchTip and the privacy
policy depend on (see [Privacy](#privacy)).

### Runtime overrides (CARP debug toolkit, dotenv)

```dart
// neuropathy-app: DebugEnv overrides are loaded first, then read through the
// app's debugLaunchOverride hook, e.g. to switch GLITCHTIP_ENABLED on
if (kDebugMode) await debug.initializeDebugTools();
await CarpGlitchTip.init(CarpGlitchTipOptions(env: debugLaunchOverride));

// flutter_dotenv
await dotenv.load();
await CarpGlitchTip.init(
  CarpGlitchTipOptions(env: GlitchTipEnv.fromMap(dotenv.env)),
);
```

Any `String? Function(String key)` works as a source;
`GlitchTipEnv.chain([...])` combines several.

### Define files and CI

Keys work on the command line, in `.json` and in `.env` define files. CARP's
kebab-case keys (`deployment-mode`) are only valid in JSON files, so keep one
JSON file per deployment mode, e.g. `dart_defines/production.json`:

```json
{
  "deployment-mode": "production",
  "GLITCHTIP_DSN": "https://<key>@<glitchtip-host>/<project-id>"
}
```

```shell
flutter build appbundle --dart-define-from-file=dart_defines/production.json
```

Paths are relative to the project root, also when the command runs in `ios/`
or `android/`. A `--dart-define` given on the command line wins over files.

The DSN is not a secret (it is embedded in the app binary anyway), but keep it
out of public repositories. When it comes from a CI secret, make the build
fail instead of silently shipping without reporting. An **empty** define
overrides the value from a file:

```shell
# Xcode Cloud (ci_post_clone.sh) / any shell
: "${GLITCHTIP_DSN:?add GLITCHTIP_DSN as a secret variable}"
flutter build ios --config-only --dart-define="GLITCHTIP_DSN=$GLITCHTIP_DSN" ...
```

```yaml
# GitHub Actions
env:
  GLITCHTIP_DSN: ${{ secrets.GLITCHTIP_DSN }}
```

## Study metadata

Bind the study once; the wrapper re-reads it whenever the app's state changes
and whenever an error is reported:

```dart
extension on SmartphoneStudy {
  StudyMetadata toGlitchTip() => StudyMetadata(
    studyId: studyId,
    studyDeploymentId: studyDeploymentId,
    deviceRoleName: deviceRoleName,
  );
}

// after the app's BLoC exists (all CARP BLoCs are ChangeNotifiers)
CarpGlitchTip.bindStudy(bloc, () => bloc.study?.toGlitchTip());
```

Or set it explicitly with `CarpGlitchTip.setStudy(...)` /
`CarpGlitchTip.clearStudy()`. Leaving a study also clears the breadcrumbs
recorded during it. Values set before `init` are kept and applied at init.

Add other information with `CarpGlitchTip.setTags({...})` (searchable) and
`CarpGlitchTip.setContext('name', {...})` (shown on each report). Keys the
Sentry SDK or the wrapper own (`app`, `device`, `os`, `study`, ...) are
ignored. Tags and contexts are sent as given, so keep personal data out of
them.

Useful searches in GlitchTip:

| Search | Finds |
|--------|-------|
| `study_deployment_id:<id>` | everything from one participant's deployment |
| `study_id:<id>` | everything from one study |
| `handled:no` | errors the app did not catch |
| `build_mode:release` | only release builds |
| `deployment_mode:test` | only the test deployment |
| `screen:/tasks` | errors on one screen (needs `navigatorObserver()`) |

## Network performance

Inside `runZoned`, every request made with `package:http` is recorded:

* a **breadcrumb** (method, URL without query, status, duration);
* when sampled (`GLITCHTIP_HTTP_SAMPLE_RATE`), a **transaction** named after
  the request, e.g. `GET cans.cachet.dk/api/studies/{uuid}/files`. Ids in
  paths become placeholders, so GlitchTip groups the requests per endpoint.
  CARP Web Services RPC calls are named after their operation, e.g.
  `POST cans.cachet.dk/api/deployment-service GetStudyDeploymentStatus`;
* an **error event** when a request fails unexpectedly: a 5xx response, or an
  exception that is not ignored (e.g. a refused connection or a TLS error).
  The same failure is reported at most once per 10 minutes, so the 15
  retries of a `carp_webservices` call do not flood GlitchTip.

Recording never changes a request: the response or the original exception
reaches the caller unchanged.

```dart
await CarpGlitchTip.init(
  CarpGlitchTipOptions(
    http: HttpOptions(
      // hide secrets in paths (CAWS self-signup codes are always hidden)
      pathTemplates: [PathTemplate(RegExp(r'/invite/[^/]+'), '/invite/{code}')],
      excludeUrls: ['https://tiles.example.com'],
      isFailedStatus: (status) => status >= 500 || status == 429,
    ),
  ),
);
```

Time other work, e.g. the app's startup, with `trace`:

```dart
await CarpGlitchTip.trace('bloc.initialize', bloc.initialize);
```

Not recorded: requests made by native code (e.g. `flutter_appauth`), in other
isolates, and by clients created outside the zone (wrap those with
`CarpGlitchTip.httpClient(client)`). To use another HTTP client implementation
(e.g. `cupertino_http`), pass it as `runZoned(..., innerClient: ...)` instead of
an own `http.runWithClient` inside `main()`.

## Ignoring errors

By default, `CarpGlitchTipOptions.offlineErrors` ignores the transient network
failures CARP packages throw while the phone is offline: DNS failures ("Failed
host lookup", "nodename nor servname provided", "No address associated with
hostname"), an unreachable network ("Network is unreachable", "The Internet
connection appears to be offline"), reset or aborted connections, and request
timeouts. A bare `TimeoutException` (what `carp_webservices` throws after its
retries) is only ignored while the network looks offline, judged by the
recent requests. A refused connection (server down), TLS errors and HTTP
error responses are still reported, as is any error that stops the app from
starting.

Add the app's own rules:

```dart
await CarpGlitchTip.init(
  CarpGlitchTipOptions(
    ignoreErrors: [
      // by type, optionally narrowed by a typed predicate or a message
      IgnoreType<PlatformException>(where: (e) => e.code == 'discovery_failed'),
      // by message: String = contains, RegExp = hasMatch
      IgnoreRule.message('Location services are disabled'),
      // anything else
      IgnoreRule.custom((c) => c.isHttp && c.statusCode == 503),
      // only while the phone looks offline
      IgnoreType<TimeoutException>().whenOffline(),
    ],
    // CarpServiceException has no toString(); describe it for rules and titles
    describeError: (e) => e is CarpServiceException ? e.message : null,
  ),
);
```

To still see network failures while the phone is online, refine the default
rule with the app's connectivity state, or set it to `null` to report all of
them:

```dart
CarpGlitchTipOptions(offlineErrors: IgnoreRule.offline().when(() => !isOnline))
```

Native crashes and ANRs are reported by the native SDKs directly; Dart rules
do not apply to them.

## Navigation

Add an observer to every navigator, e.g. to `GoRouter(observers: [...])` and
to each `ShellRoute(observers: [...])`. Navigation is recorded as breadcrumbs
(route names only, never arguments) and the current route becomes the
`screen` tag. A route seen by several observers is recorded once.

```dart
GoRouter(observers: [CarpGlitchTip.navigatorObserver()], routes: [...]);
```

Use it instead of Sentry's own `SentryNavigatorObserver`. That observer binds
a transaction per route to the scope, and its name, route parameters included,
ends up in the header of every report (see Privacy).

## Privacy

The wrapper applies a privacy policy suitable for health research, also when
an app changes Sentry options through `configure`.

| Collected | Not collected |
|-----------|---------------|
| Errors with stack traces; exception messages with URLs normalised and tokens, e-mail and MAC addresses replaced | Personal data (`sendDefaultPii`), request bodies, headers, cookies |
| Study, deployment and device role ids (tags) | User names, e-mail addresses, account or participant ids; a random id per app launch replaces the user |
| Environment, release, build mode | The persistent installation id (Android) and vendor hash (iOS) on Dart events |
| OS, device model, locale, timezone, a snapshot of the device state (battery, charging, connection type, orientation) and, on Android, which permissions are granted | Screenshots, view hierarchy, session replay, accessibility settings |
| Request method, URL without query (ids and secrets replaced by placeholders), status, duration | Query strings, route arguments, JWTs, bearer tokens |
| Navigation and app lifecycle breadcrumbs | Log output (`debugPrint`), structured logs and metrics (unless an app sets `beforeSendLog` / `beforeSendMetric` in `configure`; their texts are then scrubbed and the user replaced), native device events (screen on/off, battery, connectivity) |

A study deployment id is a pseudonym of a participant: treat GlitchTip data as
pseudonymised personal data in the study's DPIA.

**Residual data.** Native crash, ANR and app-hang reports are created by the
native SDKs and never pass Dart code. They carry the scope (study tags, the
per-launch user) and the breadcrumbs above, but also:

* on Android, the device context with the persistent installation id;
* on iOS, the vendor hash in the app context;
* on Android, network breadcrumbs (network type, VPN, signal strength), unless
  the app turns them off in `android/app/src/main/AndroidManifest.xml`:

  ```xml
  <application ...>
    <meta-data
      android:name="io.sentry.breadcrumbs.network-events"
      android:value="false" />
  </application>
  ```

In the first moments of a launch, before `init` set the per-launch user, a
native report can also carry the installation id as user id.

The wrapper cannot change envelope headers either. The trace header of a
report carries the name of a transaction that the app binds to the scope
itself, e.g. through Sentry's `SentryNavigatorObserver`. The wrapper's own
transactions are never bound and have normalised names. So do not bind
transactions named after URLs or routes with parameters.

**Server checklist**

* Keep *Scrub IP addresses* on for the organisation and the project (GlitchTip
  stores the sender's IP, truncated, on every event).
* Set the event retention (`GLITCHTIP_EVENT_RETENTION_DAYS`) to what the DPIA
  allows, and restrict who is a member of the organisation.
* GlitchTip's performance view cannot filter by environment: use one project
  (DSN) per app and deployment mode, or keep `GLITCHTIP_HTTP_SAMPLE_RATE=0`
  outside production.
* Request transactions show up on the *Performance* page as one group per
  endpoint. Spans inside transactions are only stored when
  `GLITCHTIP_ENABLE_DUCKDB=true`; the wrapper does not need them.

## Testing

Reporting is off under `flutter test` unless `enabled: true` is passed in
code. To check an app's ignore rules, use the test transport:

```dart
import 'package:carp_glitchtip_wrapper/testing.dart';

late GlitchTipTestTransport transport;

setUp(() async {
  await CarpGlitchTip.resetForTest(); // init only works once otherwise
  transport = GlitchTipTestTransport();
  await CarpGlitchTip.init(CarpGlitchTipOptions(
    enabled: true,
    dsn: 'https://key@glitchtip.example.com/1',
    ignoreErrors: myRules,
    configure: (options) => options.transport = transport,
  ));
});
tearDown(CarpGlitchTip.resetForTest);

test('my rules drop expected errors only', () async {
  expect(CarpGlitchTip.isEnabled, isTrue);
  await CarpGlitchTip.captureException(StateError('a real bug'));
  await CarpGlitchTip.captureException(MyExpectedError());
  expect(transport.events, hasLength(1));
});
```

Events and transactions of HTTP requests are captured in the background, so
wait a moment before asserting on them.

## Migrating a CARP app

1. Raise the app's Flutter constraint (and CI) to ≥ 3.44 and move iOS to Swift
   Package Manager.
2. Wrap the existing body of `main()` in `CarpGlitchTip.runZoned` and call
   `CarpGlitchTip.init` after the debug toolkit loaded its overrides and
   before `bloc.initialize()`:

   ```dart
   Future<void> main() => CarpGlitchTip.runZoned(() async {
     WidgetsFlutterBinding.ensureInitialized();
     CarpMobileSensing.ensureInitialized();
     if (kDebugMode) await debug.initializeDebugTools();
     await CarpGlitchTip.init(CarpGlitchTipOptions(
       env: debugLaunchOverride,
       describeError: (e) => e is CarpServiceException ? e.message : null,
     ));
     CarpGlitchTip.bindStudy(bloc, () => bloc.study?.toGlitchTip());
     await CarpGlitchTip.trace('bloc.initialize', bloc.initialize);
     runApp(const App());
   });
   ```

3. Add `CarpGlitchTip.navigatorObserver()` to the router and its shell routes.
4. Turn off Android network breadcrumbs in the app's manifest (see
   [Privacy](#privacy)).
5. Pass `GLITCHTIP_DSN` in each build (define files or CI secret), and check
   the status line in the build log or the app's log.
