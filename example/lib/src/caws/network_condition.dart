// Contains the network conditions the sample CAWS server can simulate.
//
// Parts:
// - `NetworkCondition`, switched by the user on the Try it tab.

/// How the sample CAWS server answers, to show what the wrapper reports in
/// each situation a CARP app meets in the field.
enum NetworkCondition {
  /// Every request succeeds after a short delay.
  online(
    label: 'Online',
    description:
        'CAWS answers every request. Requests are recorded as breadcrumbs '
        'and transactions.',
  ),

  /// Requests fail like on a phone without a connection.
  offline(
    label: 'Offline',
    description:
        "Requests fail with \"Failed host lookup: 'caws.example.org'\", like "
        'on a phone without signal. The wrapper ignores these errors.',
  ),

  /// CAWS answers with an internal server error.
  serverError(
    label: 'Error',
    semanticLabel: 'Server error',
    description:
        'CAWS answers HTTP 500. The wrapper reports it, at most once per '
        '10 minutes per request.',
  ),

  /// Requests succeed after a long delay.
  slow(
    label: 'Slow',
    description:
        'CAWS answers after 2.5 seconds. The transactions in GlitchTip show '
        'the slow responses.',
  );

  const NetworkCondition({
    required this.label,
    required this.description,
    String? semanticLabel,
  }) : semanticLabel = semanticLabel ?? label;

  /// A short name, e.g. for a segmented control.
  final String label;

  /// The full name, e.g. for screen readers.
  final String semanticLabel;

  /// What happens to requests in this condition.
  final String description;
}
