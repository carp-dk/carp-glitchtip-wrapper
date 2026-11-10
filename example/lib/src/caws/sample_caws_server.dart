// Contains an in-process stand-in for CARP Web Services (CAWS).
//
// Parts:
// - `SampleCawsData`, the bundled invitations and protocols it serves.
// - `SampleCawsServer`, which answers requests to https://caws.example.org
//   in the current network condition.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/json.dart';
import 'caws_api.dart';
import 'network_condition.dart';

/// The data the sample CAWS serves, in the CAWS JSON formats: the
/// participant's invitations and the protocol of each study deployment.
@immutable
class SampleCawsData {
  /// Creates the data from JSON texts.
  const SampleCawsData({required this.invitations, required this.protocols});

  /// The bundled invitations (a JSON list).
  static const invitationsAsset = 'assets/carp/invitations.json';

  /// The bundled protocol of each study deployment of the invitations.
  static const protocolAssets = {
    'bf19ced6-7ede-47a9-ad87-c83a6ac8c600':
        'assets/carp/protocols/cams_demo_protocol.json',
    '58ce18ff-40e3-4cd0-9fba-fc893d784891':
        'assets/carp/protocols/family_protocol.json',
  };

  /// Loads the bundled data from [bundle], e.g. `rootBundle`.
  static Future<SampleCawsData> load(AssetBundle bundle) async {
    final invitations = await bundle.loadString(invitationsAsset);
    final protocols = {
      for (final MapEntry(key: deployment, value: asset)
          in protocolAssets.entries)
        deployment: await bundle.loadString(asset),
    };
    return SampleCawsData(invitations: invitations, protocols: protocols);
  }

  /// The response body of `GetActiveParticipationInvitations`.
  final String invitations;

  /// The protocol JSON per study deployment id. CAWS returns a device
  /// deployment for `GetDeviceDeploymentFor`; the sample returns the
  /// protocol of the deployment instead, which holds what the app shows.
  final Map<String, String> protocols;
}

/// Answers requests to the sample CAWS host in-process, so the example
/// works without a server while its requests still go through `package:http`
/// and the wrapper, like the requests of carp_webservices.
///
/// One server holds the shared state (data, issued tokens, the network
/// condition); `SampleCawsClient`s created for every `http.Client()` send
/// their requests to it.
class SampleCawsServer {
  /// Creates a server for [data], which is loaded on the first request.
  SampleCawsServer({
    required Future<SampleCawsData> Function() data,
    this.latency = const Duration(milliseconds: 400),
    this.slowLatency = const Duration(milliseconds: 2500),
    NetworkCondition condition = NetworkCondition.online,
  }) : _load = data,
       network = ValueNotifier(condition);

  /// The host of the sample CAWS. It is never resolved.
  static const host = 'caws.example.org';

  /// The base URL of the sample CAWS.
  static final baseUri = Uri.https(host);

  /// The account id of the demo participant.
  static const demoAccountId = 'a3c0c9b6-5d8e-4b0f-9b55-8d1a1f2e6c47';

  /// The user name of the demo participant. Shown in the app, never
  /// reported.
  static const demoUserName = 'demo.participant';

  final Future<SampleCawsData> Function() _load;
  Future<SampleCawsData>? _data;
  final Set<String> _tokens = {};

  /// How long a request takes when the network is online.
  final Duration latency;

  /// How long a request takes when the network is slow.
  final Duration slowLatency;

  /// The network condition requests meet, switched in the app.
  final ValueNotifier<NetworkCondition> network;

  /// Whether this server answers requests to [url].
  bool handles(Uri url) => url.host == host;

  /// Answers [request] in the current [network] condition: like CAWS, or
  /// with the failure of the condition.
  Future<http.StreamedResponse> handle(http.BaseRequest request) async {
    final condition = network.value;
    final body = await request.finalize().bytesToString();
    switch (condition) {
      case NetworkCondition.offline:
        await Future<void>.delayed(latency ~/ 2);
        // what IOClient throws when the phone has no connection
        throw http.ClientException("Failed host lookup: '$host'", request.url);
      case NetworkCondition.serverError:
        await Future<void>.delayed(latency);
        return _error(
          request,
          500,
          'java.lang.IllegalStateException',
          'The service is temporarily unavailable.',
        );
      case NetworkCondition.slow:
        await Future<void>.delayed(slowLatency);
      case NetworkCondition.online:
        await Future<void>.delayed(latency);
    }
    final data = await (_data ??= _load());
    return _route(request, body, data);
  }

