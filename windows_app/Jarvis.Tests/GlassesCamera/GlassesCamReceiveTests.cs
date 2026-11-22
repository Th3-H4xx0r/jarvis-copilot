using Jarvis.Core.GlassesCamera;

namespace Jarvis.Tests.GlassesCamera;

/// The app's receive path, pure parts: the phone's VP8 pictures (I420 after decoding) into the
/// camera's 720×1280 BGRA frame, and the offer it answers.
public class GlassesCamReceiveTests
{
    private static (byte[] Y, byte[] U, byte[] V) I420(int w, int h, byte y, byte u, byte v) =>
        (Enumerable.Repeat(y, w * h).ToArray(), Enumerable.Repeat(u, (w + 1) / 2 * ((h + 1) / 2)).ToArray(), Enumerable.Repeat(v, (w + 1) / 2 * ((h + 1) / 2)).ToArray());

    private static (byte B, byte G, byte R, byte A) At(byte[] px, int w, int x, int y)
    {
        var i = (y * w + x) * 4;
        return (px[i], px[i + 1], px[i + 2], px[i + 3]);
    }

    [Fact]
    public void WhiteAndBlackComeOutWhiteAndBlack()
    {
        var (y, u, v) = I420(4, 2, 235, 128, 128);
        var dst = new byte[4 * 2 * 4];
        GlassesCamPixels.I420ToBgraFit(y, 4, u, 2, v, 2, 4, 2, dst, 4, 2, 16);
        Assert.Equal((255, 255, 255, 255), At(dst, 4, 3, 1));
        (y, u, v) = I420(4, 2, 16, 128, 128);
        GlassesCamPixels.I420ToBgraFit(y, 4, u, 2, v, 2, 4, 2, dst, 4, 2, 16);
        Assert.Equal((0, 0, 0, 255), At(dst, 4, 0, 0));
    }

    [Fact]
    public void ColoursAreBt601()
    {
        // BT.601 studio-range red (what libvpx's VP8 pictures are).
        var (y, u, v) = I420(2, 2, 81, 90, 240);
        var dst = new byte[2 * 2 * 4];
        GlassesCamPixels.I420ToBgraFit(y, 2, u, 1, v, 1, 2, 2, dst, 2, 2, 8);
        var (b, g, r, _) = At(dst, 2, 0, 0);
        Assert.InRange(r, 250, 255);
        Assert.InRange(g, 0, 5);
        Assert.InRange(b, 0, 5);
    }

    [Fact]
    public void ALandscapePictureIsBandedInThePortraitFrame()
    {
        // 8×4 grey into the 4×8 portrait frame: a centred 4×2 band, black above and below.
        var (y, u, v) = I420(8, 4, 126, 128, 128);
        var dst = new byte[4 * 8 * 4];
        GlassesCamPixels.I420ToBgraFit(y, 8, u, 4, v, 4, 8, 4, dst, 4, 8, 16);
        Assert.Equal((0, 0, 0, 255), At(dst, 4, 0, 0));
        Assert.Equal((0, 0, 0, 255), At(dst, 4, 3, 2));
        Assert.Equal(At(dst, 4, 0, 3), At(dst, 4, 3, 4));
        Assert.NotEqual((0, 0, 0, 255), At(dst, 4, 0, 3));
        Assert.Equal((0, 0, 0, 255), At(dst, 4, 0, 5));
        Assert.Equal((0, 0, 0, 255), At(dst, 4, 3, 7));
    }

    [Fact]
    public void StridesAreHonoured()
    {
        // Y rows padded to 8, chroma to 4; a 2×2 picture of distinct greys stays in place.
        var y = new byte[] { 16, 235, 0, 0, 0, 0, 0, 0, 235, 16, 0, 0, 0, 0, 0, 0 };
        var u = new byte[] { 128, 0, 0, 0 };
        var v = new byte[] { 128, 0, 0, 0 };
        var dst = new byte[2 * 2 * 4];
        GlassesCamPixels.I420ToBgraFit(y, 8, u, 4, v, 4, 2, 2, dst, 2, 2, 8);
        Assert.Equal(0, At(dst, 2, 0, 0).R);
        Assert.Equal(255, At(dst, 2, 1, 0).R);
        Assert.Equal(255, At(dst, 2, 0, 1).R);
        Assert.Equal(0, At(dst, 2, 1, 1).R);
    }

    [Fact]
    public void AHalfSizePictureIsScaledUpToFill()
    {
        var (y, u, v) = I420(360, 640, 235, 128, 128);
        var dst = new byte[720 * 1280 * 4];
        GlassesCamPixels.I420ToBgraFit(y, 360, u, 180, v, 180, 360, 640, dst, 720, 1280, 2880);
        Assert.Equal((255, 255, 255, 255), At(dst, 720, 0, 0));
        Assert.Equal((255, 255, 255, 255), At(dst, 720, 719, 1279));
    }

    [Fact]
    public void TheOfferLosesTheRotationExtension()
    {
        // Without urn:3gpp:video-orientation agreed, the phone's WebRTC turns the pixels itself, so
        // every frame arrives upright (no rotation to apply here).
        var sdp = "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=extmap:3 urn:3gpp:video-orientation\r\na=extmap:4 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\na=rtpmap:96 VP8/90000\r\n";
        var cleaned = GlassesCamSdp.ForReceiving(sdp);
        Assert.DoesNotContain("video-orientation", cleaned);
        Assert.Contains("abs-send-time", cleaned);
        Assert.Contains("a=rtpmap:96 VP8/90000\r\n", cleaned);
        Assert.Equal("v=0\nm=video 9\n", GlassesCamSdp.ForReceiving("v=0\nm=video 9\na=extmap:2 urn:3gpp:video-orientation\n"));
    }
}
