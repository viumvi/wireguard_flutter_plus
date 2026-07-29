import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wireguard_flutter_plus/linux/wireguard_flutter_linux.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_method_channel.dart';

import 'wireguard_flutter_platform_interface.dart';

export 'wireguard_flutter_platform_interface.dart' show VpnStage;

/// The main class for interacting with the WireGuard VPN plugin.
///
/// This class provides methods to initialize, start, stop, and monitor
/// the WireGuard VPN tunnel.
class WireGuardFlutter extends WireGuardFlutterInterface {
  static WireGuardFlutterInterface? __instance;
  static WireGuardFlutterInterface get _instance => __instance!;

  /// Returns the singleton instance of [WireGuardFlutter].
  ///
  /// Initializes the platform-specific implementation if not already done.
  static WireGuardFlutterInterface get instance {
    registerWith();
    return _instance;
  }

  /// Registers the platform-specific implementation.
  static void registerWith() {
    if (__instance == null) {
      if (kIsWeb) {
        throw UnsupportedError('The web platform is not supported');
      } else if (Platform.isLinux) {
        __instance = WireGuardFlutterLinux();
      } else {
        __instance = WireGuardFlutterMethodChannel();
      }
    }
  }

  WireGuardFlutter._();

  @override
  Stream<VpnStage> get vpnStageSnapshot => _instance.vpnStageSnapshot;

  @override
  Stream<Map<String, dynamic>> get trafficSnapshot => _instance.trafficSnapshot;

  /// Initializes the WireGuard VPN tunnel.
  ///
  /// [interfaceName] is the name of the network interface.
  /// [vpnName] is the name of the VPN profile (optional).
  /// [iosAppGroup] is the App Group ID for iOS/macOS shared container (optional).
  /// [extensionBundleId] is the bundle ID of the System Extension (macOS only, optional).
  @override
  Future<void> initialize(
      {required String interfaceName, String? vpnName, String? iosAppGroup, String? extensionBundleId}) {
    return _instance.initialize(
        interfaceName: interfaceName,
        vpnName: vpnName,
        iosAppGroup: iosAppGroup,
        extensionBundleId: extensionBundleId);
  }

  /// Requests macOS system extension installation.
  ///
  /// [bundleId] is the bundle ID of the System Extension.
  Future<void> requestMacSystemExtension(String bundleId) async {
    if (Platform.isMacOS) {
      await _instance.requestMacSystemExtension(bundleId);
    } else {
      throw UnsupportedError('System extensions are only supported on macOS');
    }
  }

  /// Starts the VPN tunnel.
  ///
  /// [serverAddress] is the IP address and port of the WireGuard server.
  /// [wgQuickConfig] is the WireGuard configuration string (wg-quick format).
  /// [providerBundleIdentifier] is the bundle ID of the Network Extension (iOS/macOS).
  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
    List<String>? excludedApps,
    List<String>? includedApps,
  }) async {
    return _instance.startVpn(
      serverAddress: serverAddress,
      wgQuickConfig: wgQuickConfig,
      providerBundleIdentifier: providerBundleIdentifier,
      excludedApps: excludedApps,
      includedApps: includedApps,
    );
  }

  /// Stops the VPN tunnel.
  @override
  Future<void> stopVpn() => _instance.stopVpn();

  /// Refreshes the current VPN stage.
  @override
  Future<void> refreshStage() => _instance.refreshStage();

  /// Returns the current VPN stage.
  @override
  Future<VpnStage> stage() => _instance.stage();

  /// Checks if the VPN permission is granted.
  @override
  Future<bool> checkVpnPermission() => _instance.checkVpnPermission();

  /// Returns the current traffic statistics.
  @override
  Future<Map<String, dynamic>> trafficStats() => _instance.trafficStats();
}
