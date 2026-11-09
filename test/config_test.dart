// Tests for the configuration: the env sources, resolving options and env
// into the config the wrapper runs with, the DSN helpers and the status line.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/src/config/dsn.dart';
import 'package:carp_glitchtip_wrapper/src/config/resolve.dart';
import 'package:carp_glitchtip_wrapper/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

// A DSN key (and secret) that must never show up in a status or a log line.
const _key = 'SECRETKEY';
const _secret = 'SECRETPASS';
const _dsn = 'https://$_key@glitchtip.example.com/7';

/// Resolves [options] with [env] as the only env source, chained like init
/// chains `options.env` and the compile-time defines.
ResolvedConfig resolve(
  CarpGlitchTipOptions options, {
  Map<String, String?> env = const {},
  String buildMode = 'release',
  bool isFlutterTest = false,
}) => resolveConfig(
  options,
  lookup: GlitchTipEnv.chain([GlitchTipEnv.fromMap(env)]),
  buildMode: buildMode,
  isFlutterTest: isFlutterTest,
);

/// Waits until [condition] holds, for at most a second.
Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

// '[::1]' is not accepted: the Sentry SDK cannot build its ingest URL
// for an IPv6 host
const _localHosts = ['localhost', '127.0.0.1', '10.0.2.2'];

// DSNs that must be accepted, with the build mode they are used in.
final _validDsns = [
  (what: 'an https URL', dsn: _dsn, mode: 'release'),
  (
    what: 'a secret key',
    dsn: 'https://$_key:$_secret@glitchtip.example.com/7',
    mode: 'release',
  ),
  (
    what: 'a port',
    dsn: 'https://$_key@glitchtip.example.com:8443/7',
    mode: 'profile',
  ),
  (
    what: 'a path prefix',
    dsn: 'https://$_key@glitchtip.example.com/glitchtip/7',
    mode: 'release',
  ),
  (what: 'https in a debug build', dsn: _dsn, mode: 'debug'),
  for (final host in _localHosts)
    (
      what: 'http for $host in a debug build',
      dsn: 'http://$_key@$host:8000/7',
      mode: 'debug',
    ),
];

