// Regression tests for the privacy defects found in review: what
// Privacy.text, Privacy.event and Privacy.breadcrumb make of the inputs they
// used to miss or over-scrub, and that transactions, user feedback,
// structured logs, navigation and discarded transactions follow the policy
// in the real reporting pipeline (SentryFlutter.init with a
// GlitchTipTestTransport, so nothing is sent). Tests skipped with `BUG:`
// assert the intended behaviour of gaps that are still open.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/src/network/url_normalizer.dart';
import 'package:carp_glitchtip_wrapper/src/pipeline/privacy.dart';
import 'package:carp_glitchtip_wrapper/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const _dsn = 'https://key@glitchtip.example.com/1';
const _jwt =
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
    'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';

/// What a request throws while the phone is offline; ignored by default.
const _offline = SocketException(
  "Failed host lookup: 'api.example.com'",
  osError: OSError('nodename nor servname provided, or not known', 8),
);

/// What a request throws while the server is down; reported. A new error
/// each time: the SDK drops an error object it has already reported.
SocketException _refused() => SocketException(
  'Connection refused',
  osError: OSError(
    'Connection refused',
    Platform.isMacOS || Platform.isIOS ? 61 : 111,
  ),
);

/// A value the Sentry SDK would serialise with `toString()`.
class _Upload {
  @override
  String toString() => 'Upload(jane@example.com, https://h/users/42?x=1)';
}

