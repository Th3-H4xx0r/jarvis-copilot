using System.Text;

namespace Jarvis.Core.Holo;

public enum HoloArrivalState { Receiving, Ready, Failed }

/// One arrival card's model (port of `HoloCardModel`'s data). The service fills it in; the
/// adapter redraws on `Changed`.
public sealed class HoloArrival
{
    public HoloArrival(HoloDropRecord drop, string fromName, DateTimeOffset arrived)
    {
        Drop = drop;
        FromName = fromName;
        Arrived = arrived;
    }

    public HoloDropRecord Drop { get; }
    public string FromName { get; }
    public DateTimeOffset Arrived { get; }
    public HoloArrivalState State { get; internal set; } = HoloArrivalState.Ready;
    public string? Error { get; internal set; }
    /// The fetched bytes (in the inbox, or where Save moved them).
    public string? LocalFile { get; internal set; }
    public string? SavedFile { get; internal set; }
    public bool Copied { get; internal set; }
    /// Text asked to "open": shown in full on the card.
    public bool Expanded { get; internal set; }
    public string? Note { get; internal set; }
    public HoloOutcome? Outcome { get; internal set; }

    /// A picture card (the photo or the video's frame fills it); else the compact title row.
    public bool IsPicture => Drop.Kind is HoloKind.Image or HoloKind.Video;

    public event Action? Changed;

    internal void Notify() => Changed?.Invoke();

    /// "From iPhone · just now".
    public string FromLine(DateTimeOffset now)
    {
        var at = Drop.Created ?? Arrived;
        var secs = Math.Max(0, (now - at).TotalSeconds);
        var when = secs < 60 ? "just now" : secs < 3_600 ? $"{(int)(secs / 60)} min ago" : "earlier";
        return $"From {FromName} · {when}";
    }
}

/// The file side of landing (port of `HoloReceiver.intoInbox` / `save`): fetched bytes go to the
/// drop's own inbox folder (marked as from the internet), and Save writes into the Holo Drop
/// folder, never over an existing file: the file itself, a `.url` for a link, a `.txt` for text.
public sealed class HoloLander
{
    private readonly TimeProvider _time;

    public HoloLander(string saveFolder, string tempRoot, TimeProvider? time = null)
    {
        SaveFolder = saveFolder;
        Inbox = Path.Combine(tempRoot, HoloTemp.Inbox);
        _time = time ?? TimeProvider.System;
    }

    public string SaveFolder { get; }
    public string Inbox { get; }

    /// `%USERPROFILE%\Downloads\Holo Drop`.
    public static string DefaultSaveFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Holo Drop");

    /// The fetched bytes under a safe name in this drop's own folder (two drops of the same file
    /// never collide).
    public string IntoInbox(string tmp, HoloDropRecord drop)
    {
        var folder = Path.Combine(Inbox, drop.Id.Length == 0 ? Guid.NewGuid().ToString("N") : HoloFiles.SafeName(drop.Id));
        Directory.CreateDirectory(folder);
        var dest = Path.Combine(folder, HoloFiles.SafeName(drop.Name, "Holo Drop"));
        if (File.Exists(dest)) File.Delete(dest);
        File.Move(tmp, dest);
        // The download's or LAN upload's own folder is empty now.
        var parent = Path.GetDirectoryName(tmp);
        var parentName = parent == null ? "" : Path.GetFileName(parent);
        if (parent != null && (parentName.StartsWith(HoloTemp.Prefix + "lan-", StringComparison.Ordinal)
                               || parentName.StartsWith(HoloTemp.Prefix + "dl-", StringComparison.Ordinal)))
        {
            try { Directory.Delete(parent, true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        MarkFromInternet(dest);
        return dest;
    }

    /// The written file itself: its final name decides (the sender's name may differ).
    public static bool UnsafeToOpen(string file) => HoloLanding.IsExecutable(Path.GetFileName(file), "");

    /// Into the Holo Drop folder, never over an existing file. Null when nothing was written.
    public string? Save(HoloDropRecord drop, string? local)
    {
        try
        {
            Directory.CreateDirectory(SaveFolder);
            string Dest(string name) =>
                Path.Combine(SaveFolder, HoloFiles.Unique(HoloFiles.SafeName(name), n => File.Exists(Path.Combine(SaveFolder, n))));
            switch (drop.Kind)
            {
                case HoloKind.Image:
                case HoloKind.Video:
                case HoloKind.File:
                {
                    if (local == null) return null;
                    var to = Dest(drop.Name.Length == 0 ? Path.GetFileName(local) : drop.Name);
                    File.Move(local, to);
                    MarkFromInternet(to);
                    return to;
                }
                case HoloKind.Link:
                {
                    var target = drop.Url.Length == 0 ? drop.Text : drop.Url;
                    if (target.Length == 0) return null;
                    var to = Dest(HoloFiles.SafeName(drop.DisplayName, "Link") + ".url");
                    File.WriteAllText(to, HoloLanding.LinkFileBody(target), new UTF8Encoding(false));
                    return to;
                }
                default:
                {
                    var stamp = _time.GetLocalNow().ToString("yyyy-MM-dd HH.mm", System.Globalization.CultureInfo.InvariantCulture);
                    var to = Dest($"Holo Drop text {stamp}.txt");
                    File.WriteAllText(to, drop.Text, new UTF8Encoding(false));
                    return to;
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// The Mark of the Web (zone 3, Internet), so SmartScreen and Office check what came from
    /// another device. NTFS only; elsewhere a no-op.
    public static void MarkFromInternet(string file)
    {
        if (!OperatingSystem.IsWindows()) return;
        try { File.WriteAllText(file + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=about:internet\r\n"); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException) { }
    }
}
