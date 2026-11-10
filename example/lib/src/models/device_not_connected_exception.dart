// Contains an error the app expects and handles itself.
//
// Parts:
// - `DeviceNotConnectedException`, ignored by the app's GlitchTip rules.

/// Thrown when a device of the study, e.g. an eSense earbud, is not
/// connected (yet). It is part of normal use, not a bug, so the app ignores
/// it with `IgnoreType<DeviceNotConnectedException>()` and it never reaches
/// GlitchTip.
class DeviceNotConnectedException implements Exception {
  /// Creates the exception for the device with [deviceRoleName].
  const DeviceNotConnectedException(this.deviceRoleName);

  /// The role of the device in the study, e.g. `eSense`.
  final String deviceRoleName;

  @override
  String toString() =>
      'DeviceNotConnectedException: $deviceRoleName is not connected';
}
