// Contains the state of the example app, like the BLoC of a CARP app.
//
// Parts:
// - `Onboarding`, how far the participant is: signed out, signed in or
//   enrolled in a study.
// - `AppState`, which signs in, loads invitations, accepts one and loads the
//   protocol of its deployment, and knows the study GlitchTip should see.

import 'dart:async';

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:flutter/foundation.dart';

import '../caws/caws_repository.dart';
import '../caws/network_condition.dart';
import '../models/participation_invitation.dart';
import '../models/study_protocol_summary.dart';
import '../reporting/glitchtip_study.dart';

/// How far the participant is, reported as the `onboarding` tag so errors
/// from before a study is known can be told apart.
enum Onboarding {
  /// Nobody is signed in.
  signedOut('signed_out'),

  /// Signed in, but no invitation is accepted: the study is not known yet.
  signedIn('signed_in'),

  /// An invitation is accepted: reports carry the study.
  enrolled('enrolled');

  const Onboarding(this.tag);

  /// The value of the `onboarding` tag.
  final String tag;
}

/// The state of the app: the participant, the invitations, the accepted
/// study and its protocol.
///
/// Every change goes through [notifyListeners], so the wrapper keeps the
/// study in sync once `main()` called
/// `CarpGlitchTip.bindStudy(state, () => state.study)`.
class AppState extends ChangeNotifier {
  /// Creates the state of an app that talks to CAWS through [caws], in the
  /// sample CAWS [network] condition.
  AppState({required this.caws, required this.network}) {
    network.addListener(notifyListeners);
    _tagOnboarding();
  }

  /// The tag that says how far the participant is, see [Onboarding].
  static const onboardingTag = 'onboarding';

  /// The app's CAWS client.
  final CawsRepository caws;

  /// The network condition of the sample CAWS, switched by the user.
  final ValueNotifier<NetworkCondition> network;

  bool _signingIn = false;
  Object? _signInError;
  List<ActiveParticipationInvitation>? _invitations;
  bool _loadingInvitations = false;
  Object? _invitationsError;
  ActiveParticipationInvitation? _invitation;
  StudyProtocolSummary? _protocol;
  bool _loadingProtocol = false;
  Object? _protocolError;
  StudyMetadata? _study;
  bool _disposed = false;

  /// How far the participant is.
  Onboarding get onboarding => _invitation != null
      ? Onboarding.enrolled
      : caws.session != null
      ? Onboarding.signedIn
      : Onboarding.signedOut;

  /// The signed-in participant's user name. Shown in the app only.
  String? get userName => caws.session?.userName;

  /// Whether signing in is in progress.
  bool get signingIn => _signingIn;

  /// Why the last sign-in failed, if it did.
  Object? get signInError => _signInError;

  /// The participant's invitations, once loaded.
  List<ActiveParticipationInvitation>? get invitations => _invitations;

  /// Whether the invitations are being loaded.
  bool get loadingInvitations => _loadingInvitations;

  /// Why loading the invitations failed, if it did.
  Object? get invitationsError => _invitationsError;

  /// The accepted invitation, if any.
  ActiveParticipationInvitation? get invitation => _invitation;

  /// The protocol of the accepted study, once loaded.
  StudyProtocolSummary? get protocol => _protocol;

  /// Whether the protocol of the accepted study is being loaded.
  bool get loadingProtocol => _loadingProtocol;

  /// Why loading the protocol failed, if it did.
  Object? get protocolError => _protocolError;

  /// The study GlitchTip attaches to every report: `null` until an
  /// invitation is accepted, enriched once its protocol is loaded.
  StudyMetadata? get study => _study;

  /// The network condition of the sample CAWS.
  NetworkCondition get networkCondition => network.value;

  set networkCondition(NetworkCondition condition) => network.value = condition;

  /// Signs in the demo participant and loads the invitations. Returns
  /// whether signing in worked.
  Future<bool> signIn() async {
    if (_signingIn) return false;
    _signingIn = true;
    _signInError = null;
    notifyListeners();
    try {
      await caws.signIn();
    } catch (error) {
      _signInError = error;
      return false;
    } finally {
      _signingIn = false;
      notifyListeners();
    }
    unawaited(loadInvitations());
    return true;
  }

  /// Signs out: forgets the participant, the invitations and the study.
  void signOut() {
    caws.signOut();
    _invitations = null;
    _invitationsError = null;
    _setStudy(null, null);
    notifyListeners();
  }

  /// Loads the participant's invitations from CAWS.
  Future<void> loadInvitations() async {
    if (_loadingInvitations) return;
    _loadingInvitations = true;
    _invitationsError = null;
    notifyListeners();
    try {
      _invitations = await caws.getActiveParticipationInvitations();
    } catch (error) {
      _invitationsError = error;
    } finally {
      _loadingInvitations = false;
      notifyListeners();
    }
  }

  /// Accepts [invitation]: the study is attached to reports at once, then
  /// the protocol of its deployment is loaded and added to the study.
  /// Returns whether the protocol was loaded.
  Future<bool> accept(ActiveParticipationInvitation invitation) async {
    if (_loadingProtocol) return false;
    _setStudy(invitation, null);
    _loadingProtocol = true;
    _protocolError = null;
    notifyListeners(); // the study ids and roles are known now

    try {
      final protocol = await caws.getDeviceDeployment(
        invitation.studyDeploymentId,
        invitation.deviceRoleName ?? '',
      );
      if (!identical(_invitation, invitation)) return false; // left meanwhile
      _setStudy(invitation, protocol);
      return true;
    } catch (error) {
      if (identical(_invitation, invitation)) _protocolError = error;
      return false;
    } finally {
      _loadingProtocol = false;
      notifyListeners(); // the protocol is known now, or failed
    }
  }

  /// Leaves the study: reports no longer carry it.
  void leaveStudy() {
    _setStudy(null, null);
    _protocolError = null;
    notifyListeners();
  }

  void _setStudy(
    ActiveParticipationInvitation? invitation,
    StudyProtocolSummary? protocol,
  ) {
    _invitation = invitation;
    _protocol = protocol;
    // one instance per change, so the wrapper sees an unchanged study as
    // equal when it re-reads it for every report
    _study = invitation?.toGlitchTip(protocol: protocol);
  }

  void _tagOnboarding() =>
      CarpGlitchTip.setTags({onboardingTag: onboarding.tag});

  @override
  void notifyListeners() {
    if (_disposed) return;
    _tagOnboarding();
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    network.removeListener(notifyListeners);
    super.dispose();
  }
}
