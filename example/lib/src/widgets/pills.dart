// Contains small labels for roles, devices, tags and states.
//
// Parts:
// - `PillTone`, the color roles of a pill.
// - `InfoPill`, a non-interactive label with an optional icon.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

/// The color role of an [InfoPill].
enum PillTone {
  /// Surface colors, for plain information.
  neutral,

  /// Primary container colors, e.g. for the study.
  primary,

  /// Secondary container colors.
  secondary,

  /// Tertiary container colors, e.g. for transactions.
  tertiary,

  /// Error container colors, e.g. for unhandled errors.
  error,
}

/// A non-interactive label, e.g. a participant role or a tag. Unlike a chip
/// without an action, it never looks disabled.
class InfoPill extends StatelessWidget {
  /// Creates a pill with [label] and an optional [icon].
  const InfoPill(
    this.label, {
    super.key,
    this.icon,
    this.tone = PillTone.neutral,
    this.semanticLabel,
  });

  /// The text.
  final String label;

  /// An optional leading icon.
  final IconData? icon;

  /// The colors.
  final PillTone tone;

  /// What screen readers read instead of [label].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final (background, foreground) = switch (tone) {
      PillTone.neutral => (scheme.surfaceContainerHigh, scheme.onSurface),
      PillTone.primary => (scheme.primaryContainer, scheme.onPrimaryContainer),
      PillTone.secondary => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      PillTone.tertiary => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      PillTone.error => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: background,
          shape: const StadiumBorder(),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            icon == null ? 12 : 8,
            6,
            12,
            6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: foreground),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  style: theme.typeScale.labelLarge.copyWith(color: foreground),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
