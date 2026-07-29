# macOS System Extension Setup Guide

This guide explains how to integrate and distribute `wireguard_flutter_plus` on macOS using a System Extension (`.systemextension`) instead of a traditional App Extension (`.appex`). System Extensions are required if you intend to distribute your VPN application outside of the Mac App Store (e.g., via a `.pkg` installer for enterprise distribution).

> [!WARNING]
> This guide is specifically for **System Extensions**. If you are distributing through the Mac App Store, you should use the standard App Extension (`.appex`) approach instead.

---

## 1. Create the System Extension Target

1. Open your `macos/Runner.xcworkspace` in Xcode.
2. Go to **File -> New -> Target**.
3. Select **macOS** -> **Network Extension**.
4. Click **Next**.
5. Name your extension (e.g., `WGSystemExtension`).
6. **IMPORTANT:** Under "Extension Provider Type", select **System Extension** (do NOT select App Extension).
7. Select **Packet Tunnel Provider** as the provider type.
8. Click **Finish** and activate the new scheme if prompted.

---

## 2. Configure Capabilities & Entitlements

macOS System Extensions require specific capabilities to be enabled both in the **Apple Developer Portal** and in **Xcode**.

### Step A: Apple Developer Portal
Before Xcode can generate the correct provisioning profile, you must enable these capabilities on developer.apple.com:
1. Go to **Certificates, Identifiers & Profiles** -> **Identifiers**.
2. Find your **Main App** ID (e.g., `com.yourcompany.vpn`) and check **System Extension**. Save it.
3. Find your **Extension** App ID (e.g., `com.yourcompany.vpn.WGSystemExtension`). Check **System Extension** AND **Network Extension**. Save it.

### Step B: Xcode Signing & Capabilities
1. In Xcode, select your `Runner` target, go to **Signing & Capabilities**.
2. Click **+ Capability** and add **System Extension**.
3. Select your `WGSystemExtension` target, go to **Signing & Capabilities**.
4. Click **+ Capability** and add both **System Extension** and **Network Extension**.

### Step C: Verify `.entitlements` Files

**Main App (`Runner.entitlements`)**
Ensure Xcode added the following entitlement:
```xml
<key>com.apple.developer.system-extension.install</key>
<true/>
```

### System Extension Entitlements (`WGSystemExtension`)
Open your extension's `.entitlements` file and ensure it has the correct packet tunnel provider entitlement. 

**Important Note for Xcode Managed Profiles:** 
For local development using "Automatically manage signing" with a Mac Team Profile, Xcode often generates a profile that only authorizes `packet-tunnel-provider`. If you get a "Provisioning Profile doesn't match" error, use `packet-tunnel-provider`. For production distribution (Developer ID), you will need to manually generate a profile and use `packet-tunnel-provider-systemextension`.

```xml
<key>com.apple.developer.networking.networkextension</key>
<array>
    <string>packet-tunnel-provider</string>
</array>
```

> [!CAUTION]
> **App Group Capability is Critical**
> Both your main app (`Runner`) and your System Extension (`WGSystemExtension`) MUST share the exact same App Group capability (e.g., `group.com.yourcompany.vpn`). If these do not match exactly, the VPN tunnel will crash silently upon connection due to memory sharing failures between the processes.

---

## 3. Link the `wg-go` Binary via Podfile

You must link the WireGuard Go (`wg-go`) binary to your new System Extension target so it can perform the actual VPN packet routing.

Open your `macos/Podfile` and add the following snippet at the bottom:

```ruby
target 'WGSystemExtension' do
  use_frameworks!
  use_modular_headers!

  # Link the WireGuard Go core
  pod 'wireguard_flutter_plus', :path => 'Flutter/ephemeral/.symlinks/plugins/wireguard_flutter_plus/darwin'
end
```

Run `cd macos && pod install` to apply these changes.

---

## 4. Activating the Extension from Flutter

macOS requires the host app to explicitly request the installation of a System Extension, which will trigger a macOS "Privacy & Security" prompt asking the user to allow the extension.

Use the `requestMacSystemExtension` method provided by `wireguard_flutter_plus` before attempting to start the VPN:

```dart
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

Future<void> setupAndConnect() async {
  final wireguard = WireGuardFlutter.instance;
  
  // 1. Initialize the plugin with your System Extension's bundle ID
  await wireguard.initialize(
    interfaceName: 'wg0',
    extensionBundleId: 'com.yourcompany.vpn.WGSystemExtension',
    iosAppGroup: 'group.com.yourcompany.vpn',
  );

  // 2. Request System Extension installation (macOS only)
  if (Platform.isMacOS) {
    try {
      await wireguard.requestMacSystemExtension('com.yourcompany.vpn.WGSystemExtension');
      // The user may need to go to System Settings -> Privacy & Security -> Allow
    } catch (e) {
      print('Failed to install system extension: $e');
      return;
    }
  }

  // 3. Start the VPN as normal
  await wireguard.startVpn(
    serverAddress: '1.2.3.4:51820',
    wgQuickConfig: '[Interface]...',
    providerBundleIdentifier: 'com.yourcompany.vpn.WGSystemExtension',
  );
}
```

> [!NOTE]
> System extensions are persistent daemons. When the tunnel is stopped, `wireguard_flutter_plus` will no longer call `exit(0)` on macOS System Extensions, ensuring they remain in memory and ready for the next connection.
