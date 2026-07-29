import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

import 'ui/theme.dart';
import 'ui/widgets/connection_button.dart';
import 'ui/widgets/stats_grid.dart';
import 'ui/widgets/config_input.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    MaterialApp(
      title: 'WireGuard Flutter',
      theme: AppTheme.darkTheme,
      home: const MyApp(),
      debugShowCheckedModeBanner: false,
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final wireguard = WireGuardFlutter.instance;

  String downloadCount = "0.0 B/s";
  String uploadCount = "0.0 B/s";
  String totalDownload = "0 B";
  String totalUpload = "0 B";
  String duration = "00:00:00";

  String vpnState = VpnEngine.vpnDisconnected;
  StreamSubscription? _vpnStatusSubscription;
  StreamSubscription? _vpnTraffic;

  final _config = TextEditingController(
    text: '''
[Interface]
PrivateKey = GEin20qgtPLGhcDp6CJW3EKlIKDJo+EU1CAfQN3c5Wk=
Address = 10.0.0.2/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1420

# Peer
[Peer]
PublicKey = jwZL4jcWx+TYRe5eHLidkxKcYGVr19mfJ9QQWCztsGA=
AllowedIPs = 0.0.0.0/0
Endpoint = poland.vpnserverhub.com:48874


 ''',
  );

  @override
  void initState() {
    super.initState();
    initialize();

    Future.delayed(const Duration(milliseconds: 500), () {
      _vpnTraffic = wireguard.trafficSnapshot.listen((data) {
        if (mounted) {
          setState(() {
            downloadCount =
                formatSpeed(double.parse(data["downloadSpeed"].toString()));
            uploadCount =
                formatSpeed(double.parse(data["uploadSpeed"].toString()));
            totalDownload =
                formatBytes(double.parse(data["totalDownload"].toString()));
            totalUpload =
                formatBytes(double.parse(data["totalUpload"].toString()));
            duration = data["duration"].toString();
          });
        }
      });

      _vpnStatusSubscription = wireguard.vpnStageSnapshot.listen((event) async {
        if (mounted) {
          setState(() {
            vpnState = event.name;
          });
        }
      });

      wireguard.isConnected().then((isConnected) {
        if (mounted) {
          setState(() {
            vpnState = isConnected
                ? VpnEngine.vpnConnected
                : VpnEngine.vpnDisconnected;
          });
        }
      });
    });
  }

  Future<void> initialize() async {
    if (Platform.isMacOS) {
      try {
        await wireguard.requestMacSystemExtension(
            'com.orbanvpn.wireguard.WGSystemExtension');
        // The user may need to go to System Settings -> Privacy & Security -> Allow
      } catch (e) {
        print('Failed to install system extension: $e');
        return;
      }
    }
    try {
      await wireguard.initialize(
        interfaceName: "wgflutter",
        vpnName: "Orban VPN",
        extensionBundleId: "com.orbanvpn.wireguard.WGSystemExtension",
      );
    } catch (_) {}
  }

  void _onConnectionPressed() {
    if (vpnState == VpnEngine.vpnConnected) {
      disconnect();
    } else if (vpnState == VpnEngine.vpnDisconnected) {
      startVpn();
    }
  }

  void startVpn() async {
    try {
      await wireguard.startVpn(
          serverAddress: '144.217.253.149:443',
          wgQuickConfig: _config.text,
          providerBundleIdentifier: 'com.orbanvpn.wireguard.WGSystemExtension',
          includedApps: ['com.android.chrome']);
    } catch (_) {}
  }

  void disconnect() async {
    try {
      await wireguard.stopVpn();
      if (mounted) {
        setState(() {
          vpnState = VpnEngine.vpnDisconnected;
          downloadCount = "0.0 B/s";
          uploadCount = "0.0 B/s";
          totalDownload = "0 B";
          totalUpload = "0 B";
          duration = "00:00:00";
        });
      }
    } catch (_) {}
  }

  String formatSpeed(double speedInBytes) {
    if (speedInBytes < 1024) return "${speedInBytes.toStringAsFixed(0)} B/s";
    if (speedInBytes < 1024 * 1024)
      return "${(speedInBytes / 1024).toStringAsFixed(1)} KB/s";
    if (speedInBytes < 1024 * 1024 * 1024)
      return "${(speedInBytes / (1024 * 1024)).toStringAsFixed(1)} MB/s";
    return "${(speedInBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB/s";
  }

  String formatBytes(double bytes) {
    if (bytes < 1024) return "${bytes.toStringAsFixed(0)} B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WireGuard Flutter'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              ConnectionButton(
                onPressed: _onConnectionPressed,
                status: vpnState,
                duration: duration,
              ),
              const SizedBox(height: 40),
              TrafficStatsWidget(
                downloadSpeed: downloadCount,
                uploadSpeed: uploadCount,
                totalDownload: totalDownload,
                totalUpload: totalUpload,
              ),
              const SizedBox(height: 40),
              ConfigInputWidget(controller: _config),
            ],
          ),
        ),
      ),
    );
  }
}

class VpnEngine {
  static const String vpnConnecting = "connecting";
  static const String vpnConnected = "connected";
  static const String vpnDisconnecting = "disconnecting";
  static const String vpnDisconnected = "disconnected";
  static const String vpnWaitConnection = "waitingConnection";
  static const String vpnAuthenticating = "authenticating";
  static const String vpnReconnect = "reconnect";
  static const String vpnNoConnection = "noConnection";
  static const String vpnPrepare = "preparing";
  static const String vpnDenied = "denied";
  static const String vpnExiting = "exiting";
}
