// Contains the control that switches the sample CAWS network condition.
//
// Parts:
// - `NetworkConditionVisuals`, the icon and shape of each condition.
// - `NetworkSwitcher`, a connected button group of the conditions.
// - `NetworkConditionCard`, the switcher with an explanation.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../caws/network_condition.dart';
import '../state/example_scope.dart';
import 'sections.dart';
import 'shape_icon.dart';

/// How each network condition looks.
extension NetworkConditionVisuals on NetworkCondition {
  /// The icon of the condition.
  IconData get icon => switch (this) {
    NetworkCondition.online => M3EIcons.wifi,
    NetworkCondition.offline => M3EIcons.wifi_off,
    NetworkCondition.serverError => M3EIcons.dns,
    NetworkCondition.slow => M3EIcons.hourglass_top,
  };

  /// The shape of the condition's icon container.
  IconShape get shape => switch (this) {
    NetworkCondition.online => IconShape.circle,
    NetworkCondition.offline => IconShape.cookie4,
    NetworkCondition.serverError => IconShape.softBoom,
    NetworkCondition.slow => IconShape.clover4,
  };
}

/// A connected button group that switches the network condition of the
/// sample CAWS, or a stack of full-width buttons where the connected
/// group does not fit.
class NetworkSwitcher extends StatelessWidget {
  /// Creates the switcher.
  const NetworkSwitcher({super.key});

  // the padding of a small button, and the gap between connected ones
  static const _segmentPadding = 2 * 16.0 + 2;

  // the width the buttons need next to each other
  static double _rowWidth(BuildContext context) {
    final style = M3ETheme.of(context).typeScale.labelLarge;
    final textScaler = MediaQuery.textScalerOf(context);
    var width = 0.0;
    for (final condition in NetworkCondition.values) {
      final painter = TextPainter(
        text: TextSpan(text: condition.label, style: style),
        textScaler: textScaler,
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      width += painter.width + _segmentPadding;
      painter.dispose();
    }
    return width;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _group(
      context,
      // stacked when they do not fit next to each other, e.g. on a small
      // phone or with large text
      stackedWidth: _rowWidth(context) > constraints.maxWidth
          ? constraints.maxWidth
          : null,
    ),
  );

  // connected segments, or, given a [stackedWidth], separate buttons of that
  // width below each other: connected segments are only rounded at the
  // start and the end of a row
  Widget _group(BuildContext context, {double? stackedWidth}) {
    final state = ExampleScope.watch(context).state;
    final stacked = stackedWidth != null;
    return M3EButtonGroup(
      type: stacked
          ? M3EButtonGroupType.standard
          : M3EButtonGroupType.connected,
      direction: stacked ? Axis.vertical : Axis.horizontal,
      style: M3EButtonStyle.tonal,
      size: M3EButtonSize.sm,
      selectedIndex: state.networkCondition.index,
      selectionRequired: true,
      semanticLabel: 'Sample CAWS network condition',
      onSelectedIndexChanged: (index) {
        if (index != null) {
          state.networkCondition = NetworkCondition.values[index];
        }
      },
      actions: [
        for (final condition in NetworkCondition.values)
          M3EButtonGroupAction(
            label: Text(condition.label),
            semanticLabel: condition.semanticLabel,
            // full width: in a group, a button is as wide as its minimum
            // width unless its label needs more
            minWidth: stackedWidth,
          ),
      ],
    );
  }
}

/// The network condition of the sample CAWS: what it does, and the
/// switcher.
class NetworkConditionCard extends StatelessWidget {
  /// Creates the card.
  const NetworkConditionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final condition = ExampleScope.watch(context).state.networkCondition;
    final problem = condition != NetworkCondition.online;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShapeIcon(
                condition.icon,
                shape: condition.shape,
                color: problem
                    ? scheme.errorContainer
                    : scheme.primaryContainer,
                iconColor: problem
                    ? scheme.onErrorContainer
                    : scheme.onPrimaryContainer,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Network: ${condition.semanticLabel}',
                      style: theme.typography.emphasized.titleMedium.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    AnimatedSwitcher(
                      duration: M3EMotion.medium2,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: AlignmentDirectional.topStart,
                        children: [...previous, ?current],
                      ),
                      child: Text(
                        condition.description,
                        key: ValueKey(condition),
                        style: theme.typeScale.bodyMedium.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const NetworkSwitcher(),
        ],
      ),
    );
  }
}
