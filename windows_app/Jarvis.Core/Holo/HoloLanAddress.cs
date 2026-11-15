using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Jarvis.Core.Holo;

/// One IPv4 address on one interface.
public sealed record HoloLanCandidate(string Name, string Ip, bool Up, bool WifiOrEthernet, bool HasGateway);

/// The PC's address on the local network (port of `HoloLanAddress`, Windows rules): the IPv4 of
/// an up Wi-Fi/Ethernet interface with a default gateway; never loopback, link-local or
/// Tailscale's 100.64.0.0/10.
public static class HoloLanAddress
{
    public static string? Pick(IEnumerable<HoloLanCandidate> candidates) =>
        candidates.FirstOrDefault(c => c.Up && c.WifiOrEthernet && c.HasGateway && Usable(c.Ip))?.Ip;

    public static bool Usable(string ip)
    {
        if (!IPAddress.TryParse(ip, out var a) || a.AddressFamily != AddressFamily.InterNetwork) return false;
        var b = a.GetAddressBytes();
        if (b[0] == 127 || b[0] == 0) return false;
        if (b[0] == 169 && b[1] == 254) return false;
        if (b[0] == 100 && (b[1] & 0xC0) == 64) return false;   // 100.64.0.0/10 (Tailscale, CGNAT)
        return true;
    }

    /// The live pick (works on any OS; the PC is the one that matters).
    public static string? Current()
    {
        try
        {
            var list = new List<HoloLanCandidate>();
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                var kind = ni.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet
                    or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetT or NetworkInterfaceType.FastEthernetFx;
                IPInterfaceProperties props;
                try { props = ni.GetIPProperties(); }
                catch (NetworkInformationException) { continue; }
                var gateway = props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork
                                                              && !g.Address.Equals(IPAddress.Any));
                foreach (var u in props.UnicastAddresses)
                {
                    if (u.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    list.Add(new HoloLanCandidate(ni.Name, u.Address.ToString(), ni.OperationalStatus == OperationalStatus.Up, kind, gateway));
                }
            }
            // Wired before wireless when both are up.
            return Pick(list.OrderBy(c => c.Name.Contains("Wi-Fi", StringComparison.OrdinalIgnoreCase) ? 1 : 0));
        }
        catch (Exception e) when (e is NetworkInformationException or PlatformNotSupportedException)
        {
            return null;
        }
    }
}
