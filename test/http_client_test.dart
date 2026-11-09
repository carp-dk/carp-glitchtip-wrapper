// Tests for the instrumented HTTP client (CarpGlitchTip.httpClient and the
// clients of CarpGlitchTip.runZoned): how requests become transactions,
// breadcrumbs and failure events, which requests are left alone, and that
// recording never changes the outcome of a request. Driven through the
// public API with a GlitchTipTestTransport and MockClient: no network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/src/network/glitchtip_http_client.dart';
import 'package:carp_glitchtip_wrapper/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sentry_flutter/sentry_flutter.dart'
    show SentryTransaction, TypeCheckHint;

const _dsn = 'https://key@glitchtip.example.com/1';
const _uuid = '123e4567-e89b-12d3-a456-426614174000';

/// A request URL with an id in the path and a secret in the query.
final _items = Uri.parse('https://api.example.com/items/42?token=secret');

/// What a request throws while the phone is offline; ignored by default.
const _offline = SocketException(
  "Failed host lookup: 'api.example.com'",
  osError: OSError('nodename nor servname provided, or not known', 8),
);

/// What a request throws while the server is down; reported. A new error
/// for every request, like a real client (the SDK drops an error object it
/// has already reported).
SocketException _refused() => SocketException(
  'Connection refused',
  osError: OSError(
    'Connection refused',
    Platform.isMacOS || Platform.isIOS ? 61 : 111,
  ),
);

/// An error of the app's own code; reported.
class _BackendBug implements Exception {
  @override
  String toString() => 'backend bug';
}

/// An inner client that answers with [response] or throws [error], and
/// counts how often it was closed.
class _FakeClient extends http.BaseClient {
  _FakeClient({this.response, this.error});

  final http.StreamedResponse? response;
  final Object? error;
  final List<http.BaseRequest> requests = [];
  int closed = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (error case final error?) throw error;
    return response ?? http.StreamedResponse(const Stream.empty(), 200);
  }

  @override
  void close() => closed++;
}

/// A client that answers every request with [status].
http.Client _answering(int status, [String body = '{}']) =>
    MockClient((request) async => http.Response(body, status));

/// A client that answers `/s<status>`, e.g. `/s404`, with that status.
http.Client _statusServer() => MockClient((request) async {
  final status = int.parse(request.url.pathSegments.last.substring(1));
  return http.Response('', status);
});

/// A client that fails every request with [error].
http.Client _failing(Object error) =>
    MockClient((request) async => throw error);