/// A value whose `toString()` throws.
class _Unprintable {
  @override
  String toString() => throw StateError('unprintable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final privacy = Privacy(user: SentryUser(id: 'launch-user'));

  late GlitchTipTestTransport transport;

  setUp(() async {
    await CarpGlitchTip.resetForTest();
    transport = GlitchTipTestTransport();
  });
  tearDown(CarpGlitchTip.resetForTest);

  // Starts reporting into [transport].
  Future<void> init({
    double? tracesSampleRate,
    HttpOptions httpOptions = const HttpOptions(),
    void Function(SentryFlutterOptions options)? configure,
  }) => CarpGlitchTip.init(
    CarpGlitchTipOptions(
      enabled: true,
      dsn: _dsn,
      tracesSampleRate: tracesSampleRate,
      http: httpOptions,
      configure: (o) {
        o
          ..transport = transport
          ..autoInitializeNativeSdk = false;
        configure?.call(o);
      },
    ),
  );

  // Waits for work the SDK does not await, e.g. sending a transaction.
  Future<void> eventually(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  // Gives pending work time to finish before checking what was sent.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 100));

  // Sets the account of the participant as the scope user, as an app could.
  Future<void> setAppUser() async {
    await Sentry.configureScope(
      (scope) =>
          scope.setUser(SentryUser(id: 'account-1', email: 'p@example.com')),
    );
  }

  group('Privacy.text', () {
    // Checks that each input is scrubbed to its text, which scrubbing again
    // leaves unchanged.
    void expectScrubbed(List<(String, String)> cases) {
      for (final (input, scrubbed) in cases) {
        expect(privacy.text(input), scrubbed, reason: input);
        expect(privacy.text(scrubbed), scrubbed, reason: 'again: $input');
      }
    }

    test('keeps scheme and path of custom-scheme redirects, no query', () {
      expectScrubbed([
        (
          'redirect to carp-studies-auth://auth?code=XYZ&state=S failed',
          'redirect to carp-studies-auth://auth failed',
        ),
        ('carp-studies:/anonymous?code=XYZ', 'carp-studies:/anonymous'),
      ]);
    });

    test('normalises upper-case, IPv6 and JSON-escaped URLs', () {
      expectScrubbed([
        ('HTTPS://H/users/42?x=1', 'https://h/users/{id}'),
        (
          'http://[::1]:8080/api/users/42?t=1',
          'http://[::1]:8080/api/users/{id}',
        ),
        (r'https:\/\/h\/users\/42?code=1', 'https://h/users/{id}'),
        (
          r'{"url":"https:\/\/h\/users\/42?code=1"}',
          '{"url":"https://h/users/{id}"}',
        ),
      ]);
    });

    test('keeps trailing punctuation outside the URL', () {
      expectScrubbed([
        ('see https://h/users/42.', 'see https://h/users/{id}.'),
        ('(https://h/a/42)', '(https://h/a/{id})'),
        ('{"u":"https://h/a/42"}', '{"u":"https://h/a/{id}"}'),
      ]);
    });

    test('redacts secrets of query strings and JSON', () {
      expectScrubbed([
        (
          'callback ?code=abc&state=def',
          'callback ?code={redacted}&state={redacted}',
        ),
        (
          'lang=da&code=abc&state=def',
          'lang=da&code={redacted}&state={redacted}',
        ),
        (
          '{"access_token":"opaque","expires_in":3600}',
          '{"access_token":"{redacted}","expires_in":3600}',
        ),
        (
          '{"user": "p1", "password": "x"}',
          '{"user": "p1", "password": "{redacted}"}',
        ),
      ]);
    });

    test('replaces MAC addresses, not times or IPv6 addresses', () {
      expectScrubbed([
        (
          'connecting to AA:BB:CC:DD:EE:FF failed',
          'connecting to {mac} failed',
        ),
        ('retry at 12:30:45', 'retry at 12:30:45'),
        ('bound to fe80::1', 'bound to fe80::1'),
      ]);
    });

    test('replaces percent-encoded e-mails, not package versions', () {
      expectScrubbed([
        ('no account for jane%40example.com', 'no account for {email}'),
        ('carp_study_app@4.2.0+12', 'carp_study_app@4.2.0+12'),
      ]);
    });

    test('replaces bearer tokens, not the word Bearer in prose', () {
      expectScrubbed([
        (
          'Missing Bearer authorization header',
          'Missing Bearer authorization header',
        ),
        ('Bearer abc123def456', 'Bearer {token}'),
        ('Bearer abcdefghijklmnopqrstuvwxyz', 'Bearer {token}'),
      ]);
    });

    test('keeps debug text as is', () {
      expectScrubbed([
        for (final text in [
          'android-code: 133',
          'state: disconnected',
          'package:carp_webservices/src/x.dart:12:5',
          "Instance of 'Foo'",
        ])
          (text, text),
      ]);
    });

    test('scrubs a long run of eyJ in linear time', () {
      final text = 'eyJ' * 3000;
      final once = privacy.text(text); // also compiles the patterns
      expect(privacy.text(once), once);
      var fastest = const Duration(days: 1);
      for (var i = 0; i < 3; i++) {
        final stopwatch = Stopwatch()..start();
        privacy.text(text);
        if (stopwatch.elapsed < fastest) fastest = stopwatch.elapsed;
      }
      expect(fastest, lessThan(const Duration(milliseconds: 50)));
    });

    test('still replaces JWTs after a space, a quote or =', () {
      expectScrubbed([
        ('token $_jwt expired', 'token {jwt} expired'),
        ('{"jwt":"$_jwt"}', '{"jwt":"{jwt}"}'),
        ('id=$_jwt', 'id={jwt}'),
      ]);
    });
  });

  group('Privacy.event', () {
    test('removes the iOS device app hash and the device identifier', () {
      final event = SentryEvent();
      event.contexts.app = SentryApp(
        name: 'CARP Study',
        deviceAppHash: '5f8e2a9c41d7',
      );
      event.contexts.device = SentryDevice.fromJson({
        'device_unique_identifier': 'D3B0-41A7',
        'model': 'iPhone15,2',
      });
      final contexts = privacy.event(event)!.contexts;
      expect(contexts.app!.toJson(), {'app_name': 'CARP Study'});
      expect(contexts.device!.toJson(), {'model': 'iPhone15,2'});
    });

    test('drops the information of a Flutter error, scrubs the rest', () {
      final event = SentryEvent();
      // as the SDK's FlutterErrorIntegration reports it
      event.contexts['flutter_error_details'] = <String, String>{
        'context':
            'thrown while loading https://h/users/42?code=1 for '
            'jane@example.com',
        'information': 'The relevant widget was: Text("jane@example.com")',
        'library': 'widgets library',
      };
      expect(privacy.event(event)!.contexts['flutter_error_details'], {
        'context': 'thrown while loading https://h/users/{id} for {email}',
        'library': 'widgets library',
      });
    });

    test('the coarse fallback replaces e-mail addresses with {email}', () {
      final event = SentryEvent(
        message: SentryMessage('invite for jane@example.com failed'),
        exceptions: [
          SentryException(
            type: 'StateError',
            value:
                'Bad state: no study for jane@example.com or '
                'jane%40example.com',
          ),
        ],
        breadcrumbs: [Breadcrumb(message: 'signed in')],
      );
      // a map under a key the SDK reads as a typed object makes the full
      // scrub throw
      event.contexts['device'] = {'name': "Jane's iPhone"};
      final scrubbed = privacy.event(event)!;
      expect(scrubbed.breadcrumbs, isNull, reason: 'the coarse scrub ran');
      expect(scrubbed.contexts['device'], isNull);
      expect(scrubbed.message!.formatted, 'invite for {email} failed');
      expect(
        scrubbed.exceptions!.single.value,
        'Bad state: no study for {email} or {email}',
      );
    });

    test('tags the mechanism of the reported error, not of its cause', () {
      const error = SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 61),
      );
      final event = SentryEvent(
        throwable: error,
        exceptions: [
          // the chained OSError first, as with SentryOptions.groupExceptions
          SentryException(
            type: 'OSError',
            value: 'OS Error: Connection refused, errno = 61',
            mechanism: Mechanism(type: 'OSError', source: 'osError'),
          ),
          SentryException(
            type: 'SocketException',
            value: 'SocketException: Connection refused',
            throwable: error,
            mechanism: Mechanism(type: 'runZonedGuarded', handled: false),
          ),
        ],
      );
      expect(privacy.event(event)!.tags, {
        'handled': 'no',
        'mechanism': 'runZonedGuarded',
      });
    });

    test('tags handled yes and mechanism generic without a mechanism', () {
      final event = SentryEvent(
        exceptions: [SentryException(type: 'StateError', value: 'oops')],
      );
      expect(privacy.event(event)!.tags, {
        'handled': 'yes',
        'mechanism': 'generic',
      });
    });

    test('tags CarpGlitchTip.captureException as handled', () async {
      await init();
      await CarpGlitchTip.captureException(StateError('sync failed'));
      await CarpGlitchTip.captureException(_refused());
      final events = transport.events;
      expect(events, hasLength(2));
      // the SDK adds the OSError of the SocketException as its cause
      expect(events.last.exceptions!.map((e) => e.type), contains('OSError'));
      for (final event in events) {
        expect(event.tags, containsPair('handled', 'yes'));
        expect(
          event.tags,
          containsPair('mechanism', 'CarpGlitchTip.captureException'),
        );
      }
    });

    test(
      'a SocketException without a mechanism is not tagged OSError',
      () async {
        await init();
        // as app or package code may report it, without a mechanism
        await Sentry.captureException(_refused());
        final event = transport.events.single;
        // the SDK adds the OSError, with a mechanism of its own, as cause
        expect(event.exceptions!.last.mechanism?.type, 'OSError');
        expect(event.tags, containsPair('handled', 'yes'));
        expect(event.tags, containsPair('mechanism', 'generic'));
      },
    );
  });

