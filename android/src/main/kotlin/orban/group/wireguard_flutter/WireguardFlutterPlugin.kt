package orban.group.wireguard_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import com.wgtunnel.backend.Tunnel
import com.wgtunnel.backend.model.BackendMode
import com.wgtunnel.backend.state.BackendStatus
import com.wgtunnel.parser.Config
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

const val PERMISSIONS_REQUEST_CODE = 10014
const val METHOD_CHANNEL_NAME = "orban.group.wireguard_flutter_plus/wgcontrol"
const val METHOD_EVENT_NAME = "orban.group.wireguard_flutter_plus/wgstage"
const val TRAFFIC_EVENT_NAME = "orban.group.wireguard_flutter_plus/traffic"

private const val TAG = "NVPN"

/** WireguardFlutterPlugin: AmneziaWG tunnel for Flutter, backed by wgtunnel/core. */
class WireguardFlutterPlugin :
    FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var trafficEvents: EventChannel
    private lateinit var context: Context
    private lateinit var runtime: PluginRuntime

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var stageJob: Job? = null
    private var trafficJob: Job? = null

    private var vpnStageSink: EventChannel.EventSink? = null
    private var trafficSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var permissionCallback: ((Boolean) -> Unit)? = null

    private var tunnelName: String = "vpn"
    private var currentStage: String = "disconnected"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL_NAME)
        events = EventChannel(binding.binaryMessenger, METHOD_EVENT_NAME)
        trafficEvents = EventChannel(binding.binaryMessenger, TRAFFIC_EVENT_NAME)
        context = binding.applicationContext
        runtime = PluginRuntime.get(context)

        channel.setMethodCallHandler(this)
        events.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    vpnStageSink = sink
                    sink?.success(currentStage)
                }

                override fun onCancel(arguments: Any?) {
                    vpnStageSink = null
                }
            }
        )
        trafficEvents.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    trafficSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    trafficSink = null
                }
            }
        )

        stageJob =
            scope.launch {
                runtime.backend.status
                    .map { it.toStage() }
                    .distinctUntilChanged()
                    .collect { updateStage(it) }
            }
        trafficJob =
            scope.launch {
                runtime.traffic.collect { sample ->
                    trafficSink?.success(
                        mapOf(
                            // bytes and bytes/s, like on iOS
                            "totalDownload" to sample.totalRx,
                            "totalUpload" to sample.totalTx,
                            "downloadSpeed" to sample.downloadSpeed,
                            "uploadSpeed" to sample.uploadSpeed,
                            "duration" to sample.durationText,
                        )
                    )
                }
            }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        trafficEvents.setStreamHandler(null)
        stageJob?.cancel()
        trafficJob?.cancel()
        vpnStageSink = null
        trafficSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PERMISSIONS_REQUEST_CODE) return false
        permissionCallback?.invoke(resultCode == Activity.RESULT_OK)
        permissionCallback = null
        return true
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                tunnelName = call.argument<String>("localizedDescription") ?: tunnelName
                runtime.provider.displayName = call.argument<String>("vpnName") ?: "WireGuard VPN"
                result.success(null)
            }
            "checkVpnPermission" -> requestVpnPermission { granted -> result.success(granted) }
            "checkPermission" -> {
                requestVpnPermission {}
                result.success(null)
            }
            "start" -> {
                val config =
                    withApplicationLists(
                        call.argument<String>("wgQuickConfig").orEmpty(),
                        call.argument<String>("excludedApps"),
                        call.argument<String>("includedApps"),
                    )
                connect(config, result)
            }
            "stop" -> disconnect(result)
            "stage" -> result.success(runtime.backend.status.value.toStage())
            "refresh" -> result.success(null)
            "getDownloadData" -> result.success(runtime.traffic.value.totalRx)
            "getUploadData" -> result.success(runtime.traffic.value.totalTx)
            else -> result.notImplemented()
        }
    }

    private fun withApplicationLists(config: String, excluded: String?, included: String?): String {
        var final = config
        val header = Regex("(?i)\\[Interface]")
        if (!excluded.isNullOrEmpty()) {
            final = final.replaceFirst(header, "[Interface]\nExcludedApplications = $excluded")
        }
        if (!included.isNullOrEmpty()) {
            final = final.replaceFirst(header, "[Interface]\nIncludedApplications = $included")
        }
        return final
    }

    private fun connect(wgQuickConfig: String, result: Result) {
        requestVpnPermission { granted ->
            if (!granted) {
                result.error("PERMISSION_DENIED", "User denied VPN permission", null)
                return@requestVpnPermission
            }
            scope.launch(Dispatchers.IO) {
                try {
                    val backend = runtime.backend
                    val active = backend.status.value.activeTunnels[PluginTunnel.TUNNEL_ID]
                    if (active?.transportState is Tunnel.State.Up) {
                        Log.i(TAG, "Tunnel is already up, skipping connect")
                        reply { result.success("") }
                        return@launch
                    }

                    updateStage("prepare")
                    val config = Config.parseQuickString(wgQuickConfig)
                    config.validate()

                    updateStage("connecting")
                    backend
                        .start(PluginTunnel(tunnelName), BackendMode.Vpn(config))
                        .getOrThrow()

                    Log.i(TAG, "Connect - success")
                    reply { result.success("") }
                } catch (e: Throwable) {
                    Log.e(TAG, "Connect failed: ${e.message}", e)
                    updateStage(runtime.backend.status.value.toStage())
                    reply { result.error(e.message ?: e.javaClass.simpleName, null, null) }
                }
            }
        }
    }

    private fun disconnect(result: Result) {
        scope.launch(Dispatchers.IO) {
            try {
                val backend = runtime.backend
                if (backend.status.value.activeTunnels.containsKey(PluginTunnel.TUNNEL_ID)) {
                    backend.stop(PluginTunnel.TUNNEL_ID).getOrThrow()
                }
                reply { result.success("") }
            } catch (e: Throwable) {
                Log.e(TAG, "Disconnect failed: ${e.message}", e)
                reply { result.error(e.message ?: e.javaClass.simpleName, null, null) }
            }
        }
    }

    /** Asks for the system VPN consent if it has not been granted yet. */
    private fun requestVpnPermission(callback: (Boolean) -> Unit) {
        val intent = VpnService.prepare(context)
        if (intent == null) {
            callback(true)
            return
        }
        val current = activity
        if (current == null) {
            callback(false)
            return
        }
        permissionCallback = callback
        current.startActivityForResult(intent, PERMISSIONS_REQUEST_CODE)
    }

    // MethodChannel results must be delivered on the main thread.
    private fun reply(block: () -> Unit) {
        scope.launch(Dispatchers.Main) { block() }
    }

    private fun updateStage(stage: String) {
        scope.launch(Dispatchers.Main) {
            currentStage = stage
            vpnStageSink?.success(stage)
        }
    }

    private fun BackendStatus.toStage(): String =
        when (activeTunnels[PluginTunnel.TUNNEL_ID]?.transportState) {
            null,
            is Tunnel.State.Down -> "disconnected"
            is Tunnel.State.Starting -> "connecting"
            is Tunnel.State.Stopping -> "disconnecting"
            is Tunnel.State.Up -> "connected"
        }
}
