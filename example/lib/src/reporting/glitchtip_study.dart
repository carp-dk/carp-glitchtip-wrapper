// Contains the mapping from the app's study to the wrapper's StudyMetadata.
//
// Parts:
// - `InvitationGlitchTip`, the `toGlitchTip()` extension CARP apps copy.
// - `studyTagKeys`, the tags a study adds to every report.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';

import '../models/participation_invitation.dart';
import '../models/study_protocol_summary.dart';

/// The tag GlitchTip can search for the protocol of the study, e.g.
/// `protocol:"CAMS App - Demo Study Protocol"`.
const protocolTag = 'protocol';

/// The tags a study adds to every report: the wrapper's study tags and the
/// app's [protocolTag].
const studyTagKeys = {
  GlitchTipTags.studyId,
  GlitchTipTags.studyDeploymentId,
  GlitchTipTags.deviceRole,
  GlitchTipTags.participantRole,
  protocolTag,
};

/// The study of an accepted invitation, as GlitchTip should see it.
///
/// In most CARP apps the study is only known after the participant signed in
/// and accepted an invitation: the invitation gives the ids and roles at
/// once, the protocol of the deployment is loaded afterwards.
extension InvitationGlitchTip on ActiveParticipationInvitation {
  /// The study of this invitation, with the information of its [protocol]
  /// once it is loaded.
  ///
  /// Never put the participant id or the user name here: a study deployment
  /// id is already a pseudonym of the participant.
  StudyMetadata toGlitchTip({StudyProtocolSummary? protocol}) => StudyMetadata(
    studyId: studyId,
    studyDeploymentId: studyDeploymentId,
    deviceRoleName: deviceRoleName,
    participantRoleName: participantRoleName,
    // searchable: only a few values with a low cardinality
    tags: {protocolTag: ?protocol?.name},
    // shown on every report, not searchable; plain values, no lists: the
    // wrapper compares studies with mapEquals, which compares lists by
    // identity, and would update its scope for every new mapping
    context: {
      'study_name': ?studyName,
      if (protocol != null) ...{
        'protocol': protocol.name,
        'devices': [for (final device in protocol.devices) device.roleName]
            .join(', '),
        'tasks': protocol.taskCount,
      },
    },
  );
}
