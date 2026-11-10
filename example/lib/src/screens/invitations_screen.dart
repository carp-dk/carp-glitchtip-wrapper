// Contains the screen with the participant's study invitations.
//
// Parts:
// - `InvitationsScreen`, the invitations from CAWS; accepting one attaches
//   the study to reports and loads its protocol.
// - `_StudyAttached` and `_NoStudyYet`, what GlitchTip knows of the study.
// - `_InvitationCard`, one invitation.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../app/example_routes.dart';
import '../app/texts.dart';
import '../models/participation_invitation.dart';
import '../state/app_state.dart';
import '../state/example_scope.dart';
import '../state/try_it_actions.dart';
import '../widgets/error_banner.dart';
import '../widgets/pills.dart';
import '../widgets/sections.dart';
import '../widgets/shape_icon.dart';
import '../widgets/page_app_bar.dart';
import 'status_sheet.dart';

/// The participant's invitations. Until one is accepted, GlitchTip does not
/// know the study.
class InvitationsScreen extends StatelessWidget {
  /// Creates the invitations screen.
  const InvitationsScreen({super.key});

  Future<void> _accept(
    BuildContext context,
    ActiveParticipationInvitation invitation,
  ) async {
    final navigator = Navigator.of(context);
    final loaded = await ExampleScope.read(context).state.accept(invitation);
    // replaces everything, also a status sheet opened while loading
    if (loaded) {
      await navigator.pushNamedAndRemoveUntil(
        ExampleRoutes.study,
        (_) => false,
      );
    }
  }

