package orban.group.wireguard_flutter

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.wgtunnel.backend.system.NetworkMonitor
import com.wgtunnel.backend.system.NetworkSnapshot
import java.net.Inet6Address
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Reports the best physical (non-VPN) network, which is what the tunnel runs over. */
internal class PluginNetworkMonitor(context: Context) : NetworkMonitor {
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val state = MutableStateFlow<NetworkSnapshot?>(null)
    override val networkState: StateFlow<NetworkSnapshot?> = state.asStateFlow()

    private val callback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = refresh()

            override fun onLost(network: Network) = refresh()

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                refresh()

            override fun onLinkPropertiesChanged(
                network: Network,
                linkProperties: android.net.LinkProperties,
            ) = refresh()
        }

    init {
        val request =
            NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
        connectivityManager.registerNetworkCallback(request, callback)
        refresh()
    }

    @Synchronized
    private fun refresh() {
        val best =
            connectivityManager.allNetworks
                .mapNotNull { network ->
                    val caps = connectivityManager.getNetworkCapabilities(network) ?: return@mapNotNull null
                    if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return@mapNotNull null
                    if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@mapNotNull null
                    Triple(network, caps, rank(caps))
                }
                .maxByOrNull { it.third }

        state.value =
            if (best == null) {
                NetworkSnapshot(key = "none", hasIpv6 = false, isUsable = false, network = null)
            } else {
                val (network, caps, _) = best
                NetworkSnapshot(
                    key = "${transportName(caps)}:${network.networkHandle}",
                    hasIpv6 = hasIpv6(network),
                    isUsable = true,
                    network = network,
                )
            }
    }

    // Validated networks first, then ethernet > wifi > cellular.
    private fun rank(caps: NetworkCapabilities): Int {
        var rank = 0
        if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) rank += 10
        rank +=
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 3
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 2
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 1
                else -> 0
            }
        return rank
    }

    private fun transportName(caps: NetworkCapabilities) =
        when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "eth"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cell"
            else -> "other"
        }

    private fun hasIpv6(network: Network): Boolean {
        val properties = connectivityManager.getLinkProperties(network) ?: return false
        val hasGlobalAddress =
            properties.linkAddresses.any {
                val address = it.address
                address is Inet6Address && !address.isLinkLocalAddress && !address.isLoopbackAddress
            }
        val hasDefaultRoute =
            properties.routes.any { it.isDefaultRoute && it.destination.address is Inet6Address }
        return hasGlobalAddress && hasDefaultRoute
    }
}