  group('Privacy.breadcrumb', () {
    test('scrubs nested maps and lists at every level', () {
      final crumb = privacy.breadcrumb(
        Breadcrumb(
          category: 'app',
          data: {
            'request': {
              'url': 'https://h/users/42?token=s',
              'to_arguments': {'id': '42'},
              'http.query': 'token=s',
              'headers': [
                {'mail': 'jane@example.com', 'retries': 2},
                'see https://h/a/42?code=1',
              ],
            },
            'done': true,
          },
        ),
      )!;
      expect(crumb.data, {
        'request': {
          'url': 'https://h/users/{id}',
          'headers': [
            {'mail': '{email}', 'retries': 2},
            'see https://h/a/{id}',
          ],
        },
        'done': true,
      });
      final json = jsonEncode(crumb.toJson());
      expect(jsonEncode(privacy.breadcrumb(crumb)!.toJson()), json);
    });

    test('scrubs data nested deeper than it walks as text', () {
      Object nested(int depth) => depth == 0
          ? {'mail': 'jane@example.com', 'url': 'https://h/users/42?code=1'}
          : {'next': nested(depth - 1)};
      final crumb = privacy.breadcrumb(Breadcrumb(data: {'deep': nested(8)}))!;
      final json = jsonEncode(crumb.toJson());
      expect(json, contains('{email}'));
      expect(json, contains('https://h/users/{id}'));
      expect(json, isNot(contains('@')));
      expect(json, isNot(contains('code=1')));
    });

    test('normalises Uri values under any key', () {
      final crumb = privacy.breadcrumb(
        Breadcrumb(
          data: {
            'endpoint': Uri.parse('https://h/users/42?token=s'),
            'mirrors': [Uri.parse('https://h/users/7#top')],
          },
        ),
      )!;
      expect(crumb.data, {
        'endpoint': 'https://h/users/{id}',
        'mirrors': ['https://h/users/{id}'],
      });
    });

    test('scrubs other values through toString()', () {
      final crumb = privacy.breadcrumb(
        Breadcrumb(data: {'upload': _Upload(), 'broken': _Unprintable()}),
      )!;
      expect(crumb.data, {
        'upload': 'Upload({email}, https://h/users/{id})',
        'broken': '{unknown}',
      });
    });
  });

