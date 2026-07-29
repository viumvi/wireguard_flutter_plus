/// The platform interface for WireGuard Flutter.
abstract class WireGuardFlutterInterface {
  /// Stream of VPN stage changes.
  Stream<VpnStage> get vpnStageSnapshot;

  /// Stream of traffic statistics.
  Stream<Map<String, dynamic>> get trafficSnapshot;

  /// Gets the latest traffic statistics.
  Future<Map<String, dynamic>> trafficStats() =>
      trafficSnapshot.firstWhere((_) => true);

  /// Initializes the VPN engine.
  Future<void> initialize(
      {required String interfaceName, String? vpnName, String? iosAppGroup, String? extensionBundleId});

  /// Requests macOS system extension installation.
  Future<void> requestMacSystemExtension(String bundleId) {
    throw UnimplementedError('requestMacSystemExtension() has not been implemented.');
  }

  /// Starts the VPN tunnel.
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
    List<String>? excludedApps,
    List<String>? includedApps,
  });

  /// Stops the VPN tunnel.
  Future<void> stopVpn();

  /// Refreshes the VPN stage/status.
  Future<void> refreshStage();

  /// Gets the current VPN stage.
  Future<VpnStage> stage();

  /// Checks for VPN permission.
  Future<bool> checkVpnPermission();

  /// Checks if the VPN is currently connected.
  Future<bool> isConnected() =>
      stage().then((stage) => stage == VpnStage.connected);
}

/// Represents the current stage of the VPN connection.
enum VpnStage {
  /// VPN is connected.
  connected('connected'),

  /// VPN is connecting.
  connecting('connecting'),

  /// VPN is disconnecting.
  disconnecting('disconnecting'),

  /// VPN is disconnected.
  disconnected('disconnected'),

  /// VPN is waiting for a connection.
  waitingConnection('wait_connection'),

  /// VPN is authenticating.
  authenticating('authenticating'),

  /// VPN is reconnecting.
  reconnect('reconnect'),

  /// No connection or limited connection.
  noConnection('no_connection'),

  /// VPN is preparing to connect.
  preparing('prepare'),

  /// VPN connection was denied.
  denied('denied'),

  /// VPN is exiting/terminating.
  exiting('exiting');

  final String code;

  const VpnStage(this.code);
}
