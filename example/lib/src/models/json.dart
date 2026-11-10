// Contains tolerant readers for the CAWS JSON of the sample data.
//
// Parts:
// - `JsonReading`, getters that return `null` (or nothing) for a missing
//   field or a field of another type, so unknown or partial JSON never
//   throws.

/// Tolerant readers of decoded JSON objects.
extension JsonReading on Map<String, Object?> {
  /// The string at [key], or `null`.
  String? string(String key) => switch (this[key]) {
    final String value => value,
    _ => null,
  };

  /// The JSON object at [key], or `null`.
  Map<String, Object?>? object(String key) => switch (this[key]) {
    final Map<String, Object?> value => value,
    _ => null,
  };

  /// The JSON objects in the list at [key]; empty when there is none.
  List<Map<String, Object?>> objects(String key) => switch (this[key]) {
    final List<Object?> list => list.whereType<Map<String, Object?>>().toList(),
    _ => const [],
  };

  /// The strings in the list at [key], or `null` when there is no list.
  List<String>? strings(String key) => switch (this[key]) {
    final List<Object?> list => list.whereType<String>().toList(),
    _ => null,
  };

  /// The number of entries of the list or object at [key]; 0 for anything
  /// else. CAWS sends a protocol's triggers as an object keyed by id.
  int count(String key) => switch (this[key]) {
    final List<Object?> list => list.length,
    final Map<String, Object?> map => map.length,
    _ => 0,
  };
}
