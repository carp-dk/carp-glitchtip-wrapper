// Unit tests of the sample data models: invitations in the CAWS JSON format
// and the summary of the bundled study protocols.

import 'dart:convert';

import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_server.dart';
import 'package:carp_glitchtip_wrapper_example/src/models/participation_invitation.dart';
import 'package:carp_glitchtip_wrapper_example/src/models/study_protocol_summary.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _invitation({
  Object? applicationData,
  List<String>? roleNames = const ['Mother'],
  Object? assignedDevices = const [
    {
      'device': {
        '__type': 'dk.cachet.carp.common.application.devices.Smartphone',
        'roleName': "Mother's Phone",
        'isPrimaryDevice': true,
      },
    },
  ],
}) => {
  'participation': {
    'studyDeploymentId': 'd1',
    'participantId': 'p1',
    'assignedRoles': {
      '__type': roleNames == null
          ? 'dk.cachet.carp.common.application.users.AssignedTo.All'
          : 'dk.cachet.carp.common.application.users.AssignedTo.Roles',
      'roleNames': ?roleNames,
    },
  },
  'invitation': {
    'name': 'Family Study',
    'description': 'A family study',
    'applicationData': ?applicationData,
    'someFutureField': 42,
  },
  'assignedDevices': ?assignedDevices,
  'unknown': {'ignored': true},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ActiveParticipationInvitation', () {
    test('reads the study id from plain string application data', () {
      final invitation = ActiveParticipationInvitation.fromJson(
        _invitation(applicationData: 'study-1'),
      );
      expect(invitation.studyId, 'study-1');
    });

    test('reads the study id from map application data', () {
      final invitation = ActiveParticipationInvitation.fromJson(
        _invitation(applicationData: {'studyId': 'study-2', 'other': 1}),
      );
      expect(invitation.studyId, 'study-2');
    });

    test('has no study id without usable application data', () {
      for (final data in [
        null,
        '',
        7,
        <String, Object?>{},
        {'id': 'x'},
      ]) {
        final invitation = ActiveParticipationInvitation.fromJson(
          _invitation(applicationData: data),
        );
        expect(invitation.studyId, isNull, reason: '$data');
      }
    });

    test('has the getters of carp_core', () {
      final invitation = ActiveParticipationInvitation.fromJson(
        _invitation(applicationData: 'study-1'),
      );
      expect(invitation.studyDeploymentId, 'd1');
      expect(invitation.participantId, 'p1');
      expect(invitation.studyName, 'Family Study');
      expect(invitation.studyDescription, 'A family study');
      expect(invitation.participantRoleName, 'Mother');
      expect(invitation.deviceRoleName, "Mother's Phone");
    });

    test('tolerates missing roles and devices', () {
      final invitation = ActiveParticipationInvitation.fromJson(
        _invitation(roleNames: null, assignedDevices: null),
      );
      expect(invitation.participantRoleName, isNull);
      expect(invitation.deviceRoleName, isNull);
    });

    test('needs a deployment and a participant id', () {
      expect(
        () => ActiveParticipationInvitation.fromJson(const {'invitation': {}}),
        throwsFormatException,
      );
    });

    test('parses the bundled invitations', () async {
      final json = await rootBundle.loadString(SampleCawsData.invitationsAsset);
      final invitations = ActiveParticipationInvitation.listFromJson(json);
      expect(invitations, hasLength(2));

      final [cams, family] = invitations;
      expect(cams.studyName, 'CAMS App - Demo Study');
      expect(cams.studyId, '25a7225a-6c6f-4990-a7c0-8b1da3edb5b4');
      expect(cams.studyDeploymentId, 'bf19ced6-7ede-47a9-ad87-c83a6ac8c600');
      expect(cams.participantRoleName, 'Participant');
      expect(cams.deviceRoleName, 'Primary Phone');

      // the family study has its study id in a map
      expect(family.studyId, 'd6d047d5-4cfd-479b-87ac-99f4b5fee172');
      expect(family.participantRoleName, 'Mother');
      expect(family.deviceRoleName, "Mother's Phone");

      // every deployment has a bundled protocol
      for (final invitation in invitations) {
        expect(
          SampleCawsData.protocolAssets,
          contains(invitation.studyDeploymentId),
        );
      }
    });
  });

  group('StudyProtocolSummary', () {
    Future<StudyProtocolSummary> load(String asset) async =>
        StudyProtocolSummary.decode(await rootBundle.loadString(asset));

    test('summarises the CAMS demo protocol', () async {
      final protocol = await load(
        'assets/carp/protocols/cams_demo_protocol.json',
      );
      expect(protocol.name, 'CAMS App - Demo Study Protocol');
      expect(protocol.title, 'CAMS App - Demo Study');
      expect(protocol.studyDescription, startsWith('A study demonstrating'));
      expect(protocol.participantRoles, ['Participant']);
      expect(protocol.primaryDevices.map((d) => (d.roleName, d.type)), [
        ('Primary Phone', 'MobileSensingSmartphone'),
      ]);
      expect(protocol.connectedDevices.map((d) => d.roleName), [
        'Location Service',
        'eSense',
        'Health Service',
      ]);
      expect(protocol.taskCount, 16);
      expect(protocol.triggerCount, 16);
      expect(protocol.measureTypes, hasLength(27));
      expect(
        protocol.measureTypes,
        containsAll(['location', 'esense.button', 'heartbeat']),
      );
      expect(protocol.tasks.first.type, 'MonitoringTask');
    });

    test('summarises the family protocol', () async {
      final protocol = await load('assets/carp/protocols/family_protocol.json');
      expect(protocol.name, 'Input Data Types');
      expect(protocol.title, isNull);
      expect(protocol.participantRoles, ['Father', 'Mother', 'Child']);
      expect(protocol.primaryDevices.map((d) => d.roleName), [
        "Father's Phone",
        "Mother's Phone",
        "Child's Phone",
      ]);
      expect(protocol.connectedDevices, isEmpty);
      expect(protocol.taskCount, 3);
      expect(protocol.triggerCount, 3);
    });

    test('ignores unknown fields and tolerates missing ones', () {
      final protocol = StudyProtocolSummary.decode(
        jsonEncode({
          'name': 'Minimal',
          'tasks': [
            {'name': 'T', 'measures': 'not a list'},
          ],
          'triggers': [{}],
          'futureField': {'x': 1},
        }),
      );
      expect(protocol.name, 'Minimal');
      expect(protocol.devices, isEmpty);
      expect(protocol.taskCount, 1);
      expect(protocol.tasks.single.type, 'Unknown');
      expect(protocol.measureTypes, isEmpty);
      expect(protocol.triggerCount, 1);
    });

    test('shortens type names', () {
      expect(shortMeasureType('dk.cachet.carp.esense.button'), 'esense.button');
      expect(shortMeasureType('com.example.steps'), 'com.example.steps');
      expect(shortTypeName('a.b.Smartphone'), 'Smartphone');
      expect(shortTypeName(null), 'Unknown');
    });
  });
}
