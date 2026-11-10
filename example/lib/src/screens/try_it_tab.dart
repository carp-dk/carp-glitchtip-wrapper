// Contains the Try it tab: things that happen in a CARP app, and what
// GlitchTip gets of each.
//
// Parts:
// - `TryItTab`, the network condition and the actions.
// - `_Demo`, the actions, and `_ActionCard`, one action with its outcome.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../app/example_routes.dart';
import '../state/example_scope.dart';
import '../state/try_it_actions.dart';
import '../widgets/network_switcher.dart';
import '../widgets/outcome_view.dart';
import '../widgets/sections.dart';
import '../widgets/shape_icon.dart';
import '../widgets/page_app_bar.dart';
import 'status_sheet.dart';

/// The actions of the Try it tab.
enum _Demo {
  sync(
    title: 'Sync data',
    description:
        'Uploads collected data to CAWS. What GlitchTip gets depends on the '
        'network.',
    icon: M3EIcons.cloud_upload_outlined,
    shape: IconShape.puffy,
    button: 'Sync',
  ),
  caughtError(
    title: 'Report a caught error',
    description:
        'A CAWS call fails; the app catches the CawsException and calls '
        'captureException.',
    icon: M3EIcons.bug_report_outlined,
    shape: IconShape.cookie9,
    button: 'Report',
  ),
  unhandledError(
    title: 'Throw an unhandled error',
    description: 'An async callback throws and nobody catches it.',
    icon: M3EIcons.report_problem,
    shape: IconShape.softBoom,
    button: 'Throw',
  ),
  personalData(
    title: 'Error with personal data',
    description:
        'The message has an e-mail address and a token in a URL. The '
        'wrapper scrubs both.',
    icon: M3EIcons.privacy_tip_outlined,
    shape: IconShape.pentagon,
    button: 'Report',
  ),
  expectedError(
    title: 'Expected error',
    description:
        'A DeviceNotConnectedException, which the app expects. Its ignore '
        'rule drops it.',
    icon: M3EIcons.bluetooth_disabled,
    shape: IconShape.ghostish,
    button: 'Report',
  ),
  measureTask(
    title: 'Measure a task',
    description: 'CarpGlitchTip.trace times a piece of work as a transaction.',
    icon: M3EIcons.timer_outlined,
    shape: IconShape.clover4,
    button: 'Measure',
  ),
  openScreen(
    title: 'Open a detail screen',
    description:
        'Navigation is recorded as a breadcrumb, and the screen becomes the '
        'screen tag of reports.',
    icon: M3EIcons.open_in_new,
    shape: IconShape.arch,
    button: 'Open',
  );

  const _Demo({
    required this.title,
    required this.description,
    required this.icon,
    required this.shape,
    required this.button,
  });

  final String title;
  final String description;
  final IconData icon;
  final IconShape shape;
  final String button;
}

/// Things that happen in a CARP app, each telling what GlitchTip gets.
class TryItTab extends StatefulWidget {
  /// Creates the Try it tab.
  const TryItTab({super.key});

  @override
  State<TryItTab> createState() => _TryItTabState();
}

class _TryItTabState extends State<TryItTab> {
  final Map<_Demo, ActionOutcome> _outcomes = {};
  final Set<_Demo> _running = {};

  Future<void> _run(_Demo demo) async {
    final actions = ExampleScope.read(context).actions;
    setState(() => _running.add(demo));
    final outcome = switch (demo) {
      _Demo.sync => await actions.syncData(),
      _Demo.caughtError => await actions.reportCaughtError(),
      _Demo.unhandledError => actions.throwUnhandledError(),
      _Demo.personalData => await actions.reportPersonalData(),
      _Demo.expectedError => await actions.reportExpectedError(),
      _Demo.measureTask => await actions.measureTask(),
      _Demo.openScreen => _openScreen(actions),
    };
    if (!mounted) return;
    setState(() {
      _running.remove(demo);
      _outcomes[demo] = outcome;
    });
  }

  ActionOutcome _openScreen(TryItActions actions) {
    Navigator.of(context).pushNamed(
      ExampleRoutes.tasks,
      // not recorded: the wrapper only records route names
      arguments: {'opened_from': 'try_it'},
    );
    return actions.openedScreen(ExampleRoutes.tasks);
  }

  @override
  Widget build(BuildContext context) {
    Widget card(_Demo demo) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _ActionCard(
        key: ValueKey('try-it-${demo.name}'),
        demo: demo,
        running: _running.contains(demo),
        outcome: _outcomes[demo],
        onRun: () => _run(demo),
      ),
    );
    return CustomScrollView(
      slivers: [
        const PageAppBar(
          title: 'Try it',
          subtitle: 'Make something happen, see what is reported',
          actions: [StatusAction()],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          sliver: SliverList.list(
            children: [
              const NetworkConditionCard(),
              const SectionHeader(
                'Requests',
                subtitle: 'Real HTTP requests to the sample CAWS.',
              ),
              card(_Demo.sync),
              card(_Demo.caughtError),
              const SectionHeader('Errors'),
              card(_Demo.unhandledError),
              card(_Demo.personalData),
              card(_Demo.expectedError),
              const SectionHeader('Performance and navigation'),
              card(_Demo.measureTask),
              card(_Demo.openScreen),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.demo,
    required this.running,
    required this.outcome,
    required this.onRun,
  });

  final _Demo demo;
  final bool running;
  final ActionOutcome? outcome;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final outcome = this.outcome;
    return M3ECard(
      variant: M3ECardVariant.filled,
      color: scheme.surfaceContainerLow,
      borderRadius: cardRadius,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      focusable: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShapeIcon(
                demo.icon,
                shape: demo.shape,
                color: scheme.secondaryContainer,
                iconColor: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      demo.title,
                      style: theme.typography.emphasized.titleMedium.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      demo.description,
                      style: theme.typeScale.bodyMedium.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (running) ...[
                const M3ELoadingIndicator(size: 36, semanticLabel: 'Working'),
                const SizedBox(width: 8),
              ],
              M3EButton.tonal(
                label: Text(demo.button),
                semanticLabel: '${demo.button}: ${demo.title}',
                onPressed: running ? null : onRun,
              ),
            ],
          ),
          AnimatedSize(
            duration: M3EMotion.medium4,
            curve: M3EMotion.emphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: outcome == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OutcomeView(outcome),
                  ),
          ),
        ],
      ),
    );
  }
}
