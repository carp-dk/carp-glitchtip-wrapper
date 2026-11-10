// Contains what the app shows of a study protocol.
//
// Parts:
// - `StudyProtocolSummary`, a tolerant parser of a carp_core study protocol.
// - `ProtocolDevice` and `ProtocolTask`, its devices and tasks.

import 'dart:convert';

import 'json.dart';

/// A device of a study protocol, e.g. the `Primary Phone` or an eSense
/// earbud connected to it.
class ProtocolDevice {
  /// Creates a device with the role [roleName] and the short [type] name.
  const ProtocolDevice({required this.roleName, required this.type});

  /// The role of the device in the study, e.g. `Primary Phone`.
  final String roleName;

  /// The short name of the device type, e.g. `Smartphone`.
  final String type;
}

/// A task of a study protocol and the measures it collects.
class ProtocolTask {
  /// Creates a task.
  const ProtocolTask({
    required this.name,
    required this.type,
    this.description,
    this.measures = const [],
  });

  /// The name of the task, e.g. `Task #13`.
  final String name;

  /// The short name of the task type, e.g. `BackgroundTask`.
  final String type;

  /// A description shown to the participant, e.g. of an app task.
  final String? description;

  /// The short names of the measured data types, e.g. `location`.
  final List<String> measures;
}

/// The parts of a carp_core study protocol the app shows, and that are
/// added to the study in GlitchTip once the deployment is loaded.
///
/// The example does not depend on carp_core: this reads the protocol JSON
/// directly and ignores everything else.
class StudyProtocolSummary {
  /// Creates a summary.
  const StudyProtocolSummary({
    required this.name,
    this.description,
    this.title,
    this.studyDescription,
    this.participantRoles = const [],
    this.primaryDevices = const [],
    this.connectedDevices = const [],
    this.tasks = const [],
    this.triggerCount = 0,
  });

  /// Reads a study protocol in the carp_core JSON format.
  factory StudyProtocolSummary.fromJson(Map<String, Object?> json) {
    final study = json.object('applicationData')?.object('studyDescription');
    return StudyProtocolSummary(
      name: json.string('name') ?? 'Unnamed protocol',
      description: json.string('description'),
      title: study?.string('title'),
      studyDescription: study?.string('description'),
      participantRoles: [
        for (final role in json.objects('participantRoles'))
          ?role.string('role'),
      ],
      primaryDevices: _devices(json.objects('primaryDevices')),
      connectedDevices: _devices(json.objects('connectedDevices')),
      tasks: [
        for (final task in json.objects('tasks'))
          ProtocolTask(
            name: task.string('name') ?? 'Unnamed task',
            type: shortTypeName(task.string('__type')),
            description: task.string('description'),
            measures: [
              for (final measure in task.objects('measures'))
                if (measure.string('type') case final String type)
                  shortMeasureType(type),
            ],
          ),
      ],
      triggerCount: json.count('triggers'),
    );
  }

  /// Decodes and reads a study protocol, e.g. a response body of CAWS.
  factory StudyProtocolSummary.decode(String body) {
    final json = jsonDecode(body);
    if (json is! Map<String, Object?>) {
      throw const FormatException('Expected a study protocol object');
    }
    return StudyProtocolSummary.fromJson(json);
  }

  static List<ProtocolDevice> _devices(List<Map<String, Object?>> json) => [
    for (final device in json)
      if (device.string('roleName') case final String roleName)
        ProtocolDevice(
          roleName: roleName,
          type: shortTypeName(device.string('__type')),
        ),
  ];

  /// The name of the protocol, e.g. `CAMS App - Demo Study Protocol`.
  final String name;

  /// The description of the protocol.
  final String? description;

  /// The title of the study shown to participants, from the study
  /// description in the protocol's application data.
  final String? title;

  /// The description of the study shown to participants.
  final String? studyDescription;

  /// The participant roles, e.g. `Participant`, or `Father` and `Mother`.
  final List<String> participantRoles;

  /// The primary devices, e.g. the participant's phone.
  final List<ProtocolDevice> primaryDevices;

  /// The devices and services connected to a primary device.
  final List<ProtocolDevice> connectedDevices;

  /// The tasks of the protocol.
  final List<ProtocolTask> tasks;

  /// The number of triggers that start the tasks.
  final int triggerCount;

  /// The number of tasks.
  int get taskCount => tasks.length;

  /// Every device of the protocol, primary devices first.
  List<ProtocolDevice> get devices => [...primaryDevices, ...connectedDevices];

  /// The distinct measured data types, sorted, e.g. `location`.
  List<String> get measureTypes =>
      {for (final task in tasks) ...task.measures}.toList()..sort();
}

/// The last part of a carp_core type name, e.g. `Smartphone` for
/// `dk.cachet.carp.common.application.devices.Smartphone`.
String shortTypeName(String? type) =>
    type == null || type.isEmpty ? 'Unknown' : type.split('.').last;

/// A measure type without the CARP namespace, e.g. `location` for
/// `dk.cachet.carp.location` and `esense.button` for
/// `dk.cachet.carp.esense.button`.
String shortMeasureType(String type) {
  const namespace = 'dk.cachet.carp.';
  return type.startsWith(namespace) ? type.substring(namespace.length) : type;
}
