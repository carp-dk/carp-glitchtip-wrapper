import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../util/diagnostics.dart';
import 'glitchtip_tags.dart';
import 'study_metadata.dart';

/// The metadata the wrapper attaches to every event: its own tags, the
/// study and the app's tags and contexts.
///
/// This state is the single source of truth. Changes are applied to it
/// synchronously, so the latest call always wins whether it was made
/// before or after init, and then synced to the Sentry scope (which also
/// syncs it to the native SDKs for native crash reports) one diff at a time.
class ScopeState {
  /// Tags the wrapper sets at init, e.g. the build mode.
  Map<String, String> baseTags = const {};

  /// The user every event is reported with: a random id per app launch.
  SentryUser? user;

  final Map<String, String> _appTags = {};
  final Map<String, Map<String, Object?>> _appContexts = {};
  StudyMetadata? _study;
  String? _screen;

  /// When the breadcrumbs of a study were last cleared, see [setStudy].
  /// Events must not carry breadcrumbs from before this time.
  DateTime? breadcrumbsClearedAt;

  bool _active = false;
  Map<String, String> _pushedTags = {};
  Map<String, Map<String, Object?>> _pushedContexts = {};
  bool _userPushed = false;
  bool _dirty = false;
  Future<void>? _syncing;

  /// The current study.
  StudyMetadata? get study => _study;

  /// The screen the app shows, see [GlitchTipTags.screen].
  String? get screen => _screen;

  set screen(String? screen) {
    if (screen == _screen) return;
    _screen = screen;
    _changed();
  }

  /// Sets the current [study]; `null` clears it. Leaving a study deployment
  /// (also for another one) clears the breadcrumbs recorded during it.
  void setStudy(StudyMetadata? study) {
    if (study == _study) return;
    final previous = _study;
    if (previous != null &&
        study?.studyDeploymentId != previous.studyDeploymentId) {
      // events drop older breadcrumbs, also those the native SDK adds
      breadcrumbsClearedAt = DateTime.now().toUtc();
      // the scope at once, also while the SDK is still starting: the Dart
      // list is cleared synchronously, the native one through the scope
      // observer; without a running SDK there is nothing to clear
      if (Sentry.isEnabled) {
        guard('clearing breadcrumbs', () {
          return Sentry.configureScope((scope) {
            unawaited(scope.clearBreadcrumbs());
          });
        });
      }
    }
    _study = study;
    _changed();
  }

  /// Where [refresh] reads the current study from, see
  /// `CarpGlitchTip.bindStudy`.
  StudyMetadata? Function()? studyReader;

  /// Re-reads the study from the bound reader, if any. A reader that
  /// throws (e.g. because the app's settings are not loaded yet) leaves the
  /// study unchanged.
  void refresh() {
    final reader = studyReader;
    if (reader == null) return;
    final StudyMetadata? study;
    try {
      study = reader();
    } catch (error) {
      debugWarn('reading the study failed: $error', once: true);
      return;
    }
    setStudy(study);
  }

  /// Sets or, with a `null` value, removes app tags.
  void setTags(Map<String, String?> tags) {
    tags.forEach((key, value) {
      if (GlitchTipTags.all.contains(key)) {
        debugWarn('tag "$key" is set by the wrapper and is ignored');
      } else if (value == null) {
        _appTags.remove(key);
      } else {
        _appTags[key] = value.length <= 200 ? value : value.substring(0, 200);
      }
    });
    _changed();
  }

  /// Context keys that the Sentry SDK, Flutter or the wrapper own. The SDK
  /// reads its keys as typed objects: an app map under one of them would
  /// make it drop every event.
  static const reservedContexts = {
    'app',
    'browser',
    'culture',
    'device',
    'feedback',
    'flags',
    'gpu',
    'os',
    'response',
    'runtime',
    'runtimes',
    'trace',
    'accessibility',
    'carp_glitchtip',
    'dart_context',
    'flutter_context',
    'flutter_error_details',
    'study',
  };

  /// Sets or, with a `null` value, removes an app context.
  void setContext(String key, Map<String, Object?>? value) {
    if (reservedContexts.contains(key)) {
      debugWarn('context "$key" is reserved and is ignored');
      return;
    }
    if (value == null) {
      _appContexts.remove(key);
    } else {
      _appContexts[key] = Map.unmodifiable(value);
    }
    _changed();
  }

  /// The tags every event gets.
  Map<String, String> get tags => {
    ..._appTags,
    ...?_study?.toTags(),
    ...baseTags,
    GlitchTipTags.screen: ?_screen,
  };

  /// The contexts every event gets.
  Map<String, Map<String, Object?>> get contexts => {
    ..._appContexts,
    if (_study != null) 'study': _study!.toContext(),
  };

  /// Puts the current metadata on [event], in case it was captured before
  /// the latest change reached the scope.
  void stamp(SentryEvent event) {
    final tags = this.tags;
    event.tags = {
      for (final entry in (event.tags ?? const <String, String>{}).entries)
        if (tags.containsKey(entry.key) || !_pushedTags.containsKey(entry.key))
          entry.key: entry.value,
      ...tags,
    };
    final contexts = this.contexts;
    for (final key in _pushedContexts.keys) {
      if (!contexts.containsKey(key)) event.contexts.remove(key);
    }
    contexts.forEach((key, value) => event.contexts[key] = value);
  }

  /// Starts syncing to the Sentry scope, once the SDK is running.
  void activate() {
    _active = true;
    _changed();
  }

  /// Stops syncing, e.g. when the SDK is closed.
  void deactivate() {
    _active = false;
    _pushedTags = {};
    _pushedContexts = {};
    _userPushed = false;
  }

  void _changed() {
    if (!_active) return;
    _dirty = true;
    _syncing ??= _drain();
  }

  Future<void> _drain() async {
    try {
      while (_dirty && _active) {
        _dirty = false;
        await _push();
      }
    } catch (error) {
      debugWarn('syncing the scope failed: $error', once: true);
    } finally {
      _syncing = null;
    }
  }

  Future<void> _push() async {
    final tags = this.tags;
    final contexts = this.contexts;
    final user = _userPushed ? null : this.user;

    final removedTags = [
      for (final key in _pushedTags.keys)
        if (!tags.containsKey(key)) key,
    ];
    final changedTags = {
      for (final entry in tags.entries)
        if (_pushedTags[entry.key] != entry.value) entry.key: entry.value,
    };
    final removedContexts = [
      for (final key in _pushedContexts.keys)
        if (!contexts.containsKey(key)) key,
    ];
    final changedContexts = {
      for (final entry in contexts.entries)
        if (!mapEquals(_pushedContexts[entry.key], entry.value))
          entry.key: entry.value,
    };
    _pushedTags = tags;
    _pushedContexts = contexts;
    _userPushed = true;

    if (removedTags.isEmpty &&
        changedTags.isEmpty &&
        removedContexts.isEmpty &&
        changedContexts.isEmpty &&
        user == null) {
      return;
    }
    await Sentry.configureScope((scope) async {
      // all calls of one diff without awaiting in between, so the Dart
      // scope is never seen half updated
      await Future.wait([
        if (user != null) scope.setUser(user),
        for (final key in removedTags) scope.removeTag(key),
        for (final entry in changedTags.entries)
          scope.setTag(entry.key, entry.value),
        for (final key in removedContexts)
          Future.sync(() => scope.removeContexts(key)),
        for (final entry in changedContexts.entries)
          Future.sync(() => scope.setContexts(entry.key, entry.value)),
      ]);
    });
  }
}
