import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:process_run/shell.dart';

import '../wireguard_flutter_platform_interface.dart';

class WireGuardFlutterLinux extends WireGuardFlutterInterface {
  String? name;
  String? tunnelName;
  File? configFile;

  VpnStage _stage = VpnStage.noConnection;
  final _stageController = StreamController<VpnStage>.broadcast();
  void _setStage(VpnStage stage) {
    _stage = stage;
    _stageController.add(stage);
  }

  final shell = Shell(runInShell: true, verbose: kDebugMode);

  @override
  Future<void> initialize(
      {required String interfaceName,
      String? vpnName,
      String? iosAppGroup,
      String? extensionBundleId}) async {
    name = interfaceName.replaceAll(' ', '_');
    tunnelName = interfaceName; // ✅ Assign tunnelName
    await refreshStage();
  }

  @override
  Future<void> requestMacSystemExtension(String bundleId) {
    throw UnimplementedError('System extensions are only supported on macOS');
  }

  Future<String> get filePath async {
    final tempDir = await getTemporaryDirectory();
    return '${tempDir.path}${Platform.pathSeparator}$name.conf';
  }

  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
    List<String>? excludedApps,
    List<String>? includedApps,
  }) async {
    final isAlreadyConnected = await isConnected();
    if (!isAlreadyConnected) {
      _setStage(VpnStage.preparing);
    } else {
      debugPrint('Already connected');
    }

    try {
      configFile = await File(await filePath).create();
      await configFile!.writeAsString(wgQuickConfig);
    } on PathAccessException {
      debugPrint('Denied to write file. Trying to start interface');
      if (isAlreadyConnected) {
        return _setStage(VpnStage.connected);
      }

      try {
        await shell.run('sudo wg-quick up $name');
      } catch (_) {
      } finally {
        _setStage(VpnStage.denied);
      }
    }

    if (!isAlreadyConnected) {
      _setStage(VpnStage.connecting);
      await shell.run('sudo wg-quick up ${configFile?.path ?? await filePath}');
      _setStage(VpnStage.connected);
    }
  }

  @override
  Future<void> stopVpn() async {
    assert(
      (await isConnected()),
      'Bad state: vpn has not been started. Call startVpn',
    );
    _setStage(VpnStage.disconnecting);
    try {
      await shell
          .run('sudo wg-quick down ${configFile?.path ?? (await filePath)}');
    } catch (e) {
      await refreshStage();
      rethrow;
    }
    await refreshStage();
  }

  @override
  Future<VpnStage> stage() async => _stage;

  @override
  Stream<VpnStage> get vpnStageSnapshot => _stageController.stream;

  @override
  Future<void> refreshStage() async {
    if (await isConnected()) {
      _setStage(VpnStage.connected);
    } else if (name == null) {
      _setStage(VpnStage.waitingConnection);
    } else if (configFile == null) {
      _setStage(VpnStage.noConnection);
    } else {
      _setStage(VpnStage.disconnected);
    }
  }

  @override
  Future<bool> isConnected() async {
    assert(
      name != null,
      'Bad state: not initialized. Call "initialize" before calling this command',
    );
    final processResultList = await shell.run('sudo wg');
    final process = processResultList.first;
    return process.outLines.any((line) => line.trim() == 'interface: $name');
  }

  // ✅ Added missing trafficSnapshot implementation
  @override
  Stream<Map<String, dynamic>> get trafficSnapshot async* {
    if (tunnelName == null) {
      throw Exception(
          "Tunnel name is not initialized. Call initialize() first.");
    }
    while (true) {
      await Future.delayed(
          const Duration(seconds: 2)); // Adjust polling interval
      final trafficData = await _fetchTrafficData();
      if (trafficData != null) {
        yield trafficData;
      }
    }
  }

  Future<Map<String, dynamic>?> _fetchTrafficData() async {
    try {
      final result = await shell.run('sudo wg show all dump');
      if (result.isNotEmpty) {
        final lines = result.first.outLines;
        if (lines.isNotEmpty) {
          // Parse traffic data (Modify parsing as per your wg output format)
          final data = lines.map((line) => line.split('\t')).toList();
          return {
            'interface': data[0][0],
            'publicKey': data[0][1],
            'endpoint': data[0][2],
            'bytesReceived': int.tryParse(data[0][5]) ?? 0,
            'bytesSent': int.tryParse(data[0][6]) ?? 0,
          };
        }
      }
    } catch (e) {
      debugPrint('Error fetching traffic data: $e');
    }
    return null;
  }

  @override
  Future<bool> checkVpnPermission() {
    // TODO: implement prepareVpnPermission
    throw UnimplementedError();
  }
}
