// Contains the sheet with the state of GlitchTip reporting.
//
// Parts:
// - `StatusAction`, the app bar action that opens the sheet.
// - `showStatusSheet`, which shows the status line, the mode, the
//   environment, the DSN label and the sample rates.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../state/example_scope.dart';
import '../widgets/network_switcher.dart';
import '../widgets/reporting_mode_card.dart';
import '../widgets/sections.dart';

/// The app bar action that opens the GlitchTip status sheet.
class StatusAction extends StatelessWidget {
  /// Creates the action.
  const StatusAction({super.key});

  @override
  Widget build(BuildContext context) => M3EIconButton(
    variant: M3EIconButtonVariant.standard,
    icon: const Icon(M3EIcons.monitor_heart_outlined),
    tooltip: 'GlitchTip status',
    onPressed: () => showStatusSheet(context),
  );
}

/// Shows the state of GlitchTip reporting: mode, status line, environment,
/// DSN (without its key) and sample rates.
Future<void> showStatusSheet(BuildContext context) => M3EBottomSheet.show<void>(
  context,
  builder: (context) => const _StatusSheet(),
);

class _StatusSheet extends StatefulWidget {
  const _StatusSheet();

  @override
  State<_StatusSheet> createState() => _StatusSheetState();
}

class _StatusSheetState extends State<_StatusSheet> {
  String? _sent;

  Future<void> _sendTestReport() async {
    final state = ExampleScope.read(context).state;
    final onboarding = state.onboarding.tag;
    await CarpGlitchTip.captureMessage('Test report while $onboarding');
    if (!mounted) return;
    setState(() {
      _sent = CarpGlitchTip.isEnabled
          ? 'Sent a message with onboarding: $onboarding'
                '${state.study == null ? ' and no study tags.' : ' and the study.'}'
          : 'Reporting is off: nothing was sent.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final status = CarpGlitchTip.status;
    final preview = ExampleScope.watch(context).outbox != null;
    String rate(double? value) =>
        value == null ? '–' : '${(value * 100).round()} %';
    final rows = <(String, String)>[
      ('Mode', preview ? 'Preview (outbox on the device)' : 'Live'),
      ('Environment', status.environment ?? '–'),
      ('DSN', status.dsn ?? 'none'),
      ('Errors sent', rate(status.sampleRate)),
      ('Traces recorded', rate(status.tracesSampleRate)),
      ('Requests recorded', rate(status.httpSampleRate)),
      ('Build mode', status.buildMode ?? '–'),
      ('HTTP instrumented', status.httpInstrumented ? 'yes' : 'no'),
    ];
    final sent = _sent;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Semantics(
          header: true,
          child: Text(
            'GlitchTip status',
            style: theme.typography.emphasized.headlineSmall.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const ReportingModeCard(),
        const SectionHeader('Configuration'),
        M3EList(
          itemCount: rows.length,
          itemBuilder: (context, index) =>
              M3EListItem(headline: rows[index].$2, overline: rows[index].$1),
        ),
        const SectionHeader(
          'Sample CAWS',
          subtitle: 'How the in-process server at caws.example.org answers.',
        ),
        const NetworkConditionCard(),
        const SectionHeader(
          'Test report',
          subtitle:
              'A message with the tags of this moment, e.g. before sign-in.',
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: M3EButton.tonal(
            icon: const Icon(M3EIcons.send),
            label: const Text('Send a test report'),
            onPressed: _sendTestReport,
          ),
        ),
        if (sent != null) ...[
          const SizedBox(height: 12),
          Text(
            sent,
            style: theme.typeScale.bodyMedium.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
