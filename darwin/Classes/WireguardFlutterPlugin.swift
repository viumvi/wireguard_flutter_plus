#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import FlutterMacOS
import Cocoa
import SystemExtensions
#else
#error("Unsupported platform")
#endif

import NetworkExtension
import Foundation
import Network

public class WireguardFlutterPlugin: NSObject, FlutterPlugin {
    static var utils: VPNUtils! = VPNUtils()
    public static var stage: FlutterEventSink?
    private var initialized: Bool = false
    var wireguardMethodChannel: FlutterMethodChannel?
    private var systemExtensionResult: FlutterResult?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = WireguardFlutterPlugin()
        instance.onRegister(registrar)
    }

    public func onRegister(_ registrar: FlutterPluginRegistrar){
        #if os(iOS)
        let messenger = registrar.messenger()
        #else
        let messenger = registrar.messenger
        #endif

        let wireguardMethodChannel = FlutterMethodChannel(name: "orban.group.wireguard_flutter_plus/wgcontrol", binaryMessenger: messenger)
        let vpnStageE = FlutterEventChannel(name: "orban.group.wireguard_flutter_plus/wgstage", binaryMessenger: messenger)
        let trafficChannel = FlutterEventChannel(name: "orban.group.wireguard_flutter_plus/traffic", binaryMessenger: messenger)

        trafficChannel.setStreamHandler(TrafficStreamHandler.shared)
        vpnStageE.setStreamHandler(VPNConnectionHandler())

        wireguardMethodChannel.setMethodCallHandler({ (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            switch call.method {
            case "stage":
                result(WireguardFlutterPlugin.utils.currentStatus())
            case "initialize":
                guard let localizedDescription = (call.arguments as? [String: Any])?["localizedDescription"] as? String else {
                    result(FlutterError(code: "-3", message: "localizedDescription content empty or null", details: nil))
                    return
                }
                if let groupId = (call.arguments as? [String: Any])?["groupId"] as? String {
                    TrafficStreamHandler.shared.configure(groupId: groupId)
                }
                if let extensionBundleId = (call.arguments as? [String: Any])?["extensionBundleId"] as? String {
                    WireguardFlutterPlugin.utils.providerBundleIdentifier = extensionBundleId
                }
                WireguardFlutterPlugin.utils.localizedDescription = localizedDescription
                WireguardFlutterPlugin.utils.loadProviderManager { err in
                    if err == nil {
                        result(WireguardFlutterPlugin.utils.currentStatus())
                    } else {
                        result(FlutterError(code: "-4", message: err?.localizedDescription, details: err?.localizedDescription))
                    }
                }
                self.initialized = true
            case "stop":
                self.disconnect(result: result)
            case "start":
                guard let args = call.arguments as? [String: Any],
                      let serverAddress = args["serverAddress"] as? String,
                      let wgQuickConfig = args["wgQuickConfig"] as? String,
                      let providerBundleIdentifier = args["providerBundleIdentifier"] as? String else {
                    result(FlutterError(code: "-5", message: "Invalid arguments", details: nil))
                    return
                }
                self.connect(serverAddress: serverAddress, wgQuickConfig: wgQuickConfig, providerBundleIdentifier: providerBundleIdentifier, result: result)
            case "dispose":
                self.initialized = false
                result(nil)
            case "requestMacSystemExtension":
                #if os(macOS)
                guard let args = call.arguments as? [String: Any],
                      let bundleId = args["bundleId"] as? String else {
                    result(FlutterError(code: "-5", message: "Invalid arguments", details: nil))
                    return
                }
                if #available(macOS 10.15, *) {
                    self.systemExtensionResult = result
                    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: bundleId, queue: .main)
                    request.delegate = self
                    OSSystemExtensionManager.shared.submitRequest(request)
                } else {
                    result(FlutterError(code: "-6", message: "System Extensions require macOS 10.15 or later", details: nil))
                }
                #else
                result(FlutterError(code: "-6", message: "System Extensions are only supported on macOS", details: nil))
                #endif
            default:
                result(FlutterMethodNotImplemented)
            }
        })
    }

    private func connect(serverAddress: String, wgQuickConfig: String, providerBundleIdentifier: String, result: @escaping FlutterResult) {
        WireguardFlutterPlugin.utils.configureVPN(serverAddress: serverAddress, wgQuickConfig: wgQuickConfig, providerBundleIdentifier: providerBundleIdentifier) { success in
            result(success)
        }
    }

    private func disconnect(result: @escaping FlutterResult) {
        WireguardFlutterPlugin.utils.stopVPN { success in
            if success == true {
                TrafficStreamHandler.shared.stopMonitoring()
            }
            result(success)
        }
    }
}

