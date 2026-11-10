import 'package:flutter/foundation.dart';

import 'glitchtip_tags.dart';

/// The CARP study an app is running, attached to every error report.
///
/// The ids become searchable tags ([GlitchTipTags]); everything is also shown
/// in a `study` context on each event.
///
/// In most CARP apps the study is only known after the participant has
/// signed in and accepted a study invitation. Until then, reports have no
/// study tags; keep the metadata in sync with `CarpGlitchTip.bindStudy`.
/// The values mirror carp_core's `ActiveParticipationInvitation` and CAMS'
/// `SmartphoneStudy`:
///
/// ```dart
/// extension on ActiveParticipationInvitation {
///   StudyMetadata toGlitchTip() => StudyMetadata(
///     studyId: studyId,
///     studyDeploymentId: studyDeploymentId,
///     deviceRoleName: deviceRoleName,
///     participantRoleName: participantRoleName,
///   );
/// }
/// ```
///
/// Information that comes later, e.g. from the protocol of the deployment,
/// can be added as [tags] (searchable) or [context] (shown on each event).
/// Note that a study deployment id is a pseudonym of a participant: treat
/// GlitchTip data as pseudonymised personal data.
@immutable
final class StudyMetadata {
  /// Creates the metadata of a study deployment.
  const StudyMetadata({
    this.studyId,
    required this.studyDeploymentId,
    this.deviceRoleName,
    this.participantRoleName,
    this.tags = const {},
    this.context = const {},
  });

  /// The id of the study, if known.
  final String? studyId;

  /// The id of the study deployment this device is part of.
  final String studyDeploymentId;

  /// The role of this device in the study deployment, e.g. `Primary phone`.
  final String? deviceRoleName;

  /// The role of the participant in the study deployment, e.g.
  /// `Participant`, or `Mother` in a family study.
  final String? participantRoleName;

  /// Extra searchable tags for this study, removed again with the study.
  final Map<String, String> tags;

  /// Extra values shown in the `study` context (not searchable). Do not put
  /// direct identifiers here (names, e-mail addresses, participant ids).
  final Map<String, Object?> context;

  /// The tags this study adds to every event.
  Map<String, String> toTags() => {
    ...tags,
    GlitchTipTags.studyId: ?studyId,
    GlitchTipTags.studyDeploymentId: studyDeploymentId,
    GlitchTipTags.deviceRole: ?deviceRoleName,
    GlitchTipTags.participantRole: ?participantRoleName,
  };

  /// The `study` context this study adds to every event.
  Map<String, Object?> toContext() => {
    ...context,
    'study_id': ?studyId,
    'study_deployment_id': studyDeploymentId,
    'device_role': ?deviceRoleName,
    'participant_role': ?participantRoleName,
  };

  @override
  bool operator ==(Object other) =>
      other is StudyMetadata &&
      other.studyId == studyId &&
      other.studyDeploymentId == studyDeploymentId &&
      other.deviceRoleName == deviceRoleName &&
      other.participantRoleName == participantRoleName &&
      mapEquals(other.tags, tags) &&
      mapEquals(other.context, context);

  @override
  int get hashCode => Object.hash(
    studyId,
    studyDeploymentId,
    deviceRoleName,
    participantRoleName,
    Object.hashAllUnordered(
      tags.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(context.keys),
  );

  @override
  String toString() =>
      'StudyMetadata(studyId: $studyId, '
      'studyDeploymentId: $studyDeploymentId, '
      'deviceRoleName: $deviceRoleName, '
      'participantRoleName: $participantRoleName)';
}
