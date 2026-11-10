// Contains the first screen, where the participant signs in.
//
// Parts:
// - `WelcomeScreen`, with the CARP x DTU logo, what the example shows, where
//   reports go, and the sign-in button.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../app/example_routes.dart';
import '../state/example_scope.dart';
import '../state/try_it_actions.dart';
import '../widgets/brand_logo.dart';
import '../widgets/error_banner.dart';
import '../widgets/reporting_mode_card.dart';
import '../widgets/shape_icon.dart';
import 'status_sheet.dart';

/// The welcome screen: what the example shows, and signing in as the demo
/// participant.
class WelcomeScreen extends StatelessWidget {
  /// Creates the welcome screen.
  const WelcomeScreen({super.key});

  Future<void> _signIn(BuildContext context) async {
    final navigator = Navigator.of(context);
    final signedIn = await ExampleScope.read(context).state.signIn();
    if (signedIn) {
      await navigator.pushReplacementNamed(ExampleRoutes.invitations);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final state = ExampleScope.watch(context).state;
    final error = state.signInError;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const Align(
              alignment: AlignmentDirectional.centerEnd,
              child: StatusAction(),
            ),
            const _Hero(),
            const SizedBox(height: 28),
            Semantics(
              header: true,
              child: Text(
                'GlitchTip for CARP apps',
                style: theme.typography.emphasized.displaySmall.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'A CARP study app that reports its errors and network '
              'performance to GlitchTip. The study is only known after you '
              'sign in and accept an invitation; see how it appears on '
              'every report.',
              style: theme.typeScale.bodyLarge.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            const _Step(
              number: 1,
              shape: IconShape.cookie9,
              title: 'Sign in',
              text: 'Reports carry onboarding: signed_out, no study.',
            ),
            const _Step(
              number: 2,
              shape: IconShape.clover4,
              title: 'Accept an invitation',
              text: 'Study, deployment and roles are attached to reports.',
            ),
            const _Step(
              number: 3,
              shape: IconShape.sunny,
              title: 'Load the protocol',
              text: 'Its name, devices and tasks are added to the study.',
            ),
            const SizedBox(height: 16),
            const ReportingModeCard(),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error != null) ...[
                ErrorBanner(
                  title: 'Could not sign in',
                  message: ExampleDescriptions.describe(error),
                ),
                const SizedBox(height: 12),
              ],
              M3EButton.filled(
                size: M3EButtonSize.md,
                icon: state.signingIn
                    ? const SizedBox.square(
                        dimension: 24,
                        child: M3ELoadingIndicator(semanticLabel: 'Signing in'),
                      )
                    : const Icon(M3EIcons.login),
                label: Text(
                  state.signingIn
                      ? 'Signing in…'
                      : 'Sign in as demo participant',
                ),
                onPressed: state.signingIn ? null : () => _signIn(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// the logo between expressive shapes
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(40),
      child: Container(
        height: 236,
        color: scheme.surfaceContainerLow,
        child: Stack(
          alignment: Alignment.center,
          children: [
            PositionedDirectional(
              top: -28,
              end: -20,
              child: ShapeIcon(
                M3EIcons.monitor_heart,
                shape: IconShape.sunny,
                size: 132,
                color: scheme.tertiaryContainer,
                iconColor: scheme.onTertiaryContainer,
              ),
            ),
            PositionedDirectional(
              bottom: 14,
              start: 18,
              child: ShapeIcon(
                M3EIcons.science,
                shape: IconShape.clover8,
                size: 72,
                color: scheme.primaryContainer,
                iconColor: scheme.onPrimaryContainer,
              ),
            ),
            const BrandLogo(height: 88),
          ],
        ),
      ),
    );
  }
}

// one step of the flow the example shows
class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.shape,
    required this.title,
    required this.text,
  });

  final int number;
  final IconShape shape;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: MergeSemantics(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: scheme.secondaryContainer,
                shape: shape.border,
              ),
              child: Text(
                '$number',
                style: theme.typography.emphasized.titleMedium.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.typography.emphasized.titleMedium.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  Text(
                    text,
                    style: theme.typeScale.bodyMedium.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