class TrafficStreamHandler: NSObject, FlutterStreamHandler {
    static let shared = TrafficStreamHandler()
    private var eventSink: FlutterEventSink?
    private var timer: DispatchSourceTimer?
    private var lastDownload: Int64 = 0
    private var lastUpload: Int64 = 0
    private var isFirstTick: Bool = true

    // Use app group ID for shared UserDefaults, fallback to standard
    private var defaults: UserDefaults {
        return userDefaultsInstance ?? UserDefaults.standard
    }
    private var userDefaultsInstance: UserDefaults?
    
    func configure(groupId: String) {
        #if os(iOS)
        if !groupId.isEmpty, let ud = UserDefaults(suiteName: groupId) {
            userDefaultsInstance = ud
        }
        #else
        // On macOS, standard App Groups require a Team ID prefix (e.g., <TeamID>.group...).
        // If a bare iOS-style group ID (group.*) is passed, macOS cfprefsd rejects it as an
        // unauthorized system container and detaches.
        // On macOS, stats are received over IPC (sendProviderMessage), so UserDefaults.standard is sufficient.
        if !groupId.isEmpty && !groupId.hasPrefix("group."), let ud = UserDefaults(suiteName: groupId) {
            userDefaultsInstance = ud
        }
        #endif
    } 

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        if WireguardFlutterPlugin.utils.currentStatus() == "connected" {
            startMonitoring()
        } else {
            let initialTraffic: [String: Any] = [
                "downloadSpeed": 0,
                "uploadSpeed": 0,
                "totalDownload": 0,
                "totalUpload": 0,
                "duration": "00:00:00"
            ]
            events(initialTraffic)
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        // Only cancel timer and event sink when Flutter stream is cancelled/recreated (e.g. hot restart, app background).
        // Do NOT call stopMonitoring() here because the VPN tunnel is still running in the background.
        timer?.cancel()
        timer = nil
        eventSink = nil
        return nil
    }

    func startMonitoring() {
        guard timer == nil else { return } // Prevent multiple timers
        isFirstTick = true

        // Restore saved data or initialize if not present
        lastDownload = defaults.object(forKey: "vpn_last_download") as? Int64 ?? 0
        lastUpload = defaults.object(forKey: "vpn_last_upload") as? Int64 ?? 0

        // Resolve session start time: prioritize Apple's OS connection connectedDate
        let systemConnectedDate = WireguardFlutterPlugin.utils.providerManager?.connection.connectedDate
        let savedTime = (defaults.object(forKey: "vpn_session_start_time") as? NSNumber)?.doubleValue ?? 0
        let startTime: Double
        if let systemDate = systemConnectedDate {
            startTime = systemDate.timeIntervalSince1970
            defaults.set(startTime, forKey: "vpn_session_start_time")
            defaults.synchronize()
        } else if savedTime > 0 {
            startTime = savedTime
        } else {
            startTime = Date().timeIntervalSince1970
            defaults.set(startTime, forKey: "vpn_session_start_time")
            defaults.synchronize()
        }
        if WireguardFlutterPlugin.utils.vpnStartTime == nil {
            WireguardFlutterPlugin.utils.vpnStartTime = Date(timeIntervalSince1970: startTime)
        }

        // Send last saved traffic data immediately to Flutter
        let elapsed = max(0, Int(Date().timeIntervalSince1970 - startTime))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        let duration = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

        let initialTraffic: [String: Any] = [
            "downloadSpeed": 0,
            "uploadSpeed": 0,
            "totalDownload": lastDownload,
            "totalUpload": lastUpload,
            "duration": duration
        ]
        DispatchQueue.main.async {
            self.eventSink?(initialTraffic)
        }

        let timerSource = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        timerSource.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))

        timerSource.setEventHandler { [weak self] in
            guard let self = self else { return }

            // If disconnected, stop monitoring
            guard WireguardFlutterPlugin.utils.currentStatus() == "connected" else {
                DispatchQueue.main.async {
                    self.stopMonitoring()
                }
                return
            }

            guard let stats = WireguardFlutterPlugin.utils.getTrafficStats() else { return }

            let download = Int64((stats["totalDownload"] as? Double ?? 0) * 1024)
            let upload = Int64((stats["totalUpload"] as? Double ?? 0) * 1024)

            let downloadSpeed: Int64
            let uploadSpeed: Int64
            if self.isFirstTick {
                downloadSpeed = 0
                uploadSpeed = 0
                self.isFirstTick = false
            } else {
                downloadSpeed = max(download - self.lastDownload, 0)
                uploadSpeed = max(upload - self.lastUpload, 0)
            }

            self.lastDownload = download
            self.lastUpload = upload

            // Save to UserDefaults
            self.defaults.set(self.lastDownload, forKey: "vpn_last_download")
            self.defaults.set(self.lastUpload, forKey: "vpn_last_upload")
            self.defaults.synchronize()

            let currentSystemDate = WireguardFlutterPlugin.utils.providerManager?.connection.connectedDate
            let savedStartTime = (self.defaults.object(forKey: "vpn_session_start_time") as? NSNumber)?.doubleValue ?? 0
            let effectiveStartTime: Double
            if let sysDate = currentSystemDate {
                effectiveStartTime = sysDate.timeIntervalSince1970
            } else if savedStartTime > 0 {
                effectiveStartTime = savedStartTime
            } else {
                effectiveStartTime = startTime
            }
            let elapsed = max(0, Int(Date().timeIntervalSince1970 - effectiveStartTime))
            let hours = elapsed / 3600
            let minutes = (elapsed % 3600) / 60
            let seconds = elapsed % 60
            let duration = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

            let traffic: [String: Any] = [
                "downloadSpeed": downloadSpeed,
                "uploadSpeed": uploadSpeed,
                "totalDownload": download,
                "totalUpload": upload,
                "duration": duration
            ]

            DispatchQueue.main.async {
                self.eventSink?(traffic)
            }
        }
        timer = timerSource
        timerSource.resume()
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
        lastDownload = 0
        lastUpload = 0
        isFirstTick = true

        // Clear saved data
        defaults.removeObject(forKey: "vpn_session_start_time")
        defaults.removeObject(forKey: "vpn_last_download")
        defaults.removeObject(forKey: "vpn_last_upload")
        defaults.synchronize()
        WireguardFlutterPlugin.utils.vpnStartTime = nil

        // Send reset event
        DispatchQueue.main.async {
            let resetTraffic: [String: Any] = [
                "downloadSpeed": 0,
                "uploadSpeed": 0,
                "totalDownload": 0,
                "totalUpload": 0,
                "duration": "00:00:00"
            ]
            self.eventSink?(resetTraffic)
        }
    }

    /// Force stop monitoring from outside
    func forceStop() {
        stopMonitoring()
        eventSink = nil
    }
}

