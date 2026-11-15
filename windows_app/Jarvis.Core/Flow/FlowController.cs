using System.Net.Http.Headers;
using System.Text.Json.Nodes;
using Jarvis.Core.Gaming;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Model;

namespace Jarvis.Core.Flow;

public enum PasteResult { Pasted, CopiedOnly }

public interface IPaster
{
    PasteResult Paste(string text);
}

/// The mic for one dictation: 16 kHz mono PCM16, from the first key press to the last.
public interface IFlowCapture
{
    void Start();
    /// Stop and hand back everything heard.
    short[] Stop();
    /// 0..1, for the pill's bands.
    double Level { get; }
}

public interface IClipboardText
{
    string? GetText();
    void SetText(string text);
}

public interface IKeySender
{
    /// Sends key down/up pairs as given: (virtual key, down?).
    bool Send(IReadOnlyList<(ushort Vk, bool Down)> keys);
}

/// Pastes the words where he types: clipboard + Ctrl+V, then puts his clipboard back after
/// 400 ms if nothing else was copied meanwhile. An elevated window in front can't receive
/// synthetic keys from Jarvis (UIPI), so then the words stay on the clipboard for him to paste.
public sealed class FlowPaster : IPaster
{
    public const ushort VkControl = 0x11, VkV = 0x56;
    public static readonly TimeSpan RestoreAfter = TimeSpan.FromMilliseconds(400);

    private readonly IClipboardText _clip;
    private readonly IKeySender _keys;
    private readonly Func<bool> _foregroundElevatedAboveUs;
    private readonly TimeProvider _time;
    private ITimer? _restore;

    public FlowPaster(IClipboardText clip, IKeySender keys, Func<bool> foregroundElevatedAboveUs, TimeProvider? time = null)
    {
        _clip = clip;
        _keys = keys;
        _foregroundElevatedAboveUs = foregroundElevatedAboveUs;
        _time = time ?? TimeProvider.System;
    }

    public PasteResult Paste(string text)
    {
        if (_foregroundElevatedAboveUs())
        {
            _clip.SetText(text);
            return PasteResult.CopiedOnly;
        }
        var saved = _clip.GetText();
        _clip.SetText(text);
        _keys.Send(new[] { (VkControl, true), (VkV, true), (VkV, false), (VkControl, false) });
        _restore?.Dispose();
        _restore = _time.CreateTimer(_ =>
        {
            _restore?.Dispose();
            if (saved != null && _clip.GetText() == text) _clip.SetText(saved);
        }, null, RestoreAfter, Timeout.InfiniteTimeSpan);
        return PasteResult.Pasted;
    }
}

/// His Flow settings, read at each dictation.
public sealed record FlowSettings(
    IReadOnlyList<string> Words, IReadOnlyList<FlowReplacement> Replacements, IReadOnlyList<FlowSnippet> Snippets,
    IReadOnlyList<FlowAppStyle> Styles, FlowStyle DefaultStyle, bool CleanupOn, string? Model, string? Provider)
{
    public static readonly FlowSettings Default = new(Array.Empty<string>(), Array.Empty<FlowReplacement>(), Array.Empty<FlowSnippet>(),
        FlowAppStyle.Defaults, FlowStyle.natural, false, null, null);
}

/// One Flow dictation from key to paste: the key logic, capture, `/api/transcribe` (his Speech
/// engine choice for uploads), FlowText, the optional clean-up, then the paste. Nothing starts
/// while a game is on (no paste may reach a game).
public sealed class FlowController
{
    private readonly ApiClient _api;
    private readonly Func<string?> _origin;
    private readonly IPaster _paster;
    private readonly IFlowCapture _capture;
    private readonly Func<GameMode> _gameMode;
    private readonly Func<FlowSettings> _settings;
    private readonly Func<string?> _frontExe;
    private readonly TimeProvider _time;
    private FlowKeyLogic _logic;
    private DateTimeOffset _startedAt;

    public FlowController(ApiClient api, Func<string?> origin, IPaster paster, IFlowCapture capture, Func<GameMode> gameMode,
        Func<FlowSettings> settings, Func<string?> frontExe, TimeProvider? time = null)
    {
        _api = api;
        _origin = origin;
        _paster = paster;
        _capture = capture;
        _gameMode = gameMode;
        _settings = settings;
        _frontExe = frontExe;
        _time = time ?? TimeProvider.System;
    }

    public enum Phase { Idle, Listening, Working }