  group('transactions', () {
    test('child spans have their description and data scrubbed', () async {
      await init(tracesSampleRate: 1);
      final transaction = Sentry.startTransaction(
        'sync',
        'task',
        bindToScope: false,
      );
      final span = transaction.startChild(
        'http.client',
        description: 'GET https://h/users/42?token=s',
      );
      span
        ..setData('http.query', 'token=s')
        ..setData('url', 'https://h/users/42?x=1');
      await span.finish();
      await transaction.finish();
      await eventually(() => transport.transactions.isNotEmpty);

      final sent = transport.transactions.single.spans.single;
      expect(sent.context.description, 'GET https://h/users/{id}');
      expect(sent.data, isNot(contains('http.query')));
      expect(sent.data['url'], 'https://h/users/{id}');
    });

    test(
      'an http.client transaction of the app has its name scrubbed',
      () async {
        await init(tracesSampleRate: 1);
        final transaction = Sentry.startTransaction(
          'GET https://h/users/42?token=s',
          'http.client',
          bindToScope: false,
        );
        transaction.setData('url', 'https://h/users/42?token=s');
        await transaction.finish();
        await eventually(() => transport.transactions.isNotEmpty);

        final sent = transport.transactions.single;
        expect(sent.transaction, 'GET https://h/users/{id}');
        expect(jsonEncode(sent.toJson()), isNot(contains('token=s')));
      },
    );

    test('no other part of a transaction keeps a URL or e-mail', () async {
      await init(tracesSampleRate: 1);
      final transaction = Sentry.startTransaction(
        'sync',
        'task',
        bindToScope: false,
        description: 'GET https://h/users/42?token=s',
      );
      final span = transaction.startChild('db.query', description: 'select');
      span.setTag('participant', 'jane@example.com');
      await span.finish();
      await transaction.finish();
      await eventually(() => transport.transactions.isNotEmpty);

      final json = jsonEncode(transport.transactions.single.toJson());
      expect(json, isNot(contains('token=s')));
      expect(json, isNot(contains('jane@example.com')));
    });
  });

  group('user feedback', () {
    test(
      'has the launch user and a normalised url, the rest as written',
      () async {
        // what the SDK put on the feedback before the privacy policy
        var accessibility = false;
        String? email;
        await init(
          configure: (o) => o.beforeSendFeedback = (event, hint) {
            accessibility = event.contexts.containsKey('accessibility');
            email = event.user?.email;
            return event;
          },
        );
        await setAppUser();
        await CarpGlitchTip.captureMessage('probe');
        await Sentry.captureFeedback(
          SentryFeedback(
            message: 'hi',
            contactEmail: 'p@example.com',
            url: 'https://h/a?code=1',
          ),
        );
        expect(email, 'p@example.com');
        expect(accessibility, isTrue);

        final probe = transport.events.singleWhere((e) => e.type != 'feedback');
        final sent = transport.events.singleWhere((e) => e.type == 'feedback');
        expect(sent.user!.toJson(), {'id': probe.user!.id});
        expect(sent.user!.id, isNot('account-1'));
        expect(sent.contexts['accessibility'], isNull);
        final feedback = sent.contexts.feedback!;
        expect(feedback.url, 'https://h/a');
        expect(feedback.message, 'hi');
        expect(feedback.contactEmail, 'p@example.com');
      },
    );
  });

  group('structured logs', () {
    // The logs sent so far, as JSON.
    Future<List<Map<String, dynamic>>> sentLogs() async => [
      for (final envelope in transport.envelopes)
        for (final item in envelope.items)
          if (item.header.type == 'log')
            for (final log
                in (jsonDecode(utf8.decode(await item.dataFactory()))
                        as Map<String, dynamic>)['items']
                    as List<dynamic>)
              log as Map<String, dynamic>,
    ];

    test('are not sent by default', () async {
      await init();
      Sentry.logger.info('upload for jane@example.com failed');
      await settle();
      await CarpGlitchTip.close(); // flushes the logs
      expect(await sentLogs(), isEmpty);
    });

    test('are sent scrubbed when configure sets beforeSendLog', () async {
      var hooked = 0;
      await init(
        configure: (o) => o.beforeSendLog = (log, hint) {
          hooked++;
          return log;
        },
      );
      Sentry.logger.info('upload for jane@example.com failed');
      await eventually(() => hooked == 1);
      await settle();
      await CarpGlitchTip.close(); // flushes the logs
      final logs = await sentLogs();
      expect(logs.map((log) => log['body']), ['upload for {email} failed']);
    });

    test('carry no e-mail or account id in their attributes', () async {
      await init(configure: (o) => o.beforeSendLog = (log, hint) => log);
      await setAppUser();
      Sentry.logger.fmt.info('upload for %s failed', ['jane@example.com']);
      await settle();
      await CarpGlitchTip.close(); // flushes the logs
      final logs = await sentLogs();
      expect(logs, hasLength(1));
      final json = jsonEncode(logs);
      for (final identifier in [
        'jane@example.com',
        'p@example.com',
        'account-1',
      ]) {
        expect(json, isNot(contains(identifier)), reason: identifier);
      }
    });
  });

