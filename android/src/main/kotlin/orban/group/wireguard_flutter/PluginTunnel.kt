package orban.group.wireguard_flutter

import com.wgtunnel.backend.Tunnel

/** The single tunnel managed by the plugin. */
internal class PluginTunnel(override val name: String) : Tunnel {
    override val id: Int = TUNNEL_ID
    override val isMetered: Boolean = false
    override val scriptsEnabled: Boolean = false
    override val ipStrategy: Tunnel.IpStrategy = Tunnel.IpStrategy.Ipv4Only

    // The monitor keeps ActiveConfig (rx/tx counters) fresh once a second for the traffic stats.
    override val features: Set<Tunnel.Feature> = setOf(Tunnel.Feature.ActiveConfigMonitor(1))

    override fun updateState(state: Tunnel.State) = Unit

    companion object {
        const val TUNNEL_ID = 1
    }
}
