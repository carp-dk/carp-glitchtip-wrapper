// Contains the list of tags or context values GlitchTip gets.
//
// Parts:
// - `KeyValue`, one tag or context value.
// - `KeyValueList`, an expressive segmented list of them, with the study's
//   values highlighted.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

/// One tag or context value.
class KeyValue {
  /// Creates an entry; [highlighted] entries belong to the study.
  const KeyValue(this.key, this.value, {this.highlighted = false});

  /// The tag or context key, e.g. `study_deployment_id`.
  final String key;

  /// The value.
  final String value;

  /// Whether the entry belongs to the study.
  final bool highlighted;
}

/// Tags or context values as GlitchTip gets them, the study's values
/// highlighted.
class KeyValueList extends StatelessWidget {
  /// Creates a list of [entries].
  const KeyValueList(this.entries, {super.key, this.highlightLabel = 'study'});

  /// The entries, in display order.
  final List<KeyValue> entries;

  /// What screen readers say about highlighted entries.
  final String highlightLabel;

  /// Formats a context or tag value: lists are joined, `null` is `–`.
  static String format(Object? value) => switch (value) {
    null => '–',
    final List<Object?> list => list.join(', '),
    final Map<Object?, Object?> map => [
      for (final MapEntry(:key, :value) in map.entries) '$key: $value',
    ].join(', '),
    _ => '$value',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    return M3EList(
      itemCount: entries.length,
      colorBuilder: (index) =>
          entries[index].highlighted ? scheme.primaryContainer : null,
      semanticLabelBuilder: (index) {
        final entry = entries[index];
        return '${entry.key}: ${entry.value}'
            '${entry.highlighted ? ', $highlightLabel' : ''}';
      },
      itemBuilder: (context, index) {
        final entry = entries[index];
        return M3EListItem(
          headline: entry.key,
          supportingText: entry.value,
          trailing: entry.highlighted
              ? Icon(M3EIcons.science, color: scheme.onPrimaryContainer)
              : null,
        );
      },
    );
  }
}