// DSNs that must be rejected, with a word the problem must mention.
final _invalidDsns = [
  (
    what: 'no scheme',
    dsn: '$_key@glitchtip.example.com/7',
    mode: 'release',
    problem: 'URL',
  ),
  (what: 'text', dsn: 'not a dsn', mode: 'release', problem: 'URL'),
  (what: 'no host', dsn: 'https://$_key@/7', mode: 'release', problem: 'URL'),
  (
    what: 'an unparsable port',
    dsn: 'https://$_key@glitchtip.example.com:port/7',
    mode: 'release',
    problem: 'URL',
  ),
  (
    what: 'no public key',
    dsn: 'https://glitchtip.example.com/7',
    mode: 'release',
    problem: 'key',
  ),
  (
    what: 'only a secret key',
    dsn: 'https://:$_secret@glitchtip.example.com/7',
    mode: 'release',
    problem: 'key',
  ),
  (
    what: 'no project id',
    dsn: 'https://$_key@glitchtip.example.com',
    mode: 'release',
    problem: 'project',
  ),
  (
    what: 'only a slash as path',
    dsn: 'https://$_key@glitchtip.example.com/',
    mode: 'release',
    problem: 'project',
  ),
  (
    what: 'another scheme',
    dsn: 'ftp://$_key@glitchtip.example.com/7',
    mode: 'release',
    problem: 'https',
  ),
  (
    what: 'http for a remote host in a debug build',
    dsn: 'http://$_key@glitchtip.example.com/7',
    mode: 'debug',
    problem: 'https',
  ),
  (
    what: 'http for a LAN address in a debug build',
    dsn: 'http://$_key@192.168.1.10:8000/7',
    mode: 'debug',
    problem: 'https',
  ),
  for (final mode in ['profile', 'release'])
    for (final host in _localHosts)
      (
        what: 'http for $host in a $mode build',
        dsn: 'http://$_key@$host:8000/7',
        mode: mode,
        problem: 'https',
      ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GlitchTipEnv', () {
    test('keys have the documented names', () {
      expect(GlitchTipKeys.dsn, 'GLITCHTIP_DSN');
      expect(GlitchTipKeys.enabled, 'GLITCHTIP_ENABLED');
      expect(GlitchTipKeys.environment, 'GLITCHTIP_ENVIRONMENT');
      expect(GlitchTipKeys.release, 'GLITCHTIP_RELEASE');
      expect(GlitchTipKeys.dist, 'GLITCHTIP_DIST');
      expect(GlitchTipKeys.debug, 'GLITCHTIP_DEBUG');
      expect(GlitchTipKeys.sampleRate, 'GLITCHTIP_SAMPLE_RATE');
      expect(GlitchTipKeys.tracesSampleRate, 'GLITCHTIP_TRACES_SAMPLE_RATE');
      expect(GlitchTipKeys.httpSampleRate, 'GLITCHTIP_HTTP_SAMPLE_RATE');
      expect(GlitchTipKeys.sentryDsn, 'SENTRY_DSN');
      expect(GlitchTipKeys.sentryEnvironment, 'SENTRY_ENVIRONMENT');
      expect(GlitchTipKeys.sentryRelease, 'SENTRY_RELEASE');
      expect(GlitchTipKeys.sentryDist, 'SENTRY_DIST');
      expect(GlitchTipKeys.deploymentMode, 'deployment-mode');
    });

    test('compileTime is null for a key the wrapper does not read', () {
      expect(GlitchTipEnv.compileTime('NOT_A_GLITCHTIP_KEY'), isNull);
      expect(GlitchTipEnv.compileTime(''), isNull);
    });

    test('compileTime is null for known keys that were not defined', () {
      // this suite runs without --dart-define
      for (final key in GlitchTipKeys.all) {
        expect(GlitchTipEnv.compileTime(key), isNull, reason: key);
      }
    });

    test('compileTime knows every key the wrapper reads', () {
      expect(GlitchTipEnv.defines.keys, unorderedEquals(GlitchTipKeys.all));
    });

    test('fromMap looks keys up in the map', () {
      final lookup = GlitchTipEnv.fromMap({'A': 'a', 'B': null});
      expect(lookup('A'), 'a');
      expect(lookup('B'), isNull);
      expect(lookup('C'), isNull);
    });

    group('chain', () {
      test('returns the value of the first source that has the key', () {
        final lookup = GlitchTipEnv.chain([
          GlitchTipEnv.fromMap({'A': 'first'}),
          GlitchTipEnv.fromMap({'A': 'second', 'B': 'second'}),
        ]);
        expect(lookup('A'), 'first');
        expect(lookup('B'), 'second');
        expect(lookup('C'), isNull);
      });

      test('trims values', () {
        final lookup = GlitchTipEnv.chain([
          GlitchTipEnv.fromMap({'A': ' \t a b \n'}),
        ]);
        expect(lookup('A'), 'a b');
      });

      test('skips empty and white space values', () {
        final lookup = GlitchTipEnv.chain([
          GlitchTipEnv.fromMap({'A': '', 'B': ' \t\n'}),
          GlitchTipEnv.fromMap({'A': 'a', 'B': 'b'}),
        ]);
        expect(lookup('A'), 'a');
        expect(lookup('B'), 'b');
      });

      test("skips the text 'null' in any case", () {
        for (final text in ['null', 'NULL', 'Null', ' null ']) {
          final lookup = GlitchTipEnv.chain([
            GlitchTipEnv.fromMap({'A': text, 'B': text}),
            GlitchTipEnv.fromMap({'A': 'a'}),
          ]);
          expect(lookup('A'), 'a', reason: text);
          expect(lookup('B'), isNull, reason: text);
        }
      });

      test("keeps values that only contain 'null'", () {
        final lookup = GlitchTipEnv.chain([
          GlitchTipEnv.fromMap({'A': 'nullable', 'B': 'not null'}),
        ]);
        expect(lookup('A'), 'nullable');
        expect(lookup('B'), 'not null');
      });

      test('skips a source that throws', () {
        final lookup = GlitchTipEnv.chain([
          (key) => throw StateError('not loaded yet'),
          (key) => throw const FormatException('bad define file'),
          (key) => key == 'A' ? throw UnsupportedError('A') : 'b',
          GlitchTipEnv.fromMap({'A': 'a'}),
        ]);
        expect(lookup('A'), 'a');
        expect(lookup('B'), 'b');
      });

      test('ignores null sources', () {
        final lookup = GlitchTipEnv.chain([
          null,
          GlitchTipEnv.fromMap({'A': 'a'}),
          null,
        ]);
        expect(lookup('A'), 'a');
      });

      test('returns null when no source has a usable value', () {
        expect(GlitchTipEnv.chain([])('A'), isNull);
        expect(GlitchTipEnv.chain([null])('A'), isNull);
        final lookup = GlitchTipEnv.chain([
          GlitchTipEnv.fromMap({'A': ' '}),
          (key) => throw StateError('broken'),
          GlitchTipEnv.fromMap({'A': 'null'}),
        ]);
        expect(lookup('A'), isNull);
      });
    });
  });

  group('resolveConfig', () {
    group('precedence', () {
      final settings = [
        (
          name: 'dsn',
          key: GlitchTipKeys.dsn,
          alias: GlitchTipKeys.sentryDsn,
          value: (String from) => 'https://$from@glitchtip.example.com/1',
          code: (String value) => CarpGlitchTipOptions(dsn: value),
          read: (ResolvedConfig config) => config.dsn,
          fallback: null,
        ),
        (
          name: 'environment',
          key: GlitchTipKeys.environment,
          alias: GlitchTipKeys.sentryEnvironment,
          value: (String from) => from,
          code: (String value) => CarpGlitchTipOptions(environment: value),
          read: (ResolvedConfig config) => config.environment,
          fallback: 'production',
        ),
        (
          name: 'release',
          key: GlitchTipKeys.release,
          alias: GlitchTipKeys.sentryRelease,
          value: (String from) => 'app@1.0.0+$from',
          code: (String value) => CarpGlitchTipOptions(release: value),
          read: (ResolvedConfig config) => config.release,
          fallback: null,
        ),
        (
          name: 'dist',
          key: GlitchTipKeys.dist,
          alias: GlitchTipKeys.sentryDist,
          value: (String from) => from,
          code: (String value) => CarpGlitchTipOptions(dist: value),
          read: (ResolvedConfig config) => config.dist,
          fallback: null,
        ),
      ];

      for (final s in settings) {
        group(s.name, () {
          final fromGlitchTip = s.value('glitchtip');
          final fromSentry = s.value('sentry');
          final inCode = s.value('code');

          test('${s.key} wins over ${s.alias} and code, with a warning', () {
            final config = resolve(
              s.code(inCode),
              env: {s.key: fromGlitchTip, s.alias: fromSentry},
            );
            expect(s.read(config), fromGlitchTip);
            expect(config.warnings, anyElement(contains(s.key)));
          });

          test('${s.alias} wins over code, with a warning', () {
            final config = resolve(s.code(inCode), env: {s.alias: fromSentry});
            expect(s.read(config), fromSentry);
            expect(config.warnings, anyElement(contains(s.alias)));
          });

          test('${s.key} or ${s.alias} alone is used', () {
            const none = CarpGlitchTipOptions();
            final glitchTip = resolve(none, env: {s.key: fromGlitchTip});
            expect(s.read(glitchTip), fromGlitchTip);
            expect(glitchTip.warnings, isEmpty);
            final sentry = resolve(none, env: {s.alias: fromSentry});
            expect(s.read(sentry), fromSentry);
            expect(sentry.warnings, isEmpty);
          });

          test('the value in code is used without an env key', () {
            final config = resolve(s.code(inCode));
            expect(s.read(config), inCode);
            expect(config.warnings, isEmpty);
          });

          test('falls back to ${s.fallback ?? 'null'} without any value', () {
            final config = resolve(const CarpGlitchTipOptions());
            expect(s.read(config), s.fallback);
          });
        });
      }

      test('a GLITCHTIP_ key in a later source wins over a SENTRY_ key in an '
          'earlier source', () {
        // e.g. SENTRY_ENVIRONMENT in options.env, GLITCHTIP_ENVIRONMENT
        // passed with --dart-define
        final config = resolveConfig(
          const CarpGlitchTipOptions(),
          lookup: GlitchTipEnv.chain([
            GlitchTipEnv.fromMap({GlitchTipKeys.sentryEnvironment: 'sentry'}),
            GlitchTipEnv.fromMap({GlitchTipKeys.environment: 'glitchtip'}),
          ]),
          buildMode: 'release',
        );
        expect(config.environment, 'glitchtip');
      });

      test('empty or white space strings in code count as unset', () {
        final config = resolve(
          const CarpGlitchTipOptions(
            dsn: '  ',
            environment: '',
            release: ' ',
            dist: '\t',
          ),
          env: {GlitchTipKeys.release: 'app@2.0.0+2'},
        );
        expect(config.disabledReason, DisabledReason.missingDsn);
        expect(config.environment, 'production');
        expect(config.release, 'app@2.0.0+2');
        expect(config.dist, isNull);
        // the env did not override a value set in code
        expect(config.warnings, isEmpty);
      });
    });

    group('enabled', () {
      // One row per case: the build mode, whether it runs under flutter
      // test, enabled in code, GLITCHTIP_ENABLED, the expected reason (null
      // when on) and whether a warning about GLITCHTIP_ENABLED is expected
      // (null when either is fine).
      void row(
        String name, {
        String mode = 'release',
        bool flutterTest = false,
        bool? code,
        String? env,
        DisabledReason? reason,
        bool? warns = false,
      }) {
        test(name, () {
          final config = resolve(
            CarpGlitchTipOptions(dsn: _dsn, enabled: code),
            env: {GlitchTipKeys.enabled: ?env},
            buildMode: mode,
            isFlutterTest: flutterTest,
          );
          expect(config.enabled, reason == null);
          expect(config.disabledReason, reason);
          if (reason == null) expect(config.dsn, _dsn);
          if (warns != null) {
            expect(
              config.warnings,
              warns ? anyElement(contains(GlitchTipKeys.enabled)) : isEmpty,
            );
          }
        });
      }

      const debugBuild = DisabledReason.debugBuild;
      const byConfig = DisabledReason.disabledByConfig;
      const underTest = DisabledReason.flutterTest;

      row(
        'is off by default in debug builds',
        mode: 'debug',
        reason: debugBuild,
      );
      row('is on by default in profile builds', mode: 'profile');
      row('is on by default in release builds');
      row('enabled: false in code turns it off', code: false, reason: byConfig);
      row(
        'enabled: false in code turns it off in debug builds',
        mode: 'debug',
        code: false,
        reason: byConfig,
      );
      row(
        'enabled: true in code turns it on in debug builds',
        mode: 'debug',
        code: true,
      );
      row(
        'GLITCHTIP_ENABLED=true turns it on in debug builds',
        mode: 'debug',
        env: 'true',
      );
      row(
        'GLITCHTIP_ENABLED=false turns it off',
        env: 'false',
        reason: byConfig,
      );
      row(
        'GLITCHTIP_ENABLED=false overrides enabled: true in code',
        code: true,
        env: 'false',
        reason: byConfig,
        warns: true,
      );
      row(
        'GLITCHTIP_ENABLED=true overrides enabled: false in code',
        mode: 'debug',
        code: false,
        env: 'true',
        warns: true,
      );
      row(
        'an invalid GLITCHTIP_ENABLED is ignored (release default)',
        env: 'maybe',
        warns: true,
      );
      row(
        'an invalid GLITCHTIP_ENABLED is ignored (debug default)',
        mode: 'debug',
        env: 'ture',
        reason: debugBuild,
        warns: true,
      );
      row(
        'an invalid GLITCHTIP_ENABLED keeps the value in code',
        code: false,
        env: 'enable',
        reason: byConfig,
        warns: true,
      );
      row(
        'is off under flutter test by default',
        mode: 'debug',
        flutterTest: true,
        reason: underTest,
      );
      row(
        'GLITCHTIP_ENABLED=true cannot turn it on under flutter test',
        mode: 'debug',
        flutterTest: true,
        env: 'true',
        reason: underTest,
        warns: null,
      );
      row(
        'enabled: false under flutter test is reported as flutterTest',
        mode: 'debug',
        flutterTest: true,
        code: false,
        env: 'true',
        reason: underTest,
        warns: null,
      );
      row(
        'enabled: true in code turns it on under flutter test',
        mode: 'debug',
        flutterTest: true,
        code: true,
      );
      row(
        'GLITCHTIP_ENABLED=false is ignored under flutter test',
        mode: 'debug',
        flutterTest: true,
        code: true,
        env: 'false',
        warns: null,
      );

      test('GLITCHTIP_ENABLED accepts true/1/yes/on and false/0/no/off', () {
        for (final value in ['true', '1', 'yes', 'on']) {
          final config = resolve(
            const CarpGlitchTipOptions(dsn: _dsn),
            env: {GlitchTipKeys.enabled: value},
            buildMode: 'debug',
          );
          expect(config.enabled, isTrue, reason: value);
          expect(config.warnings, isEmpty, reason: value);
        }
        for (final value in ['false', '0', 'no', 'off']) {
          final config = resolve(
            const CarpGlitchTipOptions(dsn: _dsn),
            env: {GlitchTipKeys.enabled: value},
          );
          expect(
            config.disabledReason,
            DisabledReason.disabledByConfig,
            reason: value,
          );
          expect(config.warnings, isEmpty, reason: value);
        }
      });

      test('is missingDsn when on without a DSN', () {
        for (final options in [
          const CarpGlitchTipOptions(),
          const CarpGlitchTipOptions(dsn: ''),
          const CarpGlitchTipOptions(dsn: ' \n '),
          const CarpGlitchTipOptions(enabled: true),
        ]) {
          final config = resolve(options, buildMode: 'profile');
          expect(config.enabled, isFalse);
          expect(config.disabledReason, DisabledReason.missingDsn);
          expect(config.dsn, isNull);
        }
        final underTest = resolve(
          const CarpGlitchTipOptions(enabled: true),
          buildMode: 'debug',
          isFlutterTest: true,
        );
        expect(underTest.disabledReason, DisabledReason.missingDsn);
      });

      test('is invalidDsn when on with an invalid DSN', () {
        final config = resolve(
          const CarpGlitchTipOptions(
            dsn: 'http://$_key@glitchtip.example.com/7',
          ),
        );
        expect(config.enabled, isFalse);
        expect(config.disabledReason, DisabledReason.invalidDsn);
        expect(config.dsn, isNull);
      });

      test('a build that is off anyway is not blamed on the DSN', () {
        final debug = resolve(const CarpGlitchTipOptions(), buildMode: 'debug');
        expect(debug.disabledReason, DisabledReason.debugBuild);
        final off = resolve(
          const CarpGlitchTipOptions(enabled: false, dsn: 'not a dsn'),
        );
        expect(off.disabledReason, DisabledReason.disabledByConfig);
        expect(off.disabledDetail, isNull);
      });
    });

    group('DSN', () {
      test('white space and trailing slashes are removed', () {
        for (final raw in ['  $_dsn  ', '$_dsn/', '$_dsn///', '\t$_dsn/\n']) {
          final config = resolve(CarpGlitchTipOptions(dsn: raw));
          expect(config.enabled, isTrue, reason: raw);
          expect(config.dsn, _dsn, reason: raw);
        }
        final fromEnv = resolve(
          const CarpGlitchTipOptions(),
          env: {GlitchTipKeys.sentryDsn: ' $_dsn/ '},
        );
        expect(fromEnv.dsn, _dsn);
      });

      test('an empty GLITCHTIP_DSN falls back to the DSN in code', () {
        final config = resolve(
          const CarpGlitchTipOptions(dsn: _dsn),
          env: {GlitchTipKeys.dsn: '', GlitchTipKeys.sentryDsn: 'null'},
        );
        expect(config.dsn, _dsn);
        expect(config.warnings, isEmpty);
      });

      test(
        'an invalid GLITCHTIP_DSN does not fall back to the DSN in code',
        () {
          final config = resolve(
            const CarpGlitchTipOptions(dsn: _dsn),
            env: {GlitchTipKeys.dsn: 'https://glitchtip.example.com/7'},
          );
          expect(config.disabledReason, DisabledReason.invalidDsn);
          expect(config.warnings, anyElement(contains(GlitchTipKeys.dsn)));
        },
      );

      for (final c in _validDsns) {
        test('accepts a DSN with ${c.what}', () {
          final config = resolve(
            CarpGlitchTipOptions(dsn: c.dsn, enabled: true),
            buildMode: c.mode,
          );
          expect(config.enabled, isTrue);
          expect(config.disabledReason, isNull);
          expect(config.dsn, c.dsn);
        });
      }

      for (final c in _invalidDsns) {
        test('rejects a DSN with ${c.what}, without its key', () {
          final config = resolve(
            CarpGlitchTipOptions(dsn: c.dsn, enabled: true),
            buildMode: c.mode,
          );
          expect(config.enabled, isFalse);
          expect(config.disabledReason, DisabledReason.invalidDsn);
          expect(config.dsn, isNull);
          // '<problem>: <dsn label>'
          final normalized = normalizeDsn(c.dsn);
          final problem = validateDsn(
            normalized,
            allowInsecureLocal: c.mode == 'debug',
          );
          expect(config.disabledDetail, '$problem: ${dsnLabel(normalized)}');
          expect(config.disabledDetail, contains(c.problem));
          expect(config.disabledDetail, isNot(contains(_key)));
          expect(config.disabledDetail, isNot(contains(_secret)));
        });
      }

      test('rejects a DSN whose project id is empty', () {
        // Sentry takes the project id from the last path segment, which is
        // empty when a slash comes before a query or a fragment
        for (final dsn in [
          'https://$_key@glitchtip.example.com/7/?x=1',
          'https://$_key@glitchtip.example.com/7/#x',
        ]) {
          final config = resolve(CarpGlitchTipOptions(dsn: dsn));
          expect(config.disabledReason, DisabledReason.invalidDsn, reason: dsn);
        }
      });
    });

    group('environment', () {
      final cases = [
        (mode: 'release', deploymentMode: null, expected: 'production'),
        (mode: 'profile', deploymentMode: null, expected: 'production-profile'),
        (mode: 'debug', deploymentMode: null, expected: 'production-debug'),
        (mode: 'release', deploymentMode: 'test', expected: 'test'),
        (mode: 'profile', deploymentMode: 'dev', expected: 'dev-profile'),
        (mode: 'debug', deploymentMode: 'local', expected: 'local-debug'),
      ];
      for (final c in cases) {
        test('is ${c.expected} in a ${c.mode} build with deployment mode '
            '${c.deploymentMode ?? 'unset'}', () {
          final config = resolve(
            const CarpGlitchTipOptions(),
            env: {GlitchTipKeys.deploymentMode: ?c.deploymentMode},
            buildMode: c.mode,
          );
          expect(config.environment, c.expected);
          expect(config.deploymentMode, c.deploymentMode);
        });
      }

      test('a value in code wins over the deployment mode, without suffix', () {
        final config = resolve(
          const CarpGlitchTipOptions(environment: 'staging'),
          env: {GlitchTipKeys.deploymentMode: 'test'},
          buildMode: 'debug',
        );
        expect(config.environment, 'staging');
        expect(config.deploymentMode, 'test');
        expect(config.warnings, isEmpty);
      });

      test('an env key wins over the deployment mode, without suffix', () {
        for (final key in [
          GlitchTipKeys.environment,
          GlitchTipKeys.sentryEnvironment,
        ]) {
          final config = resolve(
            const CarpGlitchTipOptions(),
            env: {key: 'qa', GlitchTipKeys.deploymentMode: 'test'},
            buildMode: 'profile',
          );
          expect(config.environment, 'qa', reason: key);
        }
      });

      test('an empty deployment mode counts as unset', () {
        final config = resolve(
          const CarpGlitchTipOptions(),
          env: {GlitchTipKeys.deploymentMode: ' '},
          buildMode: 'debug',
        );
        expect(config.environment, 'production-debug');
        expect(config.deploymentMode, isNull);
      });
    });

    group('sample rates', () {
      for (final (mode, defaultRate) in [
        ('release', 0.1),
        ('profile', 0.0),
        ('debug', 0.0),
      ]) {
        test('default to 1, $defaultRate and $defaultRate in $mode builds', () {
          final config = resolve(
            const CarpGlitchTipOptions(dsn: _dsn),
            buildMode: mode,
          );
          expect(config.sampleRate, 1);
          expect(config.tracesSampleRate, defaultRate);
          expect(config.httpSampleRate, defaultRate);
          expect(config.warnings, isEmpty);
        });
      }

      final rates = [
        (
          name: 'sampleRate',
          key: GlitchTipKeys.sampleRate,
          code: (double rate) => CarpGlitchTipOptions(sampleRate: rate),
          read: (ResolvedConfig config) => config.sampleRate,
          fallback: 1.0,
        ),
        (
          name: 'tracesSampleRate',
          key: GlitchTipKeys.tracesSampleRate,
          code: (double rate) => CarpGlitchTipOptions(tracesSampleRate: rate),
          read: (ResolvedConfig config) => config.tracesSampleRate,
          fallback: 0.1,
        ),
        (
          name: 'http.sampleRate',
          key: GlitchTipKeys.httpSampleRate,
          code: (double rate) =>
              CarpGlitchTipOptions(http: HttpOptions(sampleRate: rate)),
          read: (ResolvedConfig config) => config.httpSampleRate,
          fallback: 0.1,
        ),
      ];

      for (final r in rates) {
        group(r.name, () {
          test('uses the value in code', () {
            for (final rate in [0.0, 0.5, 1.0]) {
              final config = resolve(r.code(rate));
              expect(r.read(config), rate);
              expect(config.warnings, isEmpty);
            }
          });

          test('ignores an invalid value in code with a warning', () {
            for (final rate in [
              -0.1,
              1.5,
              double.nan,
              double.infinity,
              double.negativeInfinity,
            ]) {
              final config = resolve(r.code(rate));
              expect(r.read(config), r.fallback, reason: '$rate');
              expect(config.warnings, hasLength(1), reason: '$rate');
            }
          });

          test('uses ${r.key}', () {
            for (final (raw, rate) in [
              ('0.25', 0.25),
              ('0', 0.0),
              ('1', 1.0),
            ]) {
              final config = resolve(
                const CarpGlitchTipOptions(),
                env: {r.key: raw},
              );
              expect(r.read(config), rate, reason: raw);
              expect(config.warnings, isEmpty, reason: raw);
            }
          });

          test('${r.key} overrides the value in code with a warning', () {
            final config = resolve(r.code(0.5), env: {r.key: '0.25'});
            expect(r.read(config), 0.25);
            expect(config.warnings, anyElement(contains(r.key)));
          });

          test('ignores an invalid ${r.key} with a warning', () {
            for (final raw in [
              'abc',
              '50%',
              '1.5',
              '-0.5',
              'NaN',
              'Infinity',
            ]) {
              final unset = resolve(
                const CarpGlitchTipOptions(),
                env: {r.key: raw},
              );
              expect(r.read(unset), r.fallback, reason: raw);
              expect(unset.warnings, [contains(r.key)], reason: raw);

              final inCode = resolve(r.code(0.5), env: {r.key: raw});
              expect(r.read(inCode), 0.5, reason: raw);
              expect(inCode.warnings, anyElement(contains(r.key)));
            }
          });

          test('an empty ${r.key} counts as unset', () {
            for (final raw in ['', '  ']) {
              final config = resolve(r.code(0.5), env: {r.key: raw});
              expect(r.read(config), 0.5);
              expect(config.warnings, isEmpty);
            }
          });
        });
      }
    });

    group('debug', () {
      final cases = [
        (code: null, env: null, expected: null, warns: false),
        (code: true, env: null, expected: true, warns: false),
        (code: false, env: null, expected: false, warns: false),
        (code: null, env: 'true', expected: true, warns: false),
        (code: null, env: 'off', expected: false, warns: false),
        (code: false, env: 'yes', expected: true, warns: true),
        (code: true, env: '0', expected: false, warns: true),
        (code: true, env: 'verbose', expected: true, warns: true),
        (code: null, env: 'verbose', expected: null, warns: true),
      ];
      for (final c in cases) {
        test('is ${c.expected} with ${c.code} in code and '
            'GLITCHTIP_DEBUG=${c.env}', () {
          final config = resolve(
            CarpGlitchTipOptions(debug: c.code),
            env: {GlitchTipKeys.debug: ?c.env},
          );
          expect(config.debug, c.expected);
          expect(
            config.warnings,
            c.warns ? anyElement(contains(GlitchTipKeys.debug)) : isEmpty,
          );
        });
      }
    });

    test('keeps the build mode', () {
      for (final mode in ['debug', 'profile', 'release']) {
        final config = resolve(const CarpGlitchTipOptions(), buildMode: mode);
        expect(config.buildMode, mode);
      }
    });
  });

  group('DSN helpers', () {
    test('normalizeDsn removes white space and trailing slashes', () {
      expect(normalizeDsn(_dsn), _dsn);
      expect(normalizeDsn('  $_dsn \n'), _dsn);
      expect(normalizeDsn('$_dsn/'), _dsn);
      expect(normalizeDsn(' $_dsn/// '), _dsn);
      expect(
        normalizeDsn('https://$_key@glitchtip.example.com/glitchtip/7/'),
        'https://$_key@glitchtip.example.com/glitchtip/7',
      );
    });

    for (final c in _validDsns) {
      test('validateDsn accepts a DSN with ${c.what}', () {
        final valid = validateDsn(c.dsn, allowInsecureLocal: c.mode == 'debug');
        expect(valid, isNull);
      });
    }

    for (final c in _invalidDsns) {
      test('validateDsn rejects a DSN with ${c.what}', () {
        final problem = validateDsn(
          normalizeDsn(c.dsn),
          allowInsecureLocal: c.mode == 'debug',
        );
        expect(problem, contains(c.problem));
        expect(problem, isNot(contains(_key)));
      });
    }

    test('validateDsn allows http only for local servers when asked', () {
      for (final host in _localHosts) {
        final dsn = 'http://$_key@$host:8000/7';
        expect(validateDsn(dsn, allowInsecureLocal: true), isNull);
        expect(
          validateDsn(dsn, allowInsecureLocal: false),
          contains('https'),
          reason: dsn,
        );
      }
      for (final host in ['glitchtip.example.com', 'localhost.example.com']) {
        final dsn = 'http://$_key@$host/7';
        expect(
          validateDsn(dsn, allowInsecureLocal: true),
          contains('https'),
          reason: dsn,
        );
      }
    });

    test('dsnLabel is the DSN without its key', () {
      expect(dsnLabel(_dsn), 'glitchtip.example.com/7');
      expect(
        dsnLabel('https://$_key:$_secret@glitchtip.example.com:8443/gt/7'),
        'glitchtip.example.com:8443/gt/7',
      );
      expect(dsnLabel('http://$_key@localhost:8000/7'), 'localhost:8000/7');
    });

    test('dsnLabel of an invalid DSN does not contain its key', () {
      for (final dsn in [
        '',
        '$_key@glitchtip.example.com/7',
        'https:$_key@glitchtip.example.com/7',
        '//$_key@glitchtip.example.com/7',
        'https://$_key@/7',
        'https://$_key@glitchtip.example.com:port/7',
        'https://ke@$_key@glitchtip.example.com/7',
        'https://:$_key@glitchtip.example.com/7',
        for (final c in _invalidDsns) c.dsn,
      ]) {
        expect(dsnLabel(dsn), isNot(contains(_key)), reason: dsn);
        expect(dsnLabel(dsn), isNot(contains(_secret)), reason: dsn);
      }
    });

    test('ingestPrefix is where the Sentry SDK sends envelopes', () {
      expect(
        ingestPrefix(_dsn),
        Uri.parse('https://glitchtip.example.com/api/7/'),
      );
      expect(
        ingestPrefix('https://$_key@glitchtip.example.com:8443/7'),
        Uri.parse('https://glitchtip.example.com:8443/api/7/'),
      );
      expect(
        ingestPrefix('http://$_key@localhost:8000/7'),
        Uri.parse('http://localhost:8000/api/7/'),
      );
    });

    test('ingestPrefix keeps the path prefix of the DSN', () {
      expect(
        ingestPrefix('https://$_key@glitchtip.example.com/glitchtip/7'),
        Uri.parse('https://glitchtip.example.com/glitchtip/api/7/'),
      );
    });

    test('ingestPrefix is null for an invalid DSN', () {
      expect(ingestPrefix(''), isNull);
      expect(ingestPrefix('not a dsn'), isNull);
      expect(ingestPrefix('https://glitchtip.example.com'), isNull);
    });

    group('isIngestUrl', () {
      final prefix = ingestPrefix(_dsn)!;
      bool ingest(String url) => isIngestUrl(Uri.parse(url), prefix);

      test('matches requests to the ingest endpoints of the project', () {
        expect(ingest('https://glitchtip.example.com/api/7/envelope/'), isTrue);
        expect(ingest('https://glitchtip.example.com/api/7/store/'), isTrue);
        expect(
          ingest('https://glitchtip.example.com/api/7/envelope/?sentry_key=k'),
          isTrue,
        );
      });

      test('ignores the case of the scheme and host', () {
        expect(ingest('HTTPS://GlitchTip.Example.COM/api/7/envelope/'), isTrue);
        expect(
          isIngestUrl(
            Uri(
              scheme: 'HTTPS',
              host: 'GLITCHTIP.EXAMPLE.COM',
              path: '/api/7/envelope/',
            ),
            prefix,
          ),
          isTrue,
        );
      });

      test('treats an explicit default port like no port', () {
        expect(
          ingest('https://glitchtip.example.com:443/api/7/envelope/'),
          isTrue,
        );
      });

      test('needs the same scheme, host and port', () {
        expect(ingest('http://glitchtip.example.com/api/7/envelope/'), isFalse);
        expect(ingest('https://example.com/api/7/envelope/'), isFalse);
        expect(
          ingest('https://glitchtip.example.com:8443/api/7/envelope/'),
          isFalse,
        );
      });

      test('needs the path prefix', () {
        expect(
          ingest('https://glitchtip.example.com/api/8/envelope/'),
          isFalse,
        );
        expect(
          ingest('https://glitchtip.example.com/api/77/envelope/'),
          isFalse,
        );
        expect(
          ingest('https://glitchtip.example.com/x/api/7/envelope/'),
          isFalse,
        );
        expect(ingest('https://glitchtip.example.com/api/0/issues/'), isFalse);
        expect(ingest('https://glitchtip.example.com/'), isFalse);
      });

      test('uses the path prefix and port of the DSN', () {
        final prefixed = ingestPrefix(
          'https://$_key@glitchtip.example.com:8443/glitchtip/7',
        )!;
        bool matches(String url) => isIngestUrl(Uri.parse(url), prefixed);
        expect(
          matches(
            'https://glitchtip.example.com:8443/glitchtip/api/7/envelope/',
          ),
          isTrue,
        );
        expect(
          matches('https://glitchtip.example.com:8443/api/7/envelope/'),
          isFalse,
        );
        expect(
          matches('https://glitchtip.example.com/glitchtip/api/7/envelope/'),
          isFalse,
        );
      });
    });
  });

  group('GlitchTipStatus', () {
    test('notInitialized is off and says init was not called', () {
      const status = GlitchTipStatus.notInitialized;
      expect(status.enabled, isFalse);
      expect(status.disabledReason, DisabledReason.notInitialized);
      expect(
        status.toString(),
        contains(DisabledReason.notInitialized.description),
      );
    });

    test('every disabled reason has its own description', () {
      final descriptions = {
        for (final reason in DisabledReason.values) reason.description,
      };
      expect(descriptions, hasLength(DisabledReason.values.length));
      expect(descriptions, everyElement(isNotEmpty));
    });

    test('a disabled status is one line with its reason and detail', () {
      for (final reason in DisabledReason.values) {
        // a starting status shows the configuration, see below
        if (reason == DisabledReason.starting) continue;
        final plain = GlitchTipStatus(enabled: false, disabledReason: reason);
        expect(plain.toString(), contains(reason.description));
        expect(plain.toString(), isNot(contains('\n')));

        final detailed = GlitchTipStatus(
          enabled: false,
          disabledReason: reason,
          detail: 'StateError',
        );
        expect(
          detailed.toString(),
          allOf(contains(reason.description), contains('StateError')),
        );
        expect(detailed.toString(), isNot(contains('\n')));
      }
    });

    test('a starting status is the enabled line, marked as starting', () {
      final config = resolve(
        const CarpGlitchTipOptions(
          dsn: 'https://$_key@glitchtip.example.com/7',
          environment: 'staging',
          tracesSampleRate: 7,
        ),
      );
      final enabled = config.toStatus(httpInstrumented: true).toString();
      final starting = config.toStatus(
        httpInstrumented: true,
        disabled: DisabledReason.starting,
        detail: 'after 5000 ms',
      );
      expect(starting.enabled, isFalse);
      expect(starting.disabledReason, DisabledReason.starting);
      expect(
        starting.toString(),
        enabled.replaceFirst('enabled ', 'starting (after 5000 ms): '),
      );
      // the warnings stay, as on every line
      expect(starting.toString(), contains(config.warnings.single));
    });

    test('a failed start keeps the warnings of the configuration', () {
      final config = resolve(
        const CarpGlitchTipOptions(
          dsn: 'https://$_key@glitchtip.example.com/7',
          tracesSampleRate: 7,
        ),
      );
      final failed = config.toStatus(
        httpInstrumented: true,
        disabled: DisabledReason.initFailed,
        detail: 'StateError',
      );
      expect(failed.enabled, isFalse);
      expect(
        failed.toString(),
        'DISABLED: ${DisabledReason.initFailed.description} (StateError) '
        'warnings=${config.warnings.single}',
      );
    });

    test('an enabled status is one line with what is reported', () {
      final config = resolve(
        const CarpGlitchTipOptions(
          dsn: 'https://$_key:$_secret@glitchtip.example.com/7',
          environment: 'staging',
          release: 'app@1.2.3+4',
          sampleRate: 0.5,
          tracesSampleRate: 0.25,
          http: HttpOptions(sampleRate: 0.125),
        ),
        env: {GlitchTipKeys.enabled: 'maybe'},
      );
      final line = config.toStatus(httpInstrumented: true).toString();
      expect(line, isNot(contains('\n')));
      expect(line, contains('staging'));
      expect(line, contains('app@1.2.3+4'));
      expect(line, contains('glitchtip.example.com/7'));
      expect(line, allOf(contains('0.5'), contains('0.25'), contains('0.125')));
      expect(line, contains(config.warnings.single));
      expect(line, isNot(contains(_key)));
      expect(line, isNot(contains(_secret)));
    });

    test('toStatus copies the resolved config with the DSN label', () {
      final config = resolve(
        const CarpGlitchTipOptions(
          dsn: 'https://$_key:$_secret@glitchtip.example.com/7/',
          release: 'app@1.2.3+4',
          dist: '4',
          sampleRate: 0.5,
          tracesSampleRate: 0.25,
          http: HttpOptions(sampleRate: 0.125),
        ),
        env: {GlitchTipKeys.environment: 'qa', GlitchTipKeys.enabled: 'maybe'},
        buildMode: 'profile',
      );
      final status = config.toStatus(httpInstrumented: true);
      expect(status.enabled, isTrue);
      expect(status.disabledReason, isNull);
      expect(status.detail, isNull);
      expect(status.dsn, 'glitchtip.example.com/7');
      expect(status.environment, 'qa');
      expect(status.release, 'app@1.2.3+4');
      expect(status.dist, '4');
      expect(status.sampleRate, 0.5);
      expect(status.tracesSampleRate, 0.25);
      expect(status.httpSampleRate, 0.125);
      expect(status.buildMode, 'profile');
      expect(status.httpInstrumented, isTrue);
      expect(status.warnings, config.warnings);
      expect(status.warnings, hasLength(1));
      expect(
        config.toStatus(httpInstrumented: false).httpInstrumented,
        isFalse,
      );
    });

    test('toStatus of a disabled config keeps the reason and detail', () {
      final config = resolve(
        const CarpGlitchTipOptions(dsn: 'http://$_key@glitchtip.example.com/7'),
      );
      final status = config.toStatus(httpInstrumented: false);
      expect(status.enabled, isFalse);
      expect(status.disabledReason, DisabledReason.invalidDsn);
      expect(status.detail, config.disabledDetail);
      expect(status.detail, endsWith(': glitchtip.example.com/7'));
      expect(status.toString(), contains(status.detail));
    });

    test('never contains the DSN key', () {
      final configs = [
        resolve(
          const CarpGlitchTipOptions(
            dsn: 'https://$_key:$_secret@glitchtip.example.com/7',
          ),
        ),
        // the env overrides the DSN in code, with a warning
        resolve(
          const CarpGlitchTipOptions(dsn: 'https://${_key}2@example.com/1'),
          env: {GlitchTipKeys.dsn: _dsn, GlitchTipKeys.enabled: 'maybe'},
        ),
        for (final c in _invalidDsns)
          resolve(
            CarpGlitchTipOptions(dsn: c.dsn, enabled: true),
            buildMode: c.mode,
          ),
      ];
      for (final config in configs) {
        for (final instrumented in [true, false]) {
          final status = config.toStatus(httpInstrumented: instrumented);
          for (final text in [
            status.toString(),
            ?status.detail,
            ?status.dsn,
            ...status.warnings,
          ]) {
            expect(text, isNot(contains(_key)));
            expect(text, isNot(contains(_secret)));
          }
        }
      }
    });
  });

  group('CarpGlitchTip.init', () {
    late GlitchTipTestTransport transport;

    setUp(() async {
      await CarpGlitchTip.resetForTest();
      transport = GlitchTipTestTransport();
    });
    tearDown(CarpGlitchTip.resetForTest);

    void useTestTransport(SentryFlutterOptions options) {
      options.transport = transport;
      options.autoInitializeNativeSdk = false;
    }

    test('the status is notInitialized before init', () {
      expect(
        CarpGlitchTip.status.disabledReason,
        DisabledReason.notInitialized,
      );
      expect(CarpGlitchTip.isEnabled, isFalse);
    });

    test('under flutter test the env cannot turn reporting on', () async {
      await CarpGlitchTip.init(
        CarpGlitchTipOptions(
          env: GlitchTipEnv.fromMap({
            GlitchTipKeys.enabled: 'true',
            GlitchTipKeys.dsn: _dsn,
          }),
          configure: useTestTransport,
        ),
      );
      expect(CarpGlitchTip.isEnabled, isFalse);
      expect(CarpGlitchTip.status.disabledReason, DisabledReason.flutterTest);
      await CarpGlitchTip.captureException(StateError('boom'));
      expect(transport.envelopes, isEmpty);
    });

    test('the env in the options overrides the values in code', () async {
      await CarpGlitchTip.init(
        CarpGlitchTipOptions(
          enabled: true,
          dsn: 'https://code@glitchtip.example.com/1',
          environment: 'code',
          release: 'app@1.0.0+1',
          env: GlitchTipEnv.fromMap({
            GlitchTipKeys.dsn: _dsn,
            GlitchTipKeys.environment: 'qa',
            GlitchTipKeys.release: 'app@2.0.0+7',
            GlitchTipKeys.dist: '7',
          }),
          configure: useTestTransport,
        ),
      );
      final status = CarpGlitchTip.status;
      expect(status.enabled, isTrue);
      expect(status.dsn, 'glitchtip.example.com/7');
      expect(status.environment, 'qa');
      expect(status.release, 'app@2.0.0+7');
      expect(status.dist, '7');
      expect(status.buildMode, 'debug');
      for (final key in [
        GlitchTipKeys.dsn,
        GlitchTipKeys.environment,
        GlitchTipKeys.release,
      ]) {
        expect(status.warnings, anyElement(contains(key)));
      }

      await CarpGlitchTip.captureException(StateError('boom'));
      await eventually(() => transport.events.isNotEmpty);
      final event = transport.events.single;
      expect(event.environment, 'qa');
      expect(event.release, 'app@2.0.0+7');
      expect(event.dist, '7');
    });

    test('prints the status as one line, without the DSN key', () async {
      final lines = <String?>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message);
      try {
        await CarpGlitchTip.init(
          CarpGlitchTipOptions(
            enabled: true,
            dsn: 'http://$_key@glitchtip.example.com/7',
            configure: useTestTransport,
          ),
        );
      } finally {
        debugPrint = previous;
      }
      final status = CarpGlitchTip.status;
      expect(status.disabledReason, DisabledReason.invalidDsn);
      expect(status.detail, endsWith(': glitchtip.example.com/7'));
      expect(lines, ['[CarpGlitchTip] $status']);
      expect(lines.single, isNot(contains(_key)));
    });

    test('init after close resolves the env again', () async {
      var deploymentMode = 'test';
      final options = CarpGlitchTipOptions(
        enabled: true,
        dsn: _dsn,
        env: (key) =>
            key == GlitchTipKeys.deploymentMode ? deploymentMode : null,
        configure: useTestTransport,
      );
      await CarpGlitchTip.init(options);
      expect(CarpGlitchTip.status.environment, 'test-debug');

      await CarpGlitchTip.close();
      deploymentMode = 'dev';
      await CarpGlitchTip.init(options);
      expect(CarpGlitchTip.status.enabled, isTrue);
      expect(CarpGlitchTip.status.environment, 'dev-debug');
    });
  });
}
