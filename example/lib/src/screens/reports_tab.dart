// Contains the Reports tab: what GlitchTip gets.
//
// Parts:
// - `ReportsTab`, the reports of preview mode, newest first, or where
//   reports go in live mode.
// - `ReportVisuals`, the icon and shape of each kind of report.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../app/example_routes.dart';
import '../app/texts.dart';
import '../reporting/report.dart';
import '../reporting/report_outbox.dart';
import '../state/example_scope.dart';
import '../widgets/reporting_mode_card.dart';
import '../widgets/sections.dart';
import '../widgets/shape_icon.dart';
import '../widgets/page_app_bar.dart';
import 'status_sheet.dart';

/// How each kind of report looks.
extension ReportVisuals on Report {
  /// The icon of the report.
  IconData get icon => switch (kind) {
    ReportKind.error =>
      handled == 'no' ? M3EIcons.report_problem : M3EIcons.bug_report,
    ReportKind.message => M3EIcons.mail_outline,
    ReportKind.transaction => M3EIcons.timer_outlined,
  };

  /// The shape of the report's icon container.
  IconShape get shape => switch (kind) {
    ReportKind.error =>
      handled == 'no' ? IconShape.softBoom : IconShape.cookie9,
    ReportKind.message => IconShape.puffy,
    ReportKind.transaction => IconShape.pill,
  };

  /// A one-line summary below the title.
  String get summary {
    final duration = this.duration;
    return switch (kind) {
      ReportKind.transaction => [
        ?operation,
        ?status,
        if (duration != null) '${duration.inMilliseconds} ms',
      ].join(' · '),
      _ => [
        ?errorValue,
        if (handled case final handled?) 'handled: $handled',
        hasStudy ? 'with study' : 'no study',
      ].join(' · '),
    };
  }
}

/// The reports GlitchTip gets. In preview mode they are listed, newest
/// first; in live mode the tab says where they go.
class ReportsTab extends StatelessWidget {
  /// Creates the Reports tab.
  const ReportsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final outbox = ExampleScope.watch(context).outbox;
    if (outbox == null) return const _LiveReports();
    return ListenableBuilder(
      listenable: outbox,
      builder: (context, _) => _PreviewReports(outbox),
    );
  }
}

class _PreviewReports extends StatelessWidget {
  const _PreviewReports(this.outbox);

  final ReportOutbox outbox;

  @override
  Widget build(BuildContext context) {
    final reports = outbox.reports;
    final errors = reports.where((r) => r.kind != ReportKind.transaction);
    return CustomScrollView(
      slivers: [
        PageAppBar(
          title: 'Reports',
          subtitle: reports.isEmpty
              ? 'Preview: reports stay on this device'
              : '${countOf(errors.length, 'error or message', 'errors and messages')}, '
                    '${countOf(reports.length - errors.length, 'transaction')}',
          actions: [
            if (reports.isNotEmpty)
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(M3EIcons.delete_sweep_outlined),
                tooltip: 'Clear reports',
                onPressed: outbox.clear,
              ),
            const StatusAction(),
          ],
        ),
        if (reports.isEmpty)
          const SliverFillRemaining(hasScrollBody: false, child: _Empty())
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: M3EList.sliver(
              itemCount: reports.length,
              onTap: (index) => Navigator.of(context)
                  .pushNamed(ExampleRoutes.report, arguments: reports[index]),
              semanticLabelBuilder: (index) {
                final report = reports[index];
                return '${report.title}, ${report.summary}';
              },
              itemBuilder: (context, index) => _ReportItem(reports[index]),
            ),
          ),
      ],
    );
  }
}

class _ReportItem extends StatelessWidget {
  const _ReportItem(this.report);

  final Report report;

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    final time = report.time;
    final (color, iconColor) = switch (report.kind) {
      ReportKind.error when report.handled == 'no' => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      ReportKind.error || ReportKind.message => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      ReportKind.transaction => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
    };
    return M3EListItem(
      leading: ShapeIcon(
        report.icon,
        shape: report.shape,
        size: 40,
        color: color,
        iconColor: iconColor,
      ),
      headline: report.title,
      supportingText: report.summary,
      trailingText: time == null ? null : _clock(time),
    );
  }

  static String _clock(DateTime time) => [
    time.hour,
    time.minute,
    time.second,
  ].map((part) => part.toString().padLeft(2, '0')).join(':');
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 64),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ShapeIcon(
            M3EIcons.inbox,
            shape: IconShape.cookie12,
            size: 120,
            color: scheme.surfaceContainerHigh,
            iconColor: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 24),
          Text(
            'No reports yet',
            style: theme.typography.emphasized.headlineSmall.copyWith(
              color: scheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Errors, messages and transactions appear here as GlitchTip '
            'would get them. Try something on the Try it tab.',
            style: theme.typeScale.bodyMedium.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _LiveReports extends StatelessWidget {
  const _LiveReports();

  @override
  Widget build(BuildContext context) {
    final study = CarpGlitchTip.study;
    final searches = [
      if (study != null)
        ('study_deployment_id:${study.studyDeploymentId}', 'this deployment'),
      ('handled:no', 'errors the app did not catch'),
      ('onboarding:signed_in', 'reports before a study was accepted'),
    ];
    return CustomScrollView(
      slivers: [
        PageAppBar(
          title: 'Reports',
          subtitle: ReportingModeCard.liveTitle(CarpGlitchTip.status),
          actions: const [StatusAction()],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          sliver: SliverList.list(
            children: [
              const ReportingModeCard(),
              const SectionHeader(
                'Find them in GlitchTip',
                subtitle: 'Search the issues of the project, e.g.',
              ),
              M3EList(
                itemCount: searches.length,
                itemBuilder: (context, index) => M3EListItem(
                  headline: searches[index].$1,
                  supportingText: searches[index].$2,
                  leading: const Icon(M3EIcons.manage_search),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
