// Contains the building blocks of the example's pages.
//
// Parts:
// - `SectionHeader`, a heading with an optional explanation.
// - `SectionCard`, a filled card with generous corners.
// - `MonospaceBox`, text as GlitchTip or a log shows it.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

/// The corner radius of the example's cards.
const cardRadius = BorderRadius.all(Radius.circular(28));

/// A section heading with an optional explanation below it.
class SectionHeader extends StatelessWidget {
  /// Creates a heading with [title].
  const SectionHeader(this.title, {super.key, this.subtitle, this.trailing});

  /// The heading.
  final String title;

  /// An optional explanation.
  final String? subtitle;

  /// An optional widget at the end, e.g. a count.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final subtitle = this.subtitle;
    final trailing = this.trailing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: theme.typography.emphasized.titleLarge.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.typeScale.bodyMedium.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing],
        ],
      ),
    );
  }
}

/// A filled card with the example's generous corners.
class SectionCard extends StatelessWidget {
  /// Creates a card around [child].
  const SectionCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(20),
  });

  /// The content.
  final Widget child;

  /// The fill; surface container low by default.
  final Color? color;

  /// The space around [child].
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: color ?? scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// [text] in a monospaced font on a tinted box, e.g. the status line.
class MonospaceBox extends StatelessWidget {
  /// Creates a box for [text].
  const MonospaceBox(this.text, {super.key, this.semanticLabel});

  /// The text.
  final String text;

  /// What screen readers read instead of [text].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    return Semantics(
      label: semanticLabel,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          text,
          style: theme.typeScale.bodySmall.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
            color: theme.colorScheme.onSurface,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}
