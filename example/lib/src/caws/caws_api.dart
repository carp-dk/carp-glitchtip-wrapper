// Contains the parts of the CARP Web Services (CAWS) API the example uses.
//
// Parts:
// - `CawsApi`, the paths and RPC request types, as in carp_webservices and
//   carp_core.

/// The CAWS endpoints and RPC request types the example calls.
///
/// All CAWS RPC calls are POSTs to `/api/<name>-service` with a JSON body
/// whose `__type` names the operation. The wrapper names the GlitchTip
/// transaction of such a request after it, e.g.
/// `POST caws.example.org/api/deployment-service GetDeviceDeploymentFor`.
abstract final class CawsApi {
  /// The OpenID Connect token endpoint of CAWS' Keycloak realm.
  static const tokenPath = '/auth/realms/Carp/protocol/openid-connect/token';

  /// The participation service: invitations and participant data.
  static const participationService = '/api/participation-service';

  /// The deployment service: study deployments and device deployments.
  static const deploymentService = '/api/deployment-service';

  /// The data stream service: uploads of collected data.
  static const dataStreamService = '/api/data-stream-service';

  /// Gets the invitations of an account.
  static const getActiveParticipationInvitations =
      'dk.cachet.carp.deployments.infrastructure.ParticipationServiceRequest'
      '.GetActiveParticipationInvitations';

  /// Gets the deployment (protocol and configuration) of a primary device.
  static const getDeviceDeploymentFor =
      'dk.cachet.carp.deployments.infrastructure.DeploymentServiceRequest'
      '.GetDeviceDeploymentFor';

  /// Uploads a batch of collected data.
  static const appendToDataStreams =
      'dk.cachet.carp.data.infrastructure.DataStreamServiceRequest'
      '.AppendToDataStreams';

  /// The API version of the participation service requests.
  static const participationApiVersion = '1.0';

  /// The API version of the deployment service requests.
  static const deploymentApiVersion = '1.1';

  /// The API version of the data stream service requests.
  static const dataStreamApiVersion = '1.1';
}
