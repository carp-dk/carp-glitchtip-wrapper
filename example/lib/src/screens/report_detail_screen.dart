// Contains the screen with one report as GlitchTip would get it.
//
// Parts:
// - `ReportDetailScreen`, the exception or message, level, handled and
//   mechanism, tags (study tags highlighted), the `study` context, the
//   request and the breadcrumbs of a report.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import '../reporting/glitchtip_study.dart';
import '../reporting/report.dart';
import '../widgets/key_values.dart';
import '../widgets/pills.dart';
import '../widgets/sections.dart';
import '../widgets/shape_icon.dart';
import '../widgets/page_app_bar.dart';
import 'reports_tab.dart';

/// One report, as GlitchTip would get it after the wrapper's privacy
/// policy.
class ReportDetailScreen extends StatelessWidget {
  /// Creates the screen of [report].
  const ReportDetailScreen({super.key, required this.report});

  /// The report.
  final Report report;

  @override
  Widget build(BuildContext context) {
    final tags = report.tags;
    final study = report.studyContext;
    final request = report.request;
    final breadcrumbs = report.breadcrumbs.reversed.toList();
    final transaction = report.kind == ReportKind.transaction;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          PageAppBar(
            variant: M3EAppBarVariant.mediumFlexible,
            title: switch (report.kind) {
              ReportKind.error => 'Error',
              ReportKind.message => 'Message',
              ReportKind.transaction => 'Transaction',
            },
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: SliverList.list(
              children: [
                _Header(report),
                if (tags.isNotEmpty) ...[
                  SectionHeader(
                    'Tags',
                    subtitle: report.hasStudy
                        ? 'Searchable in GlitchTip. The study tags are '
                              'highlighted.'
                        : 'Searchable in GlitchTip. No study was known yet.',
                  ),
                  KeyValueList([
                    for (final MapEntry(:key, :value) in tags.entries)
                      KeyValue(
                        key,
                        value,
                        highlighted: studyTagKeys.contains(key),
                      ),
                  ]),
                ],
                if (study != null) ...[
                  const SectionHeader('study context'),
                  KeyValueList([
                    for (final MapEntry(:key, :value) in study.entries)
                      KeyValue(
                        key,
                        KeyValueList.format(value),
                        highlighted: true,
                      ),
                  ]),
                ],
                if (request != null) ...[
                  const SectionHeader(
                    'Request',
                    subtitle: 'Without query, ids replaced by placeholders.',
                  ),
                  MonospaceBox(
                    [?request.$1, ?request.$2].join(' '),
                    semanticLabel: 'Request',
                  ),
                ],
                if (!transaction) ...[
                  SectionHeader(
                    'Breadcrumbs',
                    subtitle: breadcrumbs.isEmpty
                        ? 'Nothing happened before this report.'
                        : 'What happened before, newest first.',
                  ),
                  if (breadcrumbs.isNotEmpty) _Breadcrumbs(breadcrumbs),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.report);

  final Report report;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final scheme = theme.colorScheme;
    final unhandled = report.handled == 'no';
    final value = report.errorValue;
    final duration = report.duration;
    return SectionCard(
      color: unhandled ? scheme.errorContainer : scheme.surfaceContainerLow,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShapeIcon(
            report.icon,
            shape: report.shape,
            size: 64,
            color: unhandled ? scheme.error : scheme.primaryContainer,
            iconColor: unhandled ? scheme.onError : scheme.onPrimaryContainer,
          ),
          const SizedBox(height: 16),
          SelectableText(
            report.title,
            style: theme.typography.emphasized.headlineSmall.copyWith(
              color: unhandled ? scheme.onErrorContainer : scheme.onSurface,
            ),
          ),
          if (value != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              value,
              style: theme.typeScale.bodyLarge.copyWith(
                color: unhandled
                    ? scheme.onErrorContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (report.level case final level?)
                InfoPill(
                  'level: $level',
                  icon: M3EIcons.warning_amber,
                  tone: unhandled ? PillTone.error : PillTone.neutral,
                ),
              if (report.handled case final handled?)
                InfoPill(
                  'handled: $handled',
                  icon: unhandled ? M3EIcons.report_problem : M3EIcons.check,
                  tone: unhandled ? PillTone.error : PillTone.secondary,
                ),
              if (report.mechanism case final mechanism?)
                InfoPill(mechanism, icon: M3EIcons.code),
              if (report.screen case final screen?)
                InfoPill('screen: $screen', icon: M3EIcons.route),
              if (report.operation case final operation?
                  when report.kind == ReportKind.transaction)
                InfoPill(
                  operation,
                  icon: M3EIcons.category,
                  tone: PillTone.tertiary,
                ),
              if (report.status case final status?
                  when report.kind == ReportKind.transaction)
                InfoPill('status: $status', icon: M3EIcons.check_circle),
              if (duration != null)
                InfoPill(
                  '${duration.inMilliseconds} ms',
                  icon: M3EIcons.timer_outlined,
                  tone: PillTone.tertiary,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs(this.breadcrumbs);

  final List<Breadcrumb> breadcrumbs;

  static IconData _icon(Breadcrumb crumb) => switch (crumb.category) {
    'http' => M3EIcons.lan,
    'navigation' => M3EIcons.route,
    'app.lifecycle' => M3EIcons.smartphone,
    _ => M3EIcons.circle,
  };

  static String _summary(Breadcrumb crumb) {
    final data = crumb.data ?? const <String, dynamic>{};
    return switch (crumb.category) {
      'http' => [
        '${data['method'] ?? ''} ${data['url'] ?? ''}'.trim(),
        if (data['status_code'] case final status?) '$status',
        if (data['reason'] case final reason?) '$reason',
        if (data['duration'] case final duration?) '$duration',
      ].join(' · '),
      'navigation' => [
        '${data['state'] ?? ''}',
        '${data['from'] ?? '–'} → ${data['to'] ?? '–'}',
      ].join(' · '),
      _ =>
        crumb.message ??
            [for (final MapEntry(:key, :value) in data.entries) '$key: $value']
                .join(', '),
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    return M3EList(
      itemCount: breadcrumbs.length,
      itemBuilder: (context, index) {
        final crumb = breadcrumbs[index];
        final time = crumb.timestamp.toLocal();
        return M3EListItem(
          leading: Icon(_icon(crumb), color: scheme.onSurfaceVariant),
          headline: crumb.category ?? crumb.type ?? 'breadcrumb',
          supportingText: _summary(crumb),
          trailingText: [
            time.hour,
            time.minute,
            time.second,
          ].map((part) => part.toString().padLeft(2, '0')).join(':'),
        );
      },
    );
  }
}
