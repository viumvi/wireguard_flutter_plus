//
//  PacketTunnelProvider.swift
//  WireGuardNetworkExtension
//
//  Created by Alexandr Ruban on 05.10.2023.
//

// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import NetworkExtension
import WireGuardKit


enum PacketTunnelProviderError: String, Error {
    case invalidProtocolConfiguration
    case cantParseWgQuickConfig
}


extension String {

    func splitToArray(separator: Character = ",", trimmingCharacters: CharacterSet? = nil) -> [String] {
        return split(separator: separator)
            .map {
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
        case .none:
            return []
        case .some(let wrapped):
            return wrapped.splitToArray(separator: separator, trimmingCharacters: trimmingCharacters)
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
                    // Line contains an attribute
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
                // Previous section has ended; process the attributes collected so far
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

    func asWgQuickConfig() -> String {
        var output = "[Interface]\n"
        output.append("PrivateKey = \(interface.privateKey.base64Key)\n")
        if let listenPort = interface.listenPort {
            output.append("ListenPort = \(listenPort)\n")
        }
        if !interface.addresses.isEmpty {
            let addressString = interface.addresses.map { $0.stringRepresentation }.joined(separator: ", ")
            output.append("Address = \(addressString)\n")
        }
        if !interface.dns.isEmpty || !interface.dnsSearch.isEmpty {
            var dnsLine = interface.dns.map { $0.stringRepresentation }
            dnsLine.append(contentsOf: interface.dnsSearch)
            let dnsString = dnsLine.joined(separator: ", ")
            output.append("DNS = \(dnsString)\n")
        }
        if let mtu = interface.mtu {
            output.append("MTU = \(mtu)\n")
        }

        for peer in peers {
            output.append("\n[Peer]\n")
            output.append("PublicKey = \(peer.publicKey.base64Key)\n")
            if let preSharedKey = peer.preSharedKey?.base64Key {
                output.append("PresharedKey = \(preSharedKey)\n")
            }
            if !peer.allowedIPs.isEmpty {
                let allowedIPsString = peer.allowedIPs.map { $0.stringRepresentation }.joined(separator: ", ")
                output.append("AllowedIPs = \(allowedIPsString)\n")
            }
            if let endpoint = peer.endpoint {
                output.append("Endpoint = \(endpoint.stringRepresentation)\n")
            }
            if let persistentKeepAlive = peer.persistentKeepAlive {
                output.append("PersistentKeepalive = \(persistentKeepAlive)\n")
            }
        }

        return output
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
   // Define the WireGuardAdapter instance.
    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { [weak self] _, message in
            self?.log(message)
        }
    }()
    
    // Variables to track download/upload bytes and traffic stats.
    private var totalDownloadBytes: Int64 = 0
    private var totalUploadBytes: Int64 = 0
    private var lastDownloadBytes: Int64 = 0
    private var lastUploadBytes: Int64 = 0
    private var trafficStatsTimer: Timer?

    // Function to log messages to console.
    func log(_ message: String) {
        print("WireGuard Tunnel: \(message)")
    }


      // Function to start the tunnel.
    public override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log("Starting tunnel")

        // Validate protocol configuration.
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

        log("Starting WireGuard adapter with config")
        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
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



     // Function to stop the tunnel.
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
            if Bundle.main.bundleURL.pathExtension != "systemextension" {
             exit(0) // Only exit if it's a standard App Extension
            }
            #endif
        }
    }


     // Function to start traffic monitoring with periodic updates.
    func startTrafficMonitoring() {
    // Set a longer interval to reduce lag.
    trafficStatsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
        guard let self = self else { return }

        // Run traffic stats processing in the background to prevent UI lag.
        DispatchQueue.global(qos: .background).async {
            self.adapter.getRuntimeConfiguration { config in
                guard let configString = config else {
                    self.log("Error: No config received.")
                    return
                }

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
                        let peers = parsedConfig.peers

                        var currentDownload: Int64 = 0
                        var currentUpload: Int64 = 0

                        // Calculate total download/upload from peers.
                        for peer in peers {
                            currentDownload += Int64(peer.rxBytes)
                            currentUpload += Int64(peer.txBytes)
                        }

                        let downloadSpeed = currentDownload - self.lastDownloadBytes
                        let uploadSpeed = currentUpload - self.lastUploadBytes

                        // Update the last stats values.
                        self.lastDownloadBytes = currentDownload
                        self.lastUploadBytes = currentUpload

                        // Update total stats.
                        self.totalDownloadBytes = currentDownload
                        self.totalUploadBytes = currentUpload

                        // Update the stats in shared app group (main thread for UI updates).
                        DispatchQueue.main.async {
                            if let sharedDefaults = UserDefaults(suiteName: "group.com.orbanvpn.wireguard") {
                                sharedDefaults.set(downloadSpeed, forKey: "downloadSpeed")
                                sharedDefaults.set(uploadSpeed, forKey: "uploadSpeed")
                                sharedDefaults.set(self.totalDownloadBytes, forKey: "totalDownloadBytes")
                                sharedDefaults.set(self.totalUploadBytes, forKey: "totalUploadBytes")
                            }
                        }

                    } catch {
                        self.log("Error parsing WireGuard config: \(error)")
                    }
                }
            }
        }
    }
    }

     // Function to stop traffic monitoring.
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
        } else {
            print("Unable to get traffic stats")
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
        // Adjust this name if your tunnel uses a different one (e.g., utun2, utun3, etc.)
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
    // Perform your custom logic before calling the superclass method
    stopTrafficMonitoring() // For example, stop monitoring traffic when the tunnel goes to sleep.
    
    // Call the superclass method to properly handle the sleep state
    super.sleep(completionHandler: completionHandler)
}

public override func wake() {
    // Perform your custom logic before calling the superclass method
    startTrafficMonitoring() // For example, restart monitoring traffic when the tunnel wakes up.

    // Call the superclass method to properly handle the wake state
    super.wake()
}

// Function to handle disconnection logic (e.g., when VPN connection is disconnected).
func handleDisconnect() {
    stopTrafficMonitoring()
    // Additional cleanup if necessary.
}
}
