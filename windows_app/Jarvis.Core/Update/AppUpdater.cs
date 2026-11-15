using Jarvis.Core.Http;

namespace Jarvis.Core.Update;

/// The in-app updater's flow (the island card drives it): ask the server for a newer Windows
/// build, download it over HTTPS ourselves (no Mark of the Web), check the server's SHA-256 and
/// the zip's layout, stage it, copy JarvisUpdater.exe out of the install folder and launch it.
/// The app then exits and the updater swaps the folders (Swapper).
public sealed class AppUpdater
{
    private readonly ApiClient _api;
    private readonly AppVersion _current;
    private readonly string _work;
    private readonly string _appDir;
    private readonly string _updaterDir;
    private readonly string _log;
    private readonly int _pid;
    private readonly Action<string, string[]> _launch;

    /// `work` = %LOCALAPPDATA%\Jarvis\update, `appDir` = %LOCALAPPDATA%\Programs\Jarvis\app,
    /// `updaterDir` = %LOCALAPPDATA%\Programs\Jarvis\updater.
    public AppUpdater(ApiClient api, AppVersion current, string work, string appDir, string updaterDir, string log, int pid,
        Action<string, string[]> launch)
    {
        _api = api;
        _current = current;
        _work = work;
        _appDir = appDir;
        _updaterDir = updaterDir;
        _log = log;
        _pid = pid;
        _launch = launch;
    }

    public async Task<UpdateOffer?> CheckAsync()
    {
        try
        {
            var j = await _api.GetAsync(UpdateOffer.LatestPath(_current.Build), TimeSpan.FromSeconds(15)).ConfigureAwait(false);
            return UpdateOffer.FromJson(j) is { } o && UpdateOffer.IsNewer(o.Build, _current.Build) ? o : null;
        }
        catch (ApiException)
        {
            return null;
        }
    }

    /// Null when the updater was launched (the caller exits next); else what went wrong.
    public async Task<string?> InstallAsync(UpdateOffer offer, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(_work);
        var zip = Path.Combine(_work, $"{offer.Build}.zip");
        try
        {
            await using (var src = await _api.DownloadAsync(offer.InstallUrl.ToString(), ct).ConfigureAwait(false))
            await using (var dst = File.Create(zip))
            {
                var buf = new byte[81920];
                long done = 0;
                int n;
                while ((n = await src.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                    done += n;
                    if (offer.Size > 0) progress?.Report(Math.Min(1.0, done / (double)offer.Size));
                }
            }
        }
        catch (ApiException e) { return $"The download failed: {e.Error}"; }
        catch (IOException e) { return $"The download failed: {e.Message}"; }

        if (!Sha256Check.Matches(zip, offer.Sha256)) return "The download doesn't match the server's checksum.";
        var staged = Path.Combine(_work, "staged");
        try { ZipLayout.Extract(zip, staged); }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException) { return $"The download couldn't be unpacked: {e.Message}"; }
        if (ZipLayout.Problem(staged, offer.Build) is { } problem) return problem;

        // The updater runs from outside the folder it replaces.
        Directory.CreateDirectory(_updaterDir);
        var updater = Path.Combine(_updaterDir, "JarvisUpdater.exe");
        File.Copy(Path.Combine(staged, ZipLayout.Root, "JarvisUpdater.exe"), updater, overwrite: true);
        _launch(updater, new[]
        {
            "--pid", _pid.ToString(System.Globalization.CultureInfo.InvariantCulture), "--app", _appDir,
            "--new", Path.Combine(staged, ZipLayout.Root), "--exe", "Jarvis.exe", "--log", _log,
        });
        try { File.Delete(zip); } catch (IOException) { }
        return null;
    }
}
