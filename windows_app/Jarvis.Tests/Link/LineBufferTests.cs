using Jarvis.Core.Link;

namespace Jarvis.Tests.Link;

public class LineBufferTests
{
    [Fact]
    public void Push_SplitsAcrossChunks()
    {
        var b = new LineBuffer();
        Assert.Single(b.Push("{\"a\":1}\n{\"b\""u8));
        var second = b.Push(":2}\n"u8);
        Assert.Equal(2, second[0]["b"]!.GetValue<int>());
    }

    [Fact]
    public void Push_SkipsBadJsonAndNonObjects() => Assert.Single(new LineBuffer().Push("nope\n[1]\n{\"ok\":true}\n"u8));

    [Fact]
    public void Push_OverMaxWithoutNewline_Throws() =>
        Assert.Throws<LineTooLongException>(() => new LineBuffer().Push(new byte[LineBuffer.MaxLine + 1]));
}
