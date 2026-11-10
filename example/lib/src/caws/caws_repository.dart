// Contains the app's client of CARP Web Services (CAWS).
//
// Parts:
// - `CawsSession`, the signed-in participant.
// - `CawsRepository`, the CAWS calls of the app, made with `package:http`
//   like carp_webservices makes them.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/participation_invitation.dart';
import '../models/study_protocol_summary.dart';
import 'caws_api.dart';
import 'caws_exception.dart';
import 'sample_caws_server.dart';

/// The participant signed in to CAWS.
class CawsSession {
  /// Creates a session.
  const CawsSession({
    required this.accessToken,
    required this.accountId,
    required this.userName,
  });

  /// Reads the token response of the OpenID Connect token endpoint; the
  /// account is read from the access token, a JWT.
  factory CawsSession.fromTokenResponse(String body) {
    final json = jsonDecode(body);
    final token = json is Map<String, Object?> ? json['access_token'] : null;
    if (token is! String) {
      throw const FormatException('The token response has no access_token');
    }
    final parts = token.split('.');
    final claims = parts.length < 2
        ? null
        : jsonDecode(utf8.decode(base64.decode(base64.normalize(parts[1]))));
    return CawsSession(
      accessToken: token,
      accountId: switch (claims) {
        {'sub': final String id} => id,
        _ => '',
      },
      userName: switch (claims) {
        {'preferred_username': final String name} => name,
        _ => 'participant',
      },
    );
  }

  /// The bearer token of CAWS requests. Never reported: the wrapper records
  /// no headers and scrubs tokens from texts.
  final String accessToken;

  /// The CAWS account id of the participant.
  final String accountId;

  /// The user name, shown in the app only. Never reported.
  final String userName;
}

/// The CAWS calls of the app.
///
/// Every call creates a new `http.Client()` and closes it afterwards, as
/// carp_webservices does. Inside `CarpGlitchTip.runZoned` each of them is
/// the wrapper's instrumented client, so every request becomes a breadcrumb
/// and a GlitchTip transaction, and server errors are reported.
class CawsRepository {
  /// Creates a repository for the CAWS at [baseUri]. [client] creates the
  /// HTTP client of each call; by default `http.Client()`, which inside
  /// `CarpGlitchTip.runZoned` is instrumented. Tests pass
  /// `() => CarpGlitchTip.httpClient(SampleCawsClient(server))`.
  CawsRepository({http.Client Function()? client, Uri? baseUri})
    : _newClient = client ?? http.Client.new,
      baseUri = baseUri ?? SampleCawsServer.baseUri;

  final http.Client Function() _newClient;

  /// The CAWS server, e.g. `https://caws.example.org`.
  final Uri baseUri;

  /// The signed-in participant, if any.
  CawsSession? session;

  /// Signs in the demo participant with the OpenID Connect token endpoint
  /// (a password grant; CARP apps use the authorization code flow).
  Future<CawsSession> signIn() async {
    final response = await _send(
      (client) => client.post(
        baseUri.replace(path: CawsApi.tokenPath),
        body: {
          'grant_type': 'password',
          'client_id': 'carp-glitchtip-example',
          'username': SampleCawsServer.demoUserName,
          'password': 'demo',
        },
      ),
    );
    return session = CawsSession.fromTokenResponse(response.body);
  }

  /// Forgets the signed-in participant.
  void signOut() => session = null;

  /// The participant's invitations to study deployments.
  Future<List<ActiveParticipationInvitation>>
  getActiveParticipationInvitations() async {
    final body = await _rpc(CawsApi.participationService, {
      '__type': CawsApi.getActiveParticipationInvitations,
      'apiVersion': CawsApi.participationApiVersion,
      'accountId': session?.accountId,
    });
    return ActiveParticipationInvitation.listFromJson(body);
  }

  /// The deployment of the device with [deviceRoleName] in the study
  /// deployment [studyDeploymentId]. The sample CAWS returns the protocol of
  /// the deployment, which holds everything the app shows.
  Future<StudyProtocolSummary> getDeviceDeployment(
    String studyDeploymentId,
    String deviceRoleName,
  ) async {
    final body = await _rpc(CawsApi.deploymentService, {
      '__type': CawsApi.getDeviceDeploymentFor,
      'apiVersion': CawsApi.deploymentApiVersion,
      'studyDeploymentId': studyDeploymentId,
      'primaryDeviceRoleName': deviceRoleName,
    });
    return StudyProtocolSummary.decode(body);
  }

  /// Uploads [count] step count measurements collected by the device with
  /// [deviceRoleName] in [studyDeploymentId].
  Future<void> appendToDataStreams(
    String studyDeploymentId,
    String deviceRoleName, {
    int count = 5,
  }) async {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _rpc(CawsApi.dataStreamService, {
      '__type': CawsApi.appendToDataStreams,
      'apiVersion': CawsApi.dataStreamApiVersion,
      'studyDeploymentId': studyDeploymentId,
      'batch': [
        {
          'dataStream': {
            'studyDeploymentId': studyDeploymentId,
            'deviceRoleName': deviceRoleName,
            'dataType': 'dk.cachet.carp.stepcount',
          },
          'firstSequenceId': 0,
          'measurements': [
            for (var i = 0; i < count; i++)
              {
                'sensorStartTime': now - (count - i) * 60000000,
                'data': {'__type': 'dk.cachet.carp.stepcount', 'steps': 12 + i},
              },
          ],
          'triggerIds': [0],
        },
      ],
    });
  }

  // an RPC call: a POST of a JSON request to a CAWS service
  Future<String> _rpc(String service, Map<String, Object?> request) async {
    final token = session?.accessToken;
    final response = await _send(
      (client) => client.post(
        baseUri.replace(path: service),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': ?(token == null ? null : 'Bearer $token'),
        },
        body: jsonEncode(request),
      ),
    );
    return response.body;
  }

  // sends one request with a new client; throws a CawsException for every
  // status that is not 2xx
  Future<http.Response> _send(
    Future<http.Response> Function(http.Client client) request,
  ) async {
    final client = _newClient();
    try {
      final response = await request(client);
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw CawsException.fromResponse(response.statusCode, response.body);
      }
      return response;
    } finally {
      client.close();
    }
  }
}
