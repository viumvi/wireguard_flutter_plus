import 'dart:async';
import 'dart:io';
import 'dart:developer';

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
PrivateKey = SC34vnBNgzjQmS9AUhW5roFPFVQG3OOhG81oyAYZNH8=
Address = 10.0.0.2/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

# SecureGate-1
[Peer]
PublicKey = BNNu+xHcTqH0FaL8kl9+XTt+ubpZXbNUNHpIPFcEEy4=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = canada.vpnserverhub.com:46953

 ''',
  );

  @override
  void initState() {
    super.initState();
    initialize();

    Future.delayed(const Duration(milliseconds: 500), () {
      _vpnTraffic = wireguard.trafficSnapshot.listen((data) {
        if (mounted) {
          log(data.toString());
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
        log(event.name);
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

  @override
  void dispose() {
    _vpnTraffic?.cancel();
    _vpnStatusSubscription?.cancel();
    _config.dispose();
    super.dispose();
  }

  Future<void> initialize() async {
    // if (Platform.isMacOS) {
    //   try {
    //     await wireguard
    //         .requestMacSystemExtension('com.orbanvpn.wireguard.WGExtension');
    //     // The user may need to go to System Settings -> Privacy & Security -> Allow
    //   } catch (e) {
    //     print('System extension request notice: $e');
    //     // If extension is already installed, or in development mode, continue initialization
    //   }
    // }
    try {
      await wireguard.initialize(
        interfaceName: "wgflutter",
        vpnName: "Orban VPN",
        iosAppGroup: "group.com.orbanvpn.wireguard",
        // extensionBundleId: "com.orbanvpn.wireguard.WGExtension",
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
        serverAddress: 'canada.vpnserverhub.com',
        wgQuickConfig: _config.text,
        providerBundleIdentifier: 'com.orbanvpn.wireguard.WGExtension',
      );
    } catch (e) {
      log('startVpn error: $e');
    }
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
                duration: duration,
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
