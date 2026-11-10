// Contains the home of an enrolled participant.
//
// Parts:
// - `HomeScreen`, an expressive navigation bar with the Study, Try it and
//   Reports tabs.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../state/example_scope.dart';
import 'reports_tab.dart';
import 'study_tab.dart';
import 'try_it_tab.dart';

/// The home of an enrolled participant: the study, actions to try, and the
/// reports GlitchTip gets.
class HomeScreen extends StatefulWidget {
  /// Creates the home screen.
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _tabs = [StudyTab(), TryItTab(), ReportsTab()];

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final outbox = ExampleScope.watch(context).outbox;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (final (index, tab) in _tabs.indexed)
            TickerMode(enabled: index == _index, child: tab),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: outbox ?? const _NoReports(),
        builder: (context, _) {
          final count = outbox?.reports.length ?? 0;
          return M3ENavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _select,
            destinations: [
              const M3ENavigationBarDestination(
                icon: Icon(M3EIcons.science_outlined),
                selectedIcon: Icon(M3EIcons.science),
                label: 'Study',
              ),
              const M3ENavigationBarDestination(
                icon: Icon(M3EIcons.bolt_outlined),
                selectedIcon: Icon(M3EIcons.bolt),
                label: 'Try it',
              ),
              M3ENavigationBarDestination(
                icon: const Icon(M3EIcons.receipt_long_outlined),
                selectedIcon: const Icon(M3EIcons.receipt_long),
                label: 'Reports',
                badgeCount: count == 0 ? null : count,
                semanticLabel: count == 0 ? 'Reports' : 'Reports, $count',
              ),
            ],
          );
        },
      ),
    );
  }
}

// a listenable that never changes, for live mode without an outbox
class _NoReports implements Listenable {
  const _NoReports();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