  http.StreamedResponse _route(
    http.BaseRequest request,
    String body,
    SampleCawsData data,
  ) {
    final path = request.url.path;
    if (request.method != 'POST') return _notFound(request);
    if (path == CawsApi.tokenPath) return _token(request, body);
    if (!path.startsWith('/api/')) return _notFound(request);

    final authorization = request.headers['authorization'] ?? '';
    final token = authorization.startsWith('Bearer ')
        ? authorization.substring('Bearer '.length)
        : null;
    if (token == null || !_tokens.contains(token)) {
      return _error(
        request,
        401,
        'dk.cachet.carp.webservices.common.exception.responses'
            '.UnauthorizedException',
        'Full authentication is required to access this resource.',
      );
    }

    final Map<String, Object?> rpc;
    try {
      final json = jsonDecode(body);
      rpc = json is Map<String, Object?> ? json : const {};
    } on FormatException {
      return _badRequest(request, 'The request body is not JSON.');
    }
    final type = rpc.string('__type');
    return switch ((path, type)) {
      (CawsApi.participationService, CawsApi.getActiveParticipationInvitations)
          when rpc.string('accountId') != null =>
        _json(request, 200, data.invitations),
      (CawsApi.deploymentService, CawsApi.getDeviceDeploymentFor) =>
        _deployment(request, rpc, data),
      (CawsApi.dataStreamService, CawsApi.appendToDataStreams) =>
        data.protocols.containsKey(rpc.string('studyDeploymentId'))
            ? _json(request, 200, '')
            : _deploymentNotFound(request),
      _ => _badRequest(request, 'Unsupported request: $type'),
    };
  }

  // a simulated OpenID Connect password grant: any demo user may sign in
  http.StreamedResponse _token(http.BaseRequest request, String body) {
    final form = Uri.splitQueryString(body);
    if (form['grant_type'] == null || form['client_id'] == null) {
      return _json(
        request,
        400,
        jsonEncode({
          'error': 'invalid_request',
          'error_description': 'Missing form parameter: grant_type',
        }),
      );
    }
    final token = _issueToken();
    return _json(
      request,
      200,
      jsonEncode({
        'access_token': token,
        'token_type': 'bearer',
        'expires_in': 300,
      }),
    );
  }

  // an unsigned JWT, so the app can read the account like from a real one
  String _issueToken() {
    String part(Map<String, Object?> json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    final token = [
      part({'alg': 'none', 'typ': 'JWT'}),
      part({
        'sub': demoAccountId,
        'preferred_username': demoUserName,
        'jti': '${_tokens.length + 1}',
      }),
      '',
    ].join('.');
    _tokens.add(token);
    return token;
  }

  http.StreamedResponse _deployment(
    http.BaseRequest request,
    Map<String, Object?> rpc,
    SampleCawsData data,
  ) {
    final protocol = data.protocols[rpc.string('studyDeploymentId')];
    if (protocol == null) return _deploymentNotFound(request);
    final json = jsonDecode(protocol) as Map<String, Object?>;
    final roles = {
      for (final device in json.objects('primaryDevices'))
        device.string('roleName'),
    };
    final role = rpc.string('primaryDeviceRoleName');
    if (!roles.contains(role)) {
      return _badRequest(
        request,
        'The device with role name "$role" is not part of this study '
        'deployment.',
      );
    }
    return _json(request, 200, protocol);
  }

  http.StreamedResponse _deploymentNotFound(http.BaseRequest request) => _error(
    request,
    404,
    'java.lang.IllegalArgumentException',
    'No study deployment with this id exists.',
  );

  http.StreamedResponse _badRequest(http.BaseRequest request, String message) =>
      _error(request, 400, 'java.lang.IllegalArgumentException', message);

  http.StreamedResponse _notFound(http.BaseRequest request) => _error(
    request,
    404,
    'org.springframework.web.servlet.NoHandlerFoundException',
    'No endpoint ${request.method} ${request.url.path}.',
  );

  // a CAWS error response
  http.StreamedResponse _error(
    http.BaseRequest request,
    int statusCode,
    String exception,
    String message,
  ) => _json(
    request,
    statusCode,
    jsonEncode({
      'statusCode': statusCode,
      'exception': exception,
      'message': message,
      'path': '${request.method} ${request.url.path}',
    }),
  );

  http.StreamedResponse _json(
    http.BaseRequest request,
    int statusCode,
    String body,
  ) {
    final bytes = utf8.encode(body);
    return http.StreamedResponse(
      Stream.value(bytes),
      statusCode,
      contentLength: bytes.length,
      request: request,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}