  group('navigation', () {
    testWidgets('a route name loses its query and fragment', (tester) async {
      await tester.runAsync(init);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [CarpGlitchTip.navigatorObserver()],
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Text('page'),
          ),
        ),
      );
      unawaited(navigator.currentState!.pushNamed('/invite?code=XXGHW#frag'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => CarpGlitchTip.captureMessage('probe'));

      final event = transport.events.single;
      final crumb = event.breadcrumbs!.lastWhere(
        (crumb) => crumb.category == 'navigation',
      );
      expect(crumb.data, containsPair('to', '/invite'));
      expect(event.tags, containsPair('screen', '/invite'));
      final json = jsonEncode(event.toJson());
      expect(json, isNot(contains('XXGHW')));
      expect(json, isNot(contains('#frag')));

      // lets the SDK's app start tracking run its timers out
      tester.binding.scheduleFrame();
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
    });

    test('a bound transaction gives a screen tag without query', () async {
      await init(tracesSampleRate: 1);
      final transaction = Sentry.startTransaction(
        '/x?code=1',
        'ui.load',
        bindToScope: true,
      );
      await CarpGlitchTip.captureException(StateError('boom'));
      await transaction.finish();

      final event = transport.events.single;
      expect(event.tags, containsPair('screen', '/x'));
      expect(event.transaction, isNull);
      expect(jsonEncode(event.toJson()), isNot(contains('code=1')));
    });

