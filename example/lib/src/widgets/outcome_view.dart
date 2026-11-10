// Contains the result of an action of the Try it tab.
//
// Parts:
// - `OutcomeView`, what happened and what GlitchTip gets.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../state/try_it_actions.dart';

/// Shows an [outcome]: what happened, and what GlitchTip gets.
class OutcomeView extends StatelessWidget {
  /// Creates the view of [outcome].
  const OutcomeView(this.outcome, {super.key});

  /// What happened.
  final ActionOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final (icon, background, foreground) = switch (outcome.kind) {
      OutcomeKind.reported => (
        M3EIcons.send,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      OutcomeKind.recorded => (
        M3EIcons.timer_outlined,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      OutcomeKind.ignored => (
        M3EIcons.block,
        scheme.surfaceContainerHighest,
        scheme.onSurface,
      ),
      OutcomeKind.off => (
        M3EIcons.cloud_off,
        scheme.surfaceContainerHighest,
        scheme.onSurface,
      ),
      OutcomeKind.info => (
        M3EIcons.info_outline,
        scheme.surfaceContainerHighest,
        scheme.onSurface,
      ),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    outcome.title,
                    style: theme.typography.emphasized.titleSmall.copyWith(
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    outcome.detail,
                    style: theme.typeScale.bodyMedium.copyWith(
                      color: foreground,
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
