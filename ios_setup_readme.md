# iOS & macOS Setup Guide for WireGuard Flutter Plus

Setting up WireGuard on iOS and macOS requires a few additional steps compared to Android due to Apple's security sandbox and Network Extension requirements.

---

## Prerequisites

- macOS with the latest Xcode installed.
- An Apple Developer Account (required for Network Extensions, App Groups, and Provisioning Profiles).
- **Go** installed on your Mac (`brew install go` or from [golang.org](https://golang.org)) (required for compiling `wireguard-go-bridge`).

---

## Step 1: Open Project in Xcode

1. Open your Flutter project in VS Code or Terminal.
2. For iOS: Right-click the `ios` folder and select **Open in Xcode** (or `open ios/Runner.xcworkspace`).
3. For macOS: Right-click the `macos` folder and select **Open in Xcode** (or `open macos/Runner.xcworkspace`).

---

## Step 2: Configure Bundle Identifiers

You need two Bundle IDs: one for the main application and one for the tunnel extension.

- **Main App Bundle ID**: e.g., `com.example.vpnapp`
- **Extension Bundle ID**: Must be prefixed with the main app ID, e.g., `com.example.vpnapp.WGExtension`.

---

## Step 3: Add Network Extension Target

1. In Xcode, go to **File > New > Target...**.
2. Select **iOS** (or **macOS**) -> **Network Extension** and click **Next**.
3. **Product Name**: Enter `WGExtension`.
4. **Team**: Select your Apple Development Team.
5. **Language**: `Swift`.
6. **Provider Type**: `Packet Tunnel Provider`.
7. Click **Finish** and select **Activate** when prompted for the scheme.

---

## Step 4: Setup WireGuardGoBridge (External Build System)

This step compiles the WireGuard Go code into a static library (`libwg-go.a`) that your extension links against.

### For iOS:
1. **File > New > Target...**
2. Go to the **Other** tab and select **External Build System**.
3. Click **Next**.
4. **Product Name**: `WireGuardGoBridgeiOS`.
5. **Build Tool**: `$(PROJECT_DIR)/Scripts/build_go_bridge.sh`.
6. Click **Finish**.

### For macOS:
1. **File > New > Target...**
2. Go to the **Other** tab and select **External Build System**.
3. Click **Next**.
4. **Product Name**: `WireGuardGoBridge`.
5. **Build Tool**: `/usr/bin/make`.
6. Click **Finish**.
7. Select the `WireGuardGoBridge` target -> **Info** tab.
8. **Directory**: `$(PROJECT_DIR)/WireGuardKitGo`
9. **Pass build settings in environment**: Checked.

---

## Step 5: Setup Dependencies & Build Settings

1. **WireGuardKitGo**:
   - Download the [wireguard-apple](https://github.com/aakashch0179/wireguard-apple) repository.
   - Place or replace the `WireGuardKitGo` directory in your project root with the one from the repository.

2. **Add Target Dependency**:
   - Select the **WGExtension** target.
   - Go to the **Build Phases** tab.
   - In **Target Dependencies**, click `+` and select:
     - `WireGuardGoBridgeiOS` (for iOS), OR
     - `WireGuardGoBridge` (for macOS).

3. **Link Binary With Libraries**:
   - In **WGExtension** > **Build Phases**, expand **Link Binary With Libraries**.
   - Click `+` -> **Add Other...** -> **Add Files...**.
   - Select `out/libwg-go.a` (build the `WireGuardGoBridge` target once first if the file hasn't been generated yet).

4. **Configure Go Path**:
   - In **Build Settings** for **BOTH** the `Runner` and `WGExtension` targets:
   - Click `+` -> **Add User-Defined Setting**.
   - Key: `PATH`
   - Value: `${PATH}:/usr/local/go/bin:/opt/homebrew/bin` (adjust to where `go` is installed on your Mac).

5. **Disable User Script Sandboxing**:
   - For `WGExtension`, `WireGuardGoBridge`, and `Runner` targets:
   - Go to **Build Settings** -> search for `ENABLE_USER_SCRIPT_SANDBOXING`.
   - Set it to **NO**.

---

## Step 6: Enable Capabilities & Entitlements

### For iOS:

#### Main App (`Runner`) Target:
1. Select **Runner** -> **Signing & Capabilities**.
2. Click **+ Capability**:
   - **Network Extensions**: Check `Packet Tunnel`.
   - **App Groups**: Click `+` and add `group.com.example.vpnapp`. Check the box.

#### Extension (`WGExtension`) Target:
1. Select **WGExtension** -> **Signing & Capabilities**.
2. Click **+ Capability**:
   - **Network Extensions**: Check `Packet Tunnel`.
   - **App Groups**: Add the **exact same** App Group ID (`group.com.example.vpnapp`) and check the box.

---

### For macOS (CRITICAL Sandboxing Requirements):

macOS enforces strict App Sandbox constraints. Without the incoming network server entitlement, the WireGuard Go backend cannot bind its local UDP socket, causing the tunnel to fail with `bind: operation not permitted`.

#### Main App (`Runner`) Target:
1. Select **Runner** -> **Signing & Capabilities**:
   - **App Sandbox**: Check **Outgoing Connections (Client)**.
   - **Network Extensions**: Check `Packet Tunnel`.

#### Extension (`WGExtension`) Target:
1. Select **WGExtension** -> **Signing & Capabilities**:
   - **App Sandbox**:
     - Check **Outgoing Connections (Client)** (`ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`).
     - **MANDATORY**: Check **Incoming Connections (Server)** (`ENABLE_INCOMING_NETWORK_CONNECTIONS = YES`).
   - **Network Extensions**: Check `Packet Tunnel`.

> [!IMPORTANT]
> **Why Incoming Connections (Server) is Required on macOS**:
> The WireGuard Go backend calls `net.ListenUDP("udp", &net.UDPAddr{Port: 0})` to bind an ephemeral local port for receiving encrypted WireGuard UDP packets. In the macOS App Sandbox, binding a UDP socket is classified as a server operation. If `com.apple.security.network.server` is not enabled, macOS denies `bind()` with `operation not permitted`, bringing the tunnel interface immediately **Down** with zero download speed.

#### Entitlements Verification for macOS (`WGExtension.entitlements`):
Ensure your `WGExtension.entitlements` contains both network permissions:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
        <string>packet-tunnel-provider</string>
    </array>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
```

#### Note on App Groups on macOS:
On macOS App Sandbox, shared `UserDefaults(suiteName:)` containers strictly require a Team ID prefix (e.g. `$(TeamIdentifierPrefix)group.com.example.vpnapp`). `wireguard_flutter_plus` automatically detects this: if an iOS-style bare identifier (`group.xxx`) is passed, the plugin communicates traffic stats directly via Apple's `NETunnelProviderSession.sendProviderMessage` IPC channel and uses `UserDefaults.standard` to avoid the macOS `cfprefsd` detaching warning.

---

## Step 7: Fix Build Order (Recommended)

1. Open **Runner** > **Build Phases**.
2. Drag **Embed Foundation Extensions** to the bottom of the list (after **Copy Bundle Resources**).

---

## Step 8: Flutter Initialization

Pass your App Group ID to `wireguard.initialize`:

```dart
await wireguard.initialize(
  interfaceName: 'wg0',
  vpnName: 'My VPN',
  iosAppGroup: 'group.com.example.vpnapp', // Your App Group ID
);
```

---

## Step 9: Starting the VPN & Cross-Platform Configs

`wireguard_flutter_plus` is designed to be fully cross-platform. The exact same WireGuard configuration syntax works seamlessly across **Android, iOS, Windows, and macOS**:

```dart
await wireGuard.startVpn(
  serverAddress: '...',
  wgQuickConfig: '...',
  providerBundleIdentifier: 'com.example.vpnapp.WGExtension', // <-- YOUR EXTENSION BUNDLE ID
);
```

### Key Behaviors:
- **`AllowedIPs = 0.0.0.0/0, ::/0`**: Fully supported on all platforms. If your tunnel interface does not have an IPv6 address, the extension automatically strips `::/0` to prevent routing errors.
- **Dynamic Endpoint Routing**: The plugin automatically resolves the server host from `Endpoint = ...` in `wgQuickConfig` and sets `protocolConfiguration.serverAddress`. This ensures macOS routes tunnel traffic through your physical Wi-Fi/Ethernet interface without routing loops.
- **Duration Continuity**: Duration tracking leverages Apple's `NEVPNConnection.connectedDate`. When reopening or hot-restarting the Flutter app while connected, duration immediately resumes from the system's actual connection time without resetting to `00:00:00`.

---

## Step 10: Implement `PacketTunnelProvider.swift`

Replace the contents of your extension's `PacketTunnelProvider.swift` with the following implementation. It includes:
- Unified Apple `OSLog` tracing.
- Automatic IPv6 routing safety filter for IPv4-only interfaces.
- IPC traffic stats messaging (`getStats`).
- Safe macOS and iOS lifecycle management.

```swift
//
//  PacketTunnelProvider.swift
//  WGExtension
//

import Foundation
import NetworkExtension
import WireGuardKit
import os.log

enum PacketTunnelProviderError: String, Error {
    case invalidProtocolConfiguration
    case cantParseWgQuickConfig
}

extension String {
    func splitToArray(separator: Character = ",", trimmingCharacters: CharacterSet? = nil) -> [String] {
        return split(separator: separator).map {
            if let charSet = trimmingCharacters {
                return $0.trimmingCharacters(in: charSet)
            } else {
                return String($0)
            }
        }
    }
}

extension Optional where Wrapped == String {
    func splitToArray(separator: Character = ",", trimmingCharacters: CharacterSet? = nil) -> [String] {
        switch self {
        case .none: return []
        case .some(let wrapped): return wrapped.splitToArray(separator: separator, trimmingCharacters: trimmingCharacters)
        }
    }
}

extension TunnelConfiguration {
    enum ParserState {
        case inInterfaceSection
        case inPeerSection
        case notInASection
    }

    enum ParseError: Error {
        case invalidLine(String.SubSequence)
        case noInterface
        case multipleInterfaces
        case interfaceHasNoPrivateKey
        case interfaceHasInvalidPrivateKey(String)
        case interfaceHasInvalidListenPort(String)
        case interfaceHasInvalidAddress(String)
        case interfaceHasInvalidDNS(String)
        case interfaceHasInvalidMTU(String)
        case interfaceHasUnrecognizedKey(String)
        case peerHasNoPublicKey
        case peerHasInvalidPublicKey(String)
        case peerHasInvalidPreSharedKey(String)
        case peerHasInvalidAllowedIP(String)
        case peerHasInvalidEndpoint(String)
        case peerHasInvalidPersistentKeepAlive(String)
        case peerHasInvalidTransferBytes(String)
        case peerHasInvalidLastHandshakeTime(String)
        case peerHasUnrecognizedKey(String)
        case multiplePeersWithSamePublicKey
        case multipleEntriesForKey(String)
    }

    convenience init(fromWgQuickConfig wgQuickConfig: String, called name: String? = nil) throws {
        var interfaceConfiguration: InterfaceConfiguration?
        var peerConfigurations = [PeerConfiguration]()

        let lines = wgQuickConfig.split { $0.isNewline }
        var parserState = ParserState.notInASection
        var attributes = [String: String]()

        for (lineIndex, line) in lines.enumerated() {
            var trimmedLine: String
            if let commentRange = line.range(of: "#") {
                trimmedLine = String(line[..<commentRange.lowerBound])
            } else {
                trimmedLine = String(line)
            }

            trimmedLine = trimmedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = trimmedLine.lowercased()

            if !trimmedLine.isEmpty {
                if let equalsIndex = trimmedLine.firstIndex(of: "=") {
                    let keyWithCase = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = keyWithCase.lowercased()
                    let value = trimmedLine[trimmedLine.index(equalsIndex, offsetBy: 1)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    let keysWithMultipleEntriesAllowed: Set<String> = ["address", "allowedips", "dns"]
                    if let presentValue = attributes[key] {
                        if keysWithMultipleEntriesAllowed.contains(key) {
                            attributes[key] = presentValue + "," + value
                        } else {
                            throw ParseError.multipleEntriesForKey(keyWithCase)
                        }
                    } else {
                        attributes[key] = value
                    }
                    let interfaceSectionKeys: Set<String> = ["privatekey", "listenport", "address", "dns", "mtu"]
                    let peerSectionKeys: Set<String> = ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"]
                    if parserState == .inInterfaceSection {
                        guard interfaceSectionKeys.contains(key) else {
                            throw ParseError.interfaceHasUnrecognizedKey(keyWithCase)
                        }
                    } else if parserState == .inPeerSection {
                        guard peerSectionKeys.contains(key) else {
                            throw ParseError.peerHasUnrecognizedKey(keyWithCase)
                        }
                    }
                } else if lowercasedLine != "[interface]" && lowercasedLine != "[peer]" {
                    throw ParseError.invalidLine(line)
                }
            }

            let isLastLine = lineIndex == lines.count - 1
            if isLastLine || lowercasedLine == "[interface]" || lowercasedLine == "[peer]" {
                if parserState == .inInterfaceSection {
                    let interface = try TunnelConfiguration.collate(interfaceAttributes: attributes)
                    guard interfaceConfiguration == nil else { throw ParseError.multipleInterfaces }
                    interfaceConfiguration = interface
                } else if parserState == .inPeerSection {
                    let peer = try TunnelConfiguration.collate(peerAttributes: attributes)
                    peerConfigurations.append(peer)
                }
            }

            if lowercasedLine == "[interface]" {
                parserState = .inInterfaceSection
                attributes.removeAll()
            } else if lowercasedLine == "[peer]" {
                parserState = .inPeerSection
                attributes.removeAll()
            }
        }

        let peerPublicKeysArray = peerConfigurations.map { $0.publicKey }
        let peerPublicKeysSet = Set<PublicKey>(peerPublicKeysArray)
        if peerPublicKeysArray.count != peerPublicKeysSet.count {
            throw ParseError.multiplePeersWithSamePublicKey
        }

        if let interfaceConfiguration = interfaceConfiguration {
            self.init(name: name, interface: interfaceConfiguration, peers: peerConfigurations)
        } else {
            throw ParseError.noInterface
        }
    }

    private static func collate(interfaceAttributes attributes: [String: String]) throws -> InterfaceConfiguration {
        guard let privateKeyString = attributes["privatekey"] else {
            throw ParseError.interfaceHasNoPrivateKey
        }
        guard let privateKey = PrivateKey(base64Key: privateKeyString) else {
            throw ParseError.interfaceHasInvalidPrivateKey(privateKeyString)
        }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        if let listenPortString = attributes["listenport"] {
            guard let listenPort = UInt16(listenPortString) else {
                throw ParseError.interfaceHasInvalidListenPort(listenPortString)
            }
            interface.listenPort = listenPort
        }
        if let addressesString = attributes["address"] {
            var addresses = [IPAddressRange]()
            for addressString in addressesString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                guard let address = IPAddressRange(from: addressString) else {
                    throw ParseError.interfaceHasInvalidAddress(addressString)
                }
                addresses.append(address)
            }
            interface.addresses = addresses
        }
        if let dnsString = attributes["dns"] {
            var dnsServers = [DNSServer]()
            var dnsSearch = [String]()
            for dnsServerString in dnsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                if let dnsServer = DNSServer(from: dnsServerString) {
                    dnsServers.append(dnsServer)
                } else {
                    dnsSearch.append(dnsServerString)
                }
            }
            interface.dns = dnsServers
            interface.dnsSearch = dnsSearch
        }
        if let mtuString = attributes["mtu"] {
            guard let mtu = UInt16(mtuString) else {
                throw ParseError.interfaceHasInvalidMTU(mtuString)
            }
            interface.mtu = mtu
        }
        return interface
    }

    private static func collate(peerAttributes attributes: [String: String]) throws -> PeerConfiguration {
        guard let publicKeyString = attributes["publickey"] else {
            throw ParseError.peerHasNoPublicKey
        }
        guard let publicKey = PublicKey(base64Key: publicKeyString) else {
            throw ParseError.peerHasInvalidPublicKey(publicKeyString)
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        if let preSharedKeyString = attributes["presharedkey"] {
            guard let preSharedKey = PreSharedKey(base64Key: preSharedKeyString) else {
                throw ParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
            }
            peer.preSharedKey = preSharedKey
        }
        if let allowedIPsString = attributes["allowedips"] {
            var allowedIPs = [IPAddressRange]()
            for allowedIPString in allowedIPsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                guard let allowedIP = IPAddressRange(from: allowedIPString) else {
                    throw ParseError.peerHasInvalidAllowedIP(allowedIPString)
                }
                allowedIPs.append(allowedIP)
            }
            peer.allowedIPs = allowedIPs
        }
        if let endpointString = attributes["endpoint"] {
            guard let endpoint = Endpoint(from: endpointString) else {
                throw ParseError.peerHasInvalidEndpoint(endpointString)
            }
            peer.endpoint = endpoint
        }
        if let persistentKeepAliveString = attributes["persistentkeepalive"] {
            guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
                throw ParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
            }
            peer.persistentKeepAlive = persistentKeepAlive
        }
        return peer
    }
}

public class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { [weak self] _, message in
            self?.log(message)
        }
    }()
    
    private var totalDownloadBytes: Int64 = 0
    private var totalUploadBytes: Int64 = 0
    private var lastDownloadBytes: Int64 = 0
    private var lastUploadBytes: Int64 = 0
    private var trafficStatsTimer: Timer?

    private static let logger = OSLog(subsystem: "com.example.vpnapp.WGExtension", category: "PacketTunnel")

    func log(_ message: String) {
        os_log("%{public}@", log: PacketTunnelProvider.logger, type: .default, "WireGuard Tunnel: \(message)")
        print("WireGuard Tunnel: \(message)")
    }

    public override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log("Starting tunnel")

        guard let protocolConfiguration = self.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = protocolConfiguration.providerConfiguration,
              let wgQuickConfig = providerConfiguration["wgQuickConfig"] as? String else {
            log("Invalid provider configuration")
            completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
            return
        }

        log("wg-quick config parseable")
        guard let tunnelConfiguration = try? TunnelConfiguration(fromWgQuickConfig: wgQuickConfig) else {
            log("wg-quick config parsing failed: \(wgQuickConfig)")
            completionHandler(PacketTunnelProviderError.cantParseWgQuickConfig)
            return
        }

        // Safety filter: strip IPv6 allowed IPs if interface has no IPv6 address to prevent routing errors
        var activeConfig = tunnelConfiguration
        let hasIPv6 = tunnelConfiguration.interface.addresses.contains { $0.address is IPv6Address }
        if !hasIPv6 {
            var updatedPeers = [PeerConfiguration]()
            for peer in tunnelConfiguration.peers {
                var updatedPeer = peer
                updatedPeer.allowedIPs = peer.allowedIPs.filter { $0.address is IPv4Address }
                updatedPeers.append(updatedPeer)
            }
            activeConfig = TunnelConfiguration(name: tunnelConfiguration.name, interface: tunnelConfiguration.interface, peers: updatedPeers)
        }

        log("Starting WireGuard adapter with config")
        adapter.start(tunnelConfiguration: activeConfig) { [weak self] adapterError in
            guard let self = self else { return }
            if let adapterError = adapterError {
                self.log("WireGuard adapter error: \(adapterError.localizedDescription)")
            } else {
                let interfaceName = self.adapter.interfaceName ?? "unknown"
                self.log("Tunnel interface is \(interfaceName)")
                self.startTrafficMonitoring()
            }
            completionHandler(adapterError)
        }
    }

    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("Stopping tunnel")
        stopTrafficMonitoring()
        adapter.stop { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("Failed to stop WireGuard adapter: \(error.localizedDescription)")
            }
            completionHandler()

            #if os(macOS)
            exit(0) // Clean exit for macOS App Extensions
            #endif
        }
    }

    func startTrafficMonitoring() {
        trafficStatsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            DispatchQueue.global(qos: .background).async {
                self.adapter.getRuntimeConfiguration { config in
                    guard let configString = config else { return }
                    if let configData = configString.data(using: .utf8) {
                        do {
                            struct WireGuardConfig: Decodable {
                                var peers: [Peer]
                                struct Peer: Decodable {
                                    var rxBytes: Int
                                    var txBytes: Int
                                }
                            }

                            let parsedConfig = try JSONDecoder().decode(WireGuardConfig.self, from: configData)
                            var currentDownload: Int64 = 0
                            var currentUpload: Int64 = 0

                            for peer in parsedConfig.peers {
                                currentDownload += Int64(peer.rxBytes)
                                currentUpload += Int64(peer.txBytes)
                            }

                            let downloadSpeed = currentDownload - self.lastDownloadBytes
                            let uploadSpeed = currentUpload - self.lastUploadBytes

                            self.lastDownloadBytes = currentDownload
                            self.lastUploadBytes = currentUpload
                            self.totalDownloadBytes = currentDownload
                            self.totalUploadBytes = currentUpload

                            #if os(iOS)
                            DispatchQueue.main.async {
                                if let sharedDefaults = UserDefaults(suiteName: "group.com.example.vpnapp") {
                                    sharedDefaults.set(downloadSpeed, forKey: "downloadSpeed")
                                    sharedDefaults.set(uploadSpeed, forKey: "uploadSpeed")
                                    sharedDefaults.set(self.totalDownloadBytes, forKey: "totalDownloadBytes")
                                    sharedDefaults.set(self.totalUploadBytes, forKey: "totalUploadBytes")
                                }
                            }
                            #endif
                        } catch {
                            self.log("Error parsing runtime config: \(error)")
                        }
                    }
                }
            }
        }
    }

    func stopTrafficMonitoring() {
        trafficStatsTimer?.invalidate()
        trafficStatsTimer = nil
    }

    public override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        if message == "getStats" {
            if let stats = getTrafficStats() {
                let dict: [String: UInt64] = ["rx": stats.rx, "tx": stats.tx]
                let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
                completionHandler?(data)
            } else if self.totalDownloadBytes > 0 || self.totalUploadBytes > 0 {
                let dict: [String: UInt64] = ["rx": UInt64(max(0, self.totalDownloadBytes)), "tx": UInt64(max(0, self.totalUploadBytes))]
                let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
                completionHandler?(data)
            } else {
                completionHandler?(nil)
            }
        } else {
            completionHandler?(nil)
        }
    }

    func getTrafficStats() -> (rx: UInt64, tx: UInt64)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0 else { return nil }

        var ptr = ifaddr
        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0

        while ptr != nil {
            guard let interface = ptr?.pointee else { break }
            let name = String(cString: interface.ifa_name)
            if name.starts(with: "utun") {
                if let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    rxBytes += UInt64(data.ifi_ibytes)
                    txBytes += UInt64(data.ifi_obytes)
                }
            }
            ptr = ptr?.pointee.ifa_next
        }

        freeifaddrs(ifaddr)
        return (rxBytes, txBytes)
    }

    public override func sleep(completionHandler: @escaping () -> Void) {
        stopTrafficMonitoring()
        super.sleep(completionHandler: completionHandler)
    }

    public override func wake() {
        startTrafficMonitoring()
        super.wake()
    }
}
```

---

## Real-Time Extension Debugging on macOS

Standard `print()` output inside a Network Extension does not appear in the standard Flutter/Xcode debug console because the extension runs in an independent system daemon process (`nesessionmanager`).

To monitor real-time extension and WireGuard Go logs, run the following in Terminal:
```bash
/usr/bin/log stream --predicate 'subsystem CONTAINS "WGExtension"' --level debug
```

---

## Troubleshooting

- **`listen udp4 :0: bind: operation not permitted` / Connected but 0 download speed**:
  Your macOS `WGExtension` target is missing the **Incoming Connections (Server)** entitlement. Enable **Incoming Connections (Server)** in `WGExtension` > **Signing & Capabilities** (or add `<key>com.apple.security.network.server</key><true/>` in `WGExtension.entitlements`).

- **`Using kCFPreferencesAnyUser with a container is only allowed for System Containers, detaching from cfprefsd`**:
  On macOS App Sandbox, App Groups require Apple's Team ID prefix (`$(TeamIdentifierPrefix)group.xxx`). In `wireguard_flutter_plus 1.0.8+`, the plugin automatically detects this and uses direct IPC (`sendProviderMessage`) and `UserDefaults.standard` on macOS to eliminate this error.

- **Duration resets to `00:00:00` upon reopening or hot-restarting the app**:
  Fixed in `wireguard_flutter_plus 1.0.8+`. The plugin preserves session timestamps across Flutter stream cancellations and queries Apple's native `NEVPNConnection.connectedDate` upon reconnecting to the stream.

- **"make: .../wireguard-go-bridge/goroot/.prepared Error 1"**:
  Install cmake via Homebrew: `arch -arm64 brew install cmake`.

- **"source files not found"**:
  Clean and rebuild Xcode workspace (`Product > Clean Build Folder`). Xcode may have attempted parallel compilation before the Go static library finished building.
