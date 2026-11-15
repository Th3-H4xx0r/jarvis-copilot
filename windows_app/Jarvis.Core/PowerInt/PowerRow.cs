using System.Text.Json.Nodes;
using Jarvis.Core.Http;
using Jarvis.Core.Link;

namespace Jarvis.Core.PowerInt;

public enum PowerSettingKind { Toggle, Text, Number, Picker, Secret }

public sealed record PowerOption(string Value, string Label);

/// One field on a Power integration's settings form (`settings_schema`; port of PowerModels.swift).
public sealed record PowerSetting(string Key, string Label, PowerSettingKind Kind, string Help,
    IReadOnlyList<PowerOption> Options, double? Min, double? Max, string Unit)
{
    public static PowerSetting? FromJson(JsonObject o)
    {
        var key = J.S(o["key"]);
        PowerSettingKind? kind = J.S(o["kind"]) switch
        {
            "toggle" => PowerSettingKind.Toggle, "text" => PowerSettingKind.Text, "number" => PowerSettingKind.Number,
            "picker" => PowerSettingKind.Picker, "secret" => PowerSettingKind.Secret, _ => null,
        };
        if (key.Length == 0 || kind is not { } k) return null;
        var options = J.Arr(o["options"]).Where(x => x["value"] != null)
            .Select(x => new PowerOption(Scalar(x["value"]), J.StrOrNull(x["label"]) ?? Scalar(x["value"]))).ToList();
        return new PowerSetting(key, J.S(o["label"], key), k, J.S(o["help"]), options, J.D(o["min"]), J.D(o["max"]), J.S(o["unit"]));
    }

    internal static string Scalar(JsonNode? n) => n is JsonValue v
        ? (v.TryGetValue<string>(out var s) ? s : v.ToJsonString())
        : n?.ToJsonString() ?? "";
}

/// A settings value as the server sent it. A secret only says whether it's set.
public abstract record PowerValue
{
    public sealed record Bool(bool Value) : PowerValue;
    public sealed record Number(double Value) : PowerValue;
    public sealed record Text(string Value) : PowerValue;
    public sealed record SecretSet(bool IsSet) : PowerValue;
    public sealed record None : PowerValue;

    public static PowerValue From(JsonNode? raw, PowerSettingKind kind)
    {
        if (kind == PowerSettingKind.Secret && raw is JsonObject o) return new SecretSet(J.B(o["set"]));
        if (raw is not JsonValue v) return new None();
        if (kind == PowerSettingKind.Toggle && v.TryGetValue<bool>(out var b)) return new Bool(b);
        if (kind == PowerSettingKind.Number && J.D(v) is { } d) return new Number(d);
        if (v.TryGetValue<string>(out var s)) return new Text(s);
        return v.TryGetValue<bool>(out _) ? new None() : new Text(v.ToJsonString());
    }
}

/// One Power integration as `/api/power` describes it.
public sealed record PowerRow(string Id, string Name, string Summary, bool Enabled, bool Protected, bool Pending,
    string StatusLine, string? Error, IReadOnlyList<PowerSetting> SettingsSchema, IReadOnlyDictionary<string, PowerValue> Settings)
{
    public static PowerRow? FromJson(JsonObject o)
    {
        var id = J.S(o["id"]);
        if (id.Length == 0) return null;
        var schema = J.Arr(o["settings_schema"]).Select(PowerSetting.FromJson).OfType<PowerSetting>().ToList();
        var values = J.Obj(o["settings"]);
        return new PowerRow(id, J.S(o["name"], id), J.S(o["summary"]),
            o["enabled"] is null || J.B(o["enabled"]), J.B(o["protected"]), J.B(o["pending"]),
            J.S(o["status_line"]), J.StrOrNull(o["error"]) is { Length: > 0 } e ? e : null,
            schema, schema.ToDictionary(s => s.Key, s => PowerValue.From(values[s.Key], s.Kind)));
    }

    /// The pane's status under the name.
    public string Line => Pending ? "Waiting for Face ID on your iPhone" : Error ?? StatusLine;
}

public abstract record PowerSetResult
{
    public sealed record Done : PowerSetResult;
    /// Waiting for Face ID on his iPhone (a protected integration, or a guarded setting).
    public sealed record Pending : PowerSetResult;
    public sealed record Failed(string Error) : PowerSetResult;
}

/// `/api/power`: the Power integrations, their switches and settings, as the "pc" client.
public sealed class PowerApi
{
    public const string Prefix = "/api/power";
    public const string Client = "pc";

    private readonly ApiClient _api;

    public PowerApi(ApiClient api) => _api = api;

    public async Task<IReadOnlyList<PowerRow>> ListAsync()
    {
        var body = await _api.GetAsync(Prefix, TimeSpan.FromSeconds(30));
        return J.Arr(body["integrations"]).Select(PowerRow.FromJson).OfType<PowerRow>().ToList();
    }

    /// `{enabled}` and/or `{settings}`.
    public async Task<PowerSetResult> ChangeAsync(string id, JsonObject body)
    {
        var payload = (JsonObject)body.DeepClone();
        payload["client"] = Client;
        try
        {
            var reply = await _api.PostAsync(Prefix + "/" + Uri.EscapeDataString(id), payload, TimeSpan.FromSeconds(60));
            if (reply["pending"] is not null && J.B(reply["pending"])) return new PowerSetResult.Pending();
            if (reply["ok"] is not null && !J.B(reply["ok"])) return new PowerSetResult.Failed(J.S(reply["error"], "Couldn't change it."));
            return new PowerSetResult.Done();
        }
        catch (ApiException e)
        {
            return new PowerSetResult.Failed(e.Error);
        }
    }
}
