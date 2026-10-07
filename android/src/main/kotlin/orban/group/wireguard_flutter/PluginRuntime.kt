package orban.group.wireguard_flutter

import android.content.Context
import com.wgtunnel.backend.Backend
import com.wgtunnel.backend.TunnelBackend
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow

/**
 * Process-wide backend. It must outlive Flutter engines: the VPN services keep running and talk to
 * the same backend instance.
 */
internal class PluginRuntime private constructor(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private lateinit var trafficTracker: TrafficTracker

    val provider = PluginAppProvider(context) { trafficTracker.sample }
    val backend: Backend = TunnelBackend(scope, provider, PluginNetworkMonitor(context))

    init {
        trafficTracker = TrafficTracker(scope, backend)
    }

    val traffic: StateFlow<TrafficSample>
        get() = trafficTracker.sample

    companion object {
        @Volatile private var instance: PluginRuntime? = null

        fun get(context: Context): PluginRuntime =
            instance
                ?: synchronized(this) {
                    instance ?: PluginRuntime(context.applicationContext).also { instance = it }
                }
    }
}