    public Phase State { get; private set; }
    public bool Locked => _logic.Phase == FlowKeyLogic.PhaseKind.Locked;
    public string? LastError { get; private set; }
    public PasteResult? LastPaste { get; private set; }
    public FlowStats Stats { get; } = new();
    public event Action? Changed;
    public event Action<string>? Pasted;
    /// The last task (tests await it).
    public Task Pending { get; private set; } = Task.CompletedTask;

    public void OnKey(bool down, double t) => Apply(down ? _logic.KeyDown(t) : _logic.KeyUp(t));
    public void OnOtherKey() => Apply(_logic.OtherKey());
    public void OnEscape() => Apply(_logic.Escape());
    public void Tick(double t) => Apply(_logic.Tick(t));
    public bool TickNeeded => _logic.Phase == FlowKeyLogic.PhaseKind.TapWait;

    private void Apply(FlowKeyLogic.Action a)
    {
        switch (a)
        {
            case FlowKeyLogic.Action.Start:
                if (ComputerControlGuard.Refusal(_gameMode()) != null) { _logic.Reset(); return; }
                Begin();
                break;
            case FlowKeyLogic.Action.Restart:
                _capture.Stop();
                if (ComputerControlGuard.Refusal(_gameMode()) != null) { _logic.Reset(); State = Phase.Idle; break; }
                Begin();
                break;
            case FlowKeyLogic.Action.Finish:
                if (State != Phase.Listening) break;
                var samples = _capture.Stop();
                State = Phase.Working;
                Pending = FinishAsync(samples);
                break;
            case FlowKeyLogic.Action.Cancel:
                if (State == Phase.Listening) _capture.Stop();
                State = Phase.Idle;
                break;
        }
        Changed?.Invoke();
    }

    private void Begin()
    {
        LastError = null;
        _startedAt = _time.GetUtcNow();
        _capture.Start();
        State = Phase.Listening;
    }

    private async Task FinishAsync(short[] samples)
    {
        try
        {
            if (samples.Length < 16000 / 4) return;   // under 0.25 s: nothing said
            var heard = await TranscribeAsync(samples).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(heard)) return;
            var s = _settings();
            var exe = _frontExe();
            var style = FlowAppStyle.Resolve(exe, s.Styles, s.DefaultStyle);
            var prepared = FlowText.Prepare(heard, s.Words, s.Replacements, s.Snippets);
            var text = prepared.Text;
            if (prepared.Snippets.Count == 0 && FlowCleanup.WorthCleaning(text, style, s.CleanupOn))
                text = await CleanAsync(text, style, exe, s).ConfigureAwait(false);
            var final = FlowText.Finish(text, prepared.Snippets);
            // Re-check: a game may have come forward while the words were transcribed.
            if (ComputerControlGuard.Refusal(_gameMode()) != null) return;
            LastPaste = _paster.Paste(final);
            Stats.Add(FlowText.WordCount(final), (_time.GetUtcNow() - _startedAt).TotalSeconds, exe, FlowText.DayKey(_time.GetLocalNow()));
            Pasted?.Invoke(final);
        }
        catch (ApiException e)
        {
            LastError = e.Error;
        }
        finally
        {
            State = Phase.Idle;
            Changed?.Invoke();
        }
    }

    private async Task<string> TranscribeAsync(short[] samples)
    {
        var origin = _origin() ?? throw new ApiException(0, ApiClient.NotConnected);
        var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(Wav.Pcm16Mono(samples, 16000));
        file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        form.Add(file, "file", "flow.wav");
        var reply = await _api.PostAbsoluteAsync(new Uri(origin.TrimEnd('/') + "/api/transcribe"), form,
            new Dictionary<string, string>(), TimeSpan.FromSeconds(30)).ConfigureAwait(false);
        if (reply["ok"] is not null && !J.B(reply["ok"])) throw new ApiException(0, J.S(reply["error"], "Couldn't transcribe."));
        return J.S(reply["transcript"], J.S(reply["text"]));
    }

    private async Task<string> CleanAsync(string text, FlowStyle style, string? exe, FlowSettings s)
    {
        try
        {
            var r = await _api.PostAsync("/api/flow/cleanup", FlowCleanup.Body(text, style, exe, s.Words, s.Model, s.Provider), FlowCleanup.Timeout)
                .ConfigureAwait(false);
            var cleaned = J.S(r["text"]);
            return J.B(r["cleaned"]) && FlowCleanup.Plausible(cleaned, text) ? cleaned : text;
        }
        catch (Exception e) when (e is ApiException or TaskCanceledException or HttpRequestException)
        {
            return text;
        }
    }
}