class VPNConnectionHandler: NSObject, FlutterStreamHandler {
    private var vpnConnection: FlutterEventSink?
    private var vpnConnectionObserver: NSObjectProtocol?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.vpnConnection = events
        if let observer = vpnConnectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        vpnConnectionObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, 
            let connection = self.vpnConnection else { return }
            let status = (notification.object as? NEVPNConnection)?.status
            connection(WireguardFlutterPlugin.utils.onVpnStatusChangedString(notification: status))
           
            if status == .connected {
                // Start traffic monitoring when connected
                TrafficStreamHandler.shared.startMonitoring()
            } else if status == .disconnected || status == .invalid {
                // Stop traffic monitoring when disconnected or invalid
                TrafficStreamHandler.shared.stopMonitoring()
            }
        }
        // Emit current status immediately upon subscribing
        events(WireguardFlutterPlugin.utils.currentStatus())
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let observer = vpnConnectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        vpnConnectionObserver = nil
        vpnConnection = nil
        return nil
    }
}

@available(iOS 15.0, *)
class VPNUtils {
    var providerManager: NETunnelProviderManager!
    var providerBundleIdentifier: String?
    var localizedDescription: String?
    var groupIdentifier: String?
    var serverAddress: String?
    var stage: FlutterEventSink!

    private var lastDownloadBytes: Int64 = 0
    private var lastUploadBytes: Int64 = 0
    private var lastUpdateTime: Date?
    var vpnStartTime: Date?

    func loadProviderManager(completion: @escaping (_ error: Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if error == nil {
                self.providerManager = managers?.first ?? NETunnelProviderManager()
                completion(nil)
            } else {
                completion(error)
            }
        }
    }

    func onVpnStatusChangedString(notification: NEVPNStatus?) -> String {
        switch notification {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        case .disconnecting: return "disconnecting"
        case .invalid: return "invalid"
        case .reasserting: return "reasserting"
        default: return "disconnected"
        }
    }

    func currentStatus() -> String {
        return providerManager != nil ? onVpnStatusChangedString(notification: providerManager.connection.status) : "disconnected"
    }

