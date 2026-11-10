## 0.1.1

* Fix testing initialisations: under `flutter test`, `CarpGlitchTip.runZoned` rethrows a startup failure without waiting for its report, so a failing widget test fails instead of hanging
* Fix `CarpGlitchTip.runZoned` on the web, where a startup failure was not rethrown
* Improve example app
* Update README

## 0.1.0

* `CarpGlitchTip.runZoned` and `CarpGlitchTip.init`: one way to start GlitchTip in CARP apps, configured from `--dart-define`
* Study metadata (`study_id`, `study_deployment_id`, `device_role`, `participant_role`) on reports
* `package:http` requests are recorded as breadcrumbs, sampled GlitchTip transactions and, when they fail, error events; also inside CARP packages such as `carp_webservices`
* Ignore rules (`IgnoreRule`, `IgnoreType`), with the network errors CARP packages throw while offline ignored by default
* `GlitchTipTestTransport` (`package:carp_glitchtip_wrapper/testing.dart`) for testing apps' rules
* See the example app for understanding how to integrate GlitchTip with CARP ecosystem
