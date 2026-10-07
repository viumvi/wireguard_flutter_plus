package orban.group.wireguard_flutter

import com.wgtunnel.backend.Backend
import com.wgtunnel.backend.Tunnel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

internal data class TrafficSample(
    val totalRx: Long = 0,
    val totalTx: Long = 0,
    val downloadSpeed: Double = 0.0, // bytes per second
    val uploadSpeed: Double = 0.0,
    val durationSeconds: Long = 0,
) {
    val durationText: String
        get() = String.format("%02d:%02d:%02d", durationSeconds / 3600, durationSeconds / 60 % 60, durationSeconds % 60)
}

/** Derives traffic counters and speeds from the backend's periodically refreshed ActiveConfig. */
internal class TrafficTracker(scope: CoroutineScope, backend: Backend) {
    private val _sample = MutableStateFlow(TrafficSample())
    val sample: StateFlow<TrafficSample> = _sample.asStateFlow()

    private var lastStatsAtMs = 0L
    private var lastRx = 0L
    private var lastTx = 0L

    init {
        scope.launch {
            backend.status.collect { status ->
                val active = status.activeTunnels[PluginTunnel.TUNNEL_ID]
                val config = active?.activeConfig
                if (active == null || active.transportState !is Tunnel.State.Up || config == null) {
                    lastStatsAtMs = 0L
                    _sample.value = TrafficSample()
                    return@collect
                }
                if (active.lastStatsAtMs == lastStatsAtMs) return@collect

                val rx = config.peers.sumOf { it.rxBytes ?: 0L }
                val tx = config.peers.sumOf { it.txBytes ?: 0L }
                val elapsedSeconds = (active.lastStatsAtMs - lastStatsAtMs) / 1000.0
                val hasPrevious = lastStatsAtMs != 0L && elapsedSeconds > 0
                _sample.value =
                    TrafficSample(
                        totalRx = rx,
                        totalTx = tx,
                        downloadSpeed = if (hasPrevious) (rx - lastRx).coerceAtLeast(0) / elapsedSeconds else 0.0,
                        uploadSpeed = if (hasPrevious) (tx - lastTx).coerceAtLeast(0) / elapsedSeconds else 0.0,
                        durationSeconds = ((System.currentTimeMillis() - (active.uptime ?: System.currentTimeMillis())) / 1000)
                            .coerceAtLeast(0),
                    )
                lastStatsAtMs = active.lastStatsAtMs
                lastRx = rx
                lastTx = tx
            }
        }
    }
}
