using Jarvis.Core.Link;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Link;

public class EndpointFileTests
{
    [Fact]
    public void Read_ValidFile_ReturnsInfo()
    {
        var p = Tmp.File("{\"v\":1,\"port\":51234,\"token\":\"" + new string('a', 64) + "\",\"pid\":4242}");
        Assert.Equal(new EndpointInfo(51234, new string('a', 64), 4242), EndpointFile.Read(p));
    }

    [Theory]
    [InlineData("{\"v\":2,\"port\":51234,\"token\":\"<a64>\",\"pid\":1}")]
    [InlineData("{\"v\":1,\"port\":0,\"token\":\"<a64>\",\"pid\":1}")]
    [InlineData("{\"v\":1,\"port\":51234,\"token\":\"<A64>\",\"pid\":1}")]
    [InlineData("{\"v\":1,\"port\":51234,\"token\":\"<a63>\",\"pid\":1}")]
    [InlineData("not json")]
    public void Read_Invalid_ReturnsNull(string body) => Assert.Null(EndpointFile.Read(Tmp.File(Tmp.Expand(body))));

    [Fact]
    public void Read_Missing_ReturnsNull() => Assert.Null(EndpointFile.Read(@"C:\nope\ui.sock"));

    [Fact]
    public void DefaultPath_IsUnderProfile() =>
        Assert.Equal(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".jarviscopilot-client", "ui.sock"), EndpointFile.DefaultPath);
}
