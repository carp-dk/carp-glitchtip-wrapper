// Contains the Study tab: the accepted study and what GlitchTip sees of it.
//
// Parts:
// - `StudyTab`, the protocol summary, the tags and the `study` context
//   attached to every report, and leaving the study.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../app/example_routes.dart';
import '../models/participation_invitation.dart';
import '../models/study_protocol_summary.dart';
import '../reporting/glitchtip_study.dart';
import '../state/app_state.dart';
import '../state/example_scope.dart';
import '../widgets/key_values.dart';
import '../widgets/pills.dart';
import '../widgets/sections.dart';
import '../widgets/shape_icon.dart';
import '../widgets/page_app_bar.dart';
import 'status_sheet.dart';

/// The accepted study: its protocol, what GlitchTip sees of it, and leaving
/// it.
class StudyTab extends StatelessWidget {
  /// Creates the Study tab.
  const StudyTab({super.key});

  void _leave(BuildContext context) {
    ExampleScope.read(context).state.leaveStudy();
    Navigator.of(context).pushReplacementNamed(ExampleRoutes.invitations);
  }

  @override
  Widget build(BuildContext context) {
    final state = ExampleScope.watch(context).state;
    final invitation = state.invitation;
    final protocol = state.protocol;
    return CustomScrollView(
      slivers: [
        PageAppBar(
          title: 'Study',
          subtitle: invitation == null
              ? 'Not enrolled'
              : [
                  ?invitation.participantRoleName,
                  ?invitation.deviceRoleName,
                ].join(' · '),
          actions: const [StatusAction()],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          sliver: SliverList.list(
            children: [
              if (invitation != null) _StudyHero(invitation, protocol),
              if (protocol != null) ...[
                SectionHeader('Protocol', subtitle: protocol.name),
                _ProtocolStats(protocol),
                const SizedBox(height: 12),
                _Devices(protocol),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: M3EButton.tonal(
                    icon: const Icon(M3EIcons.checklist),
                    label: Text('Show the ${protocol.taskCount} tasks'),
                    onPressed: () =>
                        Navigator.of(context).pushNamed(ExampleRoutes.tasks),
                  ),
                ),
              ],
              const SectionHeader(
                'What GlitchTip sees',
                subtitle:
                    'Attached to every report from now on. Tags are '
                    'searchable, e.g. study_deployment_id:<id>.',
              ),
              const _GlitchTipTags(),
              const SectionHeader(
                'study context',
                subtitle: 'Shown on every report, not searchable.',
              ),
              const _GlitchTipContext(),
              const SectionHeader(
                'Leave the study',
                subtitle:
                    'Reports stop carrying the study, and the breadcrumbs '
                    'recorded during it are cleared.',
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: M3EButton.outlined(
                  icon: const Icon(M3EIcons.exit_to_app),
                  label: const Text('Leave study'),
                  onPressed: () => _leave(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StudyHero extends StatelessWidget {
  const _StudyHero(this.invitation, this.protocol);

  final ActiveParticipationInvitation invitation;
  final StudyProtocolSummary? protocol;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final protocol = this.protocol;
    final description =
        protocol?.studyDescription ?? invitation.studyDescription;
    return SectionCard(
      color: scheme.primaryContainer,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShapeIcon(
            M3EIcons.science,
            shape: IconShape.gem,
            size: 64,
            color: scheme.primary,
            iconColor: scheme.onPrimary,
          ),
          const SizedBox(height: 16),
          Text(
            protocol?.title ?? invitation.studyName ?? 'Your study',
            style: theme.typography.emphasized.headlineSmall.copyWith(
              color: scheme.onPrimaryContainer,
            ),
          ),
          if (description != null) ...[
            const SizedBox(height: 8),
            Text(
              description,
              style: theme.typeScale.bodyMedium.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (invitation.participantRoleName case final role?)
                InfoPill(
                  role,
                  icon: M3EIcons.person_outline,
                  semanticLabel: 'Participant role: $role',
                ),
              if (invitation.deviceRoleName case final device?)
                InfoPill(
                  device,
                  icon: M3EIcons.smartphone_outlined,
                  semanticLabel: 'Device role: $device',
                ),
              if (protocol == null)
                const InfoPill(
                  'Protocol not loaded',
                  icon: M3EIcons.pending_outlined,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProtocolStats extends StatelessWidget {
  const _ProtocolStats(this.protocol);

  final StudyProtocolSummary protocol;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final stats = [
      (protocol.taskCount, 'Tasks'),
      (protocol.triggerCount, 'Triggers'),
      (protocol.measureTypes.length, 'Measures'),
    ];
    return Row(
      children: [
        for (final (index, (count, label)) in stats.indexed) ...[
          if (index > 0) const SizedBox(width: 8),
          Expanded(
            child: MergeSemantics(
              child: SectionCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 18,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$count',
                      style: theme.typography.emphasized.displaySmall.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                    Text(
                      label,
                      style: theme.typeScale.labelLarge.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Devices extends StatelessWidget {
  const _Devices(this.protocol);

  final StudyProtocolSummary protocol;

  static IconData _icon(String type) => switch (type) {
    'Smartphone' || 'MobileSensingSmartphone' => M3EIcons.smartphone,
    'LocationService' => M3EIcons.location_on,
    'ESenseDevice' => M3EIcons.headphones,
    'HealthService' => M3EIcons.favorite,
    _ => M3EIcons.sensors,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    final devices = protocol.devices;
    final primary = protocol.primaryDevices.length;
    return M3EList(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return M3EListItem(
          leading: ShapeIcon(
            _icon(device.type),
            shape: index < primary ? IconShape.cookie6 : IconShape.circle,
            size: 40,
            color: index < primary
                ? scheme.secondaryContainer
                : scheme.surfaceContainerHighest,
            iconColor: index < primary
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
          headline: device.roleName,
          supportingText: index < primary
              ? '${device.type} · primary device'
              : '${device.type} · connected',
        );
      },
    );
  }
}

// the tags the app and the wrapper add to every report right now
class _GlitchTipTags extends StatelessWidget {
  const _GlitchTipTags();

  @override
  Widget build(BuildContext context) {
    final state = ExampleScope.watch(context).state;
    final status = CarpGlitchTip.status;
    final studyTags = CarpGlitchTip.study?.toTags() ?? const {};
    return KeyValueList([
      for (final key in studyTagKeys)
        if (studyTags[key] case final value?)
          KeyValue(key, value, highlighted: true),
      KeyValue(AppState.onboardingTag, state.onboarding.tag),
      if (status.buildMode case final mode?)
        KeyValue(GlitchTipTags.buildMode, mode),
    ]);
  }
}

// the study context the wrapper adds to every report right now
class _GlitchTipContext extends StatelessWidget {
  const _GlitchTipContext();

  static const _appKeys = {'study_name', 'protocol', 'devices', 'tasks'};

  @override
  Widget build(BuildContext context) {
    ExampleScope.watch(context); // rebuilds when the study changes
    final study = CarpGlitchTip.study?.toContext() ?? const {};
    // the wrapper's keys first, then what the app added
    final keys = [
      ...study.keys.where((key) => !_appKeys.contains(key)),
      ...study.keys.where(_appKeys.contains),
    ];
    return KeyValueList([
      for (final key in keys)
        KeyValue(key, KeyValueList.format(study[key]), highlighted: true),
    ]);
  }
}
