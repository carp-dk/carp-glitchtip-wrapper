// Unit tests of the mapping from the app's study to the wrapper's
// StudyMetadata, the part CARP apps copy.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper_example/src/models/participation_invitation.dart';
import 'package:carp_glitchtip_wrapper_example/src/models/study_protocol_summary.dart';
import 'package:carp_glitchtip_wrapper_example/src/reporting/glitchtip_study.dart';
import 'package:flutter_test/flutter_test.dart';

const _invitation = ActiveParticipationInvitation(
  studyDeploymentId: 'deployment-1',
  participantId: 'participant-secret',
  roleNames: ['Participant'],
  studyName: 'CAMS App - Demo Study',
  applicationData: {'studyId': 'study-1'},
  deviceRoleNames: ['Primary Phone'],
);

const _protocol = StudyProtocolSummary(
  name: 'CAMS App - Demo Study Protocol',
  primaryDevices: [ProtocolDevice(roleName: 'Primary Phone', type: 'Phone')],
  connectedDevices: [ProtocolDevice(roleName: 'eSense', type: 'ESense')],
  tasks: [
    ProtocolTask(name: 'Task #1', type: 'BackgroundTask'),
    ProtocolTask(name: 'Task #2', type: 'BackgroundTask'),
  ],
);

void main() {
  group('toGlitchTip', () {
    test('maps the invitation to the study ids and roles', () {
      final study = _invitation.toGlitchTip();
      expect(study.studyId, 'study-1');
      expect(study.studyDeploymentId, 'deployment-1');
      expect(study.deviceRoleName, 'Primary Phone');
      expect(study.participantRoleName, 'Participant');
      expect(study.toTags(), {
        GlitchTipTags.studyId: 'study-1',
        GlitchTipTags.studyDeploymentId: 'deployment-1',
        GlitchTipTags.deviceRole: 'Primary Phone',
        GlitchTipTags.participantRole: 'Participant',
      });
      expect(study.context, {'study_name': 'CAMS App - Demo Study'});
    });

    test('adds the protocol once it is loaded', () {
      final study = _invitation.toGlitchTip(protocol: _protocol);
      expect(study.tags, {protocolTag: 'CAMS App - Demo Study Protocol'});
      expect(study.toContext(), {
        'study_name': 'CAMS App - Demo Study',
        'protocol': 'CAMS App - Demo Study Protocol',
        'devices': ['Primary Phone', 'eSense'],
        'tasks': 2,
        'study_id': 'study-1',
        'study_deployment_id': 'deployment-1',
        'device_role': 'Primary Phone',
        'participant_role': 'Participant',
      });
      expect(studyTagKeys, containsAll(study.toTags().keys));
    });

    test('never reports the participant id', () {
      final study = _invitation.toGlitchTip(protocol: _protocol);
      final reported = '${study.toTags()} ${study.toContext()}';
      expect(reported, isNot(contains('participant-secret')));
    });

    test('works without a study id, roles or devices', () {
      const invitation = ActiveParticipationInvitation(
        studyDeploymentId: 'deployment-2',
        participantId: 'p',
      );
      expect(invitation.toGlitchTip().toTags(), {
        GlitchTipTags.studyDeploymentId: 'deployment-2',
      });
    });
  });
}
