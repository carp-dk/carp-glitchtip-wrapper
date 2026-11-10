## 0.1.0

* Initial release.
* `CarpGlitchTip.runZoned` and `CarpGlitchTip.init`: one way to start
  GlitchTip reporting in every CARP app, configured from `--dart-define`
  (`GLITCHTIP_DSN`, ...), with a status line printed at startup.
* Study metadata (`study_id`, `study_deployment_id`, `device_role`,
  `participant_role`) on every report from the moment the participant has
  accepted a study invitation, kept in sync with the app through `bindStudy`.
* Every `package:http` request recorded as a breadcrumb, a sampled GlitchTip
  transaction per endpoint and, when it fails, an error event; also inside
  CARP packages such as `carp_webservices`.
* Ignore rules (`IgnoreRule`, `IgnoreType`), with the network errors CARP
  packages throw while offline ignored by default.
* GlitchTip-compatible settings and a privacy policy for health research.
* `GlitchTipTestTransport` (`package:carp_glitchtip_wrapper/testing.dart`) for
  testing apps' rules.
* An example app (Material 3 Expressive) that goes through the CARP sign-in,
  invitation and study flow against a sample CAWS backend, and shows every
  report it would send.
