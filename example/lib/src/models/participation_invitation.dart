// Contains the study invitations a participant gets from CAWS.
//
// Parts:
// - `ActiveParticipationInvitation`, a tolerant parser of the CAWS JSON with
//   the getters of carp_core's class of the same name.

import 'dart:convert';

import 'json.dart';

/// An invitation to participate in a study deployment, as returned by the
/// CAWS participation service (`GetActiveParticipationInvitations`).
///
/// A small stand-in for carp_core's `ActiveParticipationInvitation` with the
/// same getters, so the code that maps it to GlitchTip looks the same in a
/// real CARP app. Unknown fields are ignored.
class ActiveParticipationInvitation {
  /// Creates an invitation.
  const ActiveParticipationInvitation({
    required this.studyDeploymentId,
    required this.participantId,
    this.roleNames,
    this.studyName,
    this.studyDescription,
    this.applicationData,
    this.deviceRoleNames,
  });

  /// Parses one invitation of the CAWS JSON format. Throws a
  /// [FormatException] when the deployment or participant id is missing.
  factory ActiveParticipationInvitation.fromJson(Map<String, Object?> json) {
    final participation = json.object('participation');
    final invitation = json.object('invitation');
    final studyDeploymentId = participation?.string('studyDeploymentId');
    final participantId = participation?.string('participantId');
    if (studyDeploymentId == null || participantId == null) {
      throw const FormatException(
        'An invitation needs a studyDeploymentId and a participantId',
      );
    }
    return ActiveParticipationInvitation(
      studyDeploymentId: studyDeploymentId,
      participantId: participantId,
      roleNames: participation?.object('assignedRoles')?.strings('roleNames'),
      studyName: invitation?.string('name'),
      studyDescription: invitation?.string('description'),
      applicationData: invitation?['applicationData'],
      deviceRoleNames: [
        for (final assigned in json.objects('assignedDevices'))
          ?assigned.object('device')?.string('roleName'),
      ],
    );
  }

  /// Parses the response of `GetActiveParticipationInvitations`: a JSON list
  /// of invitations.
  static List<ActiveParticipationInvitation> listFromJson(String body) {
    final json = jsonDecode(body);
    if (json is! List) {
      throw const FormatException('Expected a list of invitations');
    }
    return [
      for (final item in json)
        if (item is Map<String, Object?>)
          ActiveParticipationInvitation.fromJson(item),
    ];
  }

  /// The id of the study deployment the participant is invited to.
  final String studyDeploymentId;

  /// The id of the participant in the deployment. A direct identifier of
  /// the participant: never report it.
  final String participantId;

  /// The roles the participant is assigned to, or `null` when assigned to
  /// all roles.
  final List<String>? roleNames;

  /// The name of the study, shown to the participant.
  final String? studyName;

  /// The description of the study, shown to the participant.
  final String? studyDescription;

  /// What the study's app needs to know, set by the researcher: the study id
  /// as a plain string, or a map with a `studyId`.
  final Object? applicationData;

  /// The role names of the devices the participant is invited to use.
  final List<String>? deviceRoleNames;

  /// The id of the study, from [applicationData] (a plain string, or the
  /// `studyId` of a map), or `null` when it has none.
  String? get studyId => switch (applicationData) {
    final String id when id.isNotEmpty => id,
    {'studyId': final String id} when id.isNotEmpty => id,
    _ => null,
  };

  /// The role name of the first device the participant is invited to use.
  String? get deviceRoleName => deviceRoleNames?.firstOrNull;

  /// The first role of the participant; `null` when assigned to all roles.
  String? get participantRoleName => roleNames?.firstOrNull;

  @override
  String toString() =>
      'ActiveParticipationInvitation($studyName, '
      'studyDeploymentId: $studyDeploymentId)';
}
