using Jarvis.Core.Admin;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.PowerInt;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.PowerInt;

public class PowerTests
{
    [Fact]
    public void PowerRow_ParsesProtectedPending()
    {
        var row = PowerRow.FromJson(J.Parse("{\"id\":\"holo-drop\",\"protected\":true,\"pending\":true,\"settings_schema\":[{\"key\":\"k\",\"kind\":\"toggle\"},{\"key\":\"s\",\"kind\":\"secret\"},{\"key\":\"n\",\"kind\":\"number\",\"min\":1,\"max\":9},{\"key\":\"p\",\"kind\":\"picker\",\"options\":[{\"value\":2,\"label\":\"Two\"},{\"value\":\"x\"}]}],\"settings\":{\"k\":true,\"s\":{\"set\":true},\"n\":4,\"p\":\"x\"}}"))!;
        Assert.True(row.Protected);
        Assert.True(row.Pending);
        Assert.True(row.Enabled);
        Assert.Equal(new PowerValue.Bool(true), row.Settings["k"]);
        Assert.Equal(new PowerValue.SecretSet(true), row.Settings["s"]);
        Assert.Equal(new PowerValue.Number(4), row.Settings["n"]);
        Assert.Equal(new PowerValue.Text("x"), row.Settings["p"]);
        Assert.Equal(new[] { new PowerOption("2", "Two"), new PowerOption("x", "x") }, row.SettingsSchema[3].Options);
        Assert.Equal("Waiting for Face ID on your iPhone", row.Line);
    }

    [Fact]
    public void PowerRow_SkipsUnknownKindsAndNoId()
    {
        Assert.Null(PowerRow.FromJson(J.Parse("{\"name\":\"x\"}")));
        var row = PowerRow.FromJson(J.Parse("{\"id\":\"a\",\"enabled\":false,\"settings_schema\":[{\"key\":\"k\",\"kind\":\"weird\"}]}"))!;
        Assert.False(row.Enabled);
        Assert.Empty(row.SettingsSchema);
    }

    [Fact]
    public async Task List_ReadsIntegrations()
    {
        var h = new FakeHttp(_ => FakeHttp.Json("{\"integrations\":[{\"id\":\"a\"},{\"id\":\"b\"},{}]}"));
        var rows = await new PowerApi(new ApiClient(() => "http://o", h)).ListAsync();
        Assert.Equal(new[] { "a", "b" }, rows.Select(r => r.Id));
        Assert.Equal("/api/power", h.Requests[0].Path);
    }

    [Fact]
    public async Task Change_SendsClientPc()
    {
        var h = new FakeHttp(_ => FakeHttp.Json("{\"ok\":true}"));
        var r = await new PowerApi(new ApiClient(() => "http://o", h)).ChangeAsync("holo-drop", new JsonObject { ["enabled"] = false });
        Assert.Equal("/api/power/holo-drop", h.Requests[0].Path);
        Assert.Equal("{\"client\":\"pc\",\"enabled\":false}", J.SortedJson(J.Parse(h.Requests[0].Body!)));
        Assert.IsType<PowerSetResult.Done>(r);
    }

    [Fact]
    public async Task Change_PendingReply_IsPending()
    {
        var h = new FakeHttp(_ => FakeHttp.Json("{\"pending\":true}"));
        Assert.IsType<PowerSetResult.Pending>(await new PowerApi(new ApiClient(() => "http://o", h)).ChangeAsync("x", new JsonObject()));
    }

    [Fact]
    public async Task Change_Refused_IsFailedWithError()
    {
        var h = new FakeHttp(_ => FakeHttp.Json("{\"ok\":false,\"error\":\"no\"}"));
        Assert.Equal(new PowerSetResult.Failed("no"), await new PowerApi(new ApiClient(() => "http://o", h)).ChangeAsync("x", new JsonObject()));
    }
}

public class AdminRunnerTests
{
    [Fact]
    public async Task Admin_SendsExactRequest()
    {
        var link = new FakeLink { Reply = _ => J.Parse("{\"ok\":true,\"status\":\"approved\"}") };
        await new AdminRunner(link).RunAsync("netsh advfirewall …", "Let Holo Drop receive on your network");
        var sent = (JsonObject)link.Sent[0].DeepClone();
        sent.Remove("id");
        Assert.Equal("{\"command\":\"netsh advfirewall …\",\"type\":\"admin_run\",\"why\":\"Let Holo Drop receive on your network\"}", J.SortedJson(sent));
    }

    [Theory]
    [InlineData("{\"ok\":true,\"status\":\"approved\"}", AdminStatus.Approved, "Approved on your iPhone. Click Yes on Windows' prompt to finish.")]
    [InlineData("{\"ok\":false,\"status\":\"denied\"}", AdminStatus.Denied, "Denied on your iPhone. Nothing was run.")]
    [InlineData("{\"ok\":false,\"status\":\"timeout\"}", AdminStatus.Timeout, "No answer from your iPhone in 2 minutes. Nothing was run.")]
    [InlineData("{\"ok\":false,\"error\":\"boom\"}", AdminStatus.Failed, "Couldn't ask: boom")]
    public async Task Admin_MapsReplies(string reply, AdminStatus status, string message)
    {
        var link = new FakeLink { Reply = _ => J.Parse(reply) };
        var r = await new AdminRunner(link).RunAsync("x", "y");
        Assert.Equal(status, r.Kind);
        Assert.Equal(message, r.Message);
    }

    [Fact]
    public async Task Admin_LinkDown_FailsWithDownError()
    {
        var link = new FakeLink { Reply = _ => new JsonObject { ["ok"] = false, ["error"] = JcLink.DownError } };
        var r = await new AdminRunner(link).RunAsync("x", "y");
        Assert.Equal(AdminStatus.Failed, r.Kind);
        Assert.Equal($"Couldn't ask: {JcLink.DownError}", r.Message);
    }

    [Fact]
    public async Task Admin_RaisesAskingThenDone()
    {
        var link = new FakeLink { Reply = _ => J.Parse("{\"ok\":false,\"status\":\"denied\"}") };
        var runner = new AdminRunner(link);
        var seen = new List<string>();
        runner.Asking += why => seen.Add("asking:" + why);
        runner.Done += r => seen.Add("done:" + r.Status);
        await runner.RunAsync("x", "why");
        Assert.Equal(new[] { "asking:why", "done:denied" }, seen);
        Assert.Equal("Approve on your iPhone with Face ID, then click Yes on Windows' prompt.", AdminRunner.AskingLine);
    }
}
