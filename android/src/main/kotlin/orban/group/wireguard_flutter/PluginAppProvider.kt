package orban.group.wireguard_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.wgtunnel.backend.AndroidApplicationProvider
import com.wgtunnel.backend.Tunnel
import com.wgtunnel.backend.state.BackendStatus
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map

/** Supplies the foreground notification and UI hooks the backend services need. */
internal class PluginAppProvider(
    override val context: Context,
    private val traffic: () -> StateFlow<TrafficSample>,
) : AndroidApplicationProvider {

    @Volatile var displayName: String = "WireGuard VPN"

    private val _statusRefreshes = MutableStateFlow(0)
    val statusRefreshes: StateFlow<Int> = _statusRefreshes

    override val vpnNotificationId: Int = NOTIFICATION_ID
    override val proxyNotificationId: Int = NOTIFICATION_ID + 1

    override val vpnInitNotification: Notification
        get() = buildNotification("VPN is running")

    override val proxyInitNotification: Notification
        get() = buildNotification("VPN is running")

    override val persistentNotificationSignals: Flow<Unit>
        get() = traffic().map { }

    override fun persistentNotificationKey(status: BackendStatus): Any =
        status.toNotificationComparisonKey() to notificationText(status)

    override fun refreshStatusUi() {
        _statusRefreshes.value++
    }

    override fun createVpnConfigurePendingIntent(context: Context): PendingIntent {
        val launchIntent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent()
        return PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    override suspend fun buildVpnPersistentNotification(status: BackendStatus): Notification =
        buildNotification(notificationText(status))

    override suspend fun buildProxyPersistentNotification(status: BackendStatus): Notification =
        buildNotification(notificationText(status))

    private fun notificationText(status: BackendStatus): String {
        val state = status.activeTunnels[PluginTunnel.TUNNEL_ID]?.transportState
        return when (state) {
            is Tunnel.State.Up -> {
                val sample = traffic().value
                "↑ ${formatSpeed(sample.uploadSpeed)} | ↓ ${formatSpeed(sample.downloadSpeed)} | ${sample.durationText}"
            }
            is Tunnel.State.Stopping -> "Disconnecting"
            is Tunnel.State.Starting -> "Connecting"
            else -> "VPN is running"
        }
    }

    private fun formatSpeed(bytesPerSecond: Double) = String.format("%.1f KB/s", bytesPerSecond / 1024)

    private fun buildNotification(text: String): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager?.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "VPN Service", NotificationManager.IMPORTANCE_LOW)
        )
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(displayName)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(createVpnConfigurePendingIntent(context))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "vpn_foreground_channel"
        const val NOTIFICATION_ID = 101
    }
}
