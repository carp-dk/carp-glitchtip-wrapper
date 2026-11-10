// Contains the card that says where reports go.
//
// Parts:
// - `ReportingModeCard`, preview or live mode and the wrapper's status line.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../state/example_scope.dart';
import 'sections.dart';
import 'shape_icon.dart';

/// Says where reports go: kept on the device (preview mode) or sent to
/// GlitchTip (live mode), with the status line of the wrapper.
class ReportingModeCard extends StatelessWidget {
  /// Creates the card; [showStatusLine] adds the full status line.
  const ReportingModeCard({super.key, this.showStatusLine = true});

  /// Whether the status line of `CarpGlitchTip.status` is shown.
  final bool showStatusLine;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final preview = ExampleScope.watch(context).outbox != null;
    final status = CarpGlitchTip.status;
    final (title, explanation) = preview
        ? (
            'Preview: reports stay on this device',
            'No DSN is set, so nothing is sent. The Reports tab shows exactly '
                'what GlitchTip would get.',
          )
        : status.enabled
        ? (
            'Live: reports go to GlitchTip',
            'Reports are sent to ${status.dsn} in the environment '
                '${status.environment}.',
          )
        : (
            'Live: reporting is off',
            'A DSN is set, but nothing is sent: '
                '${status.disabledReason?.description ?? 'disabled'}.',
          );
    return SectionCard(
      color: preview ? scheme.secondaryContainer : scheme.tertiaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShapeIcon(
                preview ? M3EIcons.phonelink_lock : M3EIcons.cloud_upload,
                shape: preview ? IconShape.cookie12 : IconShape.clover8,
                color: preview ? scheme.secondary : scheme.tertiary,
                iconColor: preview ? scheme.onSecondary : scheme.onTertiary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.typography.emphasized.titleMedium.copyWith(
                        color: preview
                            ? scheme.onSecondaryContainer
                            : scheme.onTertiaryContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      explanation,
                      style: theme.typeScale.bodyMedium.copyWith(
                        color: preview
                            ? scheme.onSecondaryContainer
                            : scheme.onTertiaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (showStatusLine) ...[
            const SizedBox(height: 16),
            MonospaceBox(
              '[CarpGlitchTip] $status',
              semanticLabel: 'Status line',
            ),
          ],
        ],
      ),
    );
  }
}
