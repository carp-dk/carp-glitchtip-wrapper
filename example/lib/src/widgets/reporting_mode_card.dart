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

  /// The title of the card in live mode with [status].
  static String liveTitle(GlitchTipStatus status) => status.enabled
      ? 'Live: reports go to GlitchTip'
      : status.disabledReason == DisabledReason.starting
      ? 'Live: starting'
      : 'Live: reporting is off';

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final preview = ExampleScope.watch(context).outbox != null;
    final status = CarpGlitchTip.status;
    final (title, explanation) = preview
        ? (
            'Preview: reports stay on this device',
            'No DSN is set, so nothing is sent. The Reports tab shows each '
                'report as GlitchTip would get it.',
          )
        : (
            liveTitle(status),
            status.enabled
                ? 'Reports are sent to ${status.dsn} in the environment '
                      '${status.environment}.'
                : status.disabledReason == DisabledReason.starting
                ? 'Errors are already sent to ${status.dsn}. Requests, traces '
                      'and navigation are recorded once the Sentry SDK has '
                      'started; the status line in the log says when.'
                : 'A DSN is set, but nothing is sent: '
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
