namespace Jarvis.Core.Holo;

/// What a click or a fling does when he doesn't pick: a link opens, text is copied, a file is
/// saved and opened, anything else is saved (the Mac's Orbit defaults).
public static class HoloSendDefaults
{
    public static HoloAction Action(HoloItem item) => item switch
    {
        HoloLinkItem => HoloAction.Open,
        HoloTextItem => HoloAction.Copy,
        HoloFilesItem { Paths.Count: 1 } => HoloAction.SaveOpen,
        _ => HoloAction.Save,
    };

    /// The devices the item can go to: online and accepting every kind in it.
    public static IReadOnlyList<HoloDevice> Targets(IReadOnlyList<HoloDevice> devices, HoloItem item) =>
        devices.Where(d => d.Online && item.Kinds.All(d.AcceptsKind)).ToList();
}
