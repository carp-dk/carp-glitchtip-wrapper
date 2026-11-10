// Contains helpers for the texts of the example app.
//
// Parts:
// - `countOf`, a count with its noun in the singular or plural.

/// [count] with [one] or, unless [count] is 1, [many] (by default [one]
/// with an s), e.g. `1 task` and `16 tasks`.
String countOf(int count, String one, [String? many]) =>
    '$count ${count == 1 ? one : many ?? '${one}s'}';