    test(
      'the trace headers of the wrapper\'s own transactions carry no raw URL',
      () async {
        // the name of a transaction an app binds to the scope is in the
        // trace header as is (documented); the wrapper's own are normalised
        await init(
          tracesSampleRate: 1,
          httpOptions: const HttpOptions(
            sampleRate: 1,
            tracePropagationTargets: ['h'],
          ),
        );
        final client = CarpGlitchTip.httpClient(
          MockClient((request) async => http.Response('ok', 200)),
        );
        await client.get(Uri.parse('https://h/users/42?token=s'));
        await CarpGlitchTip.trace('GET https://h/users/42?token=s', () {});
        await eventually(() => transport.transactions.length == 2);

        expect(transport.transactions, hasLength(2));
        for (final envelope in transport.envelopes) {
          // the trace header: the dynamic sampling context
          final header = jsonEncode(envelope.header.toJson());
          expect(header, isNot(contains('token=s')));
          expect(header, isNot(contains('/42')));
        }
      },
    );
  });

  group('discarded transactions', () {
    // Starts reporting with trace propagation to api.example.com and a
    // beforeSendTransaction set in configure, which records the names of
    // the transactions it sees and whether any has the discard marker.
    Future<(List<String?>, List<Object?>)> initRecording({
      int maxTransactionsPerMinute = 30,
    }) async {
      final names = <String?>[];
      final markers = <Object?>[];
      await init(
        httpOptions: HttpOptions(
          sampleRate: 1,
          tracePropagationTargets: const ['api.example.com'],
          maxTransactionsPerMinute: maxTransactionsPerMinute,
        ),
        configure: (o) => o.beforeSendTransaction = (transaction, hint) {
          names.add(transaction.transaction);
          markers.add(transaction.contexts.trace?.data?[Privacy.discardKey]);
          return transaction;
        },
      );
      return (names, markers);
    }

    test('an ignored offline failure never reaches the app hook', () async {
      final (names, markers) = await initRecording();
      final headers = <String, Map<String, String>>{};
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          headers[request.url.path] = request.headers;
          if (request.url.path == '/offline') throw _offline;
          return http.Response('', 200);
        }),
      );
      await expectLater(
        client.get(Uri.parse('https://api.example.com/offline')),
        throwsA(same(_offline)),
      );
      await client.get(Uri.parse('https://api.example.com/online'));
      await eventually(() => transport.transactions.isNotEmpty);
      await settle();

      // the failed request had a transaction, started to propagate it
      expect(headers['/offline'], contains('sentry-trace'));
      expect(names, ['GET api.example.com/online']);
      expect(markers, everyElement(isNull));
    });

    test('nor does one over maxTransactionsPerMinute', () async {
      final (names, markers) = await initRecording(maxTransactionsPerMinute: 1);
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async => http.Response('', 200)),
      );
      await client.get(Uri.parse('https://api.example.com/first'));
      await client.get(Uri.parse('https://api.example.com/second'));
      await eventually(() => transport.transactions.isNotEmpty);
      await settle();

      expect(names, ['GET api.example.com/first']);
      expect(markers, everyElement(isNull));
    });
  });

  group('round 3', () {
    // Checks [input] scrubs to [expected], and [expected] to itself.
    void scrubs(String input, String expected) {
      expect(privacy.text(input), expected, reason: input);
      expect(privacy.text(expected), expected, reason: 'again: $expected');
    }

    test('JSON secrets inside a JSON string are redacted', () {
      scrubs(
        r'{\"access_token\":\"opaque-abc\",\"x\":1}',
        r'{\"access_token\":\"{redacted}\",\"x\":1}',
      );
      scrubs(
        r'PlatformException(token_failed, {\"refresh_token\":\"8xLOxBtZp8\"}, '
            'null)',
        r'PlatformException(token_failed, {\"refresh_token\":\"{redacted}\"}, '
            'null)',
      );
    });

    test('a JSON secret with an escaped quote is redacted completely', () {
      scrubs(
        r'{"password":"a\"b-rest","x":1}',
        r'{"password":"{redacted}","x":1}',
      );
    });

    test('secrets in fragments and form bodies are redacted', () {
      scrubs(
        'fragment: access_token=SECRET&token_type=bearer',
        'fragment: access_token={redacted}&token_type=bearer',
      );
      scrubs(
        'body: access_token=SECRET&x=1',
        'body: access_token={redacted}&x=1',
      );
      scrubs('#access_token=SECRET', '#access_token={redacted}');
      scrubs('#state=abc&code=xyz', '#state={redacted}&code={redacted}');
      scrubs('form: client_secret=s3cr3t', 'form: client_secret={redacted}');
    });

    test('words that only look like parameters are kept', () {
      for (final text in [
        'the access_token= parameter is missing',
        'status code=404',
        'state: disconnected',
        'android-code: 133',
      ]) {
        scrubs(text, text);
      }
    });

    test('URLs of other schemes lose their user info', () {
      scrubs('ftp://participant:s3cret@files/data.csv', 'ftp://files/data.csv');
      scrubs('smb://jane:Passw0rd@nas/share', 'smb://nas/share');
      scrubs('redis://:hunter2@10.0.0.1:6379/0', 'redis://10.0.0.1:6379/0');
    });

    test('hardware addresses are redacted, hex dumps are kept', () {
      scrubs('remoteId: E4:5F:01:AA:BB:CC', 'remoteId: {mac}');
      scrubs('remoteId:E4:5F:01:AA:BB:CC', 'remoteId:{mac}');
      scrubs('id:E4:5F:01:AA:BB:CC', 'id:{mac}');
      scrubs('device-E4-5F-01-AA-BB-CC', 'device-{mac}');
      scrubs('[E4:5F:01:AA:BB:CC]', '[{mac}]');
      scrubs('mac=E4:5F:01:AA:BB:CC,next', 'mac={mac},next');
      scrubs('12-34-56-78-9a-bc', '{mac}');
      scrubs(
        'value: 01:02:03:04:05:06:07:08',
        'value: 01:02:03:04:05:06:07:08',
      );
      scrubs('mixed: 01:02-03:04-05:06', 'mixed: 01:02-03:04-05:06');
    });

    test('a placeholder in a URL path stays the same when scrubbed again', () {
      scrubs(
        'https://x.com/d/E4:5F:01:AA:BB:CC,next',
        'https://x.com/d/{mac},next',
      );
      scrubs('https://x.com/d/{mac}.json', 'https://x.com/d/{mac}.json');
    });

    test('long runs of punctuation or braces after a URL are fast', () {
      for (final input in [
        'https://x.com/${'.' * 8000}a',
        'https://x.com/a${'!?' * 4000}b',
        'https://x.com/${'}' * 8000}',
      ]) {
        privacy.text(input); // warm-up
        var best = const Duration(days: 1);
        for (var i = 0; i < 3; i++) {
          final watch = Stopwatch()..start();
          privacy.text(input);
          if (watch.elapsed < best) best = watch.elapsed;
        }
        expect(best, lessThan(const Duration(milliseconds: 50)));
      }
    });

    test('the coarse fallback is fast and capped on long values', () {
      final event = SentryEvent(
        exceptions: [SentryException(type: 'E', value: 'a' * 40000)],
      );
      // a raw map under a typed key makes the full policy fail
      event.contexts['device'] = {'raw': 1};
      final watch = Stopwatch()..start();
      final scrubbed = privacy.event(event)!;
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(scrubbed.contexts['device'], isNull, reason: 'coarse fallback');
      expect(scrubbed.exceptions!.single.value!.length, lessThan(8300));
    });

    test('a reported exception without a mechanism is tagged generic', () {
      final error = StateError('reported by the app');
      final event = SentryEvent(
        throwable: error,
        exceptions: [
          SentryException(type: 'StateError', value: 'x', throwable: error),
          SentryException(
            type: 'OSError',
            value: 'y',
            mechanism: Mechanism(type: 'OSError'),
          ),
        ],
      );
      expect(privacy.event(event)!.tags, {
        'handled': 'yes',
        'mechanism': 'generic',
      });
    });

    test('metrics are not sent by default', () async {
      await init();
      Sentry.metrics.count(
        'login',
        1,
        attributes: {'who': SentryAttribute.string('jane@example.com')},
      );
      await settle();
      await CarpGlitchTip.close(); // flushes the metrics
      final items = [
        for (final envelope in transport.envelopes)
          for (final item in envelope.items) item.header.type,
      ];
      expect(items, isNot(contains('trace_metric')));
    });

    test('metrics an app opts into have their attributes scrubbed', () async {
      final seen = <SentryMetric>[];
      await init(
        configure: (o) => o.beforeSendMetric = (metric, hint) {
          seen.add(metric);
          return metric;
        },
      );
      await setAppUser();
      Sentry.metrics.count(
        'login',
        1,
        attributes: {
          'who': SentryAttribute.string('jane@example.com'),
          'redirect': SentryAttribute.string('https://h/cb?code=SECRET'),
          'tries': SentryAttribute.int(3),
        },
      );
      await eventually(() => seen.isNotEmpty);
      await settle();
      await CarpGlitchTip.close(); // flushes the metrics
      final json = <String>[
        for (final envelope in transport.envelopes)
          for (final item in envelope.items)
            if (item.header.type == 'trace_metric')
              utf8.decode(await item.dataFactory()),
      ].join();
      expect(json, contains('login'));
      expect(json, contains('{email}'));
      expect(json, contains('https://h/cb'));
      for (final identifier in [
        'jane@example.com',
        'SECRET',
        'p@example.com',
        'account-1',
      ]) {
        expect(json, isNot(contains(identifier)), reason: identifier);
      }
    });

    test(
      'a navigation transaction loses the query of its route name',
      () async {
        await init(tracesSampleRate: 1);
        final transaction = Sentry.startTransaction(
          '/study/42?code=1#top',
          'navigation',
          bindToScope: false,
        );
        await transaction.finish();
        await eventually(() => transport.transactions.isNotEmpty);
        expect(transport.transactions.single.transaction, '/study/42');
      },
    );
  });

  group('round 4', () {
    // Checks [input] scrubs to [expected], and [expected] to itself.
    void scrubs(String input, String expected) {
      expect(privacy.text(input), expected, reason: input);
      expect(privacy.text(expected), expected, reason: 'again: $expected');
    }

    test('no trace header carries the name of a transaction', () async {
      await init(tracesSampleRate: 1);
      // bound to the scope, so the error event carries its trace header too
      final bound = Sentry.startTransaction(
        '/study/42?code=SECRETCODE#top',
        'navigation',
        bindToScope: true,
      );
      await CarpGlitchTip.captureException(StateError('boom'));
      await bound.finish();
      final unbound = Sentry.startTransaction(
        'upload jane@example.com',
        'task',
        bindToScope: false,
      );
      await unbound.finish();
      await CarpGlitchTip.trace('/study/42?participant=jane-doe#x', () {});
      await eventually(() => transport.transactions.length == 3);

      expect(transport.events, hasLength(1));
      expect(transport.transactions, hasLength(3));
      for (final envelope in transport.envelopes) {
        final trace = envelope.header.traceContext;
        expect(trace, isNotNull, reason: 'the trace header is kept');
        expect(trace!.transaction, isNull);
        expect(trace.traceId, isNot(SentryId.empty()));
        final header = jsonEncode(envelope.header.toJson());
        for (final secret in ['SECRETCODE', 'jane@example.com', 'jane-doe']) {
          expect(header, isNot(contains(secret)), reason: secret);
        }
      }
      expect(
        transport.transactions.map((t) => t.transaction),
        containsAll(['/study/42', 'upload {email}']),
      );
    });

    test('JSON unicode escapes do not hide URLs, secrets and e-mails', () {
      // the JSON escape of a character, built at runtime so no tool turns
      // it into the character itself
      String u(String hex) => '\\u$hex';
      final amp = u('0026');
      expect(amp, hasLength(6));
      scrubs(
        '{"redirect":"https://h/cb?state=abc${amp}code=SECRETCODE"}',
        '{"redirect":"https://h/cb"}',
      );
      scrubs(
        '{"body":"grant_type=x${amp}access_token=SECRET1${amp}y=1"}',
        '{"body":"grant_type=x&access_token={redacted}&y=1"}',
      );
      scrubs('form: code${u('003D')}abc', 'form: code=abc');
      scrubs('{"user":"jane${u('0040')}example.com"}', '{"user":"{email}"}');
    });

    test('secrets in `name: value` form are redacted', () {
      scrubs(
        '{access_token: opaqueSECRET, token_type: Bearer}',
        '{access_token: {redacted}, token_type: Bearer}',
      );
      scrubs(
        'PlatformException(token_failed, null, {access_token: aSECRET, '
            'refresh_token: rSECRET}, null)',
        'PlatformException(token_failed, null, {access_token: {redacted}, '
            'refresh_token: {redacted}}, null)',
      );
      scrubs(
        'OAuthToken - accessToken: a1b2c3, refresh_token: d4e5f6, '
            'tokenType: Bearer',
        'OAuthToken - accessToken: {redacted}, refresh_token: {redacted}, '
            'tokenType: Bearer',
      );
      scrubs('password="hunter2"', 'password="{redacted}"');
      scrubs("client_secret='s3cr3t'", "client_secret='{redacted}'");
      for (final text in [
        'the access_token= parameter is missing',
        'Invalid password: too short',
        'accessTokenExpired: true',
        '{access_token: {jwt}}',
      ]) {
        scrubs(text, text);
      }
    });

    test('a JSON secret in a JSON string keeps no part of its value', () {
      scrubs(
        r'{\"password\":\"a\\\"b-rest\",\"x\":1}',
        r'{\"password\":\"{redacted}\",\"x\":1}',
      );
    });

    test('user info with an @ in the password is removed completely', () {
      scrubs('ftp://user:p@ss@host/x', 'ftp://host/x');
      scrubs(
        'postgres://carp:s3cr@t@db.example.org:5432/carp',
        'postgres://db.example.org:5432/carp',
      );
    });

    test('hardware addresses glued to other hex pairs are redacted', () {
      scrubs('E4:5F:01:AA:BB:CC-01', '{mac}-01');
      scrubs('01-E4:5F:01:AA:BB:CC', '01-{mac}');
      scrubs('E4:5F:01:AA:BB:CC-11:22:33:44:55:66', '{mac}-{mac}');
      scrubs(
        'in https://h.dk/d/E4:5F:01:AA:BB:CC-11:22:33:44:55:66 now',
        'in https://h.dk/d/{mac}-{mac} now',
      );
      // hex dumps and mixed separators stay
      scrubs('01:02:03:04:05:06:07:08', '01:02:03:04:05:06:07:08');
      scrubs('01:02-03:04-05:06', '01:02-03:04-05:06');
    });

    test('placeholders glued in one path segment survive normalising '
        'again', () {
      expect(normalizePathSegment('%7Bmac%7D-%7Bmac%7D'), '{mac}-{mac}');
      expect(
        normalizePathSegment('{study}-{participant}'),
        '{study}-{participant}',
      );
      final templated = Privacy(
        user: SentryUser(id: 'u'),
        templates: [
          PathTemplate(RegExp(r'/d/[^/]+'), '/d/{study}-{participant}'),
        ],
      );
      final once = templated.url('https://h.dk/d/s1-p1?x=1');
      expect(once, 'https://h.dk/d/{study}-{participant}');
      expect(templated.url(once), once);
      expect(templated.text('see $once'), 'see $once');
    });

    test('the coarse fallback replaces the whole run around an e-mail', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'E',
            value:
                '{"user":"jane@example.com","note":"${'x' * 300}",'
                '"refresh":"opaque-REFRESH-SECRET"} and more',
          ),
        ],
      );
      // a raw map under a typed key makes the full policy fail
      event.contexts['device'] = {'raw': 1};
      final value = privacy.event(event)!.exceptions!.single.value!;
      expect(value, '{email} and more');
    });

    test('the name and unit of an opted-in metric are scrubbed', () async {
      final seen = <SentryMetric>[];
      await init(
        configure: (o) => o.beforeSendMetric = (metric, hint) {
          seen.add(metric);
          return metric;
        },
      );
      Sentry.metrics.distribution(
        'upload.jane@example.com',
        12,
        unit: 'ms-for-jane@example.com',
      );
      await eventually(() => seen.isNotEmpty);
      await settle();
      await CarpGlitchTip.close(); // flushes the metrics
      final json = <String>[
        for (final envelope in transport.envelopes)
          for (final item in envelope.items)
            if (item.header.type == 'trace_metric')
              utf8.decode(await item.dataFactory()),
      ].join();
      expect(json, contains('{email}'));
      expect(json, isNot(contains('jane@example.com')));
    });
  });
}
