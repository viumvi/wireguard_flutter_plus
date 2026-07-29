import 'package:flutter/services.dart';

import 'wireguard_flutter_platform_interface.dart';

class WireGuardFlutterMethodChannel extends WireGuardFlutterInterface {
  static const _methodChannelVpnControl =
      "orban.group.wireguard_flutter_plus/wgcontrol";
  static const _methodChannel = MethodChannel(_methodChannelVpnControl);
  static const _eventChannelVpnStage =
      'orban.group.wireguard_flutter_plus/wgstage';
  static const _eventChannel = EventChannel(_eventChannelVpnStage);
  static const _trafficEventChannel =
      EventChannel('orban.group.wireguard_flutter_plus/traffic');

  @override
  Stream<VpnStage> get vpnStageSnapshot =>
      _eventChannel.receiveBroadcastStream().map(
            (event) => VpnStage.values.firstWhere(
                (stage) => stage.code == event,
                orElse: () => VpnStage.noConnection,
              ),
          );

  // Update trafficSnapshot to handle download/upload data
  @override
  Stream<Map<String, dynamic>> get trafficSnapshot =>
      _trafficEventChannel.receiveBroadcastStream().map((event) {
        if (event is Map) {
          return Map<String, dynamic>.from(event);
        }
        return {
          "totalDownload": 0,
          "totalUpload": 0,
          "downloadSpeed": 0.0,
          "uploadSpeed": 0.0,
          "duration": "00:00:00"
        };
      });

  @override
  Future<void> initialize(
      {required String interfaceName, String? vpnName, String? iosAppGroup, String? extensionBundleId}) {
    return _methodChannel.invokeMethod("initialize", {
      "localizedDescription": interfaceName,
      "win32ServiceName": interfaceName,
      "vpnName": vpnName ??
          "WireGuard VPN", // Default to "WireGuard VPN" if not provided
      "groupId": iosAppGroup,
      "extensionBundleId": extensionBundleId
    });
  }

  @override
  Future<void> requestMacSystemExtension(String bundleId) async {
    return _methodChannel.invokeMethod("requestMacSystemExtension", {"bundleId": bundleId});
  }

  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
    List<String>? excludedApps,
    List<String>? includedApps,
  }) async {
    return _methodChannel.invokeMethod("start", {
      "serverAddress": serverAddress,
      "wgQuickConfig": wgQuickConfig,
      "providerBundleIdentifier": providerBundleIdentifier,
      if (excludedApps != null && excludedApps.isNotEmpty) "excludedApps": excludedApps.join(','),
      if (includedApps != null && includedApps.isNotEmpty) "includedApps": includedApps.join(','),
    });
  }

  @override
  Future<void> stopVpn() => _methodChannel.invokeMethod('stop');

  @override
  Future<void> refreshStage() => _methodChannel.invokeMethod("refresh");

  @override
  Future<VpnStage> stage() => _methodChannel.invokeMethod("stage").then(
        (value) => value != null
            ? VpnStage.values.firstWhere(
                (stage) => stage.code == value.toString(),
                orElse: () => VpnStage.disconnected,
              )
            : VpnStage.disconnected,
      );
  @override
  Future<bool> checkVpnPermission() async {
    try {
      final result = await _methodChannel.invokeMethod("checkVpnPermission");
      return result == true;
    } catch (e) {
      return false;
    }
  }
}
