# wireguard_flutter_plus

[![Pub](https://img.shields.io/pub/v/wireguard_flutter_plus.svg)](https://pub.dev/packages/wireguard_flutter_plus)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

<br/>

<a href="https://vpnserverhub.com" target="_blank">
    <img src="https://vpnserverhub.com/manual_storage/gallery/1773653784_Screenshot 2026-03-16 at 3.04.49 PM.png" alt="VPN Server Hub" />
</a>

<a href="https://vpnserverhub.com" target="_blank">
    <img src="https://vpnserverhub.com/manual_storage/gallery/1773655278_Screenshot%202026-03-16%20at%203.30.27%E2%80%AFPM.png" alt="VPN Server Hub" />
</a>

<br/>

A powerful Flutter plugin to setup and control VPN connections via the [WireGuard®](https://www.wireguard.com/) protocol.

**wireguard_flutter_plus** extends standard WireGuard capabilities with added support for traffic statistics, Android 16KB page sizes, and robust routing features across all major platforms.

Developed by [Orban Tech](https://orbaninfotech.com/).

## Key Features

- 🚀 **Cross-Platform:** Supports Android, iOS, macOS, Windows, and Linux out of the box.
- 📊 **Traffic Statistics:** Real-time download/upload speed and total data usage.
- 📱 **Modern Android Support:** Fully supports **Android 16KB page size** (API 35+ ready).
- 🔔 **Notification Support:** Native traffic status notifications.
- 🛣️ **Advanced Routing:** Full control over allowed IPs and DNS settings.

## Installation

Add `wireguard_flutter_plus` to your `pubspec.yaml`:

```bash
flutter pub add wireguard_flutter_plus

```

## Platform Configuration

### iOS & macOS
> [!IMPORTANT]
> **Detailed iOS Setup Guide**: Please read [ios_setup_readme.md](ios_setup_readme.md) for step-by-step instructions on setting up Network Extensions and App Groups.

To use WireGuard on Apple platforms, you must create a **Network Extension** target in Xcode.

1. Open your project in Xcode.
2. File > New > Target > **Network Extension**.
3. Name it (e.g., `WGExtension`) and ensure "Packet Tunnel Provider" is selected.
4. Set the **Bundle Identifier** (e.g., `com.example.app.WGExtension`). *You will use this ID in your Dart code.*
5. Ensure both your Main App and the Extension have the same **App Group** capability enabled.

### Windows

The application must be run as **Administrator** to create and manipulate the network tunnel.

* **Debug:** Run your IDE or terminal as Administrator.
* **Release:** The system will prompt the user for permission automatically.

### Linux

Requires `wireguard` and `wireguard-tools` installed on the system.

```bash
# Ubuntu/Debian
sudo apt install wireguard wireguard-tools openresolv

```

> **Note:** If `openresolv` is not installed, DNS configurations may fail.

---

## Usage

### 1. Initialize

Initialize the instance. You can provide a custom name for the VPN interface.

```dart
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

final wireguard = WireGuardFlutter.instance;

void initVpn() async {
  await wireguard.initialize(
    interfaceName: 'wg0',
    vpnName: "Orban VPN", // Visible Name in Settings/Notifications
  );
}

```

### 2. Prepare Configuration

Prepare your WireGuard `.conf` string.

```dart
const String conf = '''
[Interface]
PrivateKey = <YOUR_PRIVATE_KEY>
Address = 10.104.0.224/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = <PEER_PUBLIC_KEY>
Endpoint = 147.135.15.16:443
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

```

### 3. Connect

Start the VPN tunnel. You can also specify apps to bypass or exclusively use the VPN via the Split Tunneling feature (currently supported on Android and Linux).

```dart
void connect() async {
  await wireguard.startVpn(
    serverAddress: '147.135.15.16:443', // Required for reachability checks
    wgQuickConfig: conf, 
    providerBundleIdentifier: 'com.example.WGExtension', // iOS/macOS Extension Bundle ID
    
    // Optional: Split Tunneling
    // excludedApps: ['com.android.chrome'], // Apps that bypass the VPN
    // includedApps: ['com.whatsapp'], // ONLY these apps use the VPN
  );
}
```

> **Note on Split Tunneling:**
> - `excludedApps`: Bypasses the VPN for the listed package names. All other apps on the device will route through the VPN.
> - `includedApps`: Isolates the VPN to ONLY the listed package names. All other apps on the device will bypass the VPN.

### 4. Disconnect

```dart
void disconnect() async {
  await wireguard.stopVpn();
}

```

### 5. Listen to Status & Traffic

Monitor connection state and real-time traffic usage.

**Connection Status:**

```dart
wireguard.vpnStageSnapshot.listen((event) {
  print("VPN Status Changed: $event");
});

```

**Traffic Statistics:**

```dart
wireguard.trafficSnapshot.listen((data) {
  print("Download Speed: ${data["downloadSpeed"]}");
  print("Upload Speed: ${data["uploadSpeed"]}");
  print("Total Download: ${data["totalDownload"]}");
  print("Total Upload: ${data["totalUpload"]}");
});

```

---

## VPN Stages

| Stage | Description |
| --- | --- |
| `connecting` | The interface is attempting to connect. |
| `connected` | The tunnel is successfully established. |
| `disconnecting` | The interface is in the process of closing. |
| `disconnected` | The interface is completely stopped. |
| `waitingConnection` | Waiting for user interaction (e.g., permission dialog). |
| `authenticating` | Authenticating with the server. |
| `reconnect` | Attempting to reconnect automatically. |
| `denied` | Permission refused by the user or system. |

## Supported Platforms

| Platform | Version | Notes |
| --- | --- | --- |
| **Android** | SDK 21+ | Supports 16KB Page Size (API 35+) |
| **iOS** | 15.0+ | Requires Network Extension |
| **macOS** | 12.0+ | Requires Network Extension & App Sandbox |
| **Windows** | 7+ | Requires Admin Privileges |
| **Linux** | Any | Requires `wireguard-tools` |

## FAQ & Troubleshooting

**Linux: `resolvconf: command not found**`
This error occurs when WireGuard tries to apply DNS settings but cannot find the tool to manage them.

* **Fix:** Install `openresolv` via your package manager, or remove the `DNS` line from your configuration.

**Linux: Password Prompt**
When `initialize` is called, the app may ask for the user password (`[sudo] password for <user>:`). This is required because WireGuard needs root privileges to create network interfaces.

* **Caution:** Do not run the Flutter app itself as root (e.g., do NOT use `sudo flutter run`). Run the app normally and let it request permissions via the prompt.

---

*"WireGuard" is a registered trademark of Jason A. Donenfeld.*

## Support

If you find this package useful, you can support the maintenance and development by donating:

- **USDT (BEP20):** `0x098f0ba20623c174f2be44dc647334bdb7cadba9`
- **USDT (TRC20):** `TNieNaB8WQ5UmQKt75e3ZeLAnSSnWLjhT3`
