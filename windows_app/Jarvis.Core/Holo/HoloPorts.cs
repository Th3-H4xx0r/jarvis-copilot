namespace Jarvis.Core.Holo;

// The Windows side effects HoloDropService drives. The WPF app implements each one
// (windows_app/Jarvis/HoloDrop/); Core only decides when and what.

/// Opening and copying (`ShellExecute`, the clipboard). Saving is Core's (HoloLander).
public interface IHoloReceiver
{
    /// Opens a file in its app or a link in the browser.
    bool Open(string pathOrUrl);
    /// The clipboard: an image as a bitmap plus a file drop list, text, a link, or a file drop list.
    bool Copy(HoloDropRecord drop, string? localFile);
}

/// The arrival card and the landed toast. Calls come through the PresentationGate; the adapter
/// marshals to its UI thread and follows `HoloArrival.Changed`.
public interface IHoloCards
{
    void Show(HoloArrival card);
    void Toast(string line, bool failed);
}

/// The direction beacons: an inaudible chirp (`HoloBeaconCode.ChirpSamples` at 48 kHz) and a
/// faint full-screen flash on no-activate windows (`HoloBeaconCode.FlashFrames`).
public interface IHoloBeacons
{
    void Chirp(string nonce);
    void Flash(string nonce);
    void Stop();
}

/// The primary monitor and its windows' outlines (`HoloGeometry.Outlines`), for the sender's map.
public interface IHoloScreenReport
{
    HoloScreen Current();
}

/// `BluetoothLEAdvertisementPublisher` with `HoloBle.Service` and
/// `ManufacturerData(HoloBle.CompanyId, HoloBle.ManufacturerPayload(deviceId))`.
public interface IHoloBleBeacon
{
    void Start(string deviceId);
    void Stop();
}

/// Whether the inbound rule exists (`HoloFirewall.ShowRuleCommand` exits 0).
public interface IHoloFirewall
{
    bool RuleExists();
}

/// The Windows Firewall rule the LAN receiver needs, added through AdminRunner (C6).
public static class HoloFirewall
{
    public const string RuleName = "Jarvis Holo Drop";
    public const string Why = "Let Holo Drop receive on your network";

    public static string AddRuleCommand(string exe) =>
        $"netsh advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow program=\"{exe}\" profile=private enable=yes";

    public static string ShowRuleCommand => $"netsh advfirewall firewall show rule name=\"{RuleName}\"";
}