/// Sends a GET request that is expected to fail.
Future<void> _attempt(http.Client client, Uri url) async {
  try {
    await client.get(url);
  } catch (_) {
    // the tests check what was recorded
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GlitchTipTestTransport transport;

  setUp(() async {
    await CarpGlitchTip.resetForTest();
    transport = GlitchTipTestTransport();
  });
  tearDown(CarpGlitchTip.resetForTest);

  // Starts reporting into [transport]. Every request is sampled unless a
  // test passes other [httpOptions].
  Future<void> init({
    HttpOptions httpOptions = const HttpOptions(sampleRate: 1),
    String dsn = _dsn,
    IgnoreRule? offlineErrors = const IgnoreRule.offline(),
    List<IgnoreRule> ignoreErrors = const [],
    String? Function(Object error)? describeError,
    FutureOr<SentryEvent?> Function(SentryEvent event, Hint hint)? beforeSend,
    double? tracesSampleRate,
    void Function(SentryFlutterOptions options)? configure,
  }) => CarpGlitchTip.init(
    CarpGlitchTipOptions(
      enabled: true,
      dsn: dsn,
      tracesSampleRate: tracesSampleRate,
      http: httpOptions,
      offlineErrors: offlineErrors,
      ignoreErrors: ignoreErrors,
      describeError: describeError,
      beforeSend: beforeSend,
      configure: (options) {
        options.transport = transport;
        options.autoInitializeNativeSdk = false;
        configure?.call(options);
      },
    ),
  );

  // The SDK sends events and transactions asynchronously.
  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  // Gives anything still on its way the time to arrive, before checking that
  // it was not sent.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 150));

  List<String?> names() => [
    for (final transaction in transport.transactions) transaction.transaction,
  ];

  SentryTransaction named(String name) =>
      transport.transactions.singleWhere((t) => t.transaction == name);

  // The status of each transaction, by name.
  Map<String?, String?> statuses() => {
    for (final transaction in transport.transactions)
      transaction.transaction: '${transaction.contexts.trace?.status}',
  };

  bool isProbe(SentryEvent event) => event.message?.formatted == 'probe';

  // The error events, without the probes of [requestCrumbs].
  List<SentryEvent> failures() => [
    for (final event in transport.events)
      if (!isProbe(event)) event,
  ];

  // The value of the reported exception of each error event (the SDK adds
  // e.g. the OSError of a SocketException after it).
  List<String?> reported() => [
    for (final event in failures()) event.exceptions?.first.value,
  ];

  // The request breadcrumbs that an error reported now would carry.
  Future<List<Breadcrumb>> requestCrumbs() async {
    final probes = transport.events.where(isProbe).length;
    await CarpGlitchTip.captureMessage('probe');
    await until(() => transport.events.where(isProbe).length > probes);
    final probe = transport.events.lastWhere(isProbe);
    return [
      for (final crumb in probe.breadcrumbs ?? const <Breadcrumb>[])
        if (crumb.category == 'http') crumb,
    ];
  }

  Future<List<Object?>> crumbUrls() async => [
    for (final crumb in await requestCrumbs()) crumb.data?['url'],
  ];

  group('transaction names', () {
    test('are the method and the normalised URL', () async {
      await init();
      final client = CarpGlitchTip.httpClient(_answering(200));
      final cases = [
        (
          'https://cans.cachet.dk/api/studies/$_uuid/participants/42'
              '?token=secret#top',
          'GET cans.cachet.dk/api/studies/{uuid}/participants/{id}',
        ),
        (
          'https://API.example.com:443/users/jane.doe@example.com/?page=2',
          'GET api.example.com/users/{email}',
        ),
        (
          'http://localhost:8080/files/0123456789abcdef0123456789abcdef',
          'GET localhost:8080/files/{hash}',
        ),
        ('https://user:password@api.example.com', 'GET api.example.com/'),
      ];
      for (final (url, _) in cases) {
        await client.get(Uri.parse(url));
      }
      await until(() => transport.transactions.length == cases.length);
      expect(names(), unorderedEquals([for (final (_, name) in cases) name]));
    });

    test('hide the code of a CAWS self-signup link', () async {
      await init();
      final client = CarpGlitchTip.httpClient(_answering(503));
      await client.get(
        Uri.parse('https://cans.cachet.dk/api/self-signup/Xk9Pq2Lm'),
      );
      await until(
        () => transport.transactions.isNotEmpty && transport.events.isNotEmpty,
      );
      expect(names(), ['GET cans.cachet.dk/api/self-signup/{code}']);
      expect(reported(), [
        'HTTP 503: GET cans.cachet.dk/api/self-signup/{code}',
      ]);
      expect(await crumbUrls(), [
        'https://cans.cachet.dk/api/self-signup/{code}',
      ]);
    });

    test('end with the operation of a CAWS RPC call', () async {
      await init();
      final client = CarpGlitchTip.httpClient(_answering(200));
      final service = Uri.parse(
        'https://cans.cachet.dk/api/deployment-service',
      );
      const type =
          'dk.cachet.carp.deployments.infrastructure.DeploymentServiceRequest'
          '.GetStudyDeploymentStatus';
      String rpc(String type, {String padding = ''}) => jsonEncode({
        if (padding.isNotEmpty) 'padding': padding,
        '__type': type,
        'studyDeploymentId': _uuid,
      });

      await client.post(service, body: rpc(type));
      // no operation: not a POST, not a service, not a name, not in 4 KB
      await client.get(service);
      await client.post(
        Uri.parse('https://cans.cachet.dk/api/studies'),
        body: rpc(type),
      );
      await client.post(service, body: rpc('dk.cachet.Request.42'));
      await client.post(service, body: rpc(type, padding: 'x' * 5000));

      await until(() => transport.transactions.length == 5);
      expect(
        names(),
        unorderedEquals([
          'POST cans.cachet.dk/api/deployment-service GetStudyDeploymentStatus',
          'GET cans.cachet.dk/api/deployment-service',
          'POST cans.cachet.dk/api/studies',
          'POST cans.cachet.dk/api/deployment-service',
          'POST cans.cachet.dk/api/deployment-service',
        ]),
      );
    });

    test('apply the app path templates to every reported URL', () async {
      await init(
        httpOptions: HttpOptions(
          sampleRate: 1,
          pathTemplates: [
            PathTemplate(RegExp('/invitations/[^/]+'), '/invitations/{code}'),
          ],
        ),
      );
      final client = CarpGlitchTip.httpClient(_answering(503));
      await client.get(
        Uri.parse('https://api.example.com/invitations/Secret-Code?lang=da'),
      );
      await until(
        () => transport.transactions.isNotEmpty && transport.events.isNotEmpty,
      );

      const url = 'https://api.example.com/invitations/{code}';
      final transaction = transport.transactions.single;
      expect(transaction.transaction, 'GET api.example.com/invitations/{code}');
      expect(transaction.request?.url, url);
      final event = transport.events.single;
      expect(event.request?.url, url);
      expect(event.exceptions?.single.value, contains('/invitations/{code}'));
      final crumb = event.breadcrumbs!.singleWhere((c) => c.category == 'http');
      expect(crumb.data?['url'], url);
      for (final report in [transaction.toJson(), event.toJson()]) {
        expect('$report', isNot(contains('Secret-Code')));
        expect('$report', isNot(contains('lang=da')));
      }
    });

    test('can be changed with HttpOptions.transactionName', () async {
      final calls = <String>[];
      await init(
        httpOptions: HttpOptions(
          sampleRate: 1,
          transactionName: (method, url, name) {
            calls.add('$method | $url | $name');
            final operation = url.queryParameters['operation'];
            return operation == null ? name : '$name $operation';
          },
        ),
      );
      final client = CarpGlitchTip.httpClient(_answering(503));
      await client.post(
        Uri.parse('https://api.example.com/graphql?operation=GetStudy'),
      );
      await until(
        () => transport.transactions.isNotEmpty && transport.events.isNotEmpty,
      );
      expect(calls, [
        'POST | https://api.example.com/graphql?operation=GetStudy | '
            'POST api.example.com/graphql',
      ]);
      expect(names(), ['POST api.example.com/graphql GetStudy']);
      expect(reported(), ['HTTP 503: POST api.example.com/graphql GetStudy']);
    });

    test('scrub the name returned by transactionName', () async {
      await init(
        httpOptions: HttpOptions(
          sampleRate: 1,
          transactionName: (method, url, name) => '$name of jane@example.com',
        ),
      );
      await CarpGlitchTip.httpClient(_answering(200)).get(_items);
      await until(() => transport.transactions.isNotEmpty);
      expect(names(), ['GET api.example.com/items/{id} of {email}']);
    });

    test('keep the default name when transactionName throws', () async {
      await init(
        httpOptions: HttpOptions(
          sampleRate: 1,
          transactionName: (method, url, name) => throw StateError('bug'),
        ),
      );
      final response = await CarpGlitchTip.httpClient(
        _answering(200, 'ok'),
      ).get(_items);
      expect(response.statusCode, 200);
      expect(response.body, 'ok');
      await until(() => transport.transactions.isNotEmpty);
      expect(names(), ['GET api.example.com/items/{id}']);
    });
  });

  group('transaction status', () {
    test('follows the response status code', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          maxTransactionsPerMinute: 100,
        ),
      );
      const expected = {
        200: 'ok',
        204: 'ok',
        302: 'ok',
        400: 'invalid_argument',
        401: 'unauthenticated',
        403: 'permission_denied',
        404: 'not_found',
        409: 'already_exists',
        418: 'invalid_argument',
        429: 'resource_exhausted',
        499: 'cancelled',
        500: 'internal_error',
        501: 'unimplemented',
        502: 'internal_error',
        503: 'unavailable',
        504: 'deadline_exceeded',
        507: 'internal_error',
      };
      final client = CarpGlitchTip.httpClient(_statusServer());
      for (final status in expected.keys) {
        await client.get(Uri.parse('https://api.example.com/s$status'));
      }
      await until(() => transport.transactions.length == expected.length);
      expect(statuses(), {
        for (final MapEntry(:key, :value) in expected.entries)
          'GET api.example.com/s$key': value,
      });
    });

    test('follows the exception of a failed request', () async {
      await init(
        httpOptions: const HttpOptions(sampleRate: 1, traceIgnoredErrors: true),
      );
      final errors = <String, Object>{
        'timeout': TimeoutException('no response'),
        'refused': _refused(),
        'offline': _offline,
        'aborted': http.RequestAbortedException(),
        'bug': _BackendBug(),
      };
      final client = CarpGlitchTip.httpClient(
        MockClient(
          (request) async => throw errors[request.url.path.substring(1)]!,
        ),
      );
      for (final MapEntry(:key, :value) in errors.entries) {
        await expectLater(
          client.get(Uri.parse('https://api.example.com/$key')),
          throwsA(same(value)),
        );
      }
      await until(() => transport.transactions.length == errors.length);
      expect(statuses(), {
        'GET api.example.com/timeout': 'deadline_exceeded',
        'GET api.example.com/refused': 'internal_error',
        'GET api.example.com/offline': 'unavailable',
        'GET api.example.com/aborted': 'cancelled',
        'GET api.example.com/bug': 'internal_error',
      });
    });

    test('is not recorded for a request that failed offline', () async {
      await init();
      final client = CarpGlitchTip.httpClient(
        MockClient(
          (request) async => throw switch (request.url.path) {
            '/offline' => _offline,
            '/timeout' => TimeoutException('no response'),
            _ => _refused(),
          },
        ),
      );
      for (final path in ['offline', 'timeout', 'refused']) {
        await _attempt(client, Uri.parse('https://api.example.com/$path'));
      }
      await until(() => transport.transactions.isNotEmpty);
      await settle();
      expect(statuses(), {'GET api.example.com/refused': 'internal_error'});
    });
  });

  group('sampling', () {
    test('a sample rate of 0 records breadcrumbs, no transactions', () async {
      await init(httpOptions: const HttpOptions(sampleRate: 0));
      final client = CarpGlitchTip.httpClient(_statusServer());
      for (final status in [200, 404, 503]) {
        await client.get(Uri.parse('https://api.example.com/s$status'));
      }
      expect(await requestCrumbs(), hasLength(3));
      await until(() => failures().isNotEmpty);
      await settle();
      expect(transport.transactions, isEmpty);
      expect(reported(), ['HTTP 503: GET api.example.com/s503']);
    });

    test('a sample rate of 1 records every request', () async {
      await init();
      final client = CarpGlitchTip.httpClient(_answering(200));
      for (var i = 0; i < 10; i++) {
        await client.get(Uri.parse('https://api.example.com/items/$i'));
      }
      await until(() => transport.transactions.length == 10);
      await settle();
      expect(transport.transactions, hasLength(10));
    });

    test('decides for each request on its own', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 0.5,
          maxTransactionsPerMinute: 1000,
        ),
      );
      final client = CarpGlitchTip.httpClient(_answering(200));
      for (var i = 0; i < 60; i++) {
        await client.get(Uri.parse('https://api.example.com/items/$i'));
      }
      await until(() => transport.transactions.isNotEmpty);
      await settle();
      // all or none of 60 requests would have a chance of 1 in 2^59
      expect(transport.transactions.length, inExclusiveRange(0, 60));
    });

    test('maxTransactionsPerMinute caps the transactions', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          maxTransactionsPerMinute: 3,
        ),
      );
      final client = CarpGlitchTip.httpClient(_answering(200));
      for (var i = 0; i < 6; i++) {
        await client.get(Uri.parse('https://api.example.com/items/$i'));
      }
      expect(await requestCrumbs(), hasLength(6));
      await until(() => transport.transactions.length >= 3);
      await settle();
      expect(transport.transactions, hasLength(3));
    });

    test('maxTransactionsPerMinute: 0 records no transactions', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          maxTransactionsPerMinute: 0,
        ),
      );
      await CarpGlitchTip.httpClient(_answering(200)).get(_items);
      expect(await requestCrumbs(), hasLength(1));
      await settle();
      expect(transport.transactions, isEmpty);
    });

    test('requests share maxTransactionsPerMinute with trace()', () async {
      await init(
        tracesSampleRate: 1,
        httpOptions: const HttpOptions(
          sampleRate: 1,
          maxTransactionsPerMinute: 2,
        ),
      );
      await CarpGlitchTip.trace('load study', () async {});
      final client = CarpGlitchTip.httpClient(_answering(200));
      for (var i = 0; i < 3; i++) {
        await client.get(Uri.parse('https://api.example.com/items/$i'));
      }
      await until(() => transport.transactions.length >= 2);
      await settle();
      expect(
        names(),
        unorderedEquals(['load study', 'GET api.example.com/items/{id}']),
      );
    });
  });

  group('request transactions', () {
    test('span the request as an http.client transaction', () async {
      await init();
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response('{"id":42}', 201);
        }),
      );
      final before = DateTime.now().toUtc();
      await client.post(_items, body: 'hello');
      final after = DateTime.now().toUtc();
      await until(() => transport.transactions.isNotEmpty);

      final transaction = transport.transactions.single;
      final trace = transaction.contexts.trace!;
      expect(transaction.transaction, 'POST api.example.com/items/{id}');
      expect(trace.operation, 'http.client');
      expect(trace.origin, 'auto.http.carp_glitchtip');
      expect(transaction.transactionInfo?.source, 'route');
      expect(transaction.request?.method, 'POST');
      expect(transaction.request?.url, 'https://api.example.com/items/{id}');

      final start = transaction.startTimestamp;
      final end = transaction.timestamp!;
      expect(start.isBefore(end), isTrue);
      expect(start.isBefore(before), isFalse);
      expect(end.isAfter(after), isFalse);
      expect(
        end.difference(start),
        greaterThanOrEqualTo(const Duration(milliseconds: 45)),
      );
    });

    test('carry the request and its response in the trace data', () async {
      await init();
      final client = CarpGlitchTip.httpClient(_answering(201, '{"id":42}'));
      await client.post(_items, body: 'hello');
      await until(() => transport.transactions.isNotEmpty);
      final data = transport.transactions.single.contexts.trace!.data!;
      expect(data, containsPair('http.request.method', 'POST'));
      expect(data, containsPair('url', 'https://api.example.com/items/{id}'));
      expect(data, containsPair('http.request_content_length', 5));
      expect(data, containsPair('http.response.status_code', 201));
      expect(data, containsPair('http.response_content_length', 9));
      expect(data, isNot(contains('error.type')));
    });

    test('carry the error type of a failed request', () async {
      await init();
      await _attempt(CarpGlitchTip.httpClient(_failing(_refused())), _items);
      await until(() => transport.transactions.isNotEmpty);
      final data = transport.transactions.single.contexts.trace!.data!;
      expect(data, containsPair('http.request.method', 'GET'));
      expect(data, containsPair('url', 'https://api.example.com/items/{id}'));
      expect(data, containsPair('error.type', 'SocketException'));
      expect(data, isNot(contains('http.response.status_code')));
    });

    test('carry nothing else of the app', () async {
      await init();
      CarpGlitchTip.setStudy(
        const StudyMetadata(studyId: 's1', studyDeploymentId: 'd1'),
      );
      CarpGlitchTip.setTags({'clinic': 'north'});
      CarpGlitchTip.setContext('setup', {'sensors': 3});
      CarpGlitchTip.addBreadcrumb(Breadcrumb(message: 'joined the study'));
      // lets the metadata reach the Sentry scope
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await CarpGlitchTip.httpClient(_answering(200)).get(_items);
      await until(() => transport.transactions.isNotEmpty);
      final transaction = transport.transactions.single;
      expect(transaction.breadcrumbs ?? const [], isEmpty);
      expect(transaction.user, isNull);
      expect(transaction.tags ?? const {}, isEmpty);
      expect(transaction.contexts.keys, ['trace']);
      expect(transaction.spans, isEmpty);
    });

    test('are not bound to the scope while the request runs', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          tracePropagationTargets: ['api.example.com'],
        ),
      );
      final started = Completer<void>();
      final release = Completer<void>();
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          started.complete();
          await release.future;
          return http.Response('', 200);
        }),
      );
      final pending = client.get(_items);
      await started.future;
      // an error elsewhere in the app while the request is in flight
      await CarpGlitchTip.captureException(StateError('unrelated'));
      release.complete();
      await pending;
      await until(
        () => transport.events.isNotEmpty && transport.transactions.isNotEmpty,
      );
      final event = transport.events.single;
      expect(event.transaction, isNull);
      expect(event.tags, isNot(contains('screen')));
    });
  });

  group('failure events', () {
    test('a 5xx response is reported as an HTTP client error', () async {
      await init();
      await CarpGlitchTip.httpClient(_answering(503, 'down')).get(_items);
      await until(() => transport.events.isNotEmpty);
      await settle();

      final event = transport.events.single;
      final exception = event.exceptions!.single;
      expect(exception.type, 'SentryHttpClientError');
      expect(exception.value, 'HTTP 503: GET api.example.com/items/{id}');
      expect(exception.mechanism?.type, 'CarpGlitchTipHttpClient');
      expect(exception.mechanism?.handled, isTrue);
      expect(event.level, SentryLevel.error);
      expect(event.request?.method, 'GET');
      expect(event.request?.url, 'https://api.example.com/items/{id}');
      expect(event.request?.queryString, isNull);
      expect(event.contexts.response?.statusCode, 503);
      expect(event.contexts.response?.bodySize, 4);
      expect(event.tags, containsPair('handled', 'yes'));
      expect(event.tags, containsPair('mechanism', 'CarpGlitchTipHttpClient'));
    });

    test('the hint of a failure event has the request', () async {
      final hints = <Hint>[];
      await init(
        beforeSend: (event, hint) {
          hints.add(hint);
          return event;
        },
      );
      await CarpGlitchTip.httpClient(_answering(503)).get(_items);
      await until(() => hints.isNotEmpty);
      final failed = Uri.parse('https://api.example.com/failed');
      await _attempt(CarpGlitchTip.httpClient(_failing(_BackendBug())), failed);
      await until(() => hints.length == 2);

      final [response, exception] = hints;
      expect(
        response.get(TypeCheckHint.httpRequest),
        isA<http.BaseRequest>().having((r) => r.url, 'url', _items),
      );
      expect(
        response.get(TypeCheckHint.httpResponse),
        isA<http.BaseResponse>().having((r) => r.statusCode, 'status', 503),
      );
      expect(
        exception.get(TypeCheckHint.httpRequest),
        isA<http.BaseRequest>().having((r) => r.url, 'url', failed),
      );
    });

    test('4xx responses are not reported by default', () async {
      await init();
      final client = CarpGlitchTip.httpClient(_statusServer());
      for (final status in [400, 401, 403, 404, 409, 429, 499, 500]) {
        await client.get(Uri.parse('https://api.example.com/s$status'));
      }
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(reported(), ['HTTP 500: GET api.example.com/s500']);
    });

    test('isFailedStatus decides which responses are reported', () async {
      await init(
        httpOptions: HttpOptions(
          sampleRate: 1,
          isFailedStatus: (status) => status == 409,
        ),
      );
      final client = CarpGlitchTip.httpClient(_statusServer());
      for (final status in [503, 409]) {
        await client.get(Uri.parse('https://api.example.com/s$status'));
      }
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(reported(), ['HTTP 409: GET api.example.com/s409']);
    });

    test('captureFailedRequests: false reports no failures', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          captureFailedRequests: false,
        ),
      );
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          if (request.url.path == '/bug') throw _BackendBug();
          return http.Response('', 503);
        }),
      );
      await client.get(Uri.parse('https://api.example.com/down'));
      await _attempt(client, Uri.parse('https://api.example.com/bug'));
      await until(() => transport.transactions.length == 2);
      await settle();
      expect(transport.events, isEmpty);
    });

    test('an unexpected exception is reported with its own type', () async {
      await init();
      final error = _BackendBug();
      final stackTrace = StackTrace.fromString(
        '#0      callBackend (package:app/backend.dart:12:3)',
      );
      final client = CarpGlitchTip.httpClient(
        MockClient(
          (request) async => Error.throwWithStackTrace(error, stackTrace),
        ),
      );
      await expectLater(client.get(_items), throwsA(same(error)));
      await until(() => transport.events.isNotEmpty);
      await settle();

      final event = transport.events.single;
      expect(event.throwable, same(error));
      final exception = event.exceptions!.single;
      expect(exception.type, '_BackendBug');
      expect(exception.value, 'backend bug');
      expect(exception.mechanism?.type, 'CarpGlitchTipHttpClient');
      expect(exception.mechanism?.handled, isTrue);
      expect(
        exception.stackTrace?.frames.map((frame) => frame.fileName),
        contains('backend.dart'),
      );
      expect(event.request?.method, 'GET');
      expect(event.request?.url, 'https://api.example.com/items/{id}');
    });

    test('offline errors are not reported, a refused connection is', () async {
      await init();
      final refused = _refused();
      final client = CarpGlitchTip.httpClient(
        MockClient(
          (request) async => throw switch (request.url.path) {
            '/offline' => _offline,
            '/timeout' => TimeoutException('no response'),
            '/reset' => http.ClientException(
              'Connection reset by peer',
              request.url,
            ),
            _ => refused,
          },
        ),
      );
      for (final path in ['offline', 'timeout', 'reset', 'refused']) {
        await _attempt(client, Uri.parse('https://api.example.com/$path'));
      }
      await until(() => transport.events.isNotEmpty);
      await settle();
      final event = transport.events.single;
      expect(event.throwable, same(refused));
      final exception = event.exceptions!.first;
      expect(exception.type, 'SocketException');
      expect(exception.mechanism?.type, 'CarpGlitchTipHttpClient');
      expect(event.request?.url, 'https://api.example.com/refused');
    });

    test('offlineErrors: null reports offline errors too', () async {
      await init(offlineErrors: null);
      await _attempt(CarpGlitchTip.httpClient(_failing(_offline)), _items);
      await until(
        () => transport.events.isNotEmpty && transport.transactions.isNotEmpty,
      );
      expect(transport.events.single.throwable, same(_offline));
      expect(statuses(), {'GET api.example.com/items/{id}': 'unavailable'});
    });

    test('an ignore rule on the status code drops a 5xx event', () async {
      await init(
        ignoreErrors: [
          IgnoreRule.custom((c) => c.isHttp && c.statusCode == 503),
        ],
      );
      final client = CarpGlitchTip.httpClient(_statusServer());
      await client.get(Uri.parse('https://api.example.com/s503'));
      await client.get(Uri.parse('https://api.example.com/s500'));
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(reported(), ['HTTP 500: GET api.example.com/s500']);
      // both requests are still transactions
      expect(transport.transactions, hasLength(2));
    });

    test('ignore rules see the URL and method of a failed request', () async {
      await init(
        ignoreErrors: [
          IgnoreRule.custom(
            (c) => c.method == 'DELETE' && c.url?.host == 'api.example.com',
          ),
        ],
      );
      final client = CarpGlitchTip.httpClient(_failing(_BackendBug()));
      await expectLater(client.delete(_items), throwsA(isA<_BackendBug>()));
      await expectLater(client.get(_items), throwsA(isA<_BackendBug>()));
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(transport.events.single.request?.method, 'GET');
      // an ignored failure is not a transaction either
      expect(names(), ['GET api.example.com/items/{id}']);
    });

    test('ignore rules see the describeError text of a failure', () async {
      await init(
        describeError: (error) =>
            error is _BackendBug ? 'Service Unavailable' : null,
        ignoreErrors: [IgnoreRule.message('Service Unavailable')],
      );
      final client = CarpGlitchTip.httpClient(
        MockClient(
          (request) async => throw request.url.path == '/maintenance'
              ? _BackendBug()
              : StateError('bug'),
        ),
      );
      await _attempt(client, Uri.parse('https://api.example.com/maintenance'));
      await _attempt(client, Uri.parse('https://api.example.com/other'));
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(transport.events.single.exceptions?.single.type, 'StateError');
      expect(names(), ['GET api.example.com/other']);
    });

    test('a repeated 5xx is reported once per failureEventWindow', () async {
      const window = Duration(milliseconds: 500);
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          failureEventWindow: window,
        ),
      );
      final client = CarpGlitchTip.httpClient(_answering(503));
      for (var i = 0; i < 3; i++) {
        await client.get(_items);
      }
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(transport.events, hasLength(1));
      expect(transport.events.single.contexts['carp_glitchtip'], isNull);

      await Future<void>.delayed(window);
      await client.get(_items);
      await until(() => transport.events.length == 2);
      expect(transport.events.last.contexts['carp_glitchtip'], {
        'suppressed_since_last': 2,
      });
    });

    test('a repeated exception is reported once per window', () async {
      const window = Duration(milliseconds: 500);
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          failureEventWindow: window,
        ),
      );
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async => throw _refused()),
      );
      for (var i = 0; i < 3; i++) {
        await _attempt(client, _items);
      }
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(transport.events, hasLength(1));
      expect(transport.events.single.contexts['carp_glitchtip'], isNull);

      await Future<void>.delayed(window);
      await _attempt(client, _items);
      await until(() => transport.events.length == 2);
      expect(transport.events.last.contexts['carp_glitchtip'], {
        'suppressed_since_last': 2,
      });
    });

    test('different failures are reported separately', () async {
      await init();
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          final status = int.parse(request.url.queryParameters['status']!);
          return http.Response('', status);
        }),
      );
      for (final url in ['a?status=503', 'b?status=503', 'a?status=500']) {
        await client.get(Uri.parse('https://api.example.com/$url'));
      }
      await until(() => transport.events.length == 3);
      expect(
        reported(),
        unorderedEquals([
          'HTTP 503: GET api.example.com/a',
          'HTTP 503: GET api.example.com/b',
          'HTTP 500: GET api.example.com/a',
        ]),
      );
    });

    test('an ignored failure does not count as a repeat', () async {
      var maintenance = true;
      await init(
        ignoreErrors: [
          IgnoreRule.custom((c) => c.statusCode == 503).when(() => maintenance),
        ],
      );
      final client = CarpGlitchTip.httpClient(_answering(503));
      await client.get(_items);
      await client.get(_items);
      maintenance = false;
      await client.get(_items);
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(transport.events, hasLength(1));
      expect(transport.events.single.contexts['carp_glitchtip'], isNull);
    });
  });

  group('network health', () {
    // carp_webservices throws a bare TimeoutException after its retries; it
    // is ignored only while the network looks offline
    test('an offline failure makes the network look offline', () async {
      await init();
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          if (request.url.path == '/offline') throw _offline;
          return http.Response('', 200);
        }),
      );
      await _attempt(client, Uri.parse('https://api.example.com/offline'));
      await CarpGlitchTip.captureException(TimeoutException('while offline'));
      // a response, whatever its status, means the network is back
      await client.get(Uri.parse('https://api.example.com/online'));
      final online = TimeoutException('while online');
      await CarpGlitchTip.captureException(online);
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(transport.events.single.throwable, same(online));
    });

    test('a refused connection does not look offline', () async {
      await init();
      await _attempt(CarpGlitchTip.httpClient(_failing(_refused())), _items);
      final timeout = TimeoutException('server too slow');
      await CarpGlitchTip.captureException(timeout);
      await until(() => transport.events.length == 2);
      expect([
        for (final event in transport.events) event.throwable,
      ], contains(same(timeout)));
    });
  });

  group('breadcrumbs', () {
    test('describe a request without its query', () async {
      await init();
      final client = CarpGlitchTip.httpClient(_answering(201, '{"ok":true}'));
      await client.post(_items, body: 'abc');
      final crumb = (await requestCrumbs()).single;
      expect(crumb.type, 'http');
      expect(crumb.level, SentryLevel.info);
      expect(crumb.data, {
        'url': 'https://api.example.com/items/{id}',
        'method': 'POST',
        'status_code': 201,
        'duration': matches(RegExp(r'^\d+ms$')),
        'request_body_size': 3,
        'response_body_size': 11,
      });
    });

    test('have the level of the outcome', () async {
      await init();
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          if (request.url.path == '/offline') throw _offline;
          return http.Response('', int.parse(request.url.path.substring(2)));
        }),
      );
      for (final status in [200, 302, 404, 503]) {
        await client.get(Uri.parse('https://api.example.com/s$status'));
      }
      await _attempt(client, Uri.parse('https://api.example.com/offline'));

      final crumbs = await requestCrumbs();
      expect(
        {for (final crumb in crumbs) crumb.data!['url']: crumb.level},
        {
          'https://api.example.com/s200': SentryLevel.info,
          'https://api.example.com/s302': SentryLevel.info,
          'https://api.example.com/s404': SentryLevel.warning,
          'https://api.example.com/s503': SentryLevel.error,
          'https://api.example.com/offline': SentryLevel.error,
        },
      );
      final failed = crumbs.last.data!;
      expect(failed, containsPair('method', 'GET'));
      expect(failed, containsPair('reason', 'SocketException'));
      expect(failed, isNot(contains('status_code')));
    });

    test('record identical failures within a minute once', () async {
      await init();
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          if (request.url.path == '/ok') return http.Response('', 200);
          throw _offline;
        }),
      );
      for (var i = 0; i < 3; i++) {
        await _attempt(client, Uri.parse('https://api.example.com/a'));
      }
      await _attempt(client, Uri.parse('https://api.example.com/b'));
      await client.get(Uri.parse('https://api.example.com/ok'));
      await client.get(Uri.parse('https://api.example.com/ok'));
      expect(await crumbUrls(), [
        'https://api.example.com/a',
        'https://api.example.com/b',
        'https://api.example.com/ok',
        'https://api.example.com/ok',
      ]);
    });

    test('are not recorded with breadcrumbs: false', () async {
      await init(
        httpOptions: const HttpOptions(sampleRate: 1, breadcrumbs: false),
      );
      await CarpGlitchTip.httpClient(_answering(200)).get(_items);
      await until(() => transport.transactions.isNotEmpty);
      expect(await requestCrumbs(), isEmpty);
    });
  });

  group('trace propagation', () {
    test('adds no trace headers by default', () async {
      await init();
      final inner = _FakeClient();
      await CarpGlitchTip.httpClient(inner).get(_items);
      await until(() => transport.transactions.isNotEmpty);
      final headers = inner.requests.single.headers;
      expect(headers, isNot(contains('sentry-trace')));
      expect(headers, isNot(contains('baggage')));
    });

    test('adds trace headers to tracePropagationTargets only', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          tracePropagationTargets: ['api.example.com'],
        ),
      );
      final inner = _FakeClient();
      final client = CarpGlitchTip.httpClient(inner);
      await client.get(Uri.parse('https://api.example.com/items'));
      await client.get(Uri.parse('https://other.example.com/items'));
      await until(() => transport.transactions.length == 2);

      final [api, other] = [
        for (final request in inner.requests) request.headers,
      ];
      expect(other, isNot(contains('sentry-trace')));
      expect(other, isNot(contains('baggage')));
      final header = api['sentry-trace'] ?? '';
      final ids = RegExp(
        r'^([0-9a-f]{32})-([0-9a-f]{16})-1$',
      ).firstMatch(header);
      expect(ids, isNotNull, reason: 'sentry-trace: $header');
      expect(api['baggage'], contains('sentry-trace_id=${ids![1]}'));
      // the headers belong to the request's own transaction
      final trace = named('GET api.example.com/items').contexts.trace!;
      expect('${trace.traceId}', ids[1]);
      expect('${trace.spanId}', ids[2]);
    });

    test('accepts regular expressions as targets', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          tracePropagationTargets: [r'^https://api\.example\.com/v2/'],
        ),
      );
      final inner = _FakeClient();
      final client = CarpGlitchTip.httpClient(inner);
      await client.get(Uri.parse('https://api.example.com/v2/items'));
      await client.get(Uri.parse('https://api.example.com/v1/items'));
      expect(
        [
          for (final request in inner.requests)
            request.headers.containsKey('sentry-trace'),
        ],
        [true, false],
      );
    });

    test('drops the started transaction of an offline failure', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          tracePropagationTargets: ['api.example.com'],
        ),
      );
      final headers = <String, Map<String, String>>{};
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          headers[request.url.path] = request.headers;
          if (request.url.path == '/offline') throw _offline;
          return http.Response('', 200);
        }),
      );
      await _attempt(client, Uri.parse('https://api.example.com/offline'));
      await client.get(Uri.parse('https://api.example.com/online'));
      await until(() => transport.transactions.isNotEmpty);
      await settle();
      expect(headers['/offline'], contains('sentry-trace'));
      expect(names(), ['GET api.example.com/online']);
    });
  });

  group('not recorded', () {
    test('requests to the GlitchTip ingest URL', () async {
      await init();
      final sent = <Uri>[];
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          sent.add(request.url);
          return http.Response('', 503);
        }),
      );
      await client.post(
        Uri.parse('https://glitchtip.example.com/api/1/envelope/'),
      );
      await client.post(
        Uri.parse('https://GLITCHTIP.example.com:443/api/1/store/?key=key'),
      );
      // another project on the same server
      await client.get(
        Uri.parse('https://glitchtip.example.com/api/10/envelope/'),
      );
      expect(sent, hasLength(3));
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(names(), ['GET glitchtip.example.com/api/{id}/envelope']);
      expect(reported(), [
        'HTTP 503: GET glitchtip.example.com/api/{id}/envelope',
      ]);
      expect(await crumbUrls(), [
        'https://glitchtip.example.com/api/{id}/envelope',
      ]);
    });

    test('requests to the ingest URL of a DSN with a path prefix', () async {
      await init(dsn: 'https://key@example.com/glitchtip/1');
      final client = CarpGlitchTip.httpClient(_answering(200));
      await client.post(
        Uri.parse('https://example.com/glitchtip/api/1/envelope/'),
      );
      // outside the prefix
      await client.get(Uri.parse('https://example.com/api/1/envelope/'));
      await until(() => transport.transactions.isNotEmpty);
      await settle();
      expect(names(), ['GET example.com/api/{id}/envelope']);
      expect(await crumbUrls(), ['https://example.com/api/{id}/envelope']);
    });

    test('requests matching excludeUrls', () async {
      await init(
        httpOptions: HttpOptions(
          sampleRate: 1,
          excludeUrls: ['https://cdn.example.com/', RegExp(r'/health$')],
        ),
      );
      final client = CarpGlitchTip.httpClient(_answering(503));
      await client.get(Uri.parse('https://cdn.example.com/images/logo.png'));
      await client.get(Uri.parse('https://api.example.com/health?full=1'));
      await client.get(Uri.parse('https://api.example.com/healthy'));
      await until(() => transport.events.isNotEmpty);
      await settle();
      expect(names(), ['GET api.example.com/healthy']);
      expect(reported(), ['HTTP 503: GET api.example.com/healthy']);
      expect(await crumbUrls(), ['https://api.example.com/healthy']);
    });
  });

  group('fail open', () {
    test('the response of the inner client reaches the caller as is', () async {
      await init();
      final response = http.StreamedResponse(
        Stream.value(utf8.encode('payload')),
        503,
        contentLength: 7,
      );
      final client = CarpGlitchTip.httpClient(_FakeClient(response: response));
      final received = await client.send(http.Request('GET', _items));
      expect(received, same(response));
      expect(await received.stream.bytesToString(), 'payload');
      // and it was recorded all the same
      await until(() => transport.events.isNotEmpty);
      expect(transport.events, hasLength(1));
    });

    test('the exception of the inner client is rethrown as is', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          tracePropagationTargets: ['api.example.com'],
        ),
      );
      final errors = <Object>[
        _BackendBug(),
        http.ClientException("Failed host lookup: 'api.example.com'", _items),
        TimeoutException('no response'),
      ];
      for (final error in errors) {
        final client = CarpGlitchTip.httpClient(_FakeClient(error: error));
        await expectLater(client.get(_items), throwsA(same(error)));
      }
    });

    test('a request does not wait for its report to be sent', () async {
      final gate = Completer<void>();
      await init(
        beforeSend: (event, hint) async {
          await gate.future;
          return event;
        },
        configure: (options) {
          options.beforeSendTransaction = (transaction, hint) async {
            await gate.future;
            return transaction;
          };
        },
      );
      const timeLimit = Duration(seconds: 2);
      final response = await CarpGlitchTip.httpClient(
        _answering(503, 'down'),
      ).get(_items).timeout(timeLimit);
      expect(response.body, 'down');
      await expectLater(
        CarpGlitchTip.httpClient(
          _failing(_BackendBug()),
        ).get(_items).timeout(timeLimit),
        throwsA(isA<_BackendBug>()),
      );
      expect(transport.envelopes, isEmpty);

      gate.complete();
      await until(() => transport.envelopes.length == 4);
      expect(transport.events, hasLength(2));
      expect(transport.transactions, hasLength(2));
    });

    test('a streamed request body reaches the inner client unread', () async {
      await init();
      final client = CarpGlitchTip.httpClient(
        MockClient.streaming((request, body) async {
          return http.StreamedResponse(Stream.value(await body.toBytes()), 200);
        }),
      );
      const rpc =
          '{"__type":"dk.cachet.carp.Request.GetStudyDeploymentStatus"}';
      final request = http.StreamedRequest(
        'POST',
        Uri.parse('https://cans.cachet.dk/api/deployment-service'),
      )..sink.add(utf8.encode(rpc));
      unawaited(request.sink.close());
      final response = await client.send(request);
      expect(await response.stream.bytesToString(), rpc);
    });

    test('a throwing describeError changes nothing', () async {
      await init(describeError: (error) => throw StateError('bug'));
      final error = _BackendBug();
      await expectLater(
        CarpGlitchTip.httpClient(_failing(error)).get(_items),
        throwsA(same(error)),
      );
      final response = await CarpGlitchTip.httpClient(
        _answering(503, 'down'),
      ).get(_items);
      expect(response.body, 'down');
      await until(() => transport.events.length == 2);
      expect(
        reported(),
        unorderedEquals([
          'backend bug',
          'HTTP 503: GET api.example.com/items/{id}',
        ]),
      );
    });

    test('a throwing ignore rule changes nothing', () async {
      await init(
        ignoreErrors: [IgnoreRule.custom((c) => throw StateError('bug'))],
      );
      final error = _BackendBug();
      await expectLater(
        CarpGlitchTip.httpClient(_failing(error)).get(_items),
        throwsA(same(error)),
      );
      final response = await CarpGlitchTip.httpClient(
        _answering(503, 'down'),
      ).get(_items);
      expect(response.body, 'down');
      await until(() => transport.events.length == 2);
      expect(
        reported(),
        unorderedEquals([
          'backend bug',
          'HTTP 503: GET api.example.com/items/{id}',
        ]),
      );
    });

    test('a throwing isFailedStatus changes nothing', () async {
      await init(
        httpOptions: HttpOptions(
          sampleRate: 1,
          isFailedStatus: (status) => throw StateError('bug'),
        ),
      );
      final response = await CarpGlitchTip.httpClient(
        _answering(503, 'down'),
      ).get(_items);
      expect(response.statusCode, 503);
      expect(response.body, 'down');
    });
  });

  group('without reporting', () {
    test('a client passes requests through before init', () async {
      final response = http.StreamedResponse(const Stream.empty(), 503);
      final inner = _FakeClient(response: response);
      final request = http.Request('GET', _items);
      final received = await CarpGlitchTip.httpClient(inner).send(request);
      expect(received, same(response));
      expect(inner.requests.single, same(request));
      expect(request.headers, isEmpty);
    });

    test('a client passes requests through when disabled', () async {
      await CarpGlitchTip.init(
        const CarpGlitchTipOptions(
          enabled: false,
          dsn: _dsn,
          http: HttpOptions(
            sampleRate: 1,
            tracePropagationTargets: ['api.example.com'],
          ),
        ),
      );
      expect(CarpGlitchTip.isEnabled, isFalse);
      final inner = _FakeClient();
      final response = await CarpGlitchTip.httpClient(inner).get(_items);
      expect(response.statusCode, 200);
      expect(inner.requests.single.headers, isNot(contains('sentry-trace')));
    });

    test('a client passes requests through after close', () async {
      await init(
        httpOptions: const HttpOptions(
          sampleRate: 1,
          tracePropagationTargets: ['api.example.com'],
        ),
      );
      final requests = <http.BaseRequest>[];
      final client = CarpGlitchTip.httpClient(
        MockClient((request) async {
          requests.add(request);
          return http.Response('down', 503);
        }),
      );
      await client.get(_items);
      await until(
        () => transport.transactions.isNotEmpty && transport.events.isNotEmpty,
      );
      await CarpGlitchTip.close();

      final response = await client.get(_items);
      expect(response.body, 'down');
      expect(requests.first.headers, contains('sentry-trace'));
      expect(requests.last.headers, isNot(contains('sentry-trace')));
      await settle();
      expect(transport.transactions, hasLength(1));
      expect(transport.events, hasLength(1));
    });

    test('close() closes the inner client once', () {
      final inner = _FakeClient();
      CarpGlitchTip.httpClient(inner)
        ..close()
        ..close();
      expect(inner.closed, 1);
    });

    test('httpClient() never wraps a client twice', () async {
      await init();
      final client = CarpGlitchTip.httpClient(_answering(200));
      expect(CarpGlitchTip.httpClient(client), same(client));
      await CarpGlitchTip.httpClient(client).get(_items);
      expect(await requestCrumbs(), hasLength(1));
      await until(() => transport.transactions.isNotEmpty);
      await settle();
      expect(transport.transactions, hasLength(1));
    });
  });

  group('runZoned', () {
    test('every http.Client() in the zone records its requests', () async {
      await CarpGlitchTip.runZoned(() async {
        await init();
        final client = http.Client();
        expect(client, isA<GlitchTipHttpClient>());
        final response = await client.get(_items);
        expect(response.statusCode, 204);
      }, innerClient: () => _answering(204, ''));
      await until(() => transport.transactions.isNotEmpty);
      expect(statuses(), {'GET api.example.com/items/{id}': 'ok'});
      expect(await crumbUrls(), ['https://api.example.com/items/{id}']);
    });

    test('each http.Client() is a new client', () async {
      final inners = <_FakeClient>[];
      await CarpGlitchTip.runZoned(
        () async {
          await init();
          inners.clear(); // only the clients created below
          final first = http.Client();
          final second = http.Client();
          expect(first, isNot(same(second)));
          first.close();
          await second.get(_items);
        },
        innerClient: () {
          final inner = _FakeClient();
          inners.add(inner);
          return inner;
        },
      );
      expect(inners, hasLength(2));
      expect([for (final inner in inners) inner.closed], [1, 0]);
      expect(inners.last.requests, hasLength(1));
    });

    test('wraps the client of the enclosing zone', () async {
      final sent = <String>[];
      await http.runWithClient(
        () async {
          final outside = http.Client();
          await CarpGlitchTip.runZoned(() async {
            await init();
            final inside = http.Client();
            await inside.get(Uri.parse('https://api.example.com/inside'));
            // created outside the zone: not recorded
            await outside.get(Uri.parse('https://api.example.com/outside'));
          });
        },
        () => MockClient((request) async {
          sent.add(request.url.path);
          return http.Response('', 200);
        }),
      );
      expect(sent, ['/inside', '/outside']);
      await until(() => transport.transactions.isNotEmpty);
      expect(await crumbUrls(), ['https://api.example.com/inside']);
      await settle();
      expect(names(), ['GET api.example.com/inside']);
    });

    test('a nested runZoned does not wrap clients twice', () async {
      await CarpGlitchTip.runZoned(() async {
        await init();
        await CarpGlitchTip.runZoned(
          () async {
            final response = await http.Client().get(_items);
            expect(response.statusCode, 200);
          },
          // ignored: the outer zone instruments the clients already
          innerClient: () => _answering(500),
        );
      }, innerClient: () => _answering(200));
      expect(await requestCrumbs(), hasLength(1));
      await until(() => transport.transactions.isNotEmpty);
      await settle();
      expect(statuses(), {'GET api.example.com/items/{id}': 'ok'});
    });

    test('httpClient() returns a client of the zone unchanged', () async {
      await CarpGlitchTip.runZoned(() async {
        await init();
        final client = http.Client();
        expect(CarpGlitchTip.httpClient(client), same(client));
        await CarpGlitchTip.httpClient().get(_items);
      }, innerClient: () => _answering(200));
      expect(await requestCrumbs(), hasLength(1));
      await until(() => transport.transactions.isNotEmpty);
      await settle();
      expect(transport.transactions, hasLength(1));
    });

    test('status.httpInstrumented is true after init in the zone', () async {
      await CarpGlitchTip.runZoned(init, innerClient: () => _answering(200));
      expect(CarpGlitchTip.status.enabled, isTrue);
      expect(CarpGlitchTip.status.httpInstrumented, isTrue);
    });

    test('status.httpInstrumented is false after init outside', () async {
      await init();
      expect(CarpGlitchTip.status.enabled, isTrue);
      expect(CarpGlitchTip.status.httpInstrumented, isFalse);
    });

    test('instrumentHttp: false leaves http.Client() alone', () async {
      final sent = <String>[];
      await http.runWithClient(
        () => CarpGlitchTip.runZoned(() async {
          await init();
          final client = http.Client();
          expect(client, isNot(isA<GlitchTipHttpClient>()));
          await client.get(_items);
        }, instrumentHttp: false),
        () => MockClient((request) async {
          sent.add(request.url.path);
          return http.Response('', 200);
        }),
      );
      expect(sent, ['/items/42']);
      expect(await requestCrumbs(), isEmpty);
      await settle();
      expect(transport.transactions, isEmpty);
    });

    test(
      'status.httpInstrumented is false with instrumentHttp: false',
      () async {
        await CarpGlitchTip.runZoned(init, instrumentHttp: false);
        expect(CarpGlitchTip.status.enabled, isTrue);
        expect(CarpGlitchTip.status.httpInstrumented, isFalse);
      },
    );
  });
}
