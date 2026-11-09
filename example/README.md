# CARP GlitchTip example

A small app showing how a CARP app reports to GlitchTip with
`carp_glitchtip_wrapper`: startup in `main()`, a study bound to the app's
state, navigation breadcrumbs, recorded network requests and ignored errors.

Reporting is off in debug builds unless it is turned on, so run it with the
DSN of a GlitchTip project:

```shell
flutter run \
  --dart-define=GLITCHTIP_DSN=https://<key>@<glitchtip-host>/<project-id> \
  --dart-define=GLITCHTIP_ENABLED=true \
  --dart-define=GLITCHTIP_HTTP_SAMPLE_RATE=1 \
  --dart-define=deployment-mode=dev
```