  void _signOut(BuildContext context) {
    ExampleScope.read(context).state.signOut();
    Navigator.of(context)
        .pushNamedAndRemoveUntil(ExampleRoutes.welcome, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final state = ExampleScope.watch(context).state;
    final invitations = state.invitations;
    final error = state.invitationsError;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          PageAppBar(
            title: 'Invitations',
            subtitle: 'Signed in as ${state.userName ?? 'nobody'}',
            actions: [
              const StatusAction(),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(M3EIcons.logout),
                tooltip: 'Sign out',
                onPressed: () => _signOut(context),
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: SliverList.list(
              children: [
                if (state.study case final study?)
                  _StudyAttached(study)
                else
                  const _NoStudyYet(),
                SectionHeader(
                  'Choose a study',
                  subtitle: invitations == null
                      ? 'Asking CAWS for your invitations.'
                      : '${countOf(invitations.length, 'invitation')} from '
                            'CAWS. Accepting one attaches its study to '
                            'reports.',
                ),
                if (error != null)
                  ErrorBanner(
                    title: 'Could not load the invitations',
                    message: ExampleDescriptions.describe(error),
                    action: M3EButton.text(
                      onPressed: state.loadInvitations,
                      child: const Text('Try again'),
                    ),
                  )
                else if (invitations == null || state.loadingInvitations)
                  const _Loading('Loading invitations…')
                else
                  for (final (index, invitation) in invitations.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _InvitationCard(
                        invitation: invitation,
                        shape: index.isEven
                            ? IconShape.cookie9
                            : IconShape.flower,
                        onAccept: () => _accept(context, invitation),
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// what GlitchTip sees once an invitation is accepted, also when loading
// its protocol failed
class _StudyAttached extends StatelessWidget {
  const _StudyAttached(this.study);

  final StudyMetadata study;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final state = ExampleScope.watch(context).state;
    return SectionCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShapeIcon(
            M3EIcons.verified_outlined,
            shape: IconShape.puffy,
            color: scheme.primaryContainer,
            iconColor: scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GlitchTip knows your study',
                  style: theme.typography.emphasized.titleMedium.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Reports carry its ids and roles. Its protocol is added '
                  'once it is loaded.',
                  style: theme.typeScale.bodyMedium.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    InfoPill(
                      '${AppState.onboardingTag}: ${state.onboarding.tag}',
                      icon: M3EIcons.sell_outlined,
                      tone: PillTone.secondary,
                    ),
                    if (study.studyId case final id?)
                      InfoPill(
                        '${GlitchTipTags.studyId}: $id',
                        icon: M3EIcons.sell_outlined,
                        tone: PillTone.secondary,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                M3EButton.text(
                  onPressed: state.loadingProtocol ? null : state.leaveStudy,
                  child: const Text('Leave study'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// what GlitchTip sees before an invitation is accepted
class _NoStudyYet extends StatelessWidget {
  const _NoStudyYet();

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final state = ExampleScope.watch(context).state;
    return SectionCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShapeIcon(
            M3EIcons.travel_explore,
            shape: IconShape.puffy,
            color: scheme.secondaryContainer,
            iconColor: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GlitchTip does not know your study yet',
                  style: theme.typography.emphasized.titleMedium.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Reports from now on are tagged with your progress, but '
                  'carry no study tags.',
                  style: theme.typeScale.bodyMedium.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    InfoPill(
                      '${AppState.onboardingTag}: ${state.onboarding.tag}',
                      icon: M3EIcons.sell_outlined,
                      tone: PillTone.secondary,
                    ),
                    const InfoPill('no study_id', icon: M3EIcons.block),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InvitationCard extends StatelessWidget {
  const _InvitationCard({
    required this.invitation,
    required this.shape,
    required this.onAccept,
  });

  final ActiveParticipationInvitation invitation;
  final IconShape shape;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final state = ExampleScope.watch(context).state;
    final accepted = identical(state.invitation, invitation);
    final loading = accepted && state.loadingProtocol;
    final error = accepted ? state.protocolError : null;
    final role = invitation.participantRoleName;
    final device = invitation.deviceRoleName;
    final description = invitation.studyDescription;
    return M3ECard(
      variant: accepted ? M3ECardVariant.filled : M3ECardVariant.outlined,
      color: accepted ? scheme.primaryContainer : null,
      borderRadius: cardRadius,
      padding: const EdgeInsets.all(20),
      focusable: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShapeIcon(
                M3EIcons.science_outlined,
                shape: shape,
                size: 52,
                color: accepted ? scheme.primary : scheme.secondaryContainer,
                iconColor: accepted
                    ? scheme.onPrimary
                    : scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      invitation.studyName ?? 'Unnamed study',
                      style: theme.typography.emphasized.titleLarge.copyWith(
                        color: accepted
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                      ),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: theme.typeScale.bodyMedium.copyWith(
                          color: accepted
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (role != null)
                InfoPill(
                  role,
                  icon: M3EIcons.person_outline,
                  tone: PillTone.secondary,
                  semanticLabel: 'Participant role: $role',
                ),
              if (device != null)
                InfoPill(
                  device,
                  icon: M3EIcons.smartphone_outlined,
                  tone: PillTone.secondary,
                  semanticLabel: 'Device role: $device',
                ),
            ],
          ),
          const SizedBox(height: 16),
          AnimatedSize(
            duration: M3EMotion.medium4,
            curve: M3EMotion.emphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: loading
                ? const _Loading('Study attached. Loading its protocol…')
                : error != null
                ? ErrorBanner(
                    title: 'Could not load the protocol',
                    message: ExampleDescriptions.describe(error),
                    action: M3EButton.text(
                      onPressed: onAccept,
                      child: const Text('Try again'),
                    ),
                  )
                : Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: M3EButton.filled(
                      icon: const Icon(M3EIcons.check),
                      label: const Text('Accept invitation'),
                      semanticLabel:
                          'Accept the invitation to '
                          '${invitation.studyName ?? 'this study'}',
                      onPressed: state.loadingProtocol ? null : onAccept,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// an expressive loading indicator with a text
class _Loading extends StatelessWidget {
  const _Loading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    return Semantics(
      liveRegion: true,
      label: text,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const M3ELoadingIndicator(
                variant: M3ELoadingIndicatorVariant.contained,
                size: 48,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  text,
                  style: theme.typeScale.bodyLarge.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
