// Contains the screen with the tasks of the study's protocol.
//
// Parts:
// - `TasksScreen`, a detail screen: opening it is recorded as a navigation
//   breadcrumb and sets the `screen` tag of reports.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../app/example_routes.dart';
import '../models/study_protocol_summary.dart';
import '../state/example_scope.dart';
import '../widgets/pills.dart';
import '../widgets/sections.dart';
import '../widgets/shape_icon.dart';
import '../widgets/page_app_bar.dart';

/// The tasks of the protocol and the data they collect.
class TasksScreen extends StatelessWidget {
  /// Creates the tasks screen.
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final protocol = ExampleScope.watch(context).state.protocol;
    final tasks = protocol?.tasks ?? const <ProtocolTask>[];
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          PageAppBar(
            variant: M3EAppBarVariant.mediumFlexible,
            title: 'Tasks',
            subtitle: protocol?.name,
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: SliverList.list(
              children: [
                SectionCard(
                  color: scheme.tertiaryContainer,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShapeIcon(
                        M3EIcons.route,
                        shape: IconShape.arch,
                        color: scheme.tertiary,
                        iconColor: scheme.onTertiary,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'Opening this screen was recorded as a navigation '
                          'breadcrumb, and reports from here carry screen: '
                          '${ExampleRoutes.tasks}.',
                          style: theme.typeScale.bodyMedium.copyWith(
                            color: scheme.onTertiaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SectionHeader(
                  '${tasks.length} tasks',
                  subtitle:
                      '${protocol?.triggerCount ?? 0} triggers start '
                      'them on the devices of the study.',
                ),
                for (final task in tasks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _TaskCard(task),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard(this.task);

  final ProtocolTask task;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final description = task.description;
    return SectionCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.name,
                  style: theme.typography.emphasized.titleMedium.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
              InfoPill(task.type, tone: PillTone.tertiary),
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description,
              style: theme.typeScale.bodyMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (task.measures.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final measure in task.measures)
                  InfoPill(measure, icon: M3EIcons.sensors),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