    func getTrafficStats() -> [String: Any]? {
        guard let session = providerManager?.connection as? NETunnelProviderSession else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var resultDict: [String: Any]?
        let messageData = "getStats".data(using: .utf8)!

        do {
            try session.sendProviderMessage(messageData) { response in
                defer { semaphore.signal() }

                guard let response = response,
                      let dict = try? JSONSerialization.jsonObject(with: response) as? [String: UInt64],
                      let rxBytes = dict["rx"],
                      let txBytes = dict["tx"] else {
                    return
                }

                let currentTime = Date()
                var downloadSpeed: Double = 0
                var uploadSpeed: Double = 0

                if let lastTime = self.lastUpdateTime {
                    let timeDelta = currentTime.timeIntervalSince(lastTime)
                    if timeDelta > 0 {
                        let downloadDelta = Double(Int64(rxBytes) - self.lastDownloadBytes)
                        let uploadDelta = Double(Int64(txBytes) - self.lastUploadBytes)

                        downloadSpeed = downloadDelta / timeDelta / 1024.0 // KB/s
                        uploadSpeed = uploadDelta / timeDelta / 1024.0
                    }
                }

                self.lastDownloadBytes = Int64(rxBytes)
                self.lastUploadBytes = Int64(txBytes)
                self.lastUpdateTime = currentTime

                let effectiveStartTime = self.vpnStartTime ?? self.providerManager?.connection.connectedDate
                let durationSeconds: TimeInterval = effectiveStartTime != nil ? currentTime.timeIntervalSince(effectiveStartTime!) : 0
                let formattedDuration = self.formatDuration(durationSeconds)

                resultDict = [
                    "totalDownload": Double(rxBytes) / 1024.0,
                    "totalUpload": Double(txBytes) / 1024.0,
                    "downloadSpeed": downloadSpeed,
                    "uploadSpeed": uploadSpeed,
                    "duration": formattedDuration
                ]
            }
        } catch {
            print("Error sending provider message: \(error)")
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 1.0)
        return resultDict
    }

    func configureVPN(serverAddress: String?, wgQuickConfig: String?, providerBundleIdentifier: String?, completion: @escaping (Bool) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                print("Error (loadAllFromPreferences): \(error)")
                completion(false)
                return
            }

            // Extract endpoint host from wgQuickConfig if available to ensure macOS routes packets to the correct VPN server
            var effectiveServerAddress = serverAddress
            if let config = wgQuickConfig {
                let lines = config.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.lowercased().starts(with: "endpoint") {
                        let parts = trimmed.components(separatedBy: "=")
                        if parts.count > 1 {
                            let endpointVal = parts[1].trimmingCharacters(in: .whitespaces)
                            if let colonIndex = endpointVal.lastIndex(of: ":") {
                                effectiveServerAddress = String(endpointVal[..<colonIndex]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                            } else {
                                effectiveServerAddress = endpointVal
                            }
                        }
                        break
                    }
                }
            }

            let tunnelManager = managers?.first ?? NETunnelProviderManager()
            let protocolConfiguration = NETunnelProviderProtocol()
            protocolConfiguration.providerBundleIdentifier = providerBundleIdentifier
            protocolConfiguration.serverAddress = effectiveServerAddress
            protocolConfiguration.providerConfiguration = ["wgQuickConfig": wgQuickConfig ?? ""]
            tunnelManager.protocolConfiguration = protocolConfiguration
            tunnelManager.localizedDescription = self.localizedDescription
            tunnelManager.isEnabled = true

            tunnelManager.saveToPreferences { error in
                if let error = error {
                    print("Error (saveToPreferences): \(error)")
                    completion(false)
                } else {
                    tunnelManager.loadFromPreferences { error in
                        if let error = error {
                            print("Error (loadFromPreferences): \(error)")
                            completion(false)
                        } else if let session = tunnelManager.connection as? NETunnelProviderSession {
                            do {
                                try session.startTunnel(options: nil)
                                self.vpnStartTime = Date() 
                                self.providerManager = tunnelManager
                                completion(true)
                            } catch {
                                print("Error (startTunnel): \(error)")
                                completion(false)
                            }
                        } else {
                            completion(false)
                        }
                    }
                }
            }
        }
    }

    func stopVPN(completion: @escaping (Bool?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let session = managers?.first?.connection as? NETunnelProviderSession {
                switch session.status {
                case .connected, .connecting, .reasserting:
                    session.stopTunnel()
                    completion(true)
                default:
                    completion(false)
                }
            } else {
                completion(false)
            }
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

#if os(macOS)
@available(macOS 10.15, *)
extension WireguardFlutterPlugin: OSSystemExtensionRequestDelegate {
    public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("System Extension replacement request: replacing \(existing.bundleVersion) with \(ext.bundleVersion)")
        return .replace
    }
    
    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("System Extension requires user approval in Privacy & Security settings.")
    }
    
    public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("System Extension successfully installed.")
        self.systemExtensionResult?(true)
        self.systemExtensionResult = nil
    }
    
    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        print("System Extension installation failed with error: \(error.localizedDescription)")
        self.systemExtensionResult?(FlutterError(code: "-7", message: "System Extension failed to install", details: error.localizedDescription))
        self.systemExtensionResult = nil
    }
}
#endif
